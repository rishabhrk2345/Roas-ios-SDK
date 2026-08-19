import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// ROASSensor iOS SDK — the public entry point.
///
/// ```swift
/// // AppDelegate / App init
/// Roas.configure(publicKey: "YOUR-SITE-PUBLIC-KEY")
///
/// // when the user is known
/// Roas.identify(email: "buyer@example.com")
///
/// // pass the visitor id to RevenueCat so purchases attribute to this install
/// Purchases.configure(with: .init(withAPIKey: rcKey).with(appUserID: Roas.visitorId()))
///
/// // forward deferred/universal links so their rsclid attributes the install
/// Roas.handleDeepLink(url)
/// ```
///
/// On first launch it presents the ATT prompt (optional), reads the available
/// iOS attribution signals — Apple Search Ads token, IDFA (if allowed), IDFV —
/// registers with SKAdNetwork, and reports the install. Delivery is a persisted,
/// idempotent queue, so an offline install is reported on the next launch.
public enum Roas {
    /// Launches to keep retrying a transiently-failed Apple Search Ads read
    /// before giving up. Apple attributes an install for far longer than five
    /// launches, so the bound costs no real recovery — it just stops a device
    /// whose AdServices never answers from paying for the attempt forever.
    /// Mirrors `MAX_REFERRER_ATTEMPTS` in `Roas.kt`.
    private static let maxAsaAttempts = 5

    private static let lock = NSLock()
    private static var publicKey = ""
    private static var storage: Storage?
    private static var transport: Transport?
    private static var sessions: SessionTracker?
    private static var initialized = false

    /// The device fields stamped onto every touchpoint beacon, resolved once in
    /// `configure` and reused. `reportFirstOpen` runs on the transport's
    /// background queue while `UIScreen.main` and `UIDevice.current` are
    /// main-thread state, so the single UIKit read stays on the thread the app
    /// starts us from and every later beacon is just a dictionary copy.
    private static var deviceContext: [String: Any] = [:]

    /// Merge the device context into a beacon. Kept as a helper so the call
    /// sites that describe a device cannot drift apart the way iOS's
    /// `handleDeepLink` had already drifted from Android's.
    ///
    /// Two layers, for one reason: `deviceContext` is a launch-time snapshot of
    /// things that cannot change (model, screen, install dates) taken on the
    /// main thread because it reads UIKit, while `volatileContext()` re-reads
    /// the things that do change (battery, network, uptime, location) at the
    /// moment the beacon is built. Freezing the second group at launch would
    /// report an hour-old battery level and the network the app started on,
    /// which for fields that exist to describe *this* moment is worse than
    /// sending nothing.
    private static func describe(_ body: inout [String: Any]) {
        for (key, value) in deviceContext { body[key] = value }
        for (key, value) in DeviceContext.volatileContext() { body[key] = value }
    }

    /// Mirrors Android's `Roas.kt` `resetIfDataWasResurrected()`. Compares the
    /// app's Documents-directory creation date — recreated fresh by the OS at
    /// real install time, unlike UserDefaults content, which an iCloud/iTunes
    /// backup restore can carry over into what the OS considers a brand-new
    /// install — against what `Storage.installAnchor` last recorded. A mismatch
    /// means this process is running on an install `Storage` doesn't actually
    /// know about, so every install/session/queue field is wiped before
    /// anything else touches `store`. Called first thing in `configure`, before
    /// `Transport`/`SessionTracker` are built on top of `store`.
    private static func resetIfDataWasResurrected(_ store: Storage) {
        guard
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
            let attrs = try? FileManager.default.attributesOfItem(atPath: documentsURL.path),
            let created = attrs[.creationDate] as? Date
        else { return }
        let actual = created.timeIntervalSince1970
        guard actual > 0 else { return }
        if store.installAnchor != actual {
            store.resetForNewInstall()
            store.installAnchor = actual
        }
    }

