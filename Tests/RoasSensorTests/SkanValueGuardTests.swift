import XCTest
@testable import RoasSensor

/// `SkanValueGuard`: within one SKAdNetwork window a conversion value only
/// rises unless the caller opts in. Exercised on the macOS host — the guard is
/// pure, and the StoreKit call it gates is not.
final class SkanValueGuardTests: XCTestCase {

    private let day: TimeInterval = 24 * 3600

    func testWindowsFollowApplesBoundaries() {
        XCTAssertEqual(SkanValueGuard.window(elapsed: 0), 0)
        XCTAssertEqual(SkanValueGuard.window(elapsed: 2 * day - 1), 0)
        XCTAssertEqual(SkanValueGuard.window(elapsed: 2 * day), 1)
        XCTAssertEqual(SkanValueGuard.window(elapsed: 7 * day - 1), 1)
        XCTAssertEqual(SkanValueGuard.window(elapsed: 7 * day), 2)
        XCTAssertEqual(SkanValueGuard.window(elapsed: 35 * day - 1), 2)
        XCTAssertNil(SkanValueGuard.window(elapsed: 35 * day))
        XCTAssertEqual(SkanValueGuard.window(elapsed: -60), 0, "a clock that went backwards is still the first window")
    }

    func testALowerValueNeverOverwritesAPurchase() {
        let purchase = SkanValueGuard.decide(state: SkanWindowState(), window: 0, fine: 63, coarse: 2, lockWindow: false, allowDecrease: false)
        XCTAssertTrue(purchase.send)
        let engaged = SkanValueGuard.decide(state: purchase.state, window: 0, fine: 10, coarse: 1, lockWindow: false, allowDecrease: false)
        XCTAssertFalse(engaged.send, "nothing to send: the window already holds a higher value")
        XCTAssertEqual(engaged.state.fine, 63)
        XCTAssertEqual(engaged.state.coarse, 2)
    }

    func testAHigherFineValueKeepsTheHigherCoarseOne() {
        let first = SkanValueGuard.decide(state: SkanWindowState(), window: 0, fine: 5, coarse: 2, lockWindow: false, allowDecrease: false)
        let second = SkanValueGuard.decide(state: first.state, window: 0, fine: 20, coarse: 0, lockWindow: false, allowDecrease: false)
        XCTAssertTrue(second.send)
        XCTAssertEqual(second.fine, 20)
        XCTAssertEqual(second.coarse, 2)
    }

    func testAFineOnlyUpdateResendsTheCoarseValueAlreadySet() {
        let first = SkanValueGuard.decide(state: SkanWindowState(), window: 0, fine: 5, coarse: 1, lockWindow: false, allowDecrease: false)
        let second = SkanValueGuard.decide(state: first.state, window: 0, fine: 9, coarse: nil, lockWindow: false, allowDecrease: false)
        XCTAssertEqual(second.coarse, 1)
    }

    func testAllowDecreaseLowersOnPurpose() {
        let first = SkanValueGuard.decide(state: SkanWindowState(), window: 0, fine: 63, coarse: 2, lockWindow: false, allowDecrease: false)
        let lowered = SkanValueGuard.decide(state: first.state, window: 0, fine: 10, coarse: 0, lockWindow: false, allowDecrease: true)
        XCTAssertTrue(lowered.send)
        XCTAssertEqual(lowered.fine, 10)
        XCTAssertEqual(lowered.coarse, 0)
    }

    func testANewWindowStartsFromNothing() {
        let first = SkanValueGuard.decide(state: SkanWindowState(), window: 0, fine: 63, coarse: 2, lockWindow: false, allowDecrease: false)
        let next = SkanValueGuard.decide(state: first.state, window: 1, fine: 0, coarse: 0, lockWindow: false, allowDecrease: false)
        XCTAssertTrue(next.send)
        XCTAssertEqual(next.state.window, 1)
        XCTAssertEqual(next.coarse, 0)
    }

    func testALockedWindowIgnoresEverythingAfter() {
        let locked = SkanValueGuard.decide(state: SkanWindowState(), window: 0, fine: 40, coarse: 2, lockWindow: true, allowDecrease: false)
        XCTAssertTrue(locked.send)
        XCTAssertTrue(locked.lockWindow)
        let after = SkanValueGuard.decide(state: locked.state, window: 0, fine: 63, coarse: 2, lockWindow: false, allowDecrease: true)
        XCTAssertFalse(after.send)
    }

    func testCoarseNamesRoundTrip() {
        XCTAssertEqual(SkanValueGuard.coarseRank("HIGH"), 2)
        XCTAssertEqual(SkanValueGuard.coarseRank("mid"), 1)
        XCTAssertNil(SkanValueGuard.coarseRank("best"))
        XCTAssertEqual(SkanValueGuard.coarseName(0), "low")
        XCTAssertNil(SkanValueGuard.coarseName(-1))
    }

    func testStateSurvivesStorageAndIsClearedOnReinstall() {
        let storage = Storage(defaults: UserDefaults(suiteName: "roas.tests.\(UUID().uuidString)")!)
        storage.skanState = SkanWindowState(window: 1, fine: 30, coarse: 2, locked: true)
        storage.skanRegisteredAt = 1000
        XCTAssertEqual(storage.skanState, SkanWindowState(window: 1, fine: 30, coarse: 2, locked: true))
        storage.resetForNewInstall()
        XCTAssertEqual(storage.skanState, SkanWindowState())
        XCTAssertEqual(storage.skanRegisteredAt, 0)
    }
}
