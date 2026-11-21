import SwiftUI
import StoreKit

struct ContentView: View {
    @State private var bought: [String] = []
    @State private var ledger: [String] = []
    @State private var queued: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("observePurchases test").font(.title2).bold()
                HStack {
                    Button("Buy consumable") { buy("com.roas.test.consumable") }
                    Button("Buy yearly") { buy("com.roas.test.yearly") }
                    Button("Refresh") { refresh() }
                }.buttonStyle(.bordered)
                Text("1. Bought in the app").bold()
                ForEach(bought, id: \.self) { Text($0).font(.caption.monospaced()) }
                Text("2. SDK says it reported (ledger)").bold()
                ForEach(ledger, id: \.self) { Text($0).font(.caption.monospaced()) }
                Text("3. Purchase reports waiting to send").bold()
                ForEach(queued.indices, id: \.self) { Text(queued[$0]).font(.caption.monospaced()) }
            }.padding()
        }
        .onAppear { refresh() }
    }

    func buy(_ productId: String) {
        Task {
            do {
                guard let product = try await Product.products(for: [productId]).first else {
                    bought.append("NO PRODUCT \(productId) - is the StoreKit configuration selected in the scheme?")
                    return
                }
                switch try await product.purchase() {
                case .success(.verified(let t)):
                    bought.append("\(productId) -> transaction \(t.id)")
                    await t.finish()
                case .success: bought.append("unverified")
                case .pending: bought.append("pending")
                case .userCancelled: bought.append("cancelled")
                @unknown default: break
                }
            } catch { bought.append("error \(error)") }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            refresh()
        }
    }

    func refresh() {
        let d = UserDefaults.standard
        ledger = d.stringArray(forKey: "com.roassensor.sdk.reported_purchases") ?? []
        queued = (d.stringArray(forKey: "com.roassensor.sdk.queue") ?? []).compactMap { entry in
            guard let r = entry.range(of: "transaction_id") else { return nil }
            return String(entry[r.lowerBound...].prefix(40))
        }
    }
}
