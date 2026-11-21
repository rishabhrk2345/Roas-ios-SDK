import Foundation
#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Which of the person's StoreKit transactions the SDK should ask the server to
/// verify. Pure, so the rules are tested on the macOS host without StoreKit.
enum PurchaseRules {
    /// A transaction is reported only when it
    ///  - was bought at or after observation began on this install (StoreKit lists a
    ///    person's whole history on a reinstalled app; an old sale reported against a
    ///    fresh install's visitor id would credit a campaign that never earned it), and
    ///  - has not been refunded or revoked (those arrive from the store's notifications,
    ///    and a refund is not a purchase).
    static func isEligible(purchasedAt: Date, revokedAt: Date?, since: TimeInterval) -> Bool {
        guard since > 0 else { return false }
        guard revokedAt == nil else { return false }
        return purchasedAt.timeIntervalSince1970 >= since
    }
}

#if canImport(StoreKit)

/// Watches the App Store for this person's purchases and asks ROAS Sensor to
/// verify each one (`Roas.verifyPurchase`), so the app writes nothing at the
/// purchase site and a purchase is reported whichever way it was made: StoreKit 1,
/// StoreKit 2, RevenueCat, or a renewal that happened while the app was closed.
///
/// What it sends is only the transaction id. The server then fetches Apple's own
/// signed copy of that transaction and books the amount, currency and product
/// *Apple* reports, so a tampered build cannot invent revenue. It needs the App
/// Store In-App Purchase key on the ROAS account; without one the server refuses
/// each question and nothing is booked.
///
/// It never calls `finish()` on a transaction. Finishing belongs to whoever sells
/// the product (the app, or RevenueCat); an observer that finished it would hide
/// the purchase from them.
///
/// StoreKit 2 lists every transaction on the account whichever API made it, so one
/// listener plus a sweep on foreground covers a purchase made through StoreKit 1
/// as well. Needs iOS 15; on iOS 14 it does nothing and `verifyPurchase` remains
/// the explicit route.
@available(iOS 15.0, macOS 12.0, *)
enum PurchaseObserver {
    private static let lock = NSLock()
    private static var started = false

    /// Begin watching. Idempotent. `report` is called once per new transaction id.
    static func start(storage: Storage, report: @escaping (String) -> Void) {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()

        // Fixed once, on the first start of this install: later starts and later
        // launches keep it, so a purchase made while the SDK was not yet watching
        // is never mistaken for one made after.
        if storage.purchaseObserveSince == 0 {
            storage.purchaseObserveSince = Date().timeIntervalSince1970
        }

        // Purchases that arrive outside a `purchase()` call: a renewal, an
        // Ask-to-Buy approval, a purchase made on another device, and whatever the
        // app left unfinished.
        Task.detached(priority: .utility) {
            for await result in StoreKit.Transaction.updates {
                handle(result, storage: storage, report: report)
            }
        }
        // Whatever happened while the app was not running, and any purchase made
        // through a path that never reaches `updates` (a StoreKit 2 `purchase()`).
        sweepInBackground(storage: storage, report: report)
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { _ in sweepInBackground(storage: storage, report: report) }
        #endif
    }

    private static func sweepInBackground(storage: Storage, report: @escaping (String) -> Void) {
        Task.detached(priority: .utility) {
            await sweep(storage: storage, report: report)
        }
    }

    /// Look at every transaction on the account once and report the new ones.
    /// `Transaction.all` is every transaction whichever API made it. Reading it
    /// whole is cheap (a few records) and avoids relying on its order. Internal
    /// so a StoreKit test session can await it instead of racing a listener.
    static func sweep(storage: Storage, report: (String) -> Void) async {
        for await result in StoreKit.Transaction.all {
            handle(result, storage: storage, report: report)
        }
    }

    private static func handle(
        _ result: VerificationResult<StoreKit.Transaction>,
        storage: Storage,
        report: (String) -> Void
    ) {
        // A transaction StoreKit itself could not verify is not a purchase to ask
        // about; the server would only be asked to confirm a forgery.
        guard case .verified(let transaction) = result else { return }
        guard PurchaseRules.isEligible(
            purchasedAt: transaction.purchaseDate,
            revokedAt: transaction.revocationDate,
            since: storage.purchaseObserveSince
        ) else { return }
        let id = String(transaction.id)
        // One report per transaction across the listener and the sweeps. (An
        // explicit `Roas.verifyPurchase` call by the app is not recorded here; the
        // server dedupes on the transaction id, so the repeat is harmless.)
        guard storage.claimPurchase(id) else { return }
        report(id)
    }
}

#endif
