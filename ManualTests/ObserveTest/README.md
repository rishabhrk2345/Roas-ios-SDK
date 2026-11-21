# observePurchases manual check

`swift test` cannot run a simulated App Store: StoreKit's test session needs an app identity,
and a command-line test run has none (`notEntitled`). So the StoreKit side of
`Roas.configure(observePurchases: true)` is checked by hand in a small app.

## Set up (once)
1. Xcode: File > New > Project > iOS > App, SwiftUI, named `ObserveTest`.
2. File > Add Package Dependencies > Add Local... > this `sdk-ios` folder; add `RoasSensor` to the target.
3. Drag `Products.storekit` into the project (copy items, tick the target), then
   Product > Scheme > Edit Scheme > Run > Options > StoreKit Configuration > `Products.storekit`.
4. Replace `ObserveTestApp.swift` and `ContentView.swift` with the two files in this folder.

The app points the SDK at an unreachable host on purpose, so nothing reaches production and each
purchase report waits in the SDK's queue, which the screen shows.

## Run
1. Run on a simulator. Tap **Buy consumable** and confirm the StoreKit sheet.
2. Expect the same transaction id once in each of the three sections: bought, the SDK's reported
   ledger, and the queued report.
3. Buy the yearly subscription: a second id, once in each section.
4. Stop and run again, tap **Refresh**: nothing is added or repeated. Buy the consumable again: a
   new id, once.

Buying the yearly subscription twice shows Apple's "You're currently subscribed" sheet and creates
no transaction, which is correct.

Checked 2026-11-21 on an iPhone 17 simulator (iOS 26.5): ids 0, 1 and 2 were each reported exactly
once, and nothing was reported again after a restart.
