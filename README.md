# ROASSensor iOS SDK (`RoasSensor`)

Native iOS tracking for ROASSensor — the Swift twin of `sdk-android`, same wire
format (`/api/tracking/mobile/*`), plus the iOS-specific attribution signals.
Revenue is **not** sent from the app; it enters only through the signed RevenueCat
webhook, so ROAS stays defensible.

## What it does

- **Install reporting** on first launch, with the iOS attribution signals:
  - **Apple Search Ads** attribution token (`AdServices` `AAAttribution`) —
    deterministic, Apple-sanctioned, no consent needed.
  - **IDFA** — only when the user grants App Tracking Transparency (opt-out
    respected). Sent raw; the server hashes it (matches a RevenueCat `$idfa`).
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
.package(url: "https://github.com/rishabhrk2345/Roas-ios-SDK", from: "0.1.6")
```

CocoaPods — this is **not** on the CocoaPods trunk, so name the source yourself:

```ruby
pod 'RoasSensor', :git => 'https://github.com/rishabhrk2345/Roas-ios-SDK.git', :tag => '0.1.6'
```

> Both resolve against a **git tag**, so releasing means tagging the repo, not
> just bumping `s.version`. A version with no matching tag fails at
> `pod install` rather than quietly serving the previous code.

**This package has never been compiled** — it was written on Windows, where
there is no Swift compiler. Before trusting anything here, work through
[`TESTING.md`](TESTING.md), which starts with `swift build` / `swift test` on a
Mac host (no simulator needed) and ends at a physical device.

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

// attribute purchases via RevenueCat
Purchases.configure(with: Configuration.Builder(withAPIKey: "rc_key")
    .with(appUserID: Roas.visitorId())
    .build())

// forward universal links
func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if let url = userActivity.webpageURL { Roas.handleDeepLink(url) }
}
```

Point your RevenueCat webhook at
`https://<api>/api/tracking/webhooks/revenuecat/<public_key>`.

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
cd sdk-ios
swift test    # runs the hash-parity tests (macOS, no simulator needed)
```

Open `Package.swift` in Xcode to develop against a device (ATT/IDFA/AdServices/
StoreKit need a real device or simulator).

## Backend follow-ups this SDK anticipates

- **ASA token resolution** — the SDK sends `asa_token` on first-open; a backend
  slice resolves it against Apple's API to campaign/keyword.
- **SKAdNetwork postback ingestion** — `/api/tracking/skan/postback` (design doc
  §6) decodes conversion values into the aggregate iOS report.
