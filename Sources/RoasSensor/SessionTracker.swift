import Foundation

/// Sessions — the iOS twin of `SessionTracker.kt`, and of the web SDK's
/// `session.ts` before it.
///
/// The rules are mirrored **deliberately** and must not drift: a customer with a
/// website and an app compares the two in one dashboard, and a session that
/// means "30 idle minutes" on web but something else in the app makes that
/// comparison quietly meaningless.
///
///  * 30 minutes of inactivity ends a session;
///  * so does the visitor's **local** midnight — theirs, not UTC's;
///  * `sequence` is assigned on the device, because beacons race: the order they
///    arrive in is not the order they happened in.
///
/// State lives in `Storage` rather than memory so a session survives the app
/// being jettisoned between two foregrounds.
final class SessionTracker {

    /// The live session. `started` is true only when THIS call created it.
    struct Session {
        let id: String
        let number: Int
        let pvId: String
        let started: Bool
    }

    private let storage: Storage
    private let lock = NSLock()

    /// When the current foreground stretch began (0 = backgrounded). In memory
    /// on purpose: a stretch cannot span an app launch.
    private var foregroundSince: TimeInterval = 0

    /// Same 30 minutes as sdk/src/session.ts.
    private static let idleInterval: TimeInterval = 30 * 60

    init(storage: Storage) {
        self.storage = storage
    }

    /// The live session, rolling it over when stale. Callers should send a
    /// session-start beacon only when `started` is true — otherwise every
    /// foreground writes a duplicate touch and dilutes multi-touch credit.
    func current() -> Session {
        lock.lock(); defer { lock.unlock() }
        return currentLocked()
    }

    private func currentLocked() -> Session {
        let now = Date().timeIntervalSince1970
        let id = storage.sessionId
        let alive = !id.isEmpty
            && now - storage.sessionLastActiveAt < SessionTracker.idleInterval
            && storage.sessionDay == SessionTracker.localDay()
        if alive {
            return Session(
                id: id, number: storage.sessionNumber, pvId: storage.sessionPvId, started: false
            )
        }

        let fresh = UUID().uuidString
        storage.sessionId = fresh
        storage.sessionNumber += 1
        // One pv_id per session. The backend UPSERTS on it, so the session's
        // closing beacon folds its foreground time into the row the opening
        // beacon created instead of writing a second touch.
        storage.sessionPvId = "pv" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        storage.sessionSequence = 0
        storage.sessionForegroundMs = 0
        storage.sessionDay = SessionTracker.localDay()
        storage.sessionLastActiveAt = now
        return Session(id: fresh, number: storage.sessionNumber, pvId: storage.sessionPvId, started: true)
    }

    /// This event's index within the session, and a touch of the idle clock.
    func nextSequence() -> Int {
        lock.lock(); defer { lock.unlock() }
        _ = currentLocked() // roll over first: an event after 30 idle minutes starts a session
        let next = storage.sessionSequence + 1
        storage.sessionSequence = next
        storage.sessionLastActiveAt = Date().timeIntervalSince1970
        return next
    }

    /// The app came to the front. Call AFTER `current()`, so the rollover
    /// decision still sees how long the app was away.
    func markForeground() {
        lock.lock(); defer { lock.unlock() }
        foregroundSince = Date().timeIntervalSince1970
    }

    /// The app went to the background. Returns the session's TOTAL foreground
    /// milliseconds so far — cumulative, because a session routinely spans
    /// several stretches (a user checks a notification and comes back) and the
    /// question the number answers is "how long were they in the app this
    /// visit". The backend folds it in with a MAX, so re-reporting a total is
    /// safe and a racing beacon can never revise it downward.
    @discardableResult
    func markBackground() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        if foregroundSince > 0 {
            storage.sessionForegroundMs += Int64((now - foregroundSince) * 1000)
            foregroundSince = 0
        }
        // The idle clock runs from when they LEFT, not from their last event —
        // otherwise an app suspended in the background would keep one session
        // alive indefinitely.
        storage.sessionLastActiveAt = now
        return storage.sessionForegroundMs
    }

    private static func localDay() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}
