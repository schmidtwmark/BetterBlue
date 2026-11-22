const AWS = require('aws-sdk');
const apn = require('@parse/node-apn');
const dynamodb = new AWS.DynamoDB.DocumentClient();

const TABLE_NAME = process.env.TABLE_NAME || 'betterblue-wakeup-schedules-v4';

// APNs configuration from environment
const APNS_KEY_ID = process.env.APNS_KEY_ID;
const APNS_TEAM_ID = process.env.APNS_TEAM_ID;
const APNS_KEY = process.env.APNS_KEY;
const APNS_BUNDLE_ID = process.env.APNS_BUNDLE_ID || 'com.markschmidt.BetterBlue';
const APNS_ENVIRONMENT = process.env.APNS_ENVIRONMENT || 'development';

let apnProvider = null;

// Initialize APNs provider (reused across Lambda invocations)
function getAPNsProvider() {
    if (!apnProvider) {
        if (!APNS_KEY || !APNS_KEY_ID || !APNS_TEAM_ID) {
            console.warn('⚠️ APNs credentials not configured');
            return null;
        }

        apnProvider = new apn.Provider({
            token: {
                key: APNS_KEY,
                keyId: APNS_KEY_ID,
                teamId: APNS_TEAM_ID
            },
            production: APNS_ENVIRONMENT === 'production'
        });

        console.log(`✅ APNs provider initialized (${APNS_ENVIRONMENT} mode)`);
    }
    return apnProvider;
}

// Wakeup intervals in minutes by activity type. Anything not listed
// here is rejected at registration time (see registerWakeUp). Climate
// was a testing-only path and is no longer accepted server-side.
const WAKEUP_INTERVALS = {
    'debug': 1,      // 1 minute for debug
    'charging': 5,   // 5 minutes for charging
};
const SUPPORTED_ACTIVITY_TYPES = new Set(Object.keys(WAKEUP_INTERVALS));

// Registrations expire this long after their wakeups begin.
const REGISTRATION_LIFETIME_MINUTES = 480;
// A delayed start (a car waiting on its charging schedule) can be at
// most this far out.
const MAX_START_DELAY_MS = 24 * 60 * 60 * 1000;

// Nightly charge check rows share the table, keyed apart from wakeup
// rows so one device can have both.
const NIGHTLY_PREFIX = 'nightly#';
// Attempts per night: at the set time, then every 10 minutes until the
// app answers (a car still waiting on its schedule gets another look).
const NIGHTLY_ATTEMPTS = 3;
const NIGHTLY_ATTEMPT_SPACING_MINUTES = 10;

const CORS_HEADERS = { 'Access-Control-Allow-Origin': '*' };

function respond(statusCode, body) {
    return { statusCode, headers: CORS_HEADERS, body: JSON.stringify(body) };
}

// MARK: - Nightly timing (pure, exported for tests)

/** The wall clock in `timeZone` at `now`: { date: 'YYYY-MM-DD', minutes }. */
function localClock(now, timeZone) {
    const parts = Object.fromEntries(
        new Intl.DateTimeFormat('en-CA', {
            timeZone,
            year: 'numeric', month: '2-digit', day: '2-digit',
            hour: '2-digit', minute: '2-digit', hourCycle: 'h23'
        }).formatToParts(new Date(now)).map((p) => [p.type, p.value])
    );
    return {
        date: `${parts.year}-${parts.month}-${parts.day}`,
        minutes: Number(parts.hour) * 60 + Number(parts.minute)
    };
}

function previousDate(dateString) {
    const date = new Date(`${dateString}T12:00:00Z`);
    date.setUTCDate(date.getUTCDate() - 1);
    return date.toISOString().slice(0, 10);
}

function parseClockTime(time) {
    const match = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(time || '');
    return match ? Number(match[1]) * 60 + Number(match[2]) : null;
}

function isValidTimeZone(timeZone) {
    try {
        new Intl.DateTimeFormat('en-US', { timeZone });
        return typeof timeZone === 'string' && timeZone.length > 0;
    } catch {
        return false;
    }
}

/**
 * The night a check belongs to: the local date its set time last came
 * round on. A 23:35 check answered at 00:10 still belongs to the
 * previous date.
 */
