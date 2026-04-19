# bbcli Cheat Sheet

The Swift Package CLI at `BetterBlueKit/Sources/BBCLI` is the iteration loop for new clients. Always `cd BetterBlueKit` first — SPM resolution is relative.

## Build

```bash
cd BetterBlueKit
swift build
```

Fix Swift compile errors before anything else. `swift build 2>&1 | tail -20` surfaces the last diagnostic; `swift build 2>&1 | grep error:` lists them all.

## Interactive mode

```bash
swift run bbcli \
  -b <hyundai|kia> \
  -r <USA|Canada|Europe> \
  -u <email> \
  -p <password> \
  [--pin <1234>] \
  [--no-redaction]
```

Opens the menu:

```
1. Fetch Vehicles
2. Fetch Vehicle Status
3. Lock Vehicle
4. Unlock Vehicle
5. Start Climate
6. Stop Climate
7. Start Charge
8. Stop Charge
9. Set Charge Limits
10. Fetch EV Trip Details
0. Exit
```

Work the menu **top to bottom**; each step depends on the previous working.

## Parse-only mode

Use for offline iteration on response parsers:

```bash
swift run bbcli parse \
  -b <brand> -r <region> \
  -t <vehicles|vehicleStatus> \
  [--vin <VIN>] [--electric] \
  <path/to/response.json>
```

- `-t vehicles` — parse a vehicle list response.
- `-t vehicleStatus` — parse a single-vehicle status response. Use `--electric` to test the EV code path.
- The JSON can be a raw response body or a full debug-export entry (with `requestBody`/`responseBody`) — the CLI detects and unwraps.

## Debug tips

- `--no-redaction` prints bearer tokens, cookies, etc. in full. Useful for diffing against a reference, dangerous anywhere else.
- Every HTTP request/response is logged via `APIClientBase`. When something fails, the `bbcli` output already shows what was sent + what came back — no need to add `print` statements.
- If login succeeds but the follow-up call 401s, the auth header name is probably wrong. Diff against the reference implementation character-for-character.
- If a 200 response fails to parse, dump the `responseBody` to a file and re-run with `bbcli parse` — way faster than hitting the live API each time.

## Typical session

```bash
# First build
cd BetterBlueKit && swift build

# Verify login works
swift run bbcli -b hyundai -r Europe -u me@test.com -p secret --pin 1234
# pick 1 → Fetch Vehicles. Fix until this returns vehicles.
# pick 2 → Fetch Vehicle Status. Fix until this returns a populated VehicleStatus.
# pick 3 → Lock. Fix until the server accepts the command.
# ...and so on.
```

If a single step is mysterious, capture its response to a fixture and iterate with `bbcli parse`. Don't loop the live API more than ~10 times in a minute — every region rate-limits, and you'll get locked out.