    /// How much `Transport` writes to the console on every delivery attempt.
    /// Defaults to `.error` — quiet in a release build, loud enough that a
    /// device that can never deliver anything shows up immediately instead
    /// of needing a network debugger attached.
    public private(set) static var logLevel: RoasLogLevel = .error

    /// Fired after every delivery attempt, success or failure. Optional —
    /// most apps don't need it — but without it there was no way for the
    /// host app to know a beacon ever failed short of watching the console
    /// by hand. `error` is nil on success.
    static var deliveryCallback: ((_ path: String, _ success: Bool, _ error: String?) -> Void)?

    /// Controls console verbosity — see `logLevel`.
    public static func setLogLevel(_ level: RoasLogLevel) {
        logLevel = level
    }

    /// Observe delivery results (e.g. to surface a debug banner in a QA
    /// build, or forward to your own crash/analytics tooling). Pass nil to
    /// stop observing.
    public static func setOnDeliveryResult(_ callback: ((_ path: String, _ success: Bool, _ error: String?) -> Void)?) {
        deliveryCallback = callback
    }

    /// Start the SDK. Call once, early. Idempotent.
    ///
    /// - Parameters:
    ///   - publicKey: the app property's public key from ROASSensor setup.
    ///   - appSecret: this property's beacon signing secret, from Setup → your
    ///     app → Beacon signing. Optional: without it beacons go unsigned, which
    ///     the collector accepts until the customer turns on "require signed
    ///     beacons". It is NOT a revenue credential — that is the server-side api
    ///     key, which must never ship inside an app. The worst an extracted one
    ///     allows is forging beacons, which the public key alone already allowed,
    ///     and rotating it invalidates every build carrying the old one.
    ///   - customerUserId: your own user id if already known; bound as an external
    ///     id so the same person on web / another device / this app is one identity.
    ///   - requestTrackingAuthorization: present the ATT prompt on first launch so
    ///     the IDFA can be read when the user allows it. Set false to present it
    ///     yourself at a better moment.
    ///   - baseUrl: override the collector host (defaults to production).
    public static func configure(
        publicKey: String,
        customerUserId: String? = nil,
        requestTrackingAuthorization: Bool = true,
        // Last, mirroring `Roas.kt`. Swift's named arguments make this position
        // harmless here — but the two SDKs' entry points are read side by side
        // (and bridged by one Flutter plugin), so they stay in the same order.
        appSecret: String? = nil,
        // A public function's default-argument expression can't reference a
        // private member, so the production host is inlined here as a literal.
        baseUrl: String = "https://api.roassensor.com"
    ) {
        lock.lock()
        if initialized { lock.unlock(); return }
        self.publicKey = publicKey
        let store = Storage()
        resetIfDataWasResurrected(store)
        let tx = Transport(baseUrl: baseUrl, storage: store, appSecret: appSecret)
        let tracker = SessionTracker(storage: store)
        storage = store
        transport = tx
        sessions = tracker
        initialized = true
        lock.unlock()

        // Before anything is dispatched to the transport queue, so the value is
        // published ahead of the first background read of it.
        deviceContext = DeviceContext.snapshot()
        // The network path monitor has to be running before `currentPath` says
        // anything, and battery/location want the main thread — both started
        // here, ahead of the first beacon, for the same publish-before-read
        // reason as the snapshot above.
        DeviceContext.startMonitoring()
        refreshVolatileOnMain()

        // Resolve the session BEFORE anything reports and before the lifecycle
        // observers are registered, so a foreground notification cannot race
        // reportFirstOpen. Whichever won would create session 1 and the loser
        // would emit a SECOND touch for the same moment — an install and an
        // app_open a millisecond apart, the phantom-touch duplication the pv_id
        // upsert exists to prevent, diluting every multi-touch credit split.
        let session = tracker.current()
        tracker.markForeground()
        registerLifecycle()

        tx.flush() // deliver anything queued from a previous offline launch
        DeviceContext.registerForAdNetworkAttribution()

        let start = {
            if !store.installReported {
                // The install touchpoint IS session 1's opening beacon.
                reportFirstOpen(customerUserId)
            } else {
                // A returning user whose session had expired. If it had not — the
                // app was jettisoned and relaunched inside 30 minutes — `started`
                // is false and nothing is sent: that is still the same visit.
                if session.started { sendSessionStart(session) }
                // The install is already on record, but its Apple Search Ads
                // token may not be: a transient AdServices failure on the very
                // first launch used to be permanent, because `installReported`
                // is set regardless of whether the read succeeded. Give it
                // another try here.
                if store.asaPending { retryAppleSearchAds() }
                if let uid = customerUserId { identify(customerUserId: uid) }
            }
        }
        // Ask ATT first (only on the very first launch, before reporting), so the
        // IDFA is available on the first-open beacon if the user allows it.
        if requestTrackingAuthorization && !store.installReported {
            DeviceContext.requestTracking { start() }
        } else {
            start()
        }
    }