function nightKey(row, now) {
    const target = parseClockTime(row.time);
    const { date, minutes } = localClock(now, row.timeZone);
    return minutes >= target ? date : previousDate(date);
}

/**
 * Whether a nightly row is due a push now, and which attempt it is:
 * { night, attempt } or null. Attempts run at the set time and every
 * NIGHTLY_ATTEMPT_SPACING_MINUTES after, until the app acknowledges the
 * night or NIGHTLY_ATTEMPTS are used up.
 */
function nightlyAttemptDue(row, now) {
    const target = parseClockTime(row.time);
    if (target === null || !isValidTimeZone(row.timeZone)) return null;
    const { minutes } = localClock(now, row.timeZone);
    const night = nightKey(row, now);
    if (row.ackedNight === night) return null;
    const sinceTarget = (minutes - target + 1440) % 1440;
    const attempt = Math.floor(sinceTarget / NIGHTLY_ATTEMPT_SPACING_MINUTES);
    if (attempt >= NIGHTLY_ATTEMPTS) return null;
    const lastAttempt = row.lastNight === night ? (row.lastAttempt ?? -1) : -1;
    if (attempt <= lastAttempt) return null;
    return { night, attempt };
}

exports._test = { localClock, previousDate, parseClockTime, nightKey, nightlyAttemptDue };

// API Handler: Register device for wakeup pushes
exports.registerWakeUp = async (event) => {
    try {
        const body = JSON.parse(event.body);
        const { pushToken, activityType, startAt } = body;

        if (!pushToken) {
            return {
                statusCode: 400,
                headers: { 'Access-Control-Allow-Origin': '*' },
                body: JSON.stringify({ error: 'Missing pushToken' })
            };
        }

        // Default to 'charging' for legacy clients that don't send the
        // type. Reject anything else not in our supported set so that
        // stale / experimental types (e.g. 'climate') can't take up
        // backend slots.
        const resolvedType = activityType || 'charging';
        if (!SUPPORTED_ACTIVITY_TYPES.has(resolvedType)) {
            console.warn(`⚠️ Rejected register: unsupported activityType "${resolvedType}"`);
            return {
                statusCode: 400,
                headers: { 'Access-Control-Allow-Origin': '*' },
                body: JSON.stringify({
                    error: `Unsupported activityType: ${resolvedType}`,
                    supported: Array.from(SUPPORTED_ACTIVITY_TYPES)
                })
            };
        }

        // A car waiting on its charging schedule needs no wakeups until
        // the charge is due; `startAt` (ms) holds them until then.
        const now = Date.now();
        const delayedStart = Number.isFinite(startAt) && startAt > now && startAt - now <= MAX_START_DELAY_MS
            ? Math.floor(startAt)
            : 0;

        // Store the push token with activity type for interval-based wakeups
        await dynamodb.put({
            TableName: TABLE_NAME,
            Item: {
                pushToken: pushToken,
                activityType: resolvedType,
                startTime: now,
                startAt: delayedStart,
                lastPushTime: 0,
                wakeupCount: 0,
                status: 'active'
            }
        }).promise();

        const interval = WAKEUP_INTERVALS[resolvedType];
        const delay = delayedStart ? `, starting in ${Math.round((delayedStart - now) / 60000)}min` : '';
        console.log(`✅ Registered device for wakeup pushes: ${pushToken.substring(0, 20)}... (type: ${resolvedType}, interval: ${interval}min${delay})`);

        return {
            statusCode: 200,
            headers: { 'Access-Control-Allow-Origin': '*' },
            body: JSON.stringify({ success: true })
        };
    } catch (error) {
        console.error('❌ Error in registerWakeUp:', error);
        return {
            statusCode: 500,
            headers: { 'Access-Control-Allow-Origin': '*' },
            body: JSON.stringify({ error: error.message })
        };
    }
};

