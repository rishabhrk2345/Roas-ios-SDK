# ROASSensor iOS SDK (`RoasSensor`)

Native iOS tracking for ROASSensor — the Swift twin of `sdk-android`, same wire
format (`/api/tracking/mobile/*`), plus the iOS-specific attribution signals.
Revenue is **not** sent from the app; it enters only through a signed webhook —
App Store Server Notifications, Stripe, or RevenueCat — so ROAS stays defensible.
Anything a device can claim, anyone can forge.

## What it does

- **Install reporting** on first launch, with the iOS attribution signals:
  - **Apple Search Ads** attribution token (`AdServices` `AAAttribution`) —
    deterministic, Apple-sanctioned, no consent needed.
  - **IDFA** — only when the user grants App Tracking Transparency (opt-out
    respected). Sent raw; the server hashes it canonically.
  - **IDFV** — always available, links a vendor's apps on one device.
  - **SKAdNetwork** registration (aggregate campaign attribution).
  - **Retry across launches** — a transient `AAAttribution` failure on the very
    first launch (a device that has just installed and isn't fully on the
    network yet) no longer costs the token permanently. Up to 5 later launches
    re-read it and send the recovery as an `app_open`, never a second install.
    The twin of Android's install-referrer retry.
- **Deferred deep links** — `Roas.handleDeepLink(url)` forwards the full query
  string from a universal link so the install attributes deterministically (the
  iOS analogue of the Android install referrer).
- **Identity** — email/phone hashed on-device (byte-for-byte with the backend,
  verified by `HashingParityTests`). `identify()` also re-reads the IDFA, so a
  user who allows tracking later — from the prompt or from Settings → Privacy —
  still gets it bound.
- **Events** — funnel/behaviour, never revenue. Use `RoasProps` keys so the
  product funnel can group across platforms.
- **Device context** — ~25 fields per touchpoint: model, screen, form factor,
  build, device class, network, battery, install dates. `DeviceContextTests`
  asserts every one fits the column it lands in.
- Persisted, idempotent delivery queue: offline installs survive **and carry
  `ts`**, so an install that happened offline on Monday is recorded on Monday,
  not on the day it finally uploaded.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/rishabhrk2345/Roas-ios-SDK", from: "0.1.7")
```

CocoaPods — this is **not** on the CocoaPods trunk, so name the source yourself:

```ruby
pod 'RoasSensor', :git => 'https://github.com/rishabhrk2345/Roas-ios-SDK.git', :tag => '0.1.7'
```

> Both resolve against a **git tag**, so releasing means tagging the repo, not
> just bumping `s.version`. A version with no matching tag fails at
> `pod install` rather than quietly serving the previous code.

**Verified on hardware.** `swift build` clean, 54 tests passing, and every
device parameter confirmed on a physical iPhone 12 mini (iOS 16.7): install
delivered, IDFA bound under an ATT grant, a real Apple Search Ads token resolved
to a campaign, HMAC-signed beacons accepted. [`TESTING.md`](TESTING.md) is the
runbook that got there, including what a Simulator can and cannot prove.

Requires iOS 14+. Add to `Info.plist` (for the ATT prompt):

```
NSUserTrackingUsageDescription = "Used to measure which ads brought you here."
```

## Usage

```swift
import RoasSensor

// App start
Roas.configure(publicKey: "YOUR-SITE-PUBLIC-KEY")

// user known
Roas.identify(email: "buyer@example.com")

// events
Roas.track(.addToCart, properties: ["sku": "ABC", "qty": 1])
Roas.track(.custom, name: "boss_defeated")

// attribute a StoreKit purchase: set this as the purchase's appAccountToken
// and the App Store Server Notification traces back to this install
let purchaseToken = Roas.appAccountToken()

// forward universal links
func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if let url = userActivity.webpageURL { Roas.handleDeepLink(url) }
}
```

Point App Store Server Notifications (**Version 2**, sandbox and production) at
`https://<api>/api/tracking/webhooks/appstore/<public_key>`. Authenticity is
Apple's own signature, so there is no secret to configure; the site's
`bundle_id` must match the one inside the signed payload. RevenueCat users keep
`…/webhooks/revenuecat/<public_key>` and pass `visitorId()` as the `appUserID`
instead.

## The iOS attribution reality (be honest with customers)

iOS cannot be as deterministic as Android/web — Apple blocks device-level ad
attribution. What this SDK gets you:

| Signal | Determinism |
|---|---|
| Apple Search Ads token | deterministic (ASA traffic only) |
| IDFA (ATT-consented) | deterministic (only for users who tap "Allow", ~20–40%) |
| Deferred deep link `rsclid` | deterministic (when a universal link carries it) |
| SKAdNetwork | aggregate, campaign-level, delayed |
| IDFV / device match | device-local |

Everything unattributed is reported honestly, never guessed. See
`docs/mobile-tracking-design.md §2.2 and §11.1`.

## Building & testing

```bash
swift build && swift test    # 54 tests on the macOS host, no simulator needed
```

Open `Package.swift` in Xcode to develop against a device (ATT/IDFA/AdServices/
StoreKit need a real device or simulator).

## Backend follow-ups this SDK anticipates

- **ASA token resolution** — the SDK sends `asa_token` on first-open; a backend
  slice resolves it against Apple's API to campaign/keyword.
- **SKAdNetwork postback ingestion** — `/api/tracking/skan/postback` (design doc
  §6) decodes conversion values into the aggregate iOS report.