    /// The stable visitor id for this install. Pass to RevenueCat as `appUserID`
    /// so a purchase carries it back and attributes to the install (and its ad).
    public static func visitorId() -> String? { storage?.visitorId }

    /// A UUID derived from the visitor id, to set as StoreKit's `appAccountToken`
    /// on a purchase (`Product.PurchaseOption.appAccountToken(_:)`) — so an App
    /// Store Server Notification attributes the sale to this install. The backend
    /// reconstructs the vid from it. Only needed for the native App Store
    /// Notifications path; RevenueCat uses `visitorId()` instead.
    public static func appAccountToken() -> UUID? {
        guard let vid = storage?.visitorId, vid.hasPrefix("rs") else { return nil }
        let hex = String(vid.dropFirst(2)).uppercased()
        guard hex.count == 32 else { return nil }
        let uuidString =
            "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-"
            + "\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        return UUID(uuidString: uuidString)
    }

    /// Present the ATT prompt at a moment of the app's choosing, and bind the
    /// IDFA if the user allows it.
    ///
    /// Pair with `configure(requestTrackingAuthorization: false)`. The default is
    /// to prompt on first launch, which is the worst possible moment: a cold-start
    /// system alert, before the user has seen anything worth trusting the app
    /// with, is the classic way to depress opt-in — and every denial costs the
    /// IDFA, which is the strongest identity key an iOS install can carry.
    ///
    /// Calling this AFTER the install has been reported is fine and is the whole
    /// point. The install beacon went out with no `device_id`, so on a grant we
    /// bind the IDFA through `/identify` — which mints exactly the same
    /// `IdentityKey` the install beacon would have. Without that follow-up,
    /// deferring the prompt would mean permanently discarding the IDFA of every
    /// user who said yes, making the better-timed prompt worse than the bad one.
    ///
    /// Safe to call more than once: once the user has answered, the system
    /// returns the existing status without re-prompting.
    public static func requestTrackingAuthorization(_ completion: (() -> Void)? = nil) {
        DeviceContext.requestTracking {
            if let idfa = DeviceContext.advertisingIdentifier() {
                bindAdvertisingId(idfa)
            }
            completion?()
        }
    }

    /// Report a SKAdNetwork conversion value — the only post-install signal that
    /// reaches an ad network for a user who denied ATT, which is most of them.
    ///
    /// The install is registered at `configure`, but nothing could ever update
    /// the value afterwards: `DeviceContext` is internal, so this was unreachable
    /// from a Flutter app *and* from a native Swift one, and every postback the
    /// backend decoded therefore carried value 0. Meanwhile the receiving end —
    /// `SkanPostbackView` and `Site.skan_conversion_schema` — was already built.
    ///
    /// - Parameters:
    ///   - value: the fine value, 0–63. Its meaning is the site's SKAN schema.
    ///   - coarse: `"low"`, `"medium"` or `"high"`. Send it: below Apple's
    ///     install-volume privacy threshold the fine value is withheld and coarse
    ///     is all that survives, so fine-only reporting goes dark on exactly the
    ///     small campaigns that most need measuring.
    ///   - lockWindow: end the measurement window and post immediately. Only when
    ///     the value is genuinely final — it discards every later conversion.
    public static func updateConversionValue(
        _ value: Int, coarse: String? = nil, lockWindow: Bool = false
    ) {
        DeviceContext.updateConversionValue(value, coarse: coarse, lockWindow: lockWindow)
    }