// API Handler: Unregister wakeup
exports.unregisterWakeUp = async (event) => {
    try {
        const body = JSON.parse(event.body);
        const { pushToken } = body;

        if (!pushToken) {
            return {
                statusCode: 400,
                headers: { 'Access-Control-Allow-Origin': '*' },
                body: JSON.stringify({ error: 'Missing pushToken' })
            };
        }

        await dynamodb.delete({
            TableName: TABLE_NAME,
            Key: { pushToken: pushToken }
        }).promise();

        console.log(`✅ Unregistered device: ${pushToken.substring(0, 20)}...`);

        return {
            statusCode: 200,
            headers: { 'Access-Control-Allow-Origin': '*' },
            body: JSON.stringify({ success: true })
        };
    } catch (error) {
        console.error('❌ Error in unregisterWakeUp:', error);
        return {
            statusCode: 500,
            headers: { 'Access-Control-Allow-Origin': '*' },
            body: JSON.stringify({ error: error.message })
        };
    }
};

// Scheduled Handler: Send background wakeup pushes (runs every minute)
exports.sendWakeUps = async () => {
    try {
        const provider = getAPNsProvider();
        if (!provider) {
            console.error('❌ APNs not configured');
            return { statusCode: 500, body: 'APNs not configured' };
        }

        const now = Date.now();

        // Wakeup registrations and nightly checks share the table.
        const scan = await dynamodb.scan({ TableName: TABLE_NAME }).promise();
        const result = { Items: scan.Items.filter((item) => item.status === 'active' && item.kind !== 'nightly') };
        const nightlyRows = scan.Items.filter((item) => item.kind === 'nightly');

        // Per-invocation device count is the only steady-state log we
        // keep — useful for trend graphs, ~1.4k lines/day. The
        // per-device "wakeup #N sent" line was the bulk of CloudWatch
        // spend; we now only log on failures or expirations.
        let sentCount = 0;
        let skippedCount = 0;
        let removedCount = 0;

        const promises = result.Items.map(async (registration) => {
            const tokenShort = registration.pushToken.substring(0, 8);
            const activityType = registration.activityType || 'charging';
            // Fallback to 5 min for any legacy / now-rejected type still
            // sitting in the table — they'll auto-expire at 8h.
            const intervalMinutes = WAKEUP_INTERVALS[activityType] || 5;

            try {
                // Wakeups begin at `startAt` when the app delayed them
                // (a car waiting on its schedule), else at registration.
                const activeSince = Math.max(registration.startTime, registration.startAt || 0);
                if (now < activeSince) {
                    skippedCount++;
                    return;
                }
                const minutesSinceStart = (now - activeSince) / (1000 * 60);
                const minutesSinceLastPush = (now - (registration.lastPushTime || 0)) / (1000 * 60);

                // Auto-expire after 8 hours of wakeups
                if (minutesSinceStart > REGISTRATION_LIFETIME_MINUTES) {
                    await dynamodb.delete({
                        TableName: TABLE_NAME,
                        Key: { pushToken: registration.pushToken }
                    }).promise();
                    removedCount++;
                    return;
                }

                // Check if enough time has passed based on activity type interval
                if (registration.lastPushTime && minutesSinceLastPush < intervalMinutes) {
                    // Skip this device - not time yet
                    skippedCount++;
                    return;
                }

                // Create a background push notification to wake the app
                const notification = new apn.Notification();
                notification.topic = APNS_BUNDLE_ID;
                notification.pushType = 'background';
                notification.priority = 5; // Must be 5 for background pushes
                notification.expiry = Math.floor(now / 1000) + 60; // 1 min expiry
                notification.contentAvailable = true;
                notification.payload = {
                    liveActivityWakeup: true
                };

                // Send to APNs using the device push token
                const apnsResult = await provider.send(notification, registration.pushToken);

                if (apnsResult.sent.length > 0) {
                    const newCount = (registration.wakeupCount || 0) + 1;
                    await dynamodb.update({
                        TableName: TABLE_NAME,
                        Key: { pushToken: registration.pushToken },
                        UpdateExpression: 'SET lastPushTime = :now, wakeupCount = :count',
                        ExpressionAttributeValues: { ':now': now, ':count': newCount }
                    }).promise();
                    sentCount++;
                }

                if (apnsResult.failed.length > 0) {
                    const failure = apnsResult.failed[0];
                    console.error(`❌ APNs error for ${tokenShort}: ${failure.status} - ${failure.response?.reason}`);

                    // Remove invalid tokens
                    if (failure.status === '410' ||
                        failure.response?.reason === 'Unregistered' ||
                        failure.response?.reason === 'BadDeviceToken' ||
                        failure.response?.reason === 'ExpiredToken') {
                        await dynamodb.delete({
                            TableName: TABLE_NAME,
                            Key: { pushToken: registration.pushToken }
                        }).promise();
                        console.log(`🗑️ Removed invalid token ${tokenShort}`);
                    }
                }

            } catch (error) {
                console.error(`❌ Error processing ${tokenShort}:`, error);
            }
        });

        await Promise.all(promises);

        const nightlySent = await sendNightlyChecks(provider, nightlyRows, now);

        // Single aggregated line per cron tick — gives steady-state
        // visibility without the per-device fanout that was driving
        // CloudWatch costs to 89% of total spend.
        console.log(`📋 ${result.Items.length} active · sent ${sentCount} · skipped ${skippedCount} · expired ${removedCount} · nightly ${nightlySent}/${nightlyRows.length}`);

        return { statusCode: 200, body: `Sent wakeups to ${sentCount}/${result.Items.length} devices` };
    } catch (error) {
        console.error('❌ Error in sendWakeUps:', error);
        return { statusCode: 500, body: error.message };
    }
};

