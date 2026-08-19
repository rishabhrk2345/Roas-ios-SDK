// Paste this into your new iOS app's ContentView.swift (replace the whole file).
// It wires the ROASSensor SDK into a bare SwiftUI screen so you can watch iOS
// beacons land in your backend, from the Simulator or a real device.
//
// FILL IN the two values marked below before running.

import SwiftUI
import RoasSensor

struct ContentView: View {
    // 1) Your backend, reachable from the Mac/device.
    //    • Easiest: an ngrok HTTPS URL (no App Transport Security fuss):
    //        run `ngrok http 8000` on the PC → use "https://xxxx.ngrok-free.dev"
    //    • Or your PC's LAN IP over http (needs an ATS exception in Info.plist,
    //      and only works while the device is on the same Wi-Fi):
    //        "http://10.0.127.242:8000"
    private let baseUrl = "https://PASTE-YOUR-NGROK.ngrok-free.dev"

    // 2) An iOS app property's public key (a Site with platform=ios) from the panel.
    private let publicKey = "PASTE-YOUR-IOS-SITE-PUBLIC-KEY"

    // On a real device leave this true so the ATT prompt appears and the install
    // beacon can carry the IDFA. In the Simulator it is pointless — there is no
    // real IDFA — but harmless.
    //
    // Set it false to test the DEFERRED path instead: no prompt at launch, and
    // the "Ask ATT now" button below binds the IDFA afterwards through
    // /identify. That is the flow a real app should ship, because a cold-start
    // system alert is the classic way to depress opt-in.
    private let promptForTrackingAtLaunch = true

    @State private var log = "ROASSensor iOS sample\n"

    var body: some View {
        VStack(spacing: 10) {
            Text("ROASSensor iOS Sample").font(.headline)
            Text("vid: \(Roas.visitorId() ?? "-")")
                .font(.caption).foregroundColor(.secondary)

            Button("Track: add_to_cart") {
                Roas.track(.addToCart, properties: [
                    RoasProps.productId: "DEMO-1",
                    RoasProps.quantity: 1,
                ])
                append("track(add_to_cart) queued")
            }
            Button("Track: begin_checkout") {
                Roas.track(.beginCheckout, properties: [RoasProps.productId: "DEMO-1"])
                append("track(begin_checkout) queued")
            }
            Button("Identify: buyer@example.com") {
                // Also re-reads the IDFA, so this is what picks up a user who
                // allowed tracking later from Settings → Privacy.
                Roas.identify(email: "buyer@example.com")
                append("identify queued")
            }
            Button("Ask ATT now (deferred prompt)") {
                // NOT `requestTracking()` -- that is the Dart name in
                // roas_flutter. The Swift API is spelled out in full.
                Roas.requestTrackingAuthorization()
                append("ATT requested")
            }
            Button("SKAN conversion value 3") {
                Roas.updateConversionValue(3, coarse: "low")
                append("SKAN fine=3 coarse=low")
            }
            Button("Show ids") {
                append("vid = \(Roas.visitorId() ?? "-")")
                append("appAccountToken = \(Roas.appAccountToken()?.uuidString ?? "-")")
            }

            ScrollView {
                Text(log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // No `.buttonStyle(.borderedProminent)` -- it is iOS 15+, and this SDK
        // supports iOS 14. A sample that will not compile at the deployment
        // target its own package declares is a bad first impression.
        .padding()
        // Forward universal / deferred deep links so their click id and utm
        // context attribute this open. Harmless when the app was not opened
        // by a link.
        .onOpenURL { url in
            Roas.handleDeepLink(url)
            append("deep link forwarded: \(url.query ?? "-")")
        }
        .onAppear(perform: start)
    }

    private func start() {
        // Verbose console logging, and an on-screen record of every delivery
        // attempt. The callback is what makes a device test readable: on a
        // phone you cannot watch the Xcode console comfortably, and a beacon
        // that silently failed looks exactly like one that was never sent.
        Roas.setLogLevel(.debug)
        Roas.setOnDeliveryResult { path, success, error in
            // Transport delivers off the main thread; @State must be touched on it.
            DispatchQueue.main.async {
                append("\(success ? "OK  " : "FAIL") \(path)\(error.map { " — \($0)" } ?? "")")
            }
        }
        // Fires the install (first-open) on a fresh install, or a session-start
        // beacon on a returning launch.
        Roas.configure(
            publicKey: publicKey,
            requestTrackingAuthorization: promptForTrackingAtLaunch,
            baseUrl: baseUrl
        )
        append("configured → \(baseUrl)")
    }

    private func append(_ line: String) { log += "→ \(line)\n" }
}