    /// Bind the user's identity. At least one argument must be non-nil.
    public static func identify(email: String? = nil, phone: String? = nil, customerUserId: String? = nil) {
        guard let tx = transport else { return }
        var body = baseBody()
        body["os"] = "iOS"
        let emailHash = Hashing.hashEmail(email)
        if !emailHash.isEmpty { body["email_hash"] = emailHash }
        let phoneHash = Hashing.hashPhone(phone)
        if !phoneHash.isEmpty { body["phone_hash"] = phoneHash }
        if let uid = customerUserId { body["external_id"] = uid }
        guard body["email_hash"] != nil || body["phone_hash"] != nil || body["external_id"] != nil
        else { return }
        // The advertising id belongs on THIS beacon too, not just the install.
        // `mobile._device_keys` binds it as an IdentityKey alongside the
        // email/phone being identified, which is what merges "this IDFA" and
        // "this person" into one identity — but it can only do that from a
        // payload carrying one, and this path never sent it, so the binding
        // happened once at first-open and never again.
        //
        // That single read is exactly the one most likely to have come back
        // nil, and on iOS more so than on Android: at first-open ATT is very
        // often still `.notDetermined` (the host app deferred the prompt to a
        // better moment, which this SDK actively encourages), and a user can
        // also switch tracking on for an app later from Settings → Privacy,
        // which fires no callback at all. Re-reading here is the only thing
        // that ever picks those up. Cheap enough to do inline — unlike
        // Android's GAID this is a local read, not a bound service call.
        if let idfa = DeviceContext.advertisingIdentifier() {
            body["device_id"] = idfa // raw; the server hashes it canonically
        }
        tx.send(path: "/api/tracking/mobile/identify", body: body)
    }

    /// Record a funnel/behaviour event (never revenue — see `RoasEvent`).
    public static func track(_ event: RoasEvent, name: String? = nil, properties: [String: Any]? = nil) {
        guard let tx = transport else { return }
        var body = baseBody()
        body["os"] = "iOS"
        body["name"] = event.rawValue
        if let name = name { body["label"] = name }
        if let props = properties { body["props"] = props }
        tx.send(path: "/api/tracking/mobile/events", body: body)
    }

    /// Forward a deferred/universal link so its campaign context attributes
    /// this install deterministically — the iOS analogue of the Android
    /// install referrer. Forwards the FULL raw query string, not just
    /// `rsclid`: the previous version of this method (and Android's
    /// `handleDeepLink` in `Roas.kt`, before a live device test caught it)
    /// forwarded only `rsclid`, silently dropping `utm_source`/`rs_campaign`/
    /// etc., and refused a link using a non-rsclid click id (gclid/fbclid)
    /// outright even though `CLICK_ID_PARAMS` on the backend already
    /// recognizes those. A no-op if the URL carries no query string at all.
    public static func handleDeepLink(_ url: URL) {
        guard
            let tx = transport,
            let store = storage,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let query = components.query,
            !query.isEmpty
        else { return }
        var body = baseBody()
        body["os"] = "iOS"
        body["event_type"] = "app_open"
        body["app_version"] = appVersion()
        // Android carries this on every touchpoint beacon and iOS did not, which
        // is not cosmetic: `retention.py` computes `sessionCoverage` from the
        // share of touches that report one, and the panel WITHHOLDS the whole
        // retention headline below full coverage. A single deep-link open with a
        // null session_number therefore suppresses a number for the entire site.
        body["session_number"] = store.sessionNumber
        body["referrer_source"] = "deeplink"
        // Android's handleDeepLink has always described the device here; iOS's
        // sent a bare body, so a deferred-deep-link open — often the FIRST touch
        // that carries a click id — wrote a touchpoint with no context at all.
        describe(&body)
        body["install_referrer"] = query // server lifts click id + utm/rs_* context, same as a Play referrer
        tx.send(path: "/api/tracking/mobile/first-open", body: body)
    }