// MARK: - Nightly charge check

/** Sends the nightly checks that are due. Returns how many went out. */
async function sendNightlyChecks(provider, rows, now) {
    let sent = 0;
    await Promise.all(rows.map(async (row) => {
        const due = nightlyAttemptDue(row, now);
        if (!due) return;
        const tokenShort = row.deviceToken.substring(0, 8);
        try {
            const notification = new apn.Notification();
            notification.topic = APNS_BUNDLE_ID;
            notification.pushType = 'background';
            notification.priority = 5; // Must be 5 for background pushes
            notification.expiry = Math.floor(now / 1000) + 5 * 60;
            notification.contentAvailable = true;
            notification.payload = { nightlyChargeCheck: true };

            const apnsResult = await provider.send(notification, row.deviceToken);
            if (apnsResult.sent.length > 0) {
                sent++;
                await dynamodb.update({
                    TableName: TABLE_NAME,
                    Key: { pushToken: row.pushToken },
                    UpdateExpression: 'SET lastNight = :night, lastAttempt = :attempt',
                    ExpressionAttributeValues: { ':night': due.night, ':attempt': due.attempt }
                }).promise();
                console.log(`🌙 ${tokenShort}: nightly check ${due.night} attempt ${due.attempt + 1}`);
            }
            if (apnsResult.failed.length > 0) {
                const failure = apnsResult.failed[0];
                console.error(`❌ Nightly APNs error for ${tokenShort}: ${failure.status} - ${failure.response?.reason}`);
                if (failure.status === '410' ||
                    failure.response?.reason === 'Unregistered' ||
                    failure.response?.reason === 'BadDeviceToken') {
                    await dynamodb.delete({ TableName: TABLE_NAME, Key: { pushToken: row.pushToken } }).promise();
                    console.log(`🗑️ Removed nightly check for invalid token ${tokenShort}`);
                }
            }
        } catch (error) {
            console.error(`❌ Error sending nightly check to ${tokenShort}:`, error);
        }
    }));
    return sent;
}

// API Handler: Register (or re-time) a device's nightly charge check.
// Stores only the device token, a local time, and its time zone.
exports.registerNightly = async (event) => {
    try {
        const { pushToken, time, timeZone } = JSON.parse(event.body || '{}');
        if (!pushToken || parseClockTime(time) === null || !isValidTimeZone(timeZone)) {
            return respond(400, { error: 'Expected pushToken, time (HH:mm), and a valid timeZone' });
        }
        await dynamodb.put({
            TableName: TABLE_NAME,
            Item: {
                pushToken: NIGHTLY_PREFIX + pushToken,
                kind: 'nightly',
                status: 'nightly',
                deviceToken: pushToken,
                time,
                timeZone,
                createdAt: Date.now()
            }
        }).promise();
        console.log(`🌙 Nightly check for ${pushToken.substring(0, 8)} at ${time} ${timeZone}`);
        return respond(200, { success: true });
    } catch (error) {
        console.error('❌ Error in registerNightly:', error);
        return respond(500, { error: error.message });
    }
};

