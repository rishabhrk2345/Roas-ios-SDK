import SwiftUI
import RoasSensor

@main
struct ObserveTestApp: App {
    init() {
        Roas.setLogLevel(.debug)
        // A dummy key and an unreachable host: nothing reaches production. The SDK's report
        // simply waits in its queue, which this screen shows.
        Roas.configure(
            publicKey: "00000000-0000-0000-0000-000000000000",
            requestTrackingAuthorization: false,
            baseUrl: "https://invalid.invalid",
            observePurchases: true
        )
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