    // MARK: - internals

    /// Send a late-arriving IDFA to `/identify`, which binds it as an
    /// `IdentityKey` exactly as the install beacon would have.
    ///
    /// `_device_keys` on the server reads `device_id` off an identify payload
    /// and types it IDFA-or-GAID from `os`, so this needs no new endpoint and no
    /// special case — it is the ordinary identify path carrying one more key.
    private static func bindAdvertisingId(_ idfa: String) {
        guard let tx = transport else { return }
        var body = baseBody()
        body["os"] = "iOS"
        body["device_id"] = idfa // raw; the server hashes it canonically
        tx.send(path: "/api/tracking/mobile/identify", body: body)
    }

    private static func reportFirstOpen(_ customerUserId: String?) {
        guard let tx = transport, let store = storage else { return }
        tx.background {
            var body = baseBody()
            body["os"] = "iOS"
            body["app_version"] = appVersion()
            // Model, OS version, screen, locale, timezone, TestFlight-vs-App-Store
            // — and device_type, which is why it is no longer the constant
            // "mobile" that made every iPad look like a phone.
            describe(&body)
            if let idfa = DeviceContext.advertisingIdentifier() { body["device_id"] = idfa } // raw; server hashes
            if let idfv = DeviceContext.identifierForVendor() { body["idfv"] = idfv }
            // Sent even when there is no token — that is what makes "why did this
            // install never attribute" answerable from the backend rather than
            // from the device's own console. Rides `referrer_status`, whose
            // meaning is exactly this ("what the store attribution read did"),
            // under an ASA_ prefix — the same prefixing Android already uses for
            // RETRY_. One column, one question, no migration.
            let asa = DeviceContext.appleSearchAds()
            if let token = asa.token { body["asa_token"] = token }
            body["referrer_status"] = asa.status
            // Which channel answered, in the column Android already uses to say
            // "google" / "xiaomi" / "broadcast". Sent even when the read failed:
            // the fact being recorded is which source was consulted, and
            // `referrer_status` beside it says how it went.
            body["referrer_source"] = "asa"
            // Simulator / jailbreak signals — the raw list, never a verdict.
            // Omitted entirely on an ordinary device (see DeviceIntegrity).
            let integrity = DeviceIntegrity.signals()
            if !integrity.isEmpty { body["integrity_signals"] = integrity }
            if let uid = customerUserId { body["external_id"] = uid }
            // The install IS session 1's opening touch, so it carries the
            // session's pv_id: the closing beacon then folds foreground time into
            // this row instead of writing an app_open next to it.
            body["pv_id"] = store.sessionPvId
            body["session_number"] = store.sessionNumber
            tx.send(path: "/api/tracking/mobile/first-open", body: body)

            // The install is now on record either way — losing an install count
            // would be worse than losing its attribution — so this stays true
            // unconditionally. What is NEW is remembering that the ASA token is
            // still owed to us when the failure was transient; previously that
            // was indistinguishable from a clean read and the device never tried
            // again for the life of the install.
            store.installReported = true
            store.asaPending = asa.token == nil && DeviceContext.isTransientAsaStatus(asa.status)
            store.asaAttempts = 0
        }
    }

