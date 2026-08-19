// Paste this into your new iOS app's ContentView.swift (replace the whole file).
// It wires the ROASSensor SDK into a bare SwiftUI screen with a few buttons, so
// you can watch iOS beacons land in your backend from the Simulator.
//
// FILL IN the two values marked below before running.

import SwiftUI
import RoasSensor

struct ContentView: View {
    // 1) Your backend, reachable from the Mac/Simulator.
    //    • Easiest: an ngrok HTTPS URL (no App Transport Security fuss):
    //        run `ngrok http 8000` on the PC → use "https://xxxx.ngrok-free.dev"
    //    • Or your PC's LAN IP over http (needs the ATS exception — see the guide):
    //        "http://10.0.127.242:8000"
    private let baseUrl = "https://PASTE-YOUR-NGROK.ngrok-free.dev"

    // 2) An iOS app property's public key (Site with platform=ios) from the panel.
    private let publicKey = "PASTE-YOUR-IOS-SITE-PUBLIC-KEY"

    @State private var log = "ROASSensor iOS sample\n"

    var body: some View {
        VStack(spacing: 12) {
            Text("ROASSensor iOS Sample").font(.headline)
            Text("vid: \(Roas.visitorId() ?? "-")")
                .font(.caption).foregroundColor(.secondary)

            Button("Track: add_to_cart") {
                Roas.track(.addToCart, properties: ["sku": "DEMO-1", "qty": 1])
                append("track(add_to_cart) sent")
            }
            Button("Track: begin_checkout") {
                Roas.track(.beginCheckout)
                append("track(begin_checkout) sent")
            }
            Button("Identify: buyer@example.com") {
                Roas.identify(email: "buyer@example.com")
                append("identify sent")
            }
            Button("Show visitor id") { append("vid = \(Roas.visitorId() ?? "-")") }

            ScrollView {
                Text(log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.borderedProminent)
        .padding()
        .onAppear {
            // Fires the install (first-open). requestTrackingAuthorization=false so
            // the Simulator doesn't try to show the ATT prompt (which needs a device).
            Roas.configure(publicKey: publicKey, requestTrackingAuthorization: false, baseUrl: baseUrl)
            append("configured → \(baseUrl)")
        }
    }

    private func append(_ line: String) { log += "→ \(line)\n" }
}
