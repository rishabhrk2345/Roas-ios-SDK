import XCTest
@testable import RoasSensor

/// The session state machine, exercised on the macOS host (no simulator needed —
/// `SessionTracker` and `Storage` are pure Foundation).
///
/// These exist because the rules here are mirrored from the web SDK's
/// `session.ts` and the Android `SessionTracker.kt`, and a drift between them is
/// silent: a customer comparing their site and their app in one dashboard would
/// simply be comparing two different definitions of "a session", with nothing
/// anywhere reporting a problem.
final class SessionTrackerTests: XCTestCase {

    /// A throwaway UserDefaults per test — the real one is shared process state
    /// and would leak a session from one test into the next.
    private func makeTracker() -> (SessionTracker, Storage) {
        let suite = UserDefaults(suiteName: "roas.tests.\(UUID().uuidString)")!
        let storage = Storage(defaults: suite)
        return (SessionTracker(storage: storage), storage)
    }

    func testFirstCallStartsSessionOne() {
        let (tracker, _) = makeTracker()
        let session = tracker.current()
        XCTAssertTrue(session.started)
        XCTAssertEqual(session.number, 1)
        XCTAssertFalse(session.id.isEmpty)
        XCTAssertTrue(session.pvId.hasPrefix("pv"))
    }

    func testASecondCallResumesRatherThanRestarting() {
        // The load-bearing one. If `started` came back true on every call, every
        // foreground would emit a second touch for the same visit and dilute
        // every multi-touch credit split.
        let (tracker, _) = makeTracker()
        let first = tracker.current()
        let second = tracker.current()
        XCTAssertFalse(second.started)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.pvId, second.pvId)
    }

    func testThirtyIdleMinutesStartsANewSession() {
        let (tracker, storage) = makeTracker()
        let first = tracker.current()
        // Wind the idle clock back past the 30-minute boundary.
        storage.sessionLastActiveAt -= (30 * 60) + 1

        let second = tracker.current()
        XCTAssertTrue(second.started)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second.number, 2)
        // A new session means a new pv_id, or the second visit would upsert onto
        // the first visit's touchpoint instead of recording itself.
        XCTAssertNotEqual(second.pvId, first.pvId)
    }

    func testJustUnderThirtyIdleMinutesIsStillTheSameSession() {
        let (tracker, storage) = makeTracker()
        let first = tracker.current()
        storage.sessionLastActiveAt -= (30 * 60) - 60

        let second = tracker.current()
        XCTAssertFalse(second.started)
        XCTAssertEqual(second.id, first.id)
    }

    func testLocalMidnightStartsANewSession() {
        // Their midnight, not UTC's — "yesterday's session" should mean what the
        // marketer's customer would say it means.
        let (tracker, storage) = makeTracker()
        let first = tracker.current()
        storage.sessionDay = "1999-1-1"

        let second = tracker.current()
        XCTAssertTrue(second.started)
        XCTAssertNotEqual(second.id, first.id)
    }

    func testSequenceIsMonotonicWithinASessionAndResetsAcrossOne() {
        let (tracker, storage) = makeTracker()
        _ = tracker.current()
        XCTAssertEqual(tracker.nextSequence(), 1)
        XCTAssertEqual(tracker.nextSequence(), 2)
        XCTAssertEqual(tracker.nextSequence(), 3)

        storage.sessionLastActiveAt -= (30 * 60) + 1
        // Rolls over inside nextSequence, so the first event of the new session
        // is 1 again — the index is within a session, not a lifetime counter.
        XCTAssertEqual(tracker.nextSequence(), 1)
    }

    func testAnEventAfterThirtyIdleMinutesStartsASession() {
        let (tracker, storage) = makeTracker()
        _ = tracker.current()
        storage.sessionLastActiveAt -= (30 * 60) + 1

        _ = tracker.nextSequence()
        XCTAssertEqual(storage.sessionNumber, 2)
    }

    func testForegroundTimeAccumulatesAcrossStretches() {
        // A session routinely spans several foreground stretches (the user checks
        // a notification and comes back). The number must answer "how long were
        // they in the app this visit", so it is cumulative, not per-stretch.
        let (tracker, storage) = makeTracker()
        _ = tracker.current()

        tracker.markForeground()
        storage.sessionForegroundMs = 5_000 // stand in for a prior stretch
        let total = tracker.markBackground()
        XCTAssertGreaterThanOrEqual(total, 5_000)
        XCTAssertEqual(total, storage.sessionForegroundMs)
    }

    func testBackgroundingResetsTheIdleClockToWhenTheyLeft() {
        // Not to their last event: an app suspended in the background would
        // otherwise keep one session alive indefinitely.
        let (tracker, storage) = makeTracker()
        _ = tracker.current()
        storage.sessionLastActiveAt -= 600

        tracker.markForeground()
        _ = tracker.markBackground()
        XCTAssertEqual(storage.sessionLastActiveAt, Date().timeIntervalSince1970, accuracy: 5)
    }

    func testANewSessionZeroesTheForegroundAccumulator() {
        let (tracker, storage) = makeTracker()
        _ = tracker.current()
        storage.sessionForegroundMs = 120_000

        storage.sessionLastActiveAt -= (30 * 60) + 1
        _ = tracker.current()
        XCTAssertEqual(storage.sessionForegroundMs, 0)
    }

    func testSessionSurvivesANewTrackerOverTheSameStorage() {
        // Stands in for the process being killed and relaunched — routine on a
        // phone. A session held only in memory would restart every time the OS
        // reclaimed the app, inflating counts and destroying retention.
        let suite = UserDefaults(suiteName: "roas.tests.\(UUID().uuidString)")!
        let storage = Storage(defaults: suite)
        let first = SessionTracker(storage: storage).current()

        let resumed = SessionTracker(storage: storage).current()
        XCTAssertFalse(resumed.started)
        XCTAssertEqual(resumed.id, first.id)
        XCTAssertEqual(resumed.number, 1)
    }
}
