# Building and testing the iOS SDK on a Mac

Nothing in this package has ever been compiled. It was written on Windows,
where there is no Swift compiler, so **the first goal is not "does attribution
work", it is "does this build at all"** -- and it should be treated as likely to
fail the first time on small things (a renamed API, an availability annotation)
that no amount of reading catches.

Work the stages in order. Each one is cheap and rules out a whole class of
problem before the next one costs you a device install.

---

## Stage 0 -- get the code onto the Mac

| What | Where | Notes |
|---|---|---|
| iOS SDK | `github.com/rishabhrk2345/Roas-ios-SDK` (also `sdk-ios/` in the monorepo) | **This is the copy to use.** |
| Flutter plugin | `github.com/harsh-vasundhara/roas-sensor-flutter` @ `v0.1.6` | Has `ios/`, never built |
| Android SDK | `github.com/harsh-vasundhara/roas-android-sdk` @ 0.1.6 | The reference for beacon parity |

The SDK repo is a **publishing mirror**: development happens in the monorepo's
`sdk-ios/`, and the standalone repo is what SPM and CocoaPods resolve against.
Edit in the monorepo and re-publish; a fix committed only to the mirror is one
the next publish overwrites.

⚠️ **Do not use `roas-ios-sdk-standalone`** if you come across a copy of it. It
is an older divergent tree missing `RoasLogLevel`, `setLogLevel`,
`setOnDeliveryResult`, `requestTrackingAuthorization` and public
`updateConversionValue` -- every one of which `RoasFlutterPlugin.swift` calls.
Building the plugin against it fails, and tagging it for release would ship a
pod that cannot compile.

---

## Stage 1 -- compile and run the suite (5 minutes, no Xcode project needed)

```bash
cd sdk-ios
swift build          # macOS slice: syntax, availability, renamed APIs
swift test           # the whole suite
```

`Package.swift` declares `.macOS(.v10_15)` precisely so this runs on the host
with no simulator. The device-only code (ATT/IDFA/AdServices/StoreKit/UIKit) is
`#if canImport`-guarded and compiles out here -- so a green `swift build` proves
the shared logic, **not** the attribution code.

Then build the real slice, which does exercise those paths:

```bash
xcodebuild -scheme RoasSensor -destination 'generic/platform=iOS' build
```

Expect the first failures there, in `DeviceContext.swift` -- it carries the most
newly-written platform API surface (`NWPathMonitor`, `sysctlbyname`,
`CFNetworkCopySystemProxySettings`, battery monitoring).

### What each suite protects

| Suite | Protects |
|---|---|
| `HashingParityTests` | email/phone hashes match `security.py` byte-for-byte |
| `SignerParityTests` | the HMAC matches `tracking/signing.py` |
| `SessionTrackerTests` | 30-minute idle and local-midnight rollover |
| `StorageTests` | reset-on-restore, the flush race, ASA retry state |
| `DeviceContextTests` | every field fits its backend column and vocabulary |
| `BeaconContractTests` | the `ts` format, and taxonomy parity with Android |

The two parity suites are the ones to stop on. If either is red, identity
stitching or signed beacons are broken, and no amount of device testing will
show you why.

`DeviceContextTests` is worth understanding before you read a failure: it runs
on a host with no UIKit, so most fields are simply absent and every assertion
reads "if this key is present, it must satisfy the contract". That is the point.
It catches the one failure mode nothing else does -- `ingest.py` clips every
string to its column width and degrades every out-of-range number to NULL rather
than raising, which is correct for not losing an install and means a too-long
value produces no error anywhere. It just quietly stores something other than
what the device said.

---

## Stage 2 -- native Swift app on the simulator

`Sample-ContentView.swift` is a ready SwiftUI view. Make a throwaway app, add
this package by path, drop the view in, and:

```swift
Roas.setLogLevel(.debug)
Roas.setOnDeliveryResult { path, success, error in
    print("ROAS \(path) success=\(success) error=\(error ?? "-")")
}
Roas.configure(publicKey: "<PUBLIC_KEY>", baseUrl: "<YOUR TEST HOST>")
```

Add to the app's `Info.plist` or the ATT prompt **terminates the app**:

```xml
<key>NSUserTrackingUsageDescription</key>
<string>Used to measure which ads brought you here.</string>
```

(The SDK detects a missing key and skips the prompt rather than crashing -- but
then there is no IDFA, so add it.)

### What the simulator can and cannot prove

| Works | Does not work |
|---|---|
| Beacons reaching the backend | IDFA -- always all-zeros, so never sent |
| Session model, `pv_id` upsert, engagement | Apple Search Ads token (`ASA_ERROR:*`) |
| Signing, clock offset, `ts` | SKAdNetwork postbacks |
| `device_type`, screen, viewport, locale | Battery -- reports −1, so omitted |
| Deep-link handling | Real `installer_package` (reports `simulator`) |

`integrity_signals` will contain `simulator` and `installer_package` will be
`simulator`. Both are correct and both are worth confirming, because they are
how a customer's own QA gets separated from their real users.

---

## Stage 3 -- physical iPhone

