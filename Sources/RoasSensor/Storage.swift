import Foundation

/// On-device state: the stable visitor id, the "install already reported" flag,
/// and a persisted beacon queue. The queue survives app termination on purpose —
/// an install that happens offline must still be reported on the next launch.
final class Storage {
    private let defaults: UserDefaults
    private let lock = NSLock()

    private let vidKey = "com.roassensor.sdk.vid"
    private let installKey = "com.roassensor.sdk.install_reported"
    private let queueKey = "com.roassensor.sdk.queue"
    private let clockOffsetKey = "com.roassensor.sdk.clock_offset"
    private let sessionIdKey = "com.roassensor.sdk.session_id"
    private let sessionNumberKey = "com.roassensor.sdk.session_number"
    private let sessionPvIdKey = "com.roassensor.sdk.session_pv_id"
    private let sessionSequenceKey = "com.roassensor.sdk.session_sequence"
    private let sessionForegroundKey = "com.roassensor.sdk.session_foreground_ms"
    private let sessionDayKey = "com.roassensor.sdk.session_day"
    private let sessionLastActiveKey = "com.roassensor.sdk.session_last_active"
    /// The Documents directory's creation date this SDK last saw for THIS
    /// install — the iOS analogue of Android's
    /// `PackageManager.firstInstallTime`. See Android's `Storage.kt` for the
    /// full story: a live device test found an OEM data-retention layer
    /// resurrecting old SharedPreferences data across a genuine OS-level
    /// reinstall. iOS doesn't have Android's OEM-variance problem — Apple
    /// controls the whole stack — but it has an analogous one: restoring a
    /// device from an iCloud/iTunes backup can carry UserDefaults content
    /// over into what is, from the OS's perspective, a brand-new install on a
    /// new (or wiped) device. The app's Documents directory is recreated
    /// fresh by the OS at real install time and is NOT restored from a
    /// backup the way its file CONTENTS are, so comparing its creation date
    /// catches that the same way `firstInstallTime` does on Android. 0 means
    /// "never recorded" — treated as a fresh install too.
    private let installAnchorKey = "com.roassensor.sdk.install_anchor"
    private let asaPendingKey = "com.roassensor.sdk.asa_pending"
    private let asaAttemptsKey = "com.roassensor.sdk.asa_attempts"
    private let maxQueue = 500

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stable first-party visitor id for this install (our "vid").
    var visitorId: String {
        lock.lock(); defer { lock.unlock() }
        if let existing = defaults.string(forKey: vidKey) { return existing }
        let vid = "rs" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        defaults.set(vid, forKey: vidKey)
        return vid
    }

    var installReported: Bool {
        get { defaults.bool(forKey: installKey) }
        set { defaults.set(newValue, forKey: installKey) }
    }

    var installAnchor: TimeInterval {
        get { defaults.double(forKey: installAnchorKey) }
        set { defaults.set(newValue, forKey: installAnchorKey) }
    }

    /// The Apple Search Ads token is still owed to us: the install's one read
    /// failed transiently, so a later launch should try again.
    ///
    /// This is the iOS twin of Android's `referrerPending`, and it exists for
    /// the same reason that flag was added there: `installReported` is set
    /// unconditionally (losing an install count would be worse than losing its
    /// attribution), which used to make a transient failure on the very first
    /// launch permanent — indistinguishable from a clean read, with the device
    /// never trying again for the life of the install. That first read is the
    /// one most likely to fail: it happens moments after the install completes,
    /// on a device that may not have finished getting itself onto the network.
    var asaPending: Bool {
        get { defaults.bool(forKey: asaPendingKey) }
        set { defaults.set(newValue, forKey: asaPendingKey) }
    }

    /// How many launches have already retried, so a device whose AdServices
    /// never answers stops paying for the attempt forever. Apple attributes an
    /// install for far longer than a handful of launches, so the bound costs no
    /// real recovery.
    var asaAttempts: Int {
        get { defaults.integer(forKey: asaAttemptsKey) }
        set { defaults.set(newValue, forKey: asaAttemptsKey) }
    }

    // MARK: - Session state (see SessionTracker)
    //
    // Persisted rather than held in memory because iOS jettisons suspended apps
    // routinely: a session living only in RAM would restart every time the OS
    // reclaimed the app, inflating session counts and destroying the retention
    // numbers sessions exist to produce.

    var sessionId: String {
        get { defaults.string(forKey: sessionIdKey) ?? "" }
        set { defaults.set(newValue, forKey: sessionIdKey) }
    }

    var sessionNumber: Int {
        get { defaults.integer(forKey: sessionNumberKey) }
        set { defaults.set(newValue, forKey: sessionNumberKey) }
    }

    var sessionPvId: String {
        get { defaults.string(forKey: sessionPvIdKey) ?? "" }
        set { defaults.set(newValue, forKey: sessionPvIdKey) }
    }

