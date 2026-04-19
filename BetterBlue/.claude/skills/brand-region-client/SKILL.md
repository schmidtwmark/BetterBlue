---
name: brand-region-client
description: Add a new brand/region client to BetterBlueKit, or fix errors in an existing one. Use when the user asks to "add Kia Canada", "implement Hyundai Australia", "fix the European client", or similar. The skill gathers an API reference (open-source implementation or user-captured proxy logs), writes the client following the repo's four-file layout (+Commands / +Parsing / main / registration), and then iterates by running `swift run bbcli ...` — fixing each error against the reference until every menu action passes.
tools: Read, Write, Edit, Glob, Grep, Bash, WebFetch, WebSearch, AskUserQuestion
---

# Brand / Region Client Builder

Builds or fixes a `BetterBlueKit` API client for one `(Brand, Region)` pair. The hard part isn't Swift, it's figuring out the region's undocumented API — so every step is anchored to either an open-source reference or user-captured proxy logs.

Before starting, read [docs/AddingNewRegion.md](../../../BetterBlueKit/docs/AddingNewRegion.md) end-to-end. That guide is the rulebook; this skill is the execution playbook.

## Phase 0 — Confirm scope

Ask the user (via `AskUserQuestion`):

1. **Brand and region** — e.g. "Kia Canada".
2. **New client or fix?** — greenfield implementation vs. patching an existing one. If patching, ask which `bbcli` command is failing and with what error.
3. **Test credentials** — do they have an account they can log in with? Tests against live accounts are how we validate each step.

Do NOT proceed past this phase without explicit answers. Guessing the brand or region silently rewires the factory.

## Phase 1 — Find an authoritative reference

A wrong reference wastes hours. Check in this order:

1. **hyundai_kia_connect_api** (Python) — the broadest coverage, especially for non-USA regions. Fetch the region's module and the shared `vehicle.py` / `api_impl.py` with `WebFetch`:
   - `https://raw.githubusercontent.com/Hyundai-Kia-Connect/hyundai_kia_connect_api/master/hyundai_kia_connect_api/`
2. **bluelinky** (TypeScript) — better for USA+EU. Endpoints live under `src/controllers/`.
3. **kia_uvo / bluelink_api** — older Python forks; useful when the two above disagree.

For each reference, record:
- Base URL / host
- Login endpoint + body shape
- Auth token header name (`Authorization` vs. `accessToken` vs. `Access-Token` — these differ per region)
- Vehicle list endpoint
- Vehicle status endpoint (and whether cached/real-time live at the same URL or different URLs)
- Command endpoints for: lock, unlock, start climate, stop climate, start charge, stop charge

If NO reference covers this region (e.g. Kia Australia), skip to Phase 1b.

### Phase 1b — User-captured proxy logs

