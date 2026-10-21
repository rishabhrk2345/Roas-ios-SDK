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

    /// A `setConsent` made before `configure`, when there is no storage yet to
    /// hold it. Applied before the first-open beacon is built, so a host that
    /// reads its consent platform first never sends an install claiming consent
    /// it was just told is withheld. Mirrors `pendingConsent` in `Roas.kt`.
    private static var pendingConsent: Bool?

    /// The device fields stamped onto every touchpoint beacon, resolved once in
    /// `configure` and reused. `reportFirstOpen` runs on the transport's
    /// background queue while `UIScreen.main` and `UIDevice.current` are
    /// main-thread state, so the single UIKit read stays on the thread the app
    /// starts us from and every later beacon is just a dictionary copy.
    private static var deviceContext: [String: Any] = [:]
    /// Guards `deviceContext`, which is read on whichever thread builds a beacon
    /// and, since iOS 26, written a second time when the screen fields arrive
    /// late (see `fillScreenWhenSceneActivates`). Its own lock, never held
    /// while calling out, so it cannot deadlock with `lock`.
    private static let contextLock = NSLock()

    /// Merge the device context into a beacon. Kept as a helper so the call
    /// sites that describe a device cannot drift apart the way iOS's
    /// `handleDeepLink` had already drifted from Android's.
    ///
    /// Two layers, for one reason: `deviceContext` is a launch-time snapshot of
    /// things that cannot change (model, screen, install dates) taken on the
    /// main thread because it reads UIKit, while `volatileContext()` re-reads
    /// the things that do change (battery, network, location) at the
    /// moment the beacon is built. Freezing the second group at launch would
    /// report an hour-old battery level and the network the app started on,
    /// which for fields that exist to describe *this* moment is worse than
    /// sending nothing.
    private static func describe(_ body: inout [String: Any]) {
        contextLock.lock()
        let snapshot = deviceContext
        contextLock.unlock()
        for (key, value) in snapshot { body[key] = value }
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
    /// Relay the person's "Do Not Sell or Share" choice from your consent UI.
    /// `false` = opted out. Persisted, so they answer once. Safe to call before
    /// `configure` — and best called there, so the install records the choice.
    ///
    /// Mirrors `roas.consent()` on the web: every beacon carries the state,
    /// `identify` sends nothing while it is withheld (an email hash is a durable
    /// cross-device key), and the server never forwards an opted-out person's
    /// purchases to Meta, Google or TikTok — that hand-off is "sharing" under
    /// CCPA/CPRA. Installs and sessions still report, flagged, so your own
    /// attribution keeps working. Independent of ATT: ATT governs the IDFA,
    /// this governs what may be shared onward.
    public static func setConsent(_ granted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let store = storage { store.consent = granted } else { pendingConsent = granted }
    }

    /// The current choice: true unless `setConsent(false)` was called.
    public static func hasConsent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage?.consent ?? pendingConsent ?? true
    }

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
        if let pending = pendingConsent { store.consent = pending }
        pendingConsent = nil
        let tx = Transport(baseUrl: baseUrl, storage: store, appSecret: appSecret)
        let tracker = SessionTracker(storage: store)
        storage = store
        transport = tx
        sessions = tracker
        initialized = true
        lock.unlock()

        // Before anything is dispatched to the transport queue, so the value is
        // published ahead of the first background read of it.
        let snapshot = DeviceContext.snapshot()
        contextLock.lock()
        deviceContext = snapshot
        contextLock.unlock()
        #if canImport(UIKit)
        if snapshot["screen"] == nil { fillScreenWhenSceneActivates() }
        #endif
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

        // After a delivery the server holds what the app just did, so that is
        // when a rules-driven SKAdNetwork value can have moved.
        tx.onFlushed = { refreshSkanValue() }
        tx.flush() // deliver anything queued from a previous offline launch
        // Once, on the launch that reports the install -- NOT every launch. On
        // iOS 16.1+ "registering" is `updatePostbackConversionValue(0)`, and
        // under SKAdNetwork 4 a conversion value is allowed to DECREASE, so
        // calling it on every cold start reset whatever the app had set:
        // a purchase reported as 42 on Tuesday went back to 0 on Wednesday's
        // launch, and if the postback window closed after that, the ad
        // network was told the install never converted. The first launch is
        // the only one where 0 is the truth.
        if !store.installReported {
            DeviceContext.registerForAdNetworkAttribution()
            store.skanRegisteredAt = Date().timeIntervalSince1970
            store.skanState = SkanWindowState()
        }

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
    ///   - allowDecrease: let this call LOWER the value already set in the
    ///     current window. Off by default: SKAdNetwork 4 accepts a lower value,
    ///     so an app reporting each event as it happens would otherwise overwrite
    ///     a purchase with whatever the user did next (see `SkanValueGuard`).
    ///     Turn it on only if your schema deliberately re-encodes.
    public static func updateConversionValue(
        _ value: Int, coarse: String? = nil, lockWindow: Bool = false, allowDecrease: Bool = false
    ) {
        guard (0...63).contains(value) else {
            if logLevel >= .error { print("[RoasSensor] updateConversionValue: \(value) is outside 0-63; ignored.") }
            return
        }
        let rank = SkanValueGuard.coarseRank(coarse)
        if coarse != nil && rank == nil && logLevel >= .error {
            print("[RoasSensor] updateConversionValue: coarse must be low, medium or high; sending the fine value only.")
        }
        guard let store = storage else {
            // Before configure there is no history to guard; pass it through.
            let name = rank.flatMap { SkanValueGuard.coarseName($0) }
            DeviceContext.updateConversionValue(value, coarse: name, lockWindow: lockWindow)
            return
        }
        if store.skanRegisteredAt <= 0 {
            // Registered by an SDK build that did not record when: the install
            // anchor (the Documents directory's creation date) is the install time.
            store.skanRegisteredAt = store.installAnchor > 0 ? store.installAnchor : Date().timeIntervalSince1970
        }
        guard let window = SkanValueGuard.window(elapsed: Date().timeIntervalSince1970 - store.skanRegisteredAt) else {
            return // the last window has closed; no postback would carry it
        }
        let decision = SkanValueGuard.decide(
            state: store.skanState, window: window, fine: value, coarse: rank,
            lockWindow: lockWindow, allowDecrease: allowDecrease
        )
        guard decision.send else {
            if logLevel >= .debug {
                print("[RoasSensor] updateConversionValue: \(value) kept at \(decision.fine) (values only rise within a window).")
            }
            return
        }
        store.skanState = decision.state
        // A plain `if let`, not `flatMap(SkanValueGuard.coarseName)`: a function
        // reference handed to `flatMap` is a nonisolated context, which Xcode's
        // stricter concurrency checking flags when the host app builds this
        // package with main-actor default isolation.
        var coarseName: String?
        if let rank = decision.coarse { coarseName = SkanValueGuard.coarseName(rank) }
        DeviceContext.updateConversionValue(decision.fine, coarse: coarseName, lockWindow: decision.lockWindow)
    }

    // MARK: Rules-driven SKAdNetwork values

    private static let skanLock = NSLock()
    private static var skanLastAsked: TimeInterval = 0
    private static var skanAskQueued = false
    private static var skanRulesOffUntil: TimeInterval = 0
    /// The least time between two questions, so a burst of beacons is one request.
    private static let skanAskInterval: TimeInterval = 15
    /// An app whose schema sets nothing asks again only this often.
    private static let skanRulesOffBackoff: TimeInterval = 6 * 3600

    /// Ask the server which conversion value this device should hold, and set
    /// it. The rules are the app's SKAdNetwork schema on the ROAS Sensor panel
    /// (session / event / verified revenue → value), evaluated on the server
    /// against what this device did in the current window, so the schema that
    /// reads a postback is the same one that set it, and a revenue rule only
    /// counts money a store or your server verified. The answer goes through
    /// `updateConversionValue`'s guard, so a value still only rises within a
    /// window. When the schema has no conditions the server says so and this
    /// backs off: an app setting values in its own code is left alone.
    ///
    /// Called after beacons are delivered and when the app returns to the
    /// foreground; there is nothing for a host app to call.
    static func refreshSkanValue() {
        #if os(iOS)
        guard let tx = transport, let store = storage, store.consent, store.installReported else { return }
        let now = Date().timeIntervalSince1970
        skanLock.lock()
        if now < skanRulesOffUntil {
            skanLock.unlock()
            return
        }
        let wait = skanLastAsked + skanAskInterval - now
        if wait > 0 {
            // Inside the interval: ask once more when it ends, rather than drop
            // a purchase that landed a few seconds after an event.
            let schedule = !skanAskQueued
            skanAskQueued = true
            skanLock.unlock()
            if schedule {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    skanLock.lock()
                    skanAskQueued = false
                    skanLock.unlock()
                    refreshSkanValue()
                }
            }
            return
        }
        skanLastAsked = now
        skanLock.unlock()

        if store.skanRegisteredAt <= 0 {
            store.skanRegisteredAt = store.installAnchor > 0 ? store.installAnchor : now
        }
        guard let window = SkanValueGuard.window(elapsed: now - store.skanRegisteredAt) else { return }
        let body: [String: Any] = ["site": publicKey, "vid": store.visitorId, "window": window]
        tx.request(path: "/api/tracking/mobile/skan-value", body: body) { data in
            guard let data = data else { return }
            guard (data["rules"] as? Bool) == true else {
                skanLock.lock()
                skanRulesOffUntil = Date().timeIntervalSince1970 + skanRulesOffBackoff
                skanLock.unlock()
                return
            }
            let fine = data["fine"] as? Int
            let coarse = data["coarse"] as? String
            let lockWindow = (data["lockWindow"] as? Bool) ?? false
            guard fine != nil || coarse != nil || lockWindow else { return }
            if logLevel >= .debug {
                print("[RoasSensor] SKAdNetwork rules: window \(window), fine \(fine.map { String($0) } ?? "-"), coarse \(coarse ?? "-"), lock \(lockWindow)")
            }
            DispatchQueue.main.async {
                // Windows 2 and 3 carry no fine value: 0 leaves the guard's
                // highest fine value where it is.
                updateConversionValue(fine ?? 0, coarse: coarse, lockWindow: lockWindow)
            }
        }
        #endif
    }

    /// Bind the user's identity. At least one argument must be non-nil.
    public static func identify(email: String? = nil, phone: String? = nil, customerUserId: String? = nil) {
        guard let tx = transport else { return }
        // The one thing consent withholds on-device (as on the web): a durable
        // identity key for someone who said "do not sell or share".
        guard storage?.consent ?? true else { return }
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

    /// Ask the collector to VERIFY a purchase against Apple's own records, the
    /// moment StoreKit reports it.
    ///
    /// Revenue already reaches the backend without this, through App Store
    /// Server Notifications — Apple's own server-to-server callback, which is
    /// the source of truth and stays so. What that path cannot do is be
    /// *prompt*: the notification is a separate delivery on Apple's schedule,
    /// and until it lands the buyer is standing in the app having just paid
    /// while the dashboard shows nothing. Android is worse (Play RTDN can take
    /// minutes). This closes that gap without moving the trust boundary.
    ///
    /// It does not move it because the app only ever NAMES a receipt. The
    /// collector holds the App Store Connect key, fetches Apple's own signed
    /// copy of that transaction id and books whatever amount *Apple* reports —
    /// so a tampered build can, at most, ask about a purchase that really
    /// happened, for the price it really was. That is the whole reason this can
    /// exist while `track(.subscribe, properties: ["price": 999999])` can never
    /// be revenue: one is a claim, the other is a question put to the store.
    ///
    /// Booked under the same `external_id` the notification will carry, so the
    /// two dedupe: whichever arrives first books the conversion and the other
    /// is a no-op. Calling it for a purchase Apple has already notified us
    /// about is therefore harmless, and so is calling it twice.
    ///
    /// Fire-and-forget, like `track`: it enqueues a signed beacon and returns.
    /// The outcome arrives on `setOnDeliveryResult` under
    /// `/api/tracking/mobile/purchase`, never as a thrown error or a value —
    /// a purchase flow must not be made to wait on our network, and a customer
    /// must never see a paid purchase fail because attribution was offline.
    ///
    /// Call it once the store has actually confirmed the purchase:
    ///
    /// ```swift
    /// for await update in Transaction.updates {
    ///     guard case .verified(let transaction) = update else { continue }
    ///     Roas.verifyPurchase(transactionId: String(transaction.id))
    ///     await transaction.finish()
    /// }
    /// ```
    ///
    /// - Parameter transactionId: StoreKit's `Transaction.id` as a string. Not
    ///   `originalID` — that names the subscription's first purchase, so every
    ///   renewal would be asked about (and deduped against) the sale from
    ///   months ago instead of the one that just happened.
    ///
    /// - Note: Setting `appAccountToken()` on the purchase is still what ties
    ///   the sale to this install. This reports the purchase sooner; it does
    ///   not identify the buyer, and a purchase made without that token
    ///   attributes no better for having been verified early.
    public static func verifyPurchase(transactionId: String) {
        guard let tx = transport else { return }
        guard let fields = purchaseFields(transactionId: transactionId) else { return }
        var body = baseBody()
        body["os"] = "iOS"
        for (key, value) in fields { body[key] = value }
        tx.send(path: "/api/tracking/mobile/purchase", body: body)
    }

    /// The purchase-specific half of the beacon, split out from `verifyPurchase`
    /// so the wire contract is testable without a configured SDK or a network.
    /// Returns nil for a receipt the collector would refuse anyway.
    ///
    /// Rejecting here rather than sending is deliberate: `Transport`'s queue is
    /// persisted and retried, and the collector answers a malformed body with a
    /// 400 — which the queue treats as delivered and drops, so nothing would
    /// surface except a beacon that quietly never books. Better to not send a
    /// request that cannot succeed.
    static func purchaseFields(transactionId: String) -> [String: Any]? {
        let id = transactionId.trimmingCharacters(in: .whitespacesAndNewlines)
        // 64 is `MobilePurchaseSerializer.transaction_id`'s max_length. Apple's
        // ids are ~16 digits, so anything near this is a caller sending the
        // wrong thing (a receipt blob, a JWS) and would be refused server-side.
        guard !id.isEmpty, id.count <= 64 else { return nil }
        // `platform` picks which store the collector asks, and it is a
        // ChoiceField: "ios" exactly, not "iOS" as the `os` field carries.
        return ["platform": "ios", "transaction_id": id]
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

    /// Fetch the deferred deep link for this install, if one exists.
    ///
    /// Call this once on first open (after ``configure``) to check whether the
    /// user arrived via a tracked ad link.  If they did, ``completion`` receives
    /// a non-nil ``DeferredDeepLink`` containing the screen to open and the
    /// campaign context; for an organic install it receives nil.
    ///
    /// The lookup is deterministic: it matches on the IDFA, so it is accurate on
    /// every device where ATT consent was granted before or during install, and
    /// also on any device where the IDFA is available from a previous session.
    /// On a device whose user denied ATT the result will always be nil (no IDFA
    /// to match on).
    ///
    /// ``completion`` is called on an arbitrary background thread.  Use
    /// `DispatchQueue.main.async` to update the UI from it.
    ///
    /// ```swift
    /// Roas.fetchDeferredDeepLink { link in
    ///     guard let path = link?.deepLinkPath, !path.isEmpty else { return }
    ///     DispatchQueue.main.async { openScreen(path) }
    /// }
    /// ```
    public static func fetchDeferredDeepLink(_ completion: @escaping (DeferredDeepLink?) -> Void) {
        guard let tx = transport, let store = storage else { completion(nil); return }
        var body: [String: Any] = ["site": publicKey, "vid": store.visitorId]
        if let idfa = DeviceContext.advertisingIdentifier() {
            body["device_id"] = idfa
        }
        tx.request(path: "/api/tracking/mobile/deferred-deep-link", body: body) { data in
            guard let data = data, (data["matched"] as? Bool) == true else {
                completion(nil)
                return
            }
            completion(DeferredDeepLink(
                deepLinkPath: data["deepLinkPath"] as? String ?? "",
                channel: data["channel"] as? String ?? "",
                campaign: data["campaign"] as? String ?? "",
                adName: data["adName"] as? String ?? "",
                medium: data["medium"] as? String ?? ""
            ))
        }
    }

    /// Connect this install to the website tap that led to it, through the
    /// clipboard: iOS web to app.
    ///
    /// The App Store passes nothing from a tap on a website to the app it
    /// installs. So when an iPhone visitor taps a smart banner or one of your
    /// hosted "Download the app" links, roas.js copies that link (with a
    /// one-time code) to the clipboard. This reads it back and gives the install
    /// that exact tap's source — the banner, or the Google / Meta ad that
    /// brought the visitor to your website. Deterministic, like Android's
    /// install referrer.
    ///
    /// **Opt-in, and you choose the moment.** On iOS 16 and later, reading the
    /// clipboard shows the system "Allow Paste" prompt. This first checks — with
    /// no prompt — whether the clipboard holds a web link at all, and only reads
    /// it when it does, so most users never see a prompt. To avoid the prompt
    /// entirely, use Apple's Paste button (`UIPasteControl`) and pass what it
    /// pastes to ``handlePastedClick(_:completion:)`` instead.
    ///
    /// Call it once, early in the first session (after ``configure``). It asks
    /// at most once per install: a found link, or a clipboard with none, settles
    /// it; only a network failure leaves it to try again on a later launch.
    /// ``completion`` runs on an arbitrary thread.
    ///
    /// ```swift
    /// Roas.claimPastedClick { result in
    ///     if result.matched { print("came from", result.channel) }
    /// }
    /// ```
    public static func claimPastedClick(_ completion: ((PastedClickResult) -> Void)? = nil) {
        guard transport != nil, let store = storage else {
            completion?(.notMatched("unavailable"))
            return
        }
        if store.pastedClickDone {
            completion?(.notMatched("done"))
            return
        }
        if PastedClick.tooLate(installAnchor: store.installAnchor, now: Date().timeIntervalSince1970) {
            store.pastedClickDone = true
            store.pastedClickCode = nil
            completion?(.notMatched("too_late"))
            return
        }
        // Already read on an earlier try: send it again, never re-read the
        // clipboard (that would show the paste prompt a second time).
        if let code = store.pastedClickCode {
            submitPastedCode(code, attempt: 0, completion: completion)
            return
        }
        #if os(iOS)
        DispatchQueue.main.async {
            let board = UIPasteboard.general
            // Detection does not show the paste prompt; only reading does.
            board.detectPatterns(for: [.probableWebURL]) { result in
                let hasLink: Bool
                switch result {
                case .success(let found): hasLink = found.contains(.probableWebURL)
                case .failure: hasLink = false
                }
                guard hasLink else {
                    store.pastedClickDone = true
                    completion?(.notMatched("no_link"))
                    return
                }
                DispatchQueue.main.async {
                    Roas.handlePastedClick(board.string ?? "", completion: completion)
                }
            }
        }
        #else
        completion?(.notMatched("unavailable"))
        #endif
    }

    /// The same as ``claimPastedClick(_:)``, for text you already have — what a
    /// `UIPasteControl` (Apple's Paste button, which shows no prompt) pasted.
    ///
    /// ```swift
    /// // in your paste target
    /// override func paste(itemProviders: [NSItemProvider]) {
    ///     itemProviders.first?.loadObject(ofClass: String.self) { text, _ in
    ///         Roas.handlePastedClick(text ?? "")
    ///     }
    /// }
    /// ```
    public static func handlePastedClick(_ text: String, completion: ((PastedClickResult) -> Void)? = nil) {
        guard transport != nil, let store = storage else {
            completion?(.notMatched("unavailable"))
            return
        }
        guard let code = PastedClick.code(in: text) else {
            store.pastedClickDone = true
            completion?(.notMatched("no_link"))
            return
        }
        store.pastedClickCode = code
        submitPastedCode(code, attempt: 0, completion: completion)
    }

    /// Hand a code to the server. Called right after `configure`, the install
    /// beacon is often still in the queue and the server answers `no_install`;
    /// that is retried a few seconds apart in this session, and the code stays
    /// stored for the next launch after that — sent again without re-reading.
    private static func submitPastedCode(_ code: String, attempt: Int, completion: ((PastedClickResult) -> Void)?) {
        guard let tx = transport, let store = storage else {
            completion?(.notMatched("unavailable"))
            return
        }
        let body: [String: Any] = ["site": publicKey, "vid": store.visitorId, "code": code]
        tx.request(path: "/api/tracking/mobile/paste-click", body: body) { data in
            let matched = (data?["matched"] as? Bool) == true
            let reason = data?["reason"] as? String
            if !matched, reason == "no_install", attempt < PastedClick.inSessionRetries {
                DispatchQueue.global().asyncAfter(deadline: .now() + PastedClick.retryDelay) {
                    Roas.submitPastedCode(code, attempt: attempt + 1, completion: completion)
                }
                return
            }
            if PastedClick.isFinal(matched: matched, reason: data == nil ? nil : (reason ?? "")) {
                store.pastedClickDone = true
                store.pastedClickCode = nil
            }
            if matched {
                completion?(PastedClickResult(
                    matched: true,
                    reason: "",
                    channel: data?["channel"] as? String ?? "",
                    campaign: data?["campaign"] as? String ?? ""
                ))
            } else {
                completion?(.notMatched(data == nil ? "offline" : (reason ?? "")))
            }
        }
    }

    /// Register an APNs device token for uninstall detection.
    ///
    /// Call this from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`:
    ///
    /// ```swift
    /// func application(_ app: UIApplication,
    ///                  didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    ///     Roas.registerPushToken(token)
    /// }
    /// ```
    ///
    /// The token is stored server-side and probed daily via the APNs HTTP/2 API;
    /// a `410 Gone` or `Unregistered` reason signals that the app was uninstalled.
    ///
    /// - Parameter token: The raw device token `Data` from UIApplicationDelegate.
    public static func registerPushToken(_ token: Data) {
        guard let tx = transport, let store = storage else { return }
        let hexToken = token.map { String(format: "%02x", $0) }.joined()
        guard !hexToken.isEmpty else { return }
        var body: [String: Any] = [
            "site": publicKey,
            "vid": store.visitorId,
            "platform": "apns",
            "token": hexToken,
        ]
        if let idfa = DeviceContext.advertisingIdentifier() {
            body["device_id"] = idfa
        }
        tx.request(path: "/api/tracking/mobile/push-token", body: body) { _ in }
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
            if let uid = customerUserId, store.consent { body["external_id"] = uid }
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
        // Read per beacon, not once: the person can change their mind mid-session
        // and each row must record the state it was collected under. The
        // server's CAPI push-back refuses an opted-out buyer.
        body["consent"] = storage?.consent ?? true
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
    #if canImport(UIKit)
    /// iOS 26 reads the screen from a window scene, and a host that configures
    /// us before its first scene connects (Flutter, from `main()`) has none yet.
    /// Rather than ship every beacon without screen, viewport and density, wait
    /// for the first scene to activate and merge them in once.
    private static func fillScreenWhenSceneActivates() {
        let observer = ScreenFillToken()
        observer.token = NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification, object: nil, queue: .main
        ) { _ in
            let fields = DeviceContext.screenFields()
            guard !fields.isEmpty else { return }
            contextLock.lock()
            for (key, value) in fields where deviceContext[key] == nil { deviceContext[key] = value }
            contextLock.unlock()
            observer.remove()
        }
    }

    /// The same main-queue-only token box as `DeviceContext`'s.
    private final class ScreenFillToken: @unchecked Sendable {
        var token: NSObjectProtocol?

        func remove() {
            if let token = token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }
    }
    #endif

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
        // A purchase the store reported while the app was away (an App Store
        // notification, a renewal) can have moved the value without any beacon.
        refreshSkanValue()
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
