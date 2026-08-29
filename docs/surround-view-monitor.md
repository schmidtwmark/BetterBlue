# Surround View Monitor — feature state & regional expansion

Surround View Monitor (SVM) shows the 360° camera stills a vehicle captures on
request and uploads to the brand's servers. This document is the handoff for
anyone — engineer or coding agent — picking up the work.

**Kia US is now complete**, which is what most of this document is about. Its gallery
endpoints were found in Kia's own web portal; its capture trigger was not written down
anywhere and had to be found by probing a live account ([§6](#6-kias-capture-trigger)).
Both are shipped and confirmed on a real vehicle.

The techniques matter more than the answers, because the next region will need them: read
the vendor's own shipped client code before attempting a capture, and when there is nothing
left to read, probe against **calibrated controls** rather than guessing.

## 1. Status at a glance

| Brand / region | Capture (trigger) | Gallery (fetch) | Status |
|---|---|---|---|
| **Hyundai Canada** | `rfc/fndmcrsvm` | `rfc/lastmcrsvm` | ✅ Shipped |
| **Hyundai USA** | `POST /ac/v2/svm/findMyCarSVM` | `GET /ac/v2/svm/getSVMDetails` | ✅ Shipped |
| **Kia US** | `lbs/svm/req` | `lbs/svm/inquire` + `lbs/svm/info` | ✅ Shipped — trigger and gallery both confirmed on a live Carnival |
| **Kia Canada** | `rfc/fndmcrsvm` (probe-confirmed) | `rfc/lastmcrsvm` (probe-confirmed) | 🚧 Blocked: the whole client is a stub — [§7.1](#71-kia-canada--endpoints-exist-client-does-not) |
| **Hyundai / Kia Europe** | — | — | ❌ No such endpoint on the CCSP stack — [§7.2](#72-europe--a-definitive-no-on-the-stack-we-speak) |
| **Hyundai / Kia Australia** | — | — | ❓ Unknowable without credentials — [§7.3](#73-australia--blocked-not-negative) |

## 2. The shared data contract

Every brand delivers **the same imagery**, confirmed four ways now (Hyundai
Canada payload, Hyundai USA's bundled sample, Kia's bundled debug images, and
the Kia portal's own CSS crop offsets):

- A single wide **composite JPEG**, base64-encoded.
- Optionally an `imageSize` array `[totalW, totalH, cameraW, cameraH, topDownW,
  topDownH]`, in practice **`[4472, 720, 960, 720, 632, 720]`** — four 960×720
  fisheye panels (front / rear / left / right) followed by a 632×720 stitched
  bird's-eye view. **Kia does not send this field**; see the note in §5.3.
- Per-capture context: a coordinate fix, a `yyyyMMddHHmmss` timestamp, and
  (Hyundai only) `doorOpen` / `trunkOpen` / `sidemirrorOpen`.

`SurroundViewDecoder` (`BetterBlueKit/Sources/BetterBlueKit/Models/SurroundView.swift`)
handles every brand unchanged. **A new region needs no decoder changes.**

## 3. The shared parser — what a new region actually costs

`SurroundViewCaptureParser`
(`BetterBlueKit/Sources/BetterBlueKit/Models/SurroundViewCaptureParser.swift`)
owns everything the regions had duplicated verbatim: base64 decode, JPEG frame
extraction, `imageSize` reading, `tiles()`, the door map, the 0-or-bool flag
reader, the UTC `yyyyMMddHHmmss` reader, and the newest-first sort.

A region supplies only two things:

1. **Envelope navigation** — how to reach the array of capture dictionaries.
   This stays in the client because it is also where that region's error
   handling lives (Canada's `responseCode: 1`, Kia's `status.errorCode`).
2. **An `EntryShape`** — where each field sits, as a list of candidate key paths
   tried in order. The defaults already cover both Hyundai spellings (nested
   `gpsDetail.coord.lat` *and* flat `gpsDetail.coordLat`), so a Hyundai-shaped
   region passes nothing at all.

In practice a region's whole parse body is now three lines:

```swift
return SurroundViewCaptureParser.captures(
    from: entries, vin: vehicle.vin, shape: Self.surroundViewShape, apiName: apiName
)
```

This replaced ~220 duplicated lines across the two Hyundai clients with ~180
shared ones, with **zero edits to the existing tests** — that was the acceptance
criterion for the refactor, and it held.

## 4. Where the code lives

**BetterBlueKit (the API layer — all endpoints live here):**

- `API/APIClient.swift` — `OptionalAPIFeature.surroundView` / `.surroundViewCapture`;
  protocol methods `requestSurroundViewCapture` / `fetchSurroundViewCaptures`;
  the `supportsSurroundView()` / `supportsSurroundViewCapture()` helpers.
- `Models/SurroundView.swift` — `SurroundViewCapture`, `SurroundViewTile`,
  `SurroundViewCameraPosition`, `SurroundViewDecoder`.
- `Models/SurroundViewCaptureParser.swift` — the shared envelope parser (§3).
- `API/HyundaiCanadaAPI/HyundaiCanada+SurroundView.swift` — reference impl #1.
- `API/HyundaiUSA/HyundaiUSAAPIClient+SurroundView.swift` — reference impl #2.
- `API/KiaUSA/KiaUSAAPIClient+SurroundView.swift` — the Kia gallery + the
  capability probe.
- `API/SensitiveDataRedactor.swift` — redacts coordinates, elides base64 imagery.
- `Sources/BBCLI/SurroundViewCommands.swift` — CLI commands; `parseSurroundView`
  dispatches per region, so a saved payload from **any** brand can be parsed
  offline (it used to be Canada-only).

**BetterBlue (the app — UI, gating, fake data):**

- `Views/Components/SurroundViewMonitorView.swift` — the monitor screen. Shows
  "New Capture" only when the client declares `.surroundViewCapture`; otherwise
  offers "Check for New Photos".
- `Views/Components/SurroundViewSettingsInfo.swift` — the settings info sheet.
- `Utility/SurroundViewRendering.swift`, `Utility/FakeSurroundView.swift`.
- `Models/Account.swift` — `supportsSurroundView` / `supportsSurroundViewCapture`.
- `Models/Vehicle.swift` — per-vehicle gating: `showsSurroundView`,
  `autoShowsSurroundView`, `surroundViewOverride`.
- `Widget/VehicleAppIntents.swift` — the three intents. The two *request* intents
  gate on `supportsSurroundViewCapture` and throw
  `IntentError.surroundViewCaptureUnsupported` where there's no trigger.

## 5. Kia US "360 View"

### 5.1 Why it was hard to find

Kia brands the feature **"360 View"**, and files its endpoints under **`lbs`**
(location-based services) — so the paths mention neither "surround" nor "360".
Grepping the open-source ecosystem for `surround`/`svm`/`360` on the Kia side
finds nothing, and still doesn't.

### 5.2 Where the endpoints came from

The Kia US owners **web portal** (`owners.kia.com`, an Adobe AEM/Angular site)
still ships the compiled code for its "360 VIEW GALLERY" screen. Three backend
paths appear in cleartext in
`/etc.clientlibs/owners/designs/owners/angularJS/locations/clientlib.min.js`
(~5.3 MB, publicly fetchable, no login):

```js
f.prototype.getSvmInquire=function(a,b){return this._globalService
  .callApigwServlet(b,a,"POST","/lbs/svm/inquire","postLoginVehicle")…
f.prototype.getSvmInfo=function(a,b){…"POST","/lbs/svm/info"…
g.prototype.deleteSvm=…{svmIds:this.svmIdsDeleteList}…"POST","/lbs/svm/dsi"…
```

The portal calls them through its own AEM proxy
(`/apps/services/owners/apigwServlet.html/vinkey/<vkey>`, passing the backend
path in an `apiURL` header); a native client calls
`https://api.owners.kia.com/apigw/v1/<path>` directly — the same base and
grammar this client already uses for `cmm/gvi` and `prof/authUser`.

> This is the same technique that cracked **Hyundai USA** (a bundled canned
> response inside the app's own APK). **Try the vendor's own shipped client code
> first.** It beat a rooted-device proxy capture, a DexGuard teardown, and a
> full public-source sweep — all of which came up empty on this feature.

### 5.3 The wire protocol

**Kia is a three-call model**, unlike Hyundai's two:

| Call | Body | Returns |
|---|---|---|
| `POST lbs/svm/inquire` | `{}` | `payload.svmInfos[]` — see the real entry below. **No imagery.** |
| `POST lbs/svm/info` | `{svmId}` | the capture in full: `payload.svmInfos[0]` with `image` (base64), **`imageSize`**, and a repeat of the location block |
| `POST lbs/svm/dsi` | `{svmIds:[…]}` | deletes. Not used; recorded because it pins the verb family |

So Kia is a **three-call read model** where Hyundai needs two: a fetch is one
`inquire` plus one `info` per capture, merged before parsing.

**That per-capture cost drives two things Hyundai does not need: lazy loading and an
imagery cache.** Kia bills a request *and* ~280 KB of base64 for every capture, where
Hyundai returns the whole gallery in one response.

- **Lazy.** `fetchSurroundViewCaptures` lists every capture but loads imagery only for
  the **newest** — the one the screen opens on and the one the capture poll is waiting
  for. The rest come back as metadata (`isLoaded == false`, timestamp/location/heading
  intact) and are filled in by `fetchSurroundViewImagery` when the user selects them.
  Opening the gallery is now 2 requests and ~280 KB instead of 11 and ~2.8 MB.
- **Cached.** A capture is immutable once uploaded, so imagery is cached by `svmId`.
  The cache is replaced by whatever the listing currently holds, which evicts deleted
  captures and bounds it to Kia's retention of ten.

Together these took waiting on a capture from ~144 requests and ~35 MB down to roughly
a dozen cheap `inquire` calls plus one `info` for the picture that actually arrives.

Two traps worth knowing. `SurroundViewCapture.providerID` carries the `svmId` so a
capture can be re-requested later — but the id must go back on the wire with the **type
the server sent** (a JSON number); `providerID` is its string form and is only ever a
dictionary key. And `CachedAPIClient` **must** forward `fetchSurroundViewImagery`: the
protocol's default returns the capture untouched, which is right for a region whose
listing includes imagery and silently wrong here — inheriting it would make every
on-demand load a no-op and leave the screen permanently blank. The vehicle is identified by the `vinkey` header, as for `cmm/gvi`.

A real `inquire` entry, from a live Carnival (coordinates altered):

```json
{ "svmId": 3588225, "imageViewed": 1, "status": 0,
  "location": {
    "coord": { "lat": 39.98, "lon": -91.40, "alt": 0, "altdo": 0, "type": 0 },
    "head": 67,
    "speed": { "value": 0, "unit": 0 },
    "syncDate": { "utc": "20260829123858", "offset": -5 } } }
```

Two things that only a live response could settle. **Heading is at `location.head`** —
beside the fix, not inside it — so it is now mapped; it was left unmapped while its
location was unknown. And **Kia sends no door, trunk or mirror state at all**: that is now
a finding rather than caution, and those fields correctly stay nil ("not reported", which
the UI distinguishes from "closed"). Note also that `imageViewed` and `svmId` arrive as
JSON **numbers** here, though the portal template compares `imageViewed` against the string
`'1'`.

`imageViewed` is `1` for a capture the user hasn't opened and `2` once they have —
confirmed both ways in the portal: the NEW badge renders on `imageViewed == '1'`, and the
`info` success handler sets it to `"2"`. BetterBlue doesn't read it today; it's recorded
because it's the obvious hook for an unread indicator.

Because the imagery arrives per capture rather than in one response, the client has an
error contract the Hyundai regions don't need: a session-class failure (`invalidCredentials`
/ `invalidVehicleSession`) is rethrown **immediately** so `BBAccount` can re-authenticate
and retry, a single bad image is survivable, and a pass where **every** image failed throws
rather than returning `[]`. That last one matters most while the endpoints are unverified —
otherwise a response nesting the base64 anywhere but `payload.svmInfos[0].image` would be
indistinguishable from a car that has simply never taken a capture. All four behaviors are
covered by `URLProtocol`-stubbed tests.

Three differences from Hyundai worth knowing:

- The image field is **`image`**, not `svmImage`.
- **`imageSize` arrives with `info`, not with `inquire`.** This caught us out: the
  index entry has no geometry, so an early version merged only the base64 into it
  and the strip descriptor was never seen. `lbs/svm/info` states it outright —
  `[4472, 720, 960, 720, 632, 720]` on a live Carnival, identical to Hyundai's. The
  fetch therefore merges the **whole detail entry** over its index entry, not just
  the image. Anything the detail omits still falls back to the index.
  As a backstop for a payload that genuinely states nothing, `SurroundViewDecoder`
  can reconstruct the geometry from the strip itself: `pixelSize(ofJPEG:)` reads the
  SOF header (marker walk, no image framework, so watchOS is fine) and
  `inferredImageSize(width:height:)` rebuilds the panel widths when the aspect ratio
  matches the reference layout within 1%. A stated `imageSize` always wins, and
  anything not shaped like the known layout stays whole rather than being sliced on
  a guess.
  (The portal's CSS crop offsets — x = −41, −1099, −2018, −2940, −3905 — are *not*
  clean multiples of 960 and were the reason for earlier caution about the geometry.
  They turn out to be display-centering offsets for the masked circles, not panel
  boundaries.)
- **Heading and the door/trunk/mirror flags are left unmapped on purpose.** The
  portal never reads them, so where Kia reports them — or whether it does — is
  unknown. They surface as nil ("not reported"), which the UI already handles.
  Inventing key names here would silently mis-report a car's state.

### 5.4 Kia has disabled its own gallery client-side

Two things in that bundle are worth knowing before trusting it:

```js
b.SvmFaturSupported=(a.vehicleFeature.locationFeature.surroundView,!1)
```

That comma operator reads the capability flag and then throws the answer away,
forcing `false` — the portal's gallery is dead code. The trigger UI is likewise
commented out (§6). **This is why the Kia implementation is marked unverified on
the wire**: the paths are real and were shipped, but nothing proves the backend
still serves them. The failure mode is a clean error inside the Surround View
screen, not a broken status path — but verify before relying on it (§8).

The same bundle also *corroborates the capability flag* independently: it reads
`vehicleFeature.locationFeature.surroundView` in two places (including
`b.visibility.supportsSvm=O.surroundView`) and never mentions the
`remoteFeature.surroundViewMonitor` decoy. It also gates the feature on
entitlement code `LOC17` (`LOC1` = find my car, `LOC4` = add POI).

### 5.5 The capability flag — and the decoy

`vehicleConfig.vehicleFeature.locationFeature.surroundView` (string `"1"`/`"0"`),
read from `cmm/gvi` with `vehicleFeature: "1"`. Confirmed three ways: on a live Kia
Carnival Hybrid; by the portal's own code (§5.4); and by a recorded `cmm/gvi` payload in
`dahlb/kia_hyundai_api`'s `us_kia.py`, which carries
`"locationFeature":{…,"surroundView":"0","svr":"1"}` on an older Kia — so Kia models this
as a per-vehicle server-side gate, and cars without the hardware really do report `"0"`.

⚠️ **`remoteFeature.surroundViewMonitor` is a different flag — do not read it.**
The same Carnival reports `surroundView: "1"` and `surroundViewMonitor: "0"` in
one response, so they cannot mean the same thing. Reading the decoy would report
"unsupported" for a car whose owner uses the feature daily.

⚠️ Only change `vehicleFeature` in the `cmm/gvi` body — `vehicleStatus` must stay
`"1"` or the server returns error 9001, which `checkForKiaErrors` doesn't
recognise and would surface as a confusing parse error.

## 6. Kia's capture trigger

Kia's analogue of `findMyCarSVM` / `fndmcrsvm` is **`POST lbs/svm/req`**, body `{}`.

It was not read anywhere. Every client that speaks this API is pinned (iOS), hardened
(Android), or had the call stripped (the web portal, §6.1), so nothing was left to read —
it was found by **probing**, and the probe is only trustworthy because it was calibrated
(§6.3). Of fourteen reasoned candidates, thirteen answered errorCode **9000** ("System
could not process your request"), identical to a deliberately bogus path. `req` answered
errorCode **0** — exactly what the real `lbs/svm/info` answers when handed a body it
cannot use.

```
lbs/svm/inquire   → errorCode 0     (control: real path, correct body)
lbs/svm/info      → errorCode 0     (control: real path, EMPTY body)
lbs/svm/zzzbogus  → errorCode 9000  (control: no such path)
lbs/svm/req       → errorCode 0     ★ routes; the only candidate that does
rsi csi nsi tsi ssi gsi request capture take new initiate trigger start → 9000
```

**Routing was not proof, and the confirmation matters.** The `info` control shows a routed
path with an unusable body ALSO answers errorCode 0 with an empty payload — precisely what
`req` answered — so "routed" and "worked" were indistinguishable from the response alone.
What settled it was the vehicle: the probe call at 08:01:56 produced a real capture visible
in the Kia app at 08:02. `bbcli` menu **16** re-runs that experiment on demand (snapshot
the gallery → fire `req` → poll for an id that wasn't there before).

⚠️ **The trigger asserts `errorCode == 0` rather than trusting `checkForKiaErrors`.** That
helper only throws for the handful of codes it recognises, and 9000 — the code this API
returns for a path it cannot route — is not one of them. The fetch paths get a backstop for
free because they fail on the missing payload; the trigger parses nothing, so without an
explicit success check a refusal would return as an accepted request and the app would poll
for a capture that was never taken.

A note for whoever hits it first: no "capture already pending" code is known here, so a
duplicate request is not remapped to `.concurrentRequest` the way Hyundai USA remaps
`HT_533`. Kia caps captures at five a day; a sixth may be accepted and silently dropped.

### 6.1 How the app copes until it is confirmed

`OptionalAPIFeature` was split so "can show the gallery" and "can take a new capture" are
separate declarations. Kia US declares `.surroundView` but **not** `.surroundViewCapture`;
the app hides the "New Capture" button, offers "Check for New Photos" instead, and the two
request intents throw a specific error. Captures taken from the Kia Access app show up
normally.

This split is worth keeping even after the trigger is confirmed — it is what let the
gallery ship months before the trigger existed, and any future region with the same
asymmetry gets it for free.

### 6.2 The avenues that were closed first

**Web-bundle archaeology is closed.** It was swept exhaustively and is exhausted:

- **All 39 referenced portal bundles** were downloaded and searched, not just the
  `locations` one. The 10.3 MB dashboard bundle has `getSvmInquire`/`getSvmInfo` and a
  gallery badge poller — no trigger.
- **The Wayback Machine has no coverage of `owners.kia.com` at all.** Not "blocked" —
  *empty*: `matchType=domain` returns `[]` with HTTP 200, repeatedly, while a control
  (`owners.hyundaiusa.com`) returns records normally. There is no old snapshot to recover.
- **Common Crawl** holds HTML/PDF from the site across all 127 indexes but **zero JS
  assets**, 2019–2026.
- Sourcemaps, unminified variants, AEM `js.txt` manifests, and `?debugClientLibs=true`
  all 404 or return the same single webpack bundle. The non-`.min` `clientlib.js` is the
  same build, not an older one.
- All 28 `callApigwServlet` call sites pass **literal** path strings — nothing is hidden
  behind string concatenation.
- The entire `/lbs/` namespace contains **only** the three svm paths. The union of apigw
  paths across every bundle is 135 distinct routes; none of the other 132 is camera-shaped.
- `@Output() SvmRequestFromChild` is declared by the gallery component and **nothing
  subscribes to it**, and `svmReqInProgress` is never assigned `true` anywhere. The
  parent-side trigger handler was removed, not hidden.

**The structural reason.** The trigger may never have been an apigw path in the JS at
all. The sibling "make the car do something now" command on the same screen — **Find My
Car** — does *not* go through `callApigwServlet`. It posts to a dedicated AEM servlet that
keeps the backend path server-side:

```js
i = "/apps/services/owners/location/vehicle.html/vinkey/" + A + "/sid/" + l;
this._globalService.postWithJson(i, {requestType: t})
```

All 83 `/apps/services/owners/…` servlet paths were enumerated; none is camera-related.
Every call site passes `requestType: 0`. That the parameter exists at all hints other
values are accepted server-side, but no evidence names one — **do not guess a value.**

#### iOS proxy capture — tried; Kia's iOS app pins

The whole earlier investigation was Android-only, which looked like the mistake: Android's
pinning is a **declarative** `<pin-set>` in `network_security_config` — an Android-only
mechanism — and the `libmyuvo_link.so` RASP kills only on a re-signed APK or an emulator,
neither of which describes a proxied stock iPhone. The precedent was good, too: in
[hyundai_kia_connect_api discussion #1194](https://github.com/Hyundai-Kia-Connect/hyundai_kia_connect_api/discussions/1194)
the entire Hyundai USA SVM flow, trigger included, was captured off the **native iOS
MyHyundai app** (`User-Agent: MyHyundai/5.4.0 (iPad; iOS 26.5; Scale/2.00)`) by an author
who says outright they "do not personally know how to implement the API/library changes" —
with no jailbreak, Frida, or bypass tool mentioned anywhere.

**It was tried on Kia Access and it does not work.** Proxyman, stock non-jailbroken
iPhone, CA installed and fully trusted. The app raised a warning, Proxyman flagged
"possible SSL pinning", and the log is unambiguous:

```
request:  CONNECT api.owners.kia.com:443
timing:   clientTLSStartedAt = 1788007106.368   clientTLSEndedAt = null
response: 999 Error — clientClosedRequest
```

The app **began** the TLS handshake with Proxyman and hung up part-way through. That is the
client rejecting the certificate, not a missing trust setting (which fails differently) and
not a network problem. Kia pinned iOS where Hyundai did not. The matching no-SSL capture
completes the same `CONNECT` normally, which is the control proving the proxy path itself
was fine.

So **all three client platforms are closed** as sources: Android (RASP + declarative
pinning), iOS (code pinning), and the web portal (trigger stripped from the bundle). That
is what forced the probe — the endpoint was demonstrably live (the iOS app's "TAKE NEW
IMAGE" button works), but nothing readable named it.

#### It is an `lbs/svm` verb, not a `rems` one

Kia files remote *commands* under `rems`, so the trigger being a `rems` verb was worth
ruling out. The complete public, capture-derived US verb set (from
[`dahlb/kia_hyundai_api`](https://github.com/dahlb/kia_hyundai_api)'s `us_kia.py`, built
from real captures) is:

```
prof/authUser  cmm/sendOTP  cmm/verifyOTP  ownr/gvl  cmm/gvi  cmm/gts  rems/rvs
rems/door/lock  rems/door/unlock  rems/start  rems/stop  evc/charge  evc/cancel  evc/sts
```

**Nothing camera-shaped under `rems`, in any public client, ever.** All three confirmed
camera endpoints live under `lbs/svm`, and the capability flag lives in `locationFeature`
— so the trigger is almost certainly a **fourth `lbs/svm` verb**.

### 6.3 The probe that found it (bbcli menu 15)

With every capture avenue closed, the remaining option is to ask the server directly about
a short list of reasoned candidates. `bbcli` menu **15** does this, and the design is what
makes it legitimate rather than a shot in the dark:

- **It is calibrated, and the oracle is now measured.** Every run brackets the candidates
  with a known-good control (`inquire`) and a known-bad one (`zzzbogus`). On a live account
  these answer differently, which is what makes probing possible at all:

  | path | HTTP | `status.errorCode` | |
  |---|---|---|---|
  | `lbs/svm/inquire` | 200 | `0` | "Success with response body" |
  | `lbs/svm/zzzbogus` | 200 | **9000** | "System could not process your request" |

  So **9000 means the verb does not exist**, and a candidate is a hit only if it answers
  something *other* than 9000. Note both return HTTP 200 with a `status` block — the HTTP
  code and the presence of an envelope carry no information whatsoever.
- **It prints raw answers.** `probeSurroundViewVerb` deliberately does not interpret the
  response. The original objection to guessing was that `checkForKiaErrors` ignores codes
  it doesn't recognise, so a wrong path fails as an opaque parse error far from its cause —
  printing the untouched `status` block removes exactly that problem.
- **It stops at the first genuine hit**, because a candidate that *is* the trigger takes a
  real capture, and Kia caps the feature at five a day.

> **A probe answer means nothing in isolation.** The first version of this command flagged
> any response carrying a `status` block as routed. Every response carries one — including
> the known-bad control — so it reported a false positive on its first candidate (`rsi`)
> whose body was byte-identical to `zzzbogus`. Always compare against the miss baseline
> from the same session.

The candidate list is derived from Kia's own verb morphology, not invented. Across the
135-path gateway inventory the convention is consistent — `g`et, `s`et, `d`elete,
`r`equest — and `lbs/svm/dsi` reads as delete-svm-image (cf. `bil/pmt/dpm`, delete payment
method). So the code-shaped candidates are the `dsi` template with the verb letter swapped
(`rsi`, `csi`, `nsi`, `tsi`, `ssi`, `gsi`), and the word-shaped ones come from the
namespace's own full words (`inquire`, `info`) plus the names of the stripped portal
functions (`triggrSvmRequest`, `initiateSvmRequest`) and the app's resource string
(`svm_360_locations_take_new_image`): `request`, `capture`, `take`, `new`, `initiate`,
`trigger`, `start`, `req`.

**A negative result is a real result.** If nothing answers differently from the known-bad
control, record it here so the list is never retried.

**Ruled out** — all answered 9000, identical to a non-existent path: `rsi`, `csi`, `nsi`,
`tsi`, `ssi`, `gsi`, `request`, `capture`, `take`, `new`, `initiate`, `trigger`, `start`.
**Found**: `req`.

### 6.4 The community route

`hyundai_kia_connect_api` has a **live SVM workstream** right now: issue #1201 (Hyundai
USA SVM support), PR #1203 (in progress), discussion #1194 (the iOS capture), and issue
#1145 (the Kia EU OneApp teardown). People there have provably captured HKG US traffic on
both brands.

We now hold **four** Kia endpoints nobody has published — `inquire`, `info`, `dsi` and
`req` — plus the calibrated 9000-vs-0 oracle that found the last one, and the finding that
Kia's iOS app pins where Hyundai's does not. All of that is worth contributing back: it
lands in front of exactly the right audience while the maintainers are mid-implementation
on the Hyundai twin of this feature, and the oracle technique generalises to any other
undocumented verb in this gateway.

#### Closed — do not spend time here

- **Other Kia regional portals.** `owners.kia.com` serves **only** `/us/en` (verified:
  `/ca/en`, `/mx/es`, `/pr/es`, `/us/es` all 404). Puerto Rico is served by the US portal
  and the same stripped bundle. Every other market is a different backend: Kia Canada on
  `kia.ca`, Kia EU on OneApp/GSPA. Genesis and Hyundai owner portals exist but sit on the
  Hyundai backend, whose trigger is already public.
- Wayback (zero coverage of the host), Common Crawl (no JS assets), GitHub code search,
  Sam Curry's writeup, the kumo.dev teardown, and every reference client.
- **Do not** unauthenticated-path-probe `api.owners.kia.com` — Cloudflare-fronted, no
  oracle, and scanning a live production API is the wrong tool regardless.

## 7. The other regions

### 7.1 Kia Canada — endpoints exist, client does not

`kiaconnect.ca` runs the **identical `tods` application** as `mybluelink.ca`. A
calibrated path-existence probe (real routes answer with an application-level
JSON error; missing routes answer a Spring-style 404 echoing the path) found that
**both `rfc/fndmcrsvm` and `rfc/lastmcrsvm` exist on `kiaconnect.ca`**, answering
exactly like the known-good `vhcllst`, while `rfc/fndmcr`, `rfc/zzzbogus` and
`zzzbogus` all 404.

**But `KiaCanadaAPIClient` is a 46-line stub that throws `regionNotSupported`.**
SVM there is blocked behind building the whole client (the `brand-region-client`
skill covers that). Once it exists, SVM should be a host swap plus the existing
Hyundai Canada `EntryShape` — likely the cheapest region left.

> ⚠️ **Methodological correction to the previous revision of this doc:** web
> portal JS bundles are *not* a valid oracle for SVM in Canada. Hyundai Canada's
> own portal bundle contains no `fndmcrsvm`, no `lastmcrsvm`, not even `rfc/` —
> despite those endpoints working in production. The `rfc/*` family is a
> mobile-app-only surface, so grepping the Canadian portals produces a false
> negative. (This is the opposite of the Kia US situation, where the portal was
> the only place the paths survived — check both, trust neither alone.)
>
> Also: `svmvrdy` / `svmkcs` in both Canadian portals are **decoys** meaning
> "save my vehicle ready day" (`f.day=parseInt(c)`), not surround view.

### 7.2 Europe — a definitive no on the stack we speak

The CCSP stack BetterBlueKit implements (`prd.eu-ccapi.{hyundai,kia}.com:8080`,
`/api/v{1,2}/spa/vehicles/…` and the `/ccs2/…` variants) has **no camera or
surround-view endpoint**. Its complete public surface was enumerated from five
independent sources — `hyundai_kia_connect_api` (`KiaUvoApiEU`, `ApiImplType1`),
`bluelinky`'s European controller, `egmp-bluelink-scriptable`, and this repo's own
EU clients — and grepped for `svm`/`surround`/`camera`/`360`/`birdview`/`avm`/
`topview`: zero hits in every file. GitHub code search agrees globally (control
queries return hits; every SVM-shaped query returns 0).

**So "the EU clients already work, shipping SVM there is cheap" is false.** Do
not spend time re-deriving this.

The feature *does* exist in Europe, on a **different, newer stack**: Kia's EU
Terms of Use formally list "Remote Surround View Camera", and
`hyundai_kia_connect_api` issue **#1145** ("oneapp inspection") attaches a static
jadx teardown of the Kia OneApp EU APK listing
`GET /gspa/v1/svm/vehicles/{carId}/image` (plus two `na-images` variants) on
`gspa-ccs-eu.kia.com`.

Treat that as **a lead, not a protocol**: it is one third-party LLM-assisted
static decompile explicitly labelled "no live traffic", has zero independent
corroboration, is internally inconsistent (the machine-extracted `openapi.yaml`
attached to the same issue does *not* contain the svm path), lists **no trigger
at all**, and is gated behind an unknown OneApp `client_id` and an `X-Stamp`
computed in native `libgspa-cipher.so` that nobody has cracked.

### 7.3 Australia — blocked, not negative

Both AU clients are stubs, and both regions run CCSP
(`au-apigw.ccs.hyundai.com.au:8080` / `au-apigw.ccs.kia.com.au:8082`). No
reference client has camera code. The Canadian existence-oracle does **not**
transfer: the CCSP gateway returns the same "Authorization field missing" for
real and bogus paths alike. Existence cannot be settled without credentials.

### 7.4 Hyundai — no second generation, no per-vehicle flag

- Hyundai USA has no newer endpoint: PR #1203 contains exactly three path
  literals, and its `gen` field is the vehicle's telematics generation, not an
  API version. (That PR is still **open**, not merged.)
- Hyundai Canada has no extra SVM verbs — 20 candidate `rfc/*` names
  (delete/count/list/status variants) were swept; only the two known ones exist.
- **No Hyundai per-vehicle SVM capability flag has been found.** Both Hyundai
  vehicle parsers read only id/nickname/generation/odometer/fuelType; whether the
  fuller payloads carry an unread flag needs a captured response. Do not invent one.

## 8. Verification checklist

The Kia gallery has now been confirmed end to end on a live account. This is the
procedure to re-run it, or to check a new region:

```bash
cd BetterBlueKit && swift run bbcli
```

> The CLI now remembers this account's device id and tokens in
> `~/.bbcli/sessions.json` (0600), so an MFA-gated account is challenged once rather
> than on every launch, and a run inside Kia's 23-hour session window skips login
> entirely. `bbcli --forget` clears it. Note `redactPII` defaults to **false** here —
> scrub coordinates and VINs before pasting CLI output anywhere.

1. **Menu 14 (Probe Vehicle Features)** — confirms the VIN advertises 360 View.
2. **Menu 13 (Fetch Surround View Images)** — exercises `lbs/svm/inquire` +
   `lbs/svm/info` end to end and writes the frames to `./surround-view/`.
   ✅ **Done**: confirmed working on a 2026 Carnival, 4472×720 composite, five
   tiles. If it ever starts 404ing, Kia has retired the endpoints; flip
   `KiaUSAAPIClient.optionalFeaturesSupported()` back to `[.mfa]` — that one line
   is the whole app-facing switch.
3. **Menu 12 (Request Capture)** on Kia now fails with an explicit "not supported
   yet" message rather than an opaque error. That is expected, not a bug.

Offline, any saved payload can be parsed without a vehicle:

```bash
swift run bbcli parse -b kia -r US -t surroundView saved-inquire.json
```

(For Kia, feed it an `inquire` response with each entry's `image` merged in —
the shape the client assembles internally.)

## 9. Privacy / redaction

SVM responses carry **precise GPS + megabytes of base64 imagery**, and HTTP logs
are persisted, iCloud-synced, and bundled into user debug exports.

- Coordinates are redacted. The rule covers bare `lat`/`lon`/`latitude`/`longitude`
  and camelCase keys ending in them (e.g. `coordLat`). Kia's `coord.{lat,lon}` is
  covered by the bare-key rule; there is a test asserting a full Kia body is both
  elided and redacted.
- Base64 imagery is elided by size (`elideOversizedValues`), which is key-agnostic
  — so Kia's `image` field is covered for free, as is any future region's.
- **If a new region uses a new coordinate key, extend the rule and add a test.**
  (Altitude `alt` is deliberately left as-is — harmless without lat/lon, and
  adding it risks over-matching.)

## 10. Testing

- **Fake vehicles** exercise the whole feature in the simulator with no real car.
  `FakeSurroundView.swift` synthesizes a real 4472×720 composite routed through
  the production decoder. Debug toggles cover a refused request and a capture
  that never uploads; "Seed 3 Surround View Captures" back-dates a history.
  Fake vehicles declare both capabilities, so they remain the regression check
  that trigger-capable regions are unaffected by the capability split.
- **Kit tests:** `SurroundViewTests.swift` (decoder, Canada, redaction),
  `HyundaiUSASurroundViewTests.swift`, `KiaUSASurroundViewTests.swift`.
  The Hyundai suites double as the shared parser's coverage: Canada exercises the
  flat coordinate spelling and USA the nested one, both through the default
  `EntryShape`.
- **bbcli:** menu 12/13 (request/fetch), 14 (feature probe), and
  `parse -t surroundView` for offline payloads in any region.

## 11. Key facts to keep handy

- Composite geometry: `imageSize = [4472, 720, 960, 720, 632, 720]` → 4× 960px
  fisheye + 1× 632px bird's-eye, all 720 tall. Both brands state it — but on Kia it
  comes from `lbs/svm/info`, never from `lbs/svm/inquire`. The decoder can also
  reconstruct it from the frame's SOF header when a payload states nothing.
- Camera order in the composite: front, rear, left, right, then bird's-eye.
- Kia capability flag: `vehicleConfig.vehicleFeature.locationFeature.surroundView`
  (string `"1"`/`"0"`) from `cmm/gvi` with `vehicleFeature: "1"`.
  **Not** `remoteFeature.surroundViewMonitor` (the decoy). Entitlement: `LOC17`.
- Kia base URL / grammar: `https://api.owners.kia.com/apigw/v1/<module>/<verb>`;
  360 View lives under the `lbs` module.
- Kia app package (for a trigger capture): `com.myuvo.link`; native RASP lib
  `libmyuvo_link.so`; DexGuard-obfuscated; `api.owners.kia.com` pinned
  declaratively (7 SHA-256 pins in `network_security_config`).
- The Kia portal bundle worth re-reading:
  `owners.kia.com/etc.clientlibs/owners/designs/owners/angularJS/locations/clientlib.min.js`
