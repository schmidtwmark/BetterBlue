#!/usr/bin/env node
//
// dashboard.js
//
// Operational snapshot of the BetterBlue Live Activity backend.
//
// Calls the AWS CLI directly (not the Node SDK) so it works with
// whatever auth flavor your CLI is set up for — `aws login`,
// `aws sso login`, IAM access keys, SSO, instance roles, all of it.
// The CLI is the source of truth for credentials; we just shell out
// and parse the JSON output.
//
// Usage:
//   node dashboard.js                # defaults: --stage dev, --days 30
//   node dashboard.js --stage prod
//   node dashboard.js --stage prod --days 7
//
// Requires: AWS CLI v2 installed and authenticated. If a section
// errors with "AccessDenied", attach `ReadOnlyAccess` to your role
// or the targeted permissions printed by `node dashboard.js --help`.
//

const { execFileSync } = require('child_process');

// ---------------------------------------------------------------------------
// CLI parsing
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const args = { stage: 'dev', days: 30 };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--help' || a === '-h') { args.help = true; }
    else if (a === '--stage') { args.stage = argv[++i]; }
    else if (a === '--days') { args.days = parseInt(argv[++i], 10); }
    else if (a === '--region') { args.region = argv[++i]; }
    else { console.error(`Unknown arg: ${a}`); process.exit(2); }
  }
  return args;
}

const argv = parseArgs(process.argv);
if (argv.help) {
  console.log(`Usage: node dashboard.js [--stage dev|prod] [--days N] [--region us-east-1]

Required IAM (least-privilege):
  - dynamodb:Scan         on the WakeUp table
  - cloudwatch:GetMetricStatistics
  - ce:GetCostAndUsage    (Cost Explorer must be enabled in the account)

Auth: uses your AWS CLI's default credentials. Run \`aws login\` (or
\`aws sso login\`) first if your session is expired.
`);
  process.exit(0);
}

const STAGE = argv.stage;
const REGION = argv.region || 'us-east-1';
const DAYS = argv.days;
const TABLE_NAME = `betterblue-wakeup-schedules-${STAGE}`;
const FUNCTIONS = {
  register: `betterblue-live-activity-${STAGE}-registerWakeUp`,
  unregister: `betterblue-live-activity-${STAGE}-unregisterWakeUp`,
  send: `betterblue-live-activity-${STAGE}-sendWakeUps`,
};

// ---------------------------------------------------------------------------
// AWS CLI shell helper
// ---------------------------------------------------------------------------

/**
 * Run `aws <args>` and return the parsed JSON stdout.
 *
 * Throws an Error with a cleaned-up message on failure (the raw stderr
 * from the CLI is verbose; we extract the relevant line). Callers
 * catch per-section so one failed call doesn't kill the whole report.
 */
function aws(args, { region = REGION } = {}) {
  const fullArgs = [...args, '--region', region, '--output', 'json'];
  try {
    const out = execFileSync('aws', fullArgs, {
      stdio: ['ignore', 'pipe', 'pipe'],
      encoding: 'utf8',
      maxBuffer: 32 * 1024 * 1024, // DynamoDB scans can be large
    });
    return out.trim() ? JSON.parse(out) : {};
  } catch (e) {
    // execFileSync stuffs the CLI's stderr onto e.stderr. Pull the
    // most informative line out so the section row stays readable.
    const stderr = (e.stderr || '').toString();
    const firstUseful = stderr
      .split('\n')
      .map((l) => l.trim())
      .find((l) => l && !l.startsWith('usage:')) || e.message;
    const err = new Error(firstUseful);
    err.original = e;
    throw err;
  }
}