Ask the user to capture traffic from the official app using Proxyman / mitmproxy / Charles. The [AddingNewRegion guide](../../../BetterBlueKit/docs/AddingNewRegion.md#capturing-proxy-logs-yourself) has the step-by-step. Request, at minimum:

- Login (one request)
- Vehicle list (one request)
- Vehicle status (refreshed once so both endpoints hit if they differ)
- Lock + unlock (one each)
- Start climate with a known temperature

Have them export to a file and share the path. Then use `Read` on each to study request/response pairs. Treat every token and cookie as sensitive — never paste raw captures into code or commit them.

## Phase 2 — Pick the reference client to copy

Match the new region against an existing `BetterBlueKit` client with the closest auth model. The right starting point saves the most work:

| If the new region uses... | Copy the layout of |
|---------------------------|--------------------|
| Header-based access token, no MFA | `HyundaiUSA` |
| Cloudflare cookie + per-command PIN | `HyundaiCanada` |
| OAuth bearer token, CCS2 payloads | `HyundaiEurope` |
| MFA-gated login, separate real-time endpoint | `KiaUSA` |

Use `Read` to open the chosen client plus its `+Commands.swift` and `+Parsing.swift` extensions. Note the file naming convention — every client follows the same three-file split.

## Phase 3 — Scaffold the client

Create three files under `BetterBlueKit/Sources/BetterBlueKit/API/<Brand><Region>/`:

```
<Brand><Region>APIClient.swift            // login, fetchVehicles, fetchVehicleStatus, sendCommand
<Brand><Region>APIClient+Commands.swift   // commandURL, commandBody, method helpers
<Brand><Region>APIClient+Parsing.swift    // response → VehicleStatus / Vehicle mappers
```

The class MUST subclass `APIClientBase` and conform to `APIClientProtocol`. Start every method that isn't yet implemented by throwing `APIError.regionNotSupported("not yet implemented")` — a failing bbcli run is more actionable than a compile error.

Then register in [`APIClientFactory.swift`](../../../BetterBlueKit/Sources/BetterBlueKit/API/APIClientFactory.swift):

1. Add a `case` in the brand-appropriate private `createXClient` function.
2. Add the region to `supportedRegions(for:)` (or `betaRegions(for:)` if you want a visible "beta" marker).

## Phase 4 — Iterate with bbcli

This is the core loop. Run from the package root so Swift Package Manager resolves:

```bash
cd BetterBlueKit
swift build 2>&1 | tail -20   # compile first; fix any Swift errors
swift run bbcli -b <brand> -r <region> -u <user> -p <pass> [--pin <pin>]
```

Inside `bbcli`, work through the menu **in this order**:

1. **Fetch Vehicles** (menu `1`) — validates login + token plumbing. Usually the first thing that breaks.
2. **Fetch Vehicle Status** (menu `2`) — validates per-vehicle auth and the status parser.
3. **Lock** / **Unlock** (menu `3` / `4`) — simplest commands, minimal payloads.
4. **Start / Stop Climate** (menu `5` / `6`) — largest command bodies; temperature encoding often differs per region.
5. **Start / Stop Charge** (menu `7` / `8`), **Charge Limits** (menu `9`), **EV Trip Details** (menu `10`).

### When a step fails

For each error, gather evidence from all three sources:

1. Read the exact error `bbcli` printed — status code, body. (Re-run with `--no-redaction` to see raw tokens if the redacted output isn't enough.)
2. `Read` the equivalent request/response in the reference implementation or proxy log. Diff the headers, body, and endpoint path against what `bbcli` just sent.
3. Edit the client file to match the reference. Common diffs: different `Content-Type`, different auth header name, a nested wrapper key (`result.vehicles` vs. `payload.vehicles`), a missing `deviceid`, or a different date format.

Rebuild and re-run the same menu item. Advance to the next only when the current one returns parseable data.

### Parsing iteration

Response parsers are the most error-prone part. When a response comes back 200 but the parser throws, don't hammer the live API — dump the `responseBody` to a file and iterate offline:

```bash
swift run bbcli parse -b <brand> -r <region> -t vehicleStatus ./fixture.json
swift run bbcli parse -b <brand> -r <region> -t vehicles ./fixture.json
```

`bbcli parse` unwraps a top-level `"responseBody"` automatically — paste a full debug export and it Just Works. Save working fixtures under `BetterBlueKit/Tests/BetterBlueKitTests/Fixtures/<Region>/` so regressions are catchable.

## Phase 5 — Verify and document

1. Run every menu item end-to-end against a live account. If any still fails, it's not done.
2. Update [`Troubleshooting.md`](../../../BetterBlueKit/Sources/BetterBlueKit/Resources/Troubleshooting.md) — flip the region row from ❌ to ✅ (or ✅ beta).
3. If you added to `betaRegions(for:)` and everything now works, promote to the supported list.
4. Summarize for the user: what changed, which bbcli menu items passed, any edge cases left as TODOs.

## Scope rules

- **Never commit secrets.** Proxy captures and debug exports can contain live tokens. Scrub before embedding any example in code comments or fixtures.
- **Don't invent endpoints.** Every URL, header, and body field must be traceable to either a reference implementation or a proxy capture the user provided.
- **Don't skip bbcli validation.** A client that "looks right" without being exercised by bbcli has a ~0% success rate in production.
- **Ask when stuck.** If a reference disagrees with a proxy log, surface the conflict to the user rather than guessing.

## References

See `references/` for condensed cheat sheets:

- [references/reference-implementations.md](references/reference-implementations.md) — URL map for open-source clients.
- [references/bbcli-cheatsheet.md](references/bbcli-cheatsheet.md) — command reference and debug tips.