    var sessionSequence: Int {
        get { defaults.integer(forKey: sessionSequenceKey) }
        set { defaults.set(newValue, forKey: sessionSequenceKey) }
    }

    var sessionForegroundMs: Int64 {
        get { Int64(defaults.integer(forKey: sessionForegroundKey)) }
        set { defaults.set(Int(newValue), forKey: sessionForegroundKey) }
    }

    /// The visitor's local calendar day, for the midnight rollover.
    var sessionDay: String {
        get { defaults.string(forKey: sessionDayKey) ?? "" }
        set { defaults.set(newValue, forKey: sessionDayKey) }
    }

    var sessionLastActiveAt: TimeInterval {
        get { defaults.double(forKey: sessionLastActiveKey) }
        set { defaults.set(newValue, forKey: sessionLastActiveKey) }
    }

    /// Seconds to ADD to this device's clock to reach server time, learned from
    /// the HTTP `Date` response header.
    ///
    /// Persisted rather than held in memory because the very first beacon of a
    /// cold launch is the install — the one that matters most — and a handset
    /// whose clock is badly out (dead battery, no network time) would sign it
    /// outside the server's tolerance and have it refused. Remembering the
    /// correction exposes only the very first beacon a device ever sends.
    var clockOffsetSeconds: Int64 {
        get { Int64(defaults.integer(forKey: clockOffsetKey)) }
        set { defaults.set(Int(newValue), forKey: clockOffsetKey) }
    }

    /// Wipe every field tied to "this specific install" — vid, install/
    /// session state, and the pending beacon queue — so a device whose
    /// UserDefaults survived a backup restore starts exactly as clean as a
    /// genuinely fresh install. See `installAnchor`'s doc comment for when
    /// this fires. Mirrors Android's `Storage.kt` `resetForNewInstall`,
    /// including clearing the queue: a queued entry's JSON body has the OLD
    /// vid baked in at enqueue time, and delivering it after this reset would
    /// attach a stale identity's beacon to what the OS now says is a
    /// different install. Deliberately leaves `clockOffsetSeconds` alone —
    /// not tied to which install this is, still valid for the same physical
    /// device.
    func resetForNewInstall() {
        lock.lock()
        defaults.removeObject(forKey: vidKey)
        defaults.removeObject(forKey: installKey)
        defaults.removeObject(forKey: sessionIdKey)
        defaults.removeObject(forKey: sessionNumberKey)
        defaults.removeObject(forKey: sessionPvIdKey)
        defaults.removeObject(forKey: sessionSequenceKey)
        defaults.removeObject(forKey: sessionForegroundKey)
        defaults.removeObject(forKey: sessionDayKey)
        defaults.removeObject(forKey: sessionLastActiveKey)
        defaults.removeObject(forKey: queueKey)
        // Tied to THIS install's attribution read, so a restored-backup device
        // must not inherit a pending retry belonging to the install it replaced.
        defaults.removeObject(forKey: asaPendingKey)
        defaults.removeObject(forKey: asaAttemptsKey)
        lock.unlock()
    }

    func enqueue(_ entry: String) {
        lock.lock(); defer { lock.unlock() }
        var queue = defaults.stringArray(forKey: queueKey) ?? []
        queue.append(entry)
        while queue.count > maxQueue { queue.removeFirst() } // bound an offline device
        defaults.set(queue, forKey: queueKey)
    }

    func queued() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return defaults.stringArray(forKey: queueKey) ?? []
    }

    func replaceQueue(_ entries: [String]) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(entries, forKey: queueKey)
    }

    /// Remove exactly `delivered` from whatever the queue holds RIGHT NOW —
    /// read and mutate under the same lock, not `queued()` then
    /// `replaceQueue()` as two separate calls with a network round-trip in
    /// between.
    ///
    /// `Transport.flush()` used to do exactly that: read the queue, spend
    /// real time on network I/O delivering each entry, then call
    /// `replaceQueue` with the "remaining" list computed from that now-stale
    /// read. Verified live on Android (`Storage.kt`'s `removeDelivered`
    /// history): a second `send()` fired back-to-back with the first — which
    /// is exactly what the deferred-link probe does, right after the
    /// app_open send, on every session start — could enqueue between this
    /// flush's stale read and its write-back and be silently wiped by it, no
    /// error, no delivery callback, nothing. Ported here BEFORE adding the
    /// deferred-link probe, not after finding the same bug live on iOS too.
    func removeDelivered(_ delivered: [String]) {
        guard !delivered.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var remaining = defaults.stringArray(forKey: queueKey) ?? []
        for entry in delivered {
            if let idx = remaining.firstIndex(of: entry) { remaining.remove(at: idx) }
        }
        defaults.set(remaining, forKey: queueKey)
    }
}