// Quick sanity probe: confirm the CLI itself can authenticate before we
// fan out to N sections that would each report the same auth error.
function checkAuth() {
  try {
    const id = aws(['sts', 'get-caller-identity']);
    return { ok: true, account: id.Account, arn: id.Arn };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

// ---------------------------------------------------------------------------
// Output helpers — ANSI without pulling chalk in
// ---------------------------------------------------------------------------

const c = {
  reset: '\x1b[0m', dim: '\x1b[2m', bold: '\x1b[1m',
  red: '\x1b[31m', green: '\x1b[32m', yellow: '\x1b[33m',
  blue: '\x1b[34m', magenta: '\x1b[35m', cyan: '\x1b[36m', gray: '\x1b[90m',
};

function printHeader(title) {
  const line = '─'.repeat(Math.max(0, 64 - title.length - 2));
  console.log(`\n${c.bold}${c.cyan}┌─ ${title} ${line}${c.reset}`);
}

function printRow(label, value, opts = {}) {
  const padded = label.padEnd(34, ' ');
  const colored = opts.color ? `${opts.color}${value}${c.reset}` : value;
  console.log(`│ ${padded}${colored}`);
}

function printNote(text) {
  console.log(`│ ${c.dim}${text}${c.reset}`);
}

function printFooter() {
  console.log(`└${'─'.repeat(64)}`);
}

function fmtCount(n) { return n.toLocaleString('en-US'); }
function fmtUSD(n) { return `$${n.toFixed(2)}`; }
function fmtDuration(ms) {
  const m = Math.floor(ms / 60000);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ${m % 60}m`;
  const d = Math.floor(h / 24);
  return `${d}d ${h % 24}h`;
}

// ---------------------------------------------------------------------------
// Section: Active registrations
// ---------------------------------------------------------------------------

function reportActive() {
  printHeader(`Active Live Activities · ${TABLE_NAME}`);
  let items = [];
  try {
    let lastKey;
    do {
      const args = ['dynamodb', 'scan', '--table-name', TABLE_NAME];
      if (lastKey) {
        args.push('--starting-token', JSON.stringify(lastKey));
      }
      const page = aws(args);
      items = items.concat(page.Items || []);
      lastKey = page.LastEvaluatedKey;
    } while (lastKey);
  } catch (e) {
    printRow('Status', `unavailable: ${e.message}`, { color: c.red });
    printFooter();
    return;
  }

  // CLI scan returns DynamoDB attribute-typed values like { S: "...", N: "..." }
  // — unwrap into plain JS values for the rest of the report.
  const unwrap = (attr) => {
    if (attr === undefined) return undefined;
    if (attr.S !== undefined) return attr.S;
    if (attr.N !== undefined) return Number(attr.N);
    if (attr.BOOL !== undefined) return attr.BOOL;
    if (attr.NULL !== undefined) return null;
    return attr; // M, L, etc. — not used by this table
  };
  const rows = items.map((item) => {
    const out = {};
    for (const [k, v] of Object.entries(item)) out[k] = unwrap(v);
    return out;
  });

  const now = Date.now();
  const active = rows.filter((r) => r.status === 'active');

  // Group by activityType
  const byType = active.reduce((acc, r) => {
    const t = r.activityType || 'unknown';
    acc[t] = (acc[t] || 0) + 1;
    return acc;
  }, {});

  // Age buckets
  const buckets = { '<5m': 0, '5–30m': 0, '30m–2h': 0, '2–8h': 0 };
  for (const r of active) {
    const ageMin = (now - r.startTime) / 60000;
    if (ageMin < 5) buckets['<5m']++;
    else if (ageMin < 30) buckets['5–30m']++;
    else if (ageMin < 120) buckets['30m–2h']++;
    else buckets['2–8h']++;
  }

  // Wakeup count distribution
  const wakeupCounts = active.map((r) => r.wakeupCount || 0).sort((a, b) => b - a);
  const totalWakeups = wakeupCounts.reduce((a, b) => a + b, 0);
  const top5 = wakeupCounts.slice(0, 5);

  printRow('Total active registrations', fmtCount(active.length), { color: active.length > 0 ? c.green : c.dim });
  printRow('All rows in table', fmtCount(rows.length));
  printNote('"Active" = status === \'active\'; non-active rows are stragglers.');
  console.log('│');
  printRow('By activity type', '');
  for (const [k, v] of Object.entries(byType).sort((a, b) => b[1] - a[1])) {
    printRow(`  ${k}`, fmtCount(v));
  }
  console.log('│');
  printRow('By age', '');
  for (const [k, v] of Object.entries(buckets)) {
    printRow(`  ${k}`, fmtCount(v));
  }
  console.log('│');
  printRow('Wakeups sent (lifetime)', fmtCount(totalWakeups));
  if (top5.length > 0) {
    printRow('Top 5 wakeup counts', top5.map(fmtCount).join(', '));
  }
  if (active.length > 0) {
    const oldest = active.reduce((a, b) => a.startTime < b.startTime ? a : b);
    printRow('Oldest registration', `${fmtDuration(now - oldest.startTime)} (type: ${oldest.activityType || 'unknown'})`);
  }
  printFooter();
}

// ---------------------------------------------------------------------------
// CloudWatch metric helper
// ---------------------------------------------------------------------------

function isoUTC(d) { return d.toISOString().replace(/\.\d+Z$/, 'Z'); }

function getMetricSum({ functionName, metric, periodHours }) {
  const end = new Date();
  const start = new Date(end.getTime() - periodHours * 3600_000);
  // CloudWatch caps datapoint count at 1440 per call; pick a Period
  // that keeps us comfortably under that.
  const period = periodHours <= 6 ? 60
    : periodHours <= 24 ? 300
    : periodHours <= 168 ? 3600
    : 21600;
  const res = aws([
    'cloudwatch', 'get-metric-statistics',
    '--namespace', 'AWS/Lambda',
    '--metric-name', metric,
    '--dimensions', `Name=FunctionName,Value=${functionName}`,
    '--start-time', isoUTC(start),
    '--end-time', isoUTC(end),
    '--period', String(period),
    '--statistics', 'Sum',
  ]);
  return (res.Datapoints || []).reduce((a, p) => a + (p.Sum || 0), 0);
}

// ---------------------------------------------------------------------------
// Section: Throughput & error rates
// ---------------------------------------------------------------------------

function reportLambdaMetrics() {
  printHeader('Lambda Throughput & Errors (CloudWatch)');

  const windows = [
    { label: '24h', hours: 24 },
    { label: '7d', hours: 24 * 7 },
    { label: '30d', hours: 24 * 30 },
  ];

  const fnLabels = {
    register: 'Sessions started   (registerWakeUp)',
    unregister: 'Sessions ended     (unregisterWakeUp)',
    send: 'Wakeup runs        (sendWakeUps × 1/min)',
  };

  for (const [key, fnName] of Object.entries(FUNCTIONS)) {
    printRow(fnLabels[key], '');
    for (const w of windows) {
      try {
        const invocations = getMetricSum({ functionName: fnName, metric: 'Invocations', periodHours: w.hours });
        const errors = getMetricSum({ functionName: fnName, metric: 'Errors', periodHours: w.hours });
        const pct = invocations > 0 ? (errors / invocations) * 100 : 0;
        const errColor = pct >= 5 ? c.red : pct >= 1 ? c.yellow : c.green;
        const errPart = errors > 0
          ? `${errColor}${fmtCount(errors)} err (${pct.toFixed(2)}%)${c.reset}`
          : `${c.dim}0 err${c.reset}`;
        printRow(`  ${w.label}`, `${fmtCount(invocations)} invocations · ${errPart}`);
      } catch (e) {
        printRow(`  ${w.label}`, `unavailable: ${e.message}`, { color: c.red });
      }
    }
    console.log('│');
  }
  printNote('Error % flagged: green <1%, yellow 1–5%, red ≥5%.');
  printFooter();
}

// ---------------------------------------------------------------------------
// Section: AWS spend (Cost Explorer)
// ---------------------------------------------------------------------------

function isoDate(d) { return d.toISOString().slice(0, 10); }

function reportCosts() {
  printHeader(`AWS Spend · last ${DAYS} days (Cost Explorer)`);

  const end = new Date();
  const start = new Date(end.getTime() - DAYS * 86400_000);

  let result;
  try {
    result = aws([
      'ce', 'get-cost-and-usage',
      '--time-period', `Start=${isoDate(start)},End=${isoDate(end)}`,
      '--granularity', 'MONTHLY',
      '--metrics', 'UnblendedCost',
      '--group-by', 'Type=DIMENSION,Key=SERVICE',
    ], { region: 'us-east-1' });
  } catch (e) {
    printRow('Status', `unavailable: ${e.message}`, { color: c.red });
    printNote('Cost Explorer must be enabled in the AWS console (Billing → Cost Explorer → Enable).');
    printNote('Each Cost Explorer query also costs ~$0.01.');
    printFooter();
    return;
  }

  // Aggregate across months for the period total + per-service breakdown
  // sorted high→low so it's easy to see what's expensive.
  const totals = {};
  let grand = 0;
  for (const period of result.ResultsByTime || []) {
    for (const g of period.Groups || []) {
      const svc = g.Keys[0];
      const amt = parseFloat(g.Metrics.UnblendedCost.Amount);
      totals[svc] = (totals[svc] || 0) + amt;
      grand += amt;
    }
  }
  const sorted = Object.entries(totals).sort((a, b) => b[1] - a[1]);

  printRow('Period total', fmtUSD(grand), { color: grand > 5 ? c.yellow : c.green });
  console.log('│');
  printRow('By service', '');
  const nonzero = sorted.filter(([, v]) => v >= 0.01);
  if (nonzero.length === 0) {
    printRow('  (no charges over $0.01)', '');
  } else {
    for (const [svc, amt] of nonzero) {
      const pct = grand > 0 ? ((amt / grand) * 100).toFixed(0) : '0';
      printRow(`  ${svc}`, `${fmtUSD(amt)}  ${c.dim}(${pct}%)${c.reset}`);
    }
  }
  printNote(`Account-wide spend, not isolated to this app — but the backend uses DynamoDB / Lambda / CloudWatch / SSM.`);
  printFooter();
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

(() => {
  console.log(`${c.bold}BetterBlue Live Activity Dashboard${c.reset}`);
  console.log(`${c.dim}stage=${STAGE}  region=${REGION}  ${new Date().toISOString()}${c.reset}`);

  // Bail early on auth failure with a single clear message rather than
  // letting every section repeat the same error.
  const auth = checkAuth();
  if (!auth.ok) {
    console.error(`\n${c.red}AWS CLI is not authenticated:${c.reset} ${auth.error}`);
    console.error(`${c.dim}Try: aws login   (or aws sso login)${c.reset}\n`);
    process.exit(1);
  }
  console.log(`${c.dim}account=${auth.account}${c.reset}`);

  reportActive();
  reportLambdaMetrics();
  reportCosts();

  console.log('');
})();
