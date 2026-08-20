import Foundation
import os.log
#if canImport(UIKit)
import UIKit
#endif
// `os(iOS)`, NOT `canImport`, for all four of these. Every one of them imports
// perfectly well on macOS -- which is why the guards read as correct -- but the
// APIs behind them do not exist there: SKAdNetwork is `unavailable in macOS`
// outright, ATTrackingManager is macOS 11+, AAAttribution is macOS 11.1+, and
// `Package.swift` declares macOS 10.15 so the parity tests can run on a Mac host
// with no simulator. A canImport guard therefore compiles on iOS and breaks
// `swift build` on the host -- which is exactly what it did, invisibly, until
// someone first built the macOS slice. `DeviceLocation.swift` carries the same
// note for the same reason.
#if os(iOS)
import AdSupport
import AppTrackingTransparency
import AdServices
import StoreKit
#endif
#if canImport(Network)
import Network
#endif

/// The iOS attribution signals, each guarded so the SDK compiles and runs even
/// where a framework is unavailable. Unlike Android there is no install referrer;
/// iOS attribution comes from Apple Search Ads (deterministic), the IDFA (only
/// with ATT consent), the IDFV, SKAdNetwork (aggregate), and deferred deep links.
enum DeviceContext {

    /// Same subsystem as `Transport`, separate category — so a customer
    /// filtering Console on com.roassensor.sdk sees setup problems and
    /// delivery problems together, but can still tell them apart.
    private static let attLog = OSLog(subsystem: "com.roassensor.sdk", category: "ATT")

    /// Per-vendor id — always available, links a vendor's own apps on one device.
    static func identifierForVendor() -> String? {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }

    /// The real form factor, in the backend's `device_type` vocabulary
    /// (`desktop|mobile|tablet`).
    ///
    /// This used to be the constant string `"mobile"` on the beacon, and
    /// `ingest.py` lets a beacon's `device_type` override its own User-Agent
    /// parse — so **every iPad was recorded as a phone**, the same way every
    /// Android tablet was before `DeviceInfo.deviceType` replaced the identical
    /// hardcode there. Tablets are where install attribution is thinnest, so the
    /// form factor most worth seeing was the one reporting made invisible.
    ///
    /// Unknown idioms (`.tv`, `.carPlay`, `.vision`) fall back to `"mobile"`
    /// rather than inventing a token: `TouchPoint.device_type` is a fixed
    /// vocabulary the dashboard buckets on, and a value it has never seen would
    /// silently drop those rows out of every form-factor breakdown.
    static func deviceType() -> String {
        #if canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: return "tablet"
        case .mac: return "desktop" // Mac Catalyst
        default: return "mobile"
        }
        #else
        return "mobile"
        #endif
    }

    // MARK: - Device context

    /// This SDK's own version, sent on every install so a bad row can be traced
    /// back to the build that produced it. **Keep in step with
    /// `RoasSensor.podspec`** — the backend stores this string, so a mismatch
    /// makes rows trace to the wrong build. `DeviceInfo.SDK_VERSION` carries the
    /// identical warning on Android for the identical reason.
    ///
    /// This string, `RoasSensor.podspec`'s version, and the git TAG must all
    /// agree. That triple is what makes a row traceable: SPM and CocoaPods
    /// resolve the tag, the beacon reports this, and a mismatch means a bad row
    /// points at a build that did not produce it.
    ///
    /// It tracked Android's `DeviceInfo.SDK_VERSION` up to 0.1.6, on the theory
    /// that one number should answer "which SDK am I on" across both platforms.
    /// That broke here: 0.1.7 is an iOS-only fix (the ATT prompt, which 0.1.6
    /// silently skipped on any Flutter host), and holding it at 0.1.6 to match
    /// Android would leave two builds with genuinely different behaviour
    /// reporting the same version -- defeating the one thing the field is for.
    static let sdkVersion = "0.1.7"

    /// The hardware identifier — `iPhone14,5`, `iPad13,1`. The iOS analogue of
    /// Android's `Build.MODEL`: the key Apple's own device tables join on, and
    /// the only way to answer "which devices are we losing installs on".
    /// `UIDevice.model` is deliberately NOT used — it returns the useless
    /// constant "iPhone" for every iPhone ever made.
    /// Read through `Mirror` rather than by rebinding a pointer into `info`:
    /// `machine` is a fixed-size C tuple, and the pointer form both borrows
    /// `info` while still reading it (an exclusivity trap) and leans on
    /// `String(validatingUTF8:)`, which newer Swift has renamed. This walks the
    /// tuple's bytes and stops at the NUL, which is what the C string means.
    static func deviceModel() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "" }
        return Mirror(reflecting: info.machine).children.reduce(into: "") { model, element in
            guard let byte = element.value as? CChar, byte != 0 else { return }
            // bitPattern, not UInt8(byte): the plain initializer TRAPS on a
            // negative CChar. Machine identifiers are ASCII so it would never
            // fire in practice, but "never in practice" is not a reason to leave
            // a crash reachable from a host app's launch path.
            model.append(Character(UnicodeScalar(UInt8(bitPattern: byte))))
        }
    }

    static func osVersion() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ""
        #endif
    }

    /// Pixels, matching Android's `widthPixels x heightPixels` — `bounds` alone
    /// is in points, so two devices with very different screens would report the
    /// same string and the column would be worthless for exactly the comparison
    /// it exists to support.
    static func screen() -> String {
        #if canImport(UIKit)
        let bounds = UIScreen.main.nativeBounds
        return "\(Int(bounds.width))x\(Int(bounds.height))"
        #else
        return ""
        #endif
    }

    /// BCP-47 (`en-IN`), the same shape Android's `Locale.toLanguageTag()` sends.
    /// The two must agree: one dashboard groups both.
    static func language() -> String {
        Locale.preferredLanguages.first ?? ""
    }

    /// The IANA zone id (`Asia/Kolkata`). Not cosmetic — `SessionTracker` rolls a
    /// session at the visitor's *local* midnight and `retention.py` counts a
    /// return as a session on a later calendar day, so without this the server
    /// cannot re-derive or check the boundary its own cohorts are built on.
    static func timezone() -> String {
        TimeZone.current.identifier
    }

    /// Where this build came from, in the spirit of Android's
    /// `installer_package`: separating the customer's own QA from real users is
    /// most of the value of the integrity signals, and a TestFlight build is the
    /// single clearest QA tell iOS offers.
    ///
    /// Four states, and the file-existence check is what separates the two that
    /// look identical from the URL alone.
    ///
    /// `appStoreReceiptURL` is non-nil even when no receipt was ever issued, and
    /// on a build installed straight from Xcode it points at a `sandboxReceipt`
    /// path with **nothing at it**. Reading only the filename therefore labelled
    /// a developer's own debug build `testflight` — observed on an iPhone 14
    /// running this very SDK. That is not a cosmetic mislabel: this column exists
    /// to separate the customer's own testing from real users, so a developer
    /// build wearing a QA-channel badge defeats the one job it has.
    ///
    /// TestFlight installs a real sandbox receipt file; a development build does
    /// not. So: file present + sandbox name → TestFlight, file present otherwise
    /// → App Store, URL but no file → development.
    static func installerSource() -> String {
        #if targetEnvironment(simulator)
        return "simulator"
        #else
        guard let receipt = Bundle.main.appStoreReceiptURL else { return "" }
        guard FileManager.default.fileExists(atPath: receipt.path) else { return "development" }
        return receipt.lastPathComponent == "sandboxReceipt" ? "testflight" : "app_store"
        #endif
    }

    /// Logical size in points — `WxH`. `screen()` above is raw pixels, which
    /// says nothing about physical size on its own: 1170px is a phone or a
    /// tablet depending entirely on scale. This is also what `device_type` is
    /// derived from, so sending the inputs lets the phone/tablet split be
    /// retuned server-side instead of frozen in whatever build a handset
    /// happens to be running. Points are iOS's dp — the same idea Android's
    /// `viewport` carries, so one column holds both.
    static func viewport() -> String {
        #if canImport(UIKit)
        let bounds = UIScreen.main.bounds
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        return width > 0 && height > 0 ? "\(width)x\(height)" : ""
        #else
        return ""
        #endif
    }

    /// Screen density in DPI, so it is comparable with Android's `densityDpi`
    /// in the same column rather than being a bare 2.0/3.0 that means nothing
    /// beside a value of 440. 160 is the platform-independent baseline both
    /// systems scale from (iOS `scale` 1 == Android `mdpi` == 160dpi).
    static func screenDensity() -> Int? {
        #if canImport(UIKit)
        let dpi = Int((UIScreen.main.scale * 160).rounded())
        return dpi > 0 ? dpi : nil
        #else
        return nil
        #endif
    }

    /// The user's REGION, distinct from `language()`: a Hindi speaker in the US
    /// and one in India share a language tag and belong in different rows of a
    /// geo report. Free, and unlike IP geo it is unaffected by a VPN.
    static func localeCountry() -> String {
        let region: String?
        if #available(iOS 16, macOS 13, *) {
            region = Locale.current.region?.identifier
        } else {
            region = Locale.current.regionCode
        }
        return String((region ?? "").uppercased().prefix(8))
    }

    /// Physical RAM in MB. Memory class segments budget from flagship, which is
    /// genuinely predictive of conversion and LTV. Android also sends its own
    /// `is_low_ram` OS flag; iOS has no equivalent and deliberately does not
    /// invent one — the server can threshold this number and retune it later,
    /// which a boolean baked into a shipped build could not.
    static func totalRamMb() -> Int? {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let mb = Int(bytes / (1024 * 1024))
        return mb > 0 ? mb : nil
    }

    static func cpuCores() -> Int? {
        let count = ProcessInfo.processInfo.processorCount
        return count > 0 ? count : nil
    }

    /// Seconds since boot. A device reporting an install within moments of
    /// booting, over and over, is the shape of a farm VM being cycled — a real
    /// handset accumulates uptime. Also lets the server sanity-check a client
    /// clock independently of `clock_offset_seconds`.
    ///
    /// `systemUptime` excludes time the device spent asleep, so on iOS this
    /// reads a little low against Android's `elapsedRealtime`. That is fine for
    /// what the field is for — the farm tell is a value near zero, and no
    /// threshold sits anywhere near the difference.
    static func uptimeSeconds() -> Int? {
        let uptime = Int(ProcessInfo.processInfo.systemUptime)
        return uptime > 0 ? uptime : nil
    }

    /// The OS build identifier (`21G72`), read from `kern.osversion`.
    ///
    /// It shares Android's `build_fingerprint` column because it answers the
    /// same question that column exists for: keeping the RAW evidence, not just
    /// the booleans `DeviceIntegrity` derives from it, is what lets an
    /// integrity rule be retuned on a deploy AND applied retroactively to
    /// installs already recorded. It is not the multi-part string Android
    /// sends — iOS has no such thing — but it is the closest raw build
    /// evidence the platform exposes, and it separates a beta or an
    /// out-of-support build from a current one.
    static func osBuild() -> String {
        sysctlString("kern.osversion")
    }

    /// The board identifier (`D63AP`) — the analogue of the `Build.BOARD`
    /// fallback Android puts in `soc` below API 31. `device_model`
    /// (`iPhone14,5`) is one string a spoofer edits wholesale; this is a
    /// separate field it must remember to keep CONSISTENT with it, which is
    /// where careless spoofing shows.
    static func board() -> String {
        String(sysctlString("hw.model").prefix(64))
    }

    /// `(firstInstall, lastUpdate)` as epoch **seconds**, or nil.
    ///
    /// The two containers answer the two questions on their own. iOS replaces
    /// the **bundle** container on every app update while the **data**
    /// container (Documents) persists from the original install, so the
    /// Documents creation date is the true install moment and the bundle's is
    /// the last update. `resetIfDataWasResurrected` already relies on the first
    /// of these for exactly this property.
    ///
    /// Seconds, not millis: the server's `_epoch_seconds` guard deliberately
    /// rejects millis-shaped values, so converting here is required rather
    /// than tidy.
    static func installTimes() -> (Int64?, Int64?) {
        let manager = FileManager.default
        /// Creation date, falling back to modification date. Both are optional
        /// in `attributesOfItem` and which one a path carries is not something
        /// to rely on -- see the bundle chain below.
        func stamp(_ url: URL?) -> Int64? {
            guard
                let url = url,
                let attrs = try? manager.attributesOfItem(atPath: url.path)
            else { return nil }
            let date = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
            guard let seconds = date.map({ Int64($0.timeIntervalSince1970) }), seconds > 0 else {
                return nil
            }
            return seconds
        }
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first
        // The `.app` bundle reports no creation date on a real device -- it
        // sits on a sealed, read-only volume -- while the Simulator hands one
        // over happily. Measured on an iPhone 12 mini running iOS 16.7:
        // `first_install_at` arrived and `last_update_at` was empty, on a build
        // where the Simulator had reported both. So try outward: the bundle,
        // then the container directory holding it, then the executable. The
        // first that answers wins; if none do the field is simply absent, which
        // is the rule everywhere else in this file.
        let bundle = Bundle.main.bundleURL
        let lastUpdate = stamp(bundle)
            ?? stamp(bundle.deletingLastPathComponent())
            ?? stamp(Bundle.main.executableURL)
        return (stamp(documents), lastUpdate)
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        // Stop at the NUL, which is what the C string means — the buffer is
        // sized to include it. Decoded from the bytes rather than through
        // `String(cString:)`, which newer Swift deprecates: the same renaming
        // trap `deviceModel()` above already documents for
        // `String(validatingUTF8:)`.
        // `prefix(while:)` spelled out rather than as a trailing closure: a
        // trailing closure sitting inside another call's argument list is the
        // kind of thing Swift's parser has opinions about across versions.
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    // MARK: - Volatile context

    #if canImport(Network)
    /// Started once in `startMonitoring()`. Held for the process lifetime on
    /// purpose: `currentPath` is only populated while a monitor is running, and
    /// starting one per beacon would pay the setup cost on the install report's
    /// critical path for a field that merely decorates it.
    private static var pathMonitor: NWPathMonitor?
    #endif

    /// Values read on the main thread and cached — battery and location both
    /// touch APIs that expect it. Refreshed at `configure` and on every
    /// foreground, which is often enough for fields whose whole purpose is
    /// coarse segmentation.
    private static let volatileLock = NSLock()
    private static var mainThreadContext: [String: Any] = [:]

    /// Begin watching the network path. Call once, from `configure`.
    static func startMonitoring() {
        #if canImport(Network)
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "com.roassensor.sdk.network"))
        pathMonitor = monitor
        #endif
    }

    /// Re-read the fields that need the main thread. **Call on the main thread.**
    static func refreshVolatile() {
        var context: [String: Any] = [:]
        #if canImport(UIKit)
        // Enabling monitoring is a mutation of the HOST app's shared UIDevice,
        // so it is done once and never toggled back: restoring the previous
        // value immediately would send `batteryLevel` back to -1 and defeat the
        // read. Leaving it on only causes iOS to post battery notifications the
        // app is free to ignore — and any host app that wanted the value now
        // gets it too.
        //
        // The level stays -1 for a moment after enabling, which is why every
        // read is guarded and why a very first cold launch may report no
        // battery on the install beacon while every later beacon carries it.
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel
        if level >= 0 {
            context["battery_level"] = Int((level * 100).rounded())
        }
        switch device.batteryState {
        case .charging, .full: context["battery_charging"] = true
        case .unplugged: context["battery_charging"] = false
        default: break // .unknown — the device did not say, which is not "false"
        }
        #endif
        // Coordinates ONLY when the host app already holds a location
        // permission of its own — this SDK declares none and prompts for none,
        // so on every other app this is simply absent. See DeviceLocation.
        if let (latitude, longitude) = DeviceLocation.read() {
            context["latitude"] = latitude
            context["longitude"] = longitude
        }
        volatileLock.lock()
        mainThreadContext = context
        volatileLock.unlock()
    }

    /// The fields that change over a process lifetime, merged onto each
    /// touchpoint beacon. Safe to call from any thread.
    static func volatileContext() -> [String: Any] {
        volatileLock.lock()
        var context = mainThreadContext
        volatileLock.unlock()
        if let uptime = uptimeSeconds() { context["uptime_seconds"] = uptime }
        #if canImport(Network)
        if let path = pathMonitor?.currentPath {
            let transport: String
            if path.usesInterfaceType(.wifi) {
                transport = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                transport = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                // A handset on wired ethernet is worth seeing: it is far more
                // often a simulator or a device farm than a phone.
                transport = "ethernet"
            } else if path.status == .satisfied {
                transport = "other"
            } else {
                transport = ""
            }
            if !transport.isEmpty { context["network_type"] = transport }
            context["is_vpn"] = isVPN(path)
        }
        #endif
        return context
    }

    #if canImport(Network)
    /// Whether a VPN is carrying this path.
    ///
    /// Load-bearing rather than decorative: the backend's deferred same-IP
    /// match is the only place an install with no ASA token and no deep link
    /// can still be attributed, and it compares the install's IP to the click's
    /// — which a VPN silently invalidates, producing a wrong match or a missed
    /// one with no way to tell after the fact.
    ///
    /// iOS exposes no VPN flag, so this reads the tunnel interface names the
    /// system uses (`utun`, `ipsec`, `ppp`, `tap`, `tun`). It catches every
    /// ordinary VPN, including the Personal VPN and NetworkExtension providers.
    ///
    /// **It also fires on iCloud Private Relay**, which is a tunnel that is not
    /// a VPN in the usual sense — and that is deliberate rather than a bug to
    /// be filtered out. This column has one consumer: judging whether the
    /// install's IP is the device's own before an IP-proximity match is trusted.
    /// Private Relay relays the egress IP exactly as a VPN does, so for the only
    /// question the field answers, true is the correct answer. It would be the
    /// wrong answer for a "how many of my users run a VPN" report, and this
    /// field should not be used to build one.
    ///
    /// A signal, not proof — the column is tri-state server-side and NULL means
    /// "the device never told us", which is deliberately not the same as false.
    private static func isVPN(_ path: NWPath) -> Bool {
        let tunnelPrefixes = ["utun", "ipsec", "ppp", "tap", "tun"]
        for interface in path.availableInterfaces {
            let name = interface.name.lowercased()
            if tunnelPrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        }
        // A VPN configured as a proxy shows up in the scoped proxy settings
        // rather than as an interface on the path.
        //
        // Bridged through NSDictionary rather than cast straight to
        // `[String: Any]`: CFDictionary is toll-free bridged to NSDictionary
        // and that cast is guaranteed, whereas the direct one relies on a
        // conditional bridge that has changed behaviour across Swift releases.
        guard let unmanaged = CFNetworkCopySystemProxySettings() else { return false }
        let settings = unmanaged.takeRetainedValue() as NSDictionary
        guard let scoped = settings["__SCOPED__"] as? [String: Any] else { return false }
        return scoped.keys.contains { key in
            let name = key.lowercased()
            return tunnelPrefixes.contains(where: { name.hasPrefix($0) })
        }
    }
    #endif

    /// Every device field, resolved once — the twin of `DeviceInfo.describe` on
    /// Android, filling the same columns from the same call sites.
    ///
    /// A **snapshot** rather than a per-beacon read, because `userInterfaceIdiom`,
    /// `UIDevice.systemVersion` and `UIScreen.main` are main-thread state while
    /// `reportFirstOpen` runs on the transport's background queue. `Roas` takes
    /// this once during `configure`, on whichever thread the app starts us from,
    /// and every later beacon is then a dictionary copy that touches no UIKit at
    /// all. Nothing here changes over a process lifetime, so there is nothing to
    /// re-read: `nativeBounds` is the physical screen, not the current window.
    ///
    /// Empty values are omitted rather than written as "" — a blank field is
    /// always better than a lost install, and an absent key lets the server keep
    /// whatever it already knew.
    ///
    /// Only the fields that genuinely cannot change live here. Battery,
    /// network, location and uptime move over a process lifetime and are read
    /// through `volatileContext()` instead — snapshotting those would report
    /// the state at launch on a beacon sent an hour later, which is worse than
    /// not reporting them at all for fields whose whole purpose is to describe
    /// the moment.
    static func snapshot() -> [String: Any] {
        var context: [String: Any] = [
            "sdk_version": sdkVersion,
            "device_type": deviceType(),
            "device_manufacturer": "Apple",
        ]
        let pairs: [(String, String)] = [
            ("os_version", osVersion()),
            ("device_model", deviceModel()),
            ("screen", screen()),
            ("viewport", viewport()),
            ("language", language()),
            ("locale_country", localeCountry()),
            ("timezone", timezone()),
            ("installer_package", installerSource()),
            ("build_fingerprint", osBuild()),
            ("soc", board()),
        ]
        for (key, value) in pairs where !value.isEmpty {
            context[key] = value
        }
        if let density = screenDensity() { context["screen_density"] = density }
        if let ram = totalRamMb() { context["total_ram_mb"] = ram }
        if let cores = cpuCores() { context["cpu_cores"] = cores }
        // The OS's own record of when this app was installed and last updated,
        // read from the container layout rather than from anything inside our
        // own storage — so no backup/restore or data clone can forge it (the
        // same property `Roas.resetIfDataWasResurrected` already relies on). It
        // gives the server a true install moment independent of when the beacon
        // arrived, and `first_install_at != last_update_at` is how a genuine
        // first install is told apart from an update reporting for the first
        // time after the SDK was added.
        let (firstInstall, lastUpdate) = installTimes()
        if let firstInstall = firstInstall { context["first_install_timestamp"] = firstInstall }
        if let lastUpdate = lastUpdate { context["last_update_timestamp"] = lastUpdate }
        return context
    }

    /// The IDFA — only when the user granted App Tracking Transparency. Returns nil
    /// otherwise (the system hands back all-zeros, which we never send). Opt-out is
    /// respected: no consent, no id.
    static func advertisingIdentifier() -> String? {
        #if os(iOS)
        if #available(iOS 14, *) {
            guard ATTrackingManager.trackingAuthorizationStatus == .authorized else { return nil }
        }
        let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        return idfa == "00000000-0000-0000-0000-000000000000" ? nil : idfa
        #else
        return nil
        #endif
    }

    /// Present the ATT prompt, then call back. No-op (immediate callback) where ATT
    /// is unavailable. The caller reports the install AFTER this resolves, so the
    /// IDFA is available on first-open when the user allowed it.
    static func requestTracking(_ completion: @escaping () -> Void) {
        #if os(iOS)
        if #available(iOS 14, *) {
            // iOS TERMINATES the host app — not an error, a hard crash — if this
            // is called without NSUserTrackingUsageDescription in Info.plist. The
            // caller runs reportFirstOpen *inside* this completion, so that crash
            // costs the install beacon too: the customer gets an app that dies on
            // launch AND no attribution, with nothing connecting the two.
            //
            // Found exactly that way. A `flutter create` iOS folder ships without
            // the key, so the first real-device Flutter run died silently — a
            // healthy backend and a correct URL, and zero rows.
            //
            // Skipping the prompt loses the IDFA, which is a real cost; crashing
            // loses the IDFA, the install, and the app. Degrade, never take down
            // the install report — the same rule DeviceInfo states on Android.
            guard Bundle.main.object(forInfoDictionaryKey: "NSUserTrackingUsageDescription") != nil else {
                if Roas.logLevel >= .error {
                    // One literal, no `+`: os_log takes a StaticString, and
                    // concatenation produces a String — which is a compile error,
                    // not a warning.
                    os_log(
                        "ATT skipped: no NSUserTrackingUsageDescription in Info.plist. Add it to prompt for tracking; until then there is no IDFA.",
                        log: attLog,
                        type: .error
                    )
                }
                completion()
                return
            }
            promptWhenActive(completion)
            return
        }
        #endif
        completion()
    }

    #if os(iOS)
    /// How long to wait for the app to become active before giving up on the
    /// prompt. Generous, because the cost of it being too short is a silently
    /// skipped prompt, while the cost of being too long is a delayed install
    /// report on an app that was never going to foreground anyway.
    private static let activeWaitSeconds: TimeInterval = 10

    /// One-shot guard: `completion` must run exactly once, whichever of the
    /// paths below reaches it first. It is not optional — `Roas.configure` runs
    /// `reportFirstOpen` *inside* this completion, so a path that fails to call
    /// it does not merely lose the IDFA, it loses the install.
    private final class PromptState {
        private let lock = NSLock()
        private var finished = false
        /// Main-thread only, so no lock: set when the prompt is actually shown.
        var promptShown = false
        private let completion: () -> Void

        init(_ completion: @escaping () -> Void) { self.completion = completion }

        func finish() {
            lock.lock()
            let already = finished
            finished = true
            lock.unlock()
            if !already { completion() }
        }
    }

    /// Raise the ATT prompt once the app is genuinely `.active`.
    ///
    /// iOS only displays this dialog while the app is active. A request fired a
    /// moment too early is **silently discarded** — no prompt, no answer
    /// recorded, and `.notDetermined` returned as though the user had never
    /// been asked. There is no error and nothing in the log.
    ///
    /// This used to be a flat 0.6s delay, tuned against a native SwiftUI app
    /// calling `configure` from `onAppear`, where the view is already on screen.
    /// It is not enough for **Flutter**, where `Roas.initialize` runs from Dart
    /// `main()` before `runApp()` and the engine has yet to boot, load Dart and
    /// render a first frame. Measured on an iPhone 12 mini: no prompt at launch,
    /// the app absent from Settings → Privacy & Security → Tracking (which lists
    /// only apps that have actually asked), and the IDFA lost for the life of the
    /// install unless something called `requestTracking` again later. Every
    /// Flutter host was losing its launch-time prompt this way.
    ///
    /// So: ask now if we are active, otherwise wait for `didBecomeActive` — the
    /// real signal rather than a guess at how long it takes to arrive.
    @available(iOS 14, *)
    private static func promptWhenActive(_ completion: @escaping () -> Void) {
        let state = PromptState(completion)

        func prompt() {
            state.promptShown = true
            ATTrackingManager.requestTrackingAuthorization { _ in state.finish() }
        }

        DispatchQueue.main.async {
            if UIApplication.shared.applicationState == .active {
                prompt()
                return
            }
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in
                if let observer = observer { NotificationCenter.default.removeObserver(observer) }
                prompt()
            }
            // The install report cannot wait forever on an app that never
            // foregrounds. If the prompt is already up when this fires we do
            // NOT cut it short — a visible prompt means the app is active and
            // the user is mid-answer; `identify()` re-reads the IDFA afterwards
            // either way.
            DispatchQueue.main.asyncAfter(deadline: .now() + activeWaitSeconds) {
                if let observer = observer { NotificationCenter.default.removeObserver(observer) }
                if !state.promptShown { state.finish() }
            }
        }
    }
    #endif

    /// An Apple Search Ads read: the token, and **why** when there isn't one.
    ///
    /// The status half is the point. Android has never had to guess why an
    /// install arrived unattributed — `referrer_status` says so, and that is what
    /// made the Galaxy M32 / Tab S6 Lite failures countable instead of something
    /// found by hand on borrowed hardware. iOS had no equivalent: a nil token
    /// collapsed "this device predates AdServices", "the API errored", and "this
    /// install genuinely came from no Apple Search Ads campaign" into one silence,
    /// so nobody could size their own iOS attribution loss — or tell a real ROAS
    /// drop from a measurement gap.
    struct AsaResult {
        let token: String?
        let status: String
    }

    static func appleSearchAds() -> AsaResult {
        #if os(iOS)
        if #available(iOS 14.3, *) {
            do {
                let token = try AAAttribution.attributionToken()
                return AsaResult(token: token, status: token.isEmpty ? "ASA_OK_EMPTY" : "ASA_OK")
            } catch {
                // Kept as the raw code rather than a message: `referrer_status` is
                // 32 chars, and Apple's descriptions are not.
                return AsaResult(token: nil, status: "ASA_ERROR:\((error as NSError).code)")
            }
        }
        // AdServices exists but this OS predates the API — an old device, not a
        // failure, and a different fact from the framework being absent entirely.
        return AsaResult(token: nil, status: "ASA_UNSUPPORTED_OS")
        #else
        return AsaResult(token: nil, status: "ASA_UNAVAILABLE")
        #endif
    }

    /// Whether a failed read is worth trying again on a later launch — the twin
    /// of `InstallReferrerReader.isTransient` on Android, and the reason
    /// `Roas.retryAppleSearchAds` exists.
    ///
    /// Only `ASA_ERROR:*` qualifies. Apple documents `AAAttribution` as
    /// genuinely failing on a device that has just booted or has no network
    /// yet, which is precisely the state a device is in moments after a fresh
    /// install completes — the one read we get. The other statuses are settled
    /// facts, not failures: `ASA_UNSUPPORTED_OS` and `ASA_UNAVAILABLE` describe
    /// the device and will say the same thing forever, and both `ASA_OK`
    /// variants already succeeded.
    static func isTransientAsaStatus(_ status: String) -> Bool {
        #if targetEnvironment(simulator)
        // AdServices does not work in the Simulator at all -- it returns an
        // error on every call, forever -- so no number of retries can produce a
        // token. Retrying there spends the five-launch budget on a certainty
        // and fills a QA log with failures that mean nothing. Observed as
        // `ASA_ERROR:3` on an iPhone 15 Pro Simulator.
        //
        // Deliberately keyed on the Simulator rather than on error code 3:
        // whatever that code turns out to mean on a real device, "AdServices
        // cannot work here" is provable from the build environment alone.
        return false
        #else
        return status.hasPrefix("ASA_ERROR:")
        #endif
    }

    /// Register the install with SKAdNetwork / AdAttributionKit so the ad network
    /// can attribute it. Best-effort; call once at first launch.
    static func registerForAdNetworkAttribution() {
        #if os(iOS)
        if #available(iOS 16.1, *) {
            SKAdNetwork.updatePostbackConversionValue(0) { _ in }
        } else if #available(iOS 11.3, *) {
            SKAdNetwork.registerAppForAdNetworkAttribution()
        }
        #endif
    }

    /// Update the SKAdNetwork fine (0–63) and, where available, coarse conversion
    /// value on a key event. What the number *means* is the site's
    /// `skan_conversion_schema` server-side — this only transmits it.
    ///
    /// Coarse is carried because `skadnetwork.decode_event` already reads a
    /// `coarse` map and nothing was ever able to set one. It matters more than
    /// the fine value in practice: Apple withholds the fine value entirely below
    /// its (undisclosed) install-volume privacy threshold, which most campaigns
    /// sit under, and then coarse is the *only* signal that survives the
    /// postback. Sending fine alone means small campaigns report nothing at all.
    ///
    /// `lockWindow` ends the measurement window immediately and sends the
    /// postback early. Off by default: it trades all later conversion data for
    /// speed, which is only the right call once the value is genuinely final.
    static func updateConversionValue(_ value: Int, coarse: String?, lockWindow: Bool) {
        #if os(iOS)
        if #available(iOS 16.1, *) {
            if let coarse = coarse, let mapped = coarseValue(coarse) {
                SKAdNetwork.updatePostbackConversionValue(
                    value, coarseValue: mapped, lockWindow: lockWindow
                ) { _ in }
            } else {
                SKAdNetwork.updatePostbackConversionValue(value) { _ in }
            }
        } else if #available(iOS 14, *) {
            // Pre-16.1 has no coarse concept at all; the fine value is the whole
            // channel, so a caller sending only coarse would silently do nothing.
            SKAdNetwork.updateConversionValue(value)
        }
        #endif
    }

    #if os(iOS)
    /// The strings the backend schema uses (`{"coarse": {"high": …, "low": …}}`)
    /// mapped to Apple's enum. Unknown input returns nil and the caller falls
    /// back to a fine-only update rather than guessing a bucket.
    @available(iOS 16.1, *)
    private static func coarseValue(_ name: String) -> SKAdNetwork.CoarseConversionValue? {
        switch name.lowercased() {
        case "low": return .low
        case "medium", "mid": return .medium
        case "high": return .high
        default: return nil
        }
    }
    #endif
}