The only stage that can prove attribution.

1. **TestFlight build** -- confirm `installer_package` reads `testflight`, and
   `development` from Xcode. This has been wrong before: a receipt URL exists
   even when no receipt was ever issued, so reading only the filename labelled a
   developer's own build as TestFlight. If both channels report the same string,
   `installerSource()` is broken again.
2. **Deep link** -- open a `/c/<slug>` tracking link that routes into the app and
   confirm the `app_open` touchpoint carries the click id, the UTM context, and
   **`session_number`** (newly added; its absence suppresses the retention
   headline site-wide).
3. **ATT deferred** -- `configure(requestTrackingAuthorization: false)`, then
   `Roas.requestTracking()` after a priming screen. An `/identify` beacon
   carrying `device_id` should follow a grant.
4. **ATT via Settings** -- deny the prompt, then enable tracking for the app in
   Settings → Privacy → Tracking, then trigger any `identify()`. The IDFA should
   appear. This path fires no callback at all, and re-reading in `identify()` is
   the only thing that catches it.
5. **Offline install** -- airplane mode, install, launch, wait, restore network.
   The install must arrive with `ts` set to when it *happened*: check
   `occurred_at`, not `created_at`. This is the fix worth the most; Android
   measured 48 hours of error here.

---

## Stage 4 -- the Flutter plugin

`example/` in the plugin repo is Android-only. On the Mac:

```bash
cd example
flutter create --platforms=ios .
```

Then in `example/ios/Podfile`:

```ruby
platform :ios, '14.0'    # the template leaves this commented out; the plugin needs 14
```

and add the native SDK, which is not published yet:

```ruby
pod 'RoasSensor', :path => '../../../sdk-ios'   # adjust to where you put it
```

Also set **iOS Deployment Target 14.0** on the app target in Xcode -- a separate
setting from the Podfile's. Fixing only the Podfile clears `pod install` and
then fails again during the build with the same complaint.

Add `NSUserTrackingUsageDescription` to `example/ios/Runner/Info.plist`.

Then exercise the bridge specifically -- the Dart side is symmetric but the
Swift half has never run:

```dart
await Roas.initialize(publicKey: '...', baseUrl: '...', appSecret: '...');
final vid = await Roas.visitorId();           // non-null, "rs" + 32 hex
final token = await Roas.appAccountToken();   // iOS only, a valid UUID
await Roas.requestTracking();                 // must complete, not hang
await Roas.updateConversionValue(3, coarse: 'low');
```

The delivery `EventChannel` is where I would expect a problem first: it crosses
threads (`Transport` delivers off-main, a `FlutterEventSink` must be invoked on
main) and it clears a process-wide native callback on cancel. Hot-restart the
app a few times with the stream listening -- that is the case the cleanup exists
for.

---

## Stage 5 -- confirm the data server-side

Django admin → Tracking → Touch points, newest row.

| Fieldset | Confirms |
|---|---|
| Journey | `session_id`, `session_number`, `sequence`, `pv_id`, `engagement_ms` |
| Device | `device_type`, `screen`, `viewport`, `timezone`, `language` |
| Native app: attribution | `idfv`, `install_referrer`, `referrer_status`, `referrer_source` |

Checks that are easy to get wrong:

- `device_type` must be `tablet` on an iPad. If it says `mobile`, the idiom read
  regressed and every iPad in the database is a phone again.
- `viewport` (points) and `screen` (pixels) must differ. The same value in both
  means `nativeBounds` and `bounds` got mixed up.
- `screen_density` should be 320 (@2x) or 480 (@3x).
- `first_install_at` must survive an app update; `last_update_at` must move.
  Install, note both, then install an updated build over it.
- `is_vpn` reads **true under iCloud Private Relay**, which is intended -- the
  field exists to say "this IP is not the device's own" before an IP-proximity
  match is trusted. It is not a VPN-usage metric.
- `uptime_seconds` should be large on a phone you have not rebooted.
- `occurred_at` vs `created_at` -- the offline-install check from Stage 3.

Session-start and install beacons carry the full device context; `identify` and
`track` deliberately do not, and the backgrounding beacon carries only `pv_id`
plus `engagement_ms`. A missing device field on those is correct, not a bug.

---

## Known-risky spots, ranked

1. `DeviceContext.swift` -- the most newly-written platform API surface.
2. `roas_flutter`'s iOS `EventChannel` -- threading and lifecycle.
3. `installerSource()` -- has been wrong before, in a way that looks fine.
4. `DeviceLocation` -- guarded `#if os(iOS)` because the instance
   `authorizationStatus` is macOS 11+ while `Package.swift` declares macOS 10.15
   for the parity tests. If `swift build` fails on CoreLocation, that guard is
   why.

## Not covered by any test

The suite reaches everything that does not need a device or a running
`Roas.configure()`. It does **not** cover: that `ts` and the device context
actually reach a beacon body (that needs a configured SDK and a fake transport),
the ASA retry flow end to end, lifecycle/foreground transitions, or anything
UIKit-backed. Stages 2 and 3 are how those get proven.