exports.unregisterNightly = async (event) => {
    try {
        const { pushToken } = JSON.parse(event.body || '{}');
        if (!pushToken) return respond(400, { error: 'Missing pushToken' });
        await dynamodb.delete({ TableName: TABLE_NAME, Key: { pushToken: NIGHTLY_PREFIX + pushToken } }).promise();
        console.log(`🌙 Nightly check removed for ${pushToken.substring(0, 8)}`);
        return respond(200, { success: true });
    } catch (error) {
        console.error('❌ Error in unregisterNightly:', error);
        return respond(500, { error: error.message });
    }
};

// API Handler: The app looked and has an answer for tonight (charging,
// not charging), so no more attempts until tomorrow.
exports.ackNightly = async (event) => {
    try {
        const { pushToken, outcome } = JSON.parse(event.body || '{}');
        if (!pushToken) return respond(400, { error: 'Missing pushToken' });
        const key = { pushToken: NIGHTLY_PREFIX + pushToken };
        const { Item: row } = await dynamodb.get({ TableName: TABLE_NAME, Key: key }).promise();
        if (!row) return respond(404, { error: 'No nightly check registered' });
        const night = nightKey(row, Date.now());
        await dynamodb.update({
            TableName: TABLE_NAME,
            Key: key,
            UpdateExpression: 'SET ackedNight = :night, lastOutcome = :outcome',
            ExpressionAttributeValues: { ':night': night, ':outcome': String(outcome || 'unknown').slice(0, 32) }
        }).promise();
        console.log(`🌙 ${pushToken.substring(0, 8)} answered ${night}: ${outcome}`);
        return respond(200, { success: true });
    } catch (error) {
        console.error('❌ Error in ackNightly:', error);
        return respond(500, { error: error.message });
    }
};

// MARK: - Push-to-start relay

// APNs caps Live Activity payloads at 4 KB.
const MAX_LIVE_ACTIVITY_PAYLOAD_BYTES = 4096;

// API Handler: Start a Live Activity on the phone with a push — the only
// way a backgrounded app can get one started. The app sends the
// attributes and content state; it sends stand-ins that identify
// nothing, and fills the card in once it appears. Nothing is stored.
exports.startLiveActivity = async (event) => {
    try {
        const { pushToStartToken, attributes, contentState, alert, staleDate } = JSON.parse(event.body || '{}');
        if (typeof pushToStartToken !== 'string' || !/^[0-9a-f]{32,400}$/i.test(pushToStartToken) ||
            typeof attributes !== 'object' || typeof contentState !== 'object') {
            return respond(400, { error: 'Expected pushToStartToken, attributes, and contentState' });
        }
        const provider = getAPNsProvider();
        if (!provider) return respond(500, { error: 'APNs not configured' });

        const now = Math.floor(Date.now() / 1000);
        const aps = {
            timestamp: now,
            event: 'start',
            'attributes-type': 'VehicleActivityAttributes',
            attributes,
            'content-state': contentState,
            alert: {
                title: String(alert?.title || 'Charging Started').slice(0, 64),
                body: String(alert?.body || '').slice(0, 128)
            }
        };
        if (Number.isFinite(staleDate) && staleDate > now) aps['stale-date'] = Math.floor(staleDate);

        const notification = new apn.Notification();
        notification.topic = `${APNS_BUNDLE_ID}.push-type.liveactivity`;
        notification.pushType = 'liveactivity';
        notification.priority = 10;
        notification.expiry = now + 5 * 60;
        notification.rawPayload = { aps };
        if (notification.length() > MAX_LIVE_ACTIVITY_PAYLOAD_BYTES) {
            return respond(413, { error: 'Payload too large' });
        }

        const result = await provider.send(notification, pushToStartToken);
        if (result.sent.length > 0) {
            console.log(`🚀 Push-to-start sent to ${pushToStartToken.substring(0, 8)}`);
            return respond(200, { success: true });
        }
        const failure = result.failed[0];
        console.error(`❌ Push-to-start failed for ${pushToStartToken.substring(0, 8)}: ${failure?.status} - ${failure?.response?.reason}`);
        return respond(502, { error: failure?.response?.reason || 'APNs rejected the push' });
    } catch (error) {
        console.error('❌ Error in startLiveActivity:', error);
        return respond(500, { error: error.message });
    }
};
