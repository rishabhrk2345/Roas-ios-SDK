import XCTest
@testable import RoasSensor

/// `Storage`'s reset/queue-removal behavior, exercised on the macOS host (no
/// simulator needed — `Storage` is pure Foundation). These exist because both
/// behaviors were added to close real bugs found live on Android and ported
/// here before the same bugs could be found live on iOS too: `resetForNewInstall`
/// (data resurrected across an iCloud/iTunes backup restore) and
/// `removeDelivered` (a stale-read/write-back race that could silently drop a
/// beacon enqueued mid-flush).
final class StorageTests: XCTestCase {

    /// A throwaway UserDefaults per test — the real one is shared process state
    /// and would leak state from one test into the next.
    private func makeStorage() -> Storage {
        let suite = UserDefaults(suiteName: "roas.tests.\(UUID().uuidString)")!
        return Storage(defaults: suite)
    }

    // MARK: - resetForNewInstall

    func testResetForNewInstallClearsVidAndInstallState() {
        let storage = makeStorage()
        let originalVid = storage.visitorId
        storage.installReported = true

        storage.resetForNewInstall()

        XCTAssertNotEqual(storage.visitorId, originalVid)
        XCTAssertFalse(storage.installReported)
    }

    func testResetForNewInstallClearsSessionState() {
        let storage = makeStorage()
        storage.sessionId = "sess-1"
        storage.sessionNumber = 3
        storage.sessionPvId = "pv-1"
        storage.sessionSequence = 5
        storage.sessionForegroundMs = 12_000
        storage.sessionDay = "2026-08-12"
        storage.sessionLastActiveAt = 123.0

        storage.resetForNewInstall()

        XCTAssertEqual(storage.sessionId, "")
        XCTAssertEqual(storage.sessionNumber, 0)
        XCTAssertEqual(storage.sessionPvId, "")
        XCTAssertEqual(storage.sessionSequence, 0)
        XCTAssertEqual(storage.sessionForegroundMs, 0)
        XCTAssertEqual(storage.sessionDay, "")
        XCTAssertEqual(storage.sessionLastActiveAt, 0)
    }

    func testResetForNewInstallClearsTheQueue() {
        // Load-bearing: a queued entry's JSON body has the OLD vid baked in at
        // enqueue time. Delivering it after a reset would attach a stale
        // identity's beacon to what the OS now says is a different install.
        let storage = makeStorage()
        storage.enqueue("{\"path\":\"/mobile/first-open\"}")
        XCTAssertEqual(storage.queued().count, 1)

        storage.resetForNewInstall()

        XCTAssertTrue(storage.queued().isEmpty)
    }

    func testResetForNewInstallLeavesClockOffsetAlone() {
        // Not tied to which install this is — still valid for the same
        // physical device.
        let storage = makeStorage()
        storage.clockOffsetSeconds = 42

        storage.resetForNewInstall()

        XCTAssertEqual(storage.clockOffsetSeconds, 42)
    }

    // MARK: - Apple Search Ads retry state

    func testAsaRetryStateDefaultsToNothingOwed() {
        // A fresh install owes no retry until an install read actually fails
        // transiently — otherwise every clean install would spend a launch
        // re-reading a token it already has.
        let storage = makeStorage()
        XCTAssertFalse(storage.asaPending)
        XCTAssertEqual(storage.asaAttempts, 0)
    }

    func testAsaRetryStateRoundTrips() {
        let storage = makeStorage()
        storage.asaPending = true
        storage.asaAttempts = 3
        XCTAssertTrue(storage.asaPending)
        XCTAssertEqual(storage.asaAttempts, 3)
    }

    func testResetForNewInstallClearsAsaRetryState() {
        // Tied to THIS install's attribution read: a device restored from a
        // backup must not inherit a pending retry belonging to the install it
        // replaced, or it would send an app_open carrying a token for a
        // different install entirely.
        let storage = makeStorage()
        storage.asaPending = true
        storage.asaAttempts = 4

        storage.resetForNewInstall()

        XCTAssertFalse(storage.asaPending)
        XCTAssertEqual(storage.asaAttempts, 0)
    }

    // MARK: - installAnchor

    func testInstallAnchorDefaultsToZero() {
        let storage = makeStorage()
        XCTAssertEqual(storage.installAnchor, 0)
    }

    func testInstallAnchorRoundTrips() {
        let storage = makeStorage()
        storage.installAnchor = 1_700_000_000
        XCTAssertEqual(storage.installAnchor, 1_700_000_000)
    }

    // MARK: - removeDelivered

    func testRemoveDeliveredLeavesUndeliveredEntriesQueued() {
        let storage = makeStorage()
        storage.enqueue("a")
        storage.enqueue("b")
        storage.enqueue("c")

        storage.removeDelivered(["a", "c"])

        XCTAssertEqual(storage.queued(), ["b"])
    }

    func testRemoveDeliveredRereadsAtRemovalTimeRatherThanOverwriting() {
        // The exact race this method exists to close: something enqueues
        // between a flush's read and its write-back. A naive
        // `replaceQueue(remaining)` computed from a stale snapshot would wipe
        // out the entry enqueued in between; `removeDelivered` must not.
        let storage = makeStorage()
        storage.enqueue("a")
        storage.enqueue("b")
        let snapshotAtFlushStart = storage.queued() // ["a", "b"]

        // Something else enqueues while "delivery" of the snapshot is in flight.
        storage.enqueue("c")

        storage.removeDelivered(snapshotAtFlushStart)

        XCTAssertEqual(storage.queued(), ["c"])
    }

    func testRemoveDeliveredWithEmptyListIsANoOp() {
        let storage = makeStorage()
        storage.enqueue("a")

        storage.removeDelivered([])

        XCTAssertEqual(storage.queued(), ["a"])
    }
}
