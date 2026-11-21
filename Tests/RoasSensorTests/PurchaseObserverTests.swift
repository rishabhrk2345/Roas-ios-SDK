import XCTest
@testable import RoasSensor

/// The rules deciding which StoreKit transactions the SDK asks the server about,
/// and the ledger that keeps one transaction from being reported twice. Both are
/// pure Foundation, so they run on the macOS host; the StoreKit listener itself
/// needs a device or a StoreKit test session.
final class PurchaseObserverTests: XCTestCase {

    private func makeStorage() -> Storage {
        Storage(defaults: UserDefaults(suiteName: "roas.tests.\(UUID().uuidString)")!)
    }

    private let since: TimeInterval = 1_800_000_000

    // MARK: - PurchaseRules

    func testAPurchaseAfterObservationBeganIsEligible() {
        XCTAssertTrue(PurchaseRules.isEligible(
            purchasedAt: Date(timeIntervalSince1970: since + 60), revokedAt: nil, since: since))
    }

    func testAPurchaseAtTheStartMomentIsEligible() {
        XCTAssertTrue(PurchaseRules.isEligible(
            purchasedAt: Date(timeIntervalSince1970: since), revokedAt: nil, since: since))
    }

    func testAPurchaseFromBeforeObservationBeganIsNeverReported() {
        // A reinstalled app sees the person's whole history; none of it belongs to this install.
        XCTAssertFalse(PurchaseRules.isEligible(
            purchasedAt: Date(timeIntervalSince1970: since - 86_400 * 200), revokedAt: nil, since: since))
    }

    func testARefundedOrRevokedTransactionIsNotAPurchase() {
        XCTAssertFalse(PurchaseRules.isEligible(
            purchasedAt: Date(timeIntervalSince1970: since + 60),
            revokedAt: Date(timeIntervalSince1970: since + 120), since: since))
    }

    func testNothingIsEligibleBeforeObservationHasStarted() {
        // since == 0 means "not started": there is no boundary to compare to, so report nothing.
        XCTAssertFalse(PurchaseRules.isEligible(
            purchasedAt: Date(timeIntervalSince1970: 1_900_000_000), revokedAt: nil, since: 0))
    }

    // MARK: - The ledger

    func testATransactionIsClaimedOnce() {
        let storage = makeStorage()
        XCTAssertTrue(storage.claimPurchase("2000000123456789"))
        XCTAssertFalse(storage.claimPurchase("2000000123456789"))
        XCTAssertTrue(storage.hasReportedPurchase("2000000123456789"))
        XCTAssertFalse(storage.hasReportedPurchase("2000000999999999"))
    }

    func testTheLedgerIsBoundedAndKeepsTheNewest() {
        let storage = makeStorage()
        for i in 0..<(Storage.maxReportedPurchases + 20) {
            XCTAssertTrue(storage.claimPurchase("t\(i)"))
        }
        XCTAssertFalse(storage.hasReportedPurchase("t0"))   // aged out
        XCTAssertTrue(storage.hasReportedPurchase("t\(Storage.maxReportedPurchases + 19)"))
    }

    func testAReinstallStartsWithAnEmptyLedgerAndNoStartTime() {
        let storage = makeStorage()
        storage.purchaseObserveSince = since
        _ = storage.claimPurchase("2000000123456789")

        storage.resetForNewInstall()

        XCTAssertEqual(storage.purchaseObserveSince, 0)
        XCTAssertFalse(storage.hasReportedPurchase("2000000123456789"))
    }
}