    /// Try the Apple Search Ads read again on a later launch, after a transient
    /// failure on first open. The iOS twin of `Roas.kt`'s `retryReferrer`.
    ///
    /// The recovered token is sent as an **app_open**, not a second first-open:
    /// the install touchpoint already exists, and writing a duplicate would
    /// inflate install counts and split multi-touch credit across two phantom
    /// touches. `MobileFirstOpenView` resolves `asa_token` on every beacon it
    /// receives, not only on an install, so the campaign lands on this touch and
    /// the attribution waterfall picks it up through the vid exactly as it would
    /// have on the install itself.
    private static func retryAppleSearchAds() {
        guard let tx = transport, let store = storage else { return }
        let attempts = store.asaAttempts
        if attempts >= maxAsaAttempts {
            store.asaPending = false
            return
        }
        store.asaAttempts = attempts + 1
        tx.background {
            let asa = DeviceContext.appleSearchAds()
            if let token = asa.token {
                var body = baseBody()
                body["os"] = "iOS"
                body["event_type"] = "app_open"
                body["app_version"] = appVersion()
                describe(&body)
                body["asa_token"] = token
                // Distinct from a first-launch "ASA_OK" on purpose: a recovered
                // token and a clean one attribute the same, but only one of them
                // says the first read failed. Same RETRY_ prefixing Android uses.
                body["referrer_status"] = String("RETRY_\(asa.status)".prefix(32))
                body["referrer_source"] = "asa"
                body["session_number"] = store.sessionNumber
                tx.send(path: "/api/tracking/mobile/first-open", body: body)
                store.asaPending = false
            } else if !DeviceContext.isTransientAsaStatus(asa.status) {
                store.asaPending = false // permanent — stop asking
            }
        }
    }

    /// Fields every beacon carries.
    ///
    /// `sequence` is minted here, per beacon, and that is the point: beacons are
    /// fire-and-forget and race each other, so the order they land in is not the
    /// order they happened in. A server timestamp would reconstruct the wrong
    /// path — a checkout appearing before the product view that led to it.
    ///
    /// `pv_id` is deliberately NOT here. It belongs only on the two touchpoint
    /// beacons that open and close a session; on every beacon it would make
    /// identify/track calls upsert onto the session's touch instead of recording
    /// themselves.
    private static func baseBody() -> [String: Any] {
        var body: [String: Any] = ["site": publicKey, "vid": storage?.visitorId ?? ""]
        if let tracker = sessions {
            body["session_id"] = tracker.current().id
            body["sequence"] = tracker.nextSequence()
        }
        // WHEN this happened, not when it was delivered. The queue is persisted
        // precisely so an install that happens offline still reports — but
        // without this the server falls back to its own clock at ingest
        // (`ingest._occurred_at`), so an install that happened offline on Monday
        // and flushed on Wednesday was RECORDED as a Wednesday install. That
        // silently moves installs between days, past the end of a lookback
        // window, and out of the campaign that earned them — on exactly the
        // devices least able to report reliably in the first place. Measured at
        // 48 hours of error on a real device before Android fixed the same gap.
        let offset = storage?.clockOffsetSeconds ?? 0
        body["ts"] = nowIso(offsetSeconds: offset)
        // How far this device's clock sits from the server's, as already learned
        // from the HTTP `Date` header. It was computed for signing and then
        // discarded; reporting it is free and answers two questions nothing else
        // can — a device hours out of sync is a click-injection risk, and it is
        // the explanation for any `ts` the server had to reject.
        body["clock_offset_seconds"] = offset
        return body
    }

    /// Now, in UTC ISO-8601, corrected by the server-clock offset `Transport`
    /// already learns from the `Date` response header.
    ///
    /// The correction matters: a handset with a badly wrong clock (dead battery,
    /// no network time) is the same handset most likely to be queueing beacons
    /// offline, and the server REJECTS a `ts` more than five minutes in the
    /// future or ninety days old, falling back to ingest time. Correcting it
    /// keeps those devices' events on the right day instead of quietly reverting
    /// to the behaviour this replaced.
    ///
    /// A fixed `en_US_POSIX` locale and UTC, for the same reason `Transport`
    /// pins them when parsing the `Date` header: a device set to a non-Gregorian
    /// calendar would otherwise format a year the server cannot parse.
    ///
    /// Internal rather than private so `BeaconContractTests` can assert the
    /// exact shape `ingest._occurred_at` parses. This string is a wire contract
    /// with the backend, and a wire contract that nothing checks is one that
    /// drifts.
    static func nowIso(offsetSeconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: Date().addingTimeInterval(TimeInterval(offsetSeconds)))
    }

    /// `DeviceContext.refreshVolatile` touches UIDevice and CoreLocation, both
    /// of which expect the main thread. `configure` is documented to run at app
    /// start and normally already is there; the hop exists so a host app that
    /// starts us from a background queue still gets correct values instead of a
    /// main-thread-checker complaint.
    private static func refreshVolatileOnMain() {
        if Thread.isMainThread {
            DeviceContext.refreshVolatile()
        } else {
            DispatchQueue.main.async { DeviceContext.refreshVolatile() }
        }
    }

    // MARK: - Sessions

    /// Watch the app cross the foreground/background line — the only signal a
    /// session boundary can be derived from.
    ///
    /// `willResignActive`/`didBecomeActive` are deliberately NOT used: they also
    /// fire for a control-centre pull, a permission alert, or an incoming call,
    /// which are not the user leaving. `didEnterBackground`/`willEnterForeground`
    /// are the real boundary.
    private static func registerLifecycle() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { _ in onEnterBackground() }
        center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { _ in onEnterForeground() }
        // The last chance to flush a session on a device that is shutting the app
        // down for good; iOS gives no callback once the process is jettisoned.
        center.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in onEnterBackground() }
        #endif
    }

    private static func onEnterForeground() {
        guard let tracker = sessions else { return }
        // Battery and location move while the app is away; this notification is
        // delivered on the main thread, which is where both want to be read.
        refreshVolatileOnMain()
        let session = tracker.current()
        tracker.markForeground()
        if session.started { sendSessionStart(session) }
    }

    private static func onEnterBackground() {
        guard let tx = transport, let tracker = sessions, let store = storage else { return }
        let foregroundMs = tracker.markBackground()
        // Upserts onto the session's opening touch via its pv_id, so a visit is
        // one row that gains its duration — not two rows that split its credit.
        var body = baseBody()
        body["os"] = "iOS"
        body["event_type"] = "app_open"
        body["pv_id"] = store.sessionPvId
        body["engagement_ms"] = foregroundMs
        tx.send(path: "/api/tracking/mobile/first-open", body: body)
    }

    /// The opening beacon for a session that is not an install, plus a
    /// best-effort same-IP deferred match.
    ///
    /// A user who was ALREADY installed when they tapped an ad link never
    /// gets an install beacon (that only happens on a fresh install), and
    /// unless the link was a verified universal link routed straight into
    /// the app, `handleDeepLink` is never called either — most `/c/<slug>`
    /// redirects just reopen an already-installed app with no URL ever
    /// reaching it at all. Confirmed live on Android: an ad click 38 seconds
    /// before a plain app_open left the resulting touchpoint with zero
    /// campaign data, even though the click itself was logged correctly from
    /// the same IP. The backend already has a same-IP match for exactly this
    /// (`MobileDeferredLinkView`, gated behind `Site.allow_probabilistic`)
    /// but nothing called it outside of a fresh install until now. Safe to
    /// call unconditionally: the server no-ops when the site hasn't opted in,
    /// and it only ever backfills a touch still missing ad context, so it can
    /// never overwrite a real signal.
    private static func sendSessionStart(_ session: SessionTracker.Session) {
        guard let tx = transport else { return }
        var body = baseBody()
        body["os"] = "iOS"
        body["event_type"] = "app_open"
        body["app_version"] = appVersion()
        describe(&body) // sets device_type too
        body["pv_id"] = session.pvId
        body["session_number"] = session.number
        tx.send(path: "/api/tracking/mobile/first-open", body: body)

        tx.send(
            path: "/api/tracking/mobile/deferred-link",
            body: ["site": publicKey, "vid": storage?.visitorId ?? ""]
        )
    }

    private static func appVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }
}
