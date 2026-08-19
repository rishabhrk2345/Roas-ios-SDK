import Foundation
import os.log

/// Delivers beacons: enqueue (persisted), then flush via URLSession. At-least-once
/// and idempotent — the server dedups on `external_id` / pv_id — so retrying a
/// first-open after a flaky network is always safe.
///
/// Every delivery attempt is logged (gated by `Roas.logLevel`) and reported to
/// `Roas.deliveryCallback` if one is set — this used to be entirely silent,
/// which made "did this beacon ever actually leave the device" undiagnosable
/// without attaching a debugger.
final class Transport {
    private let base: String
    private let storage: Storage
    private let queue = DispatchQueue(label: "com.roassensor.sdk.transport")
    private let session: URLSession
    /// Signs beacons so the collector can tell this app from a `curl` carrying
    /// the public site key. Nil until an app adopts signing.
    private let appSecret: String?
    private static let log = OSLog(subsystem: "com.roassensor.sdk", category: "Transport")

    /// Below this, the difference is network latency, not a wrong clock.
    private static let clockSkewThresholdSeconds: Int64 = 30

    init(
        baseUrl: String,
        storage: Storage,
        appSecret: String? = nil,
        session: URLSession = .shared
    ) {
        self.base = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        self.storage = storage
        self.appSecret = appSecret
        self.session = session
    }

    /// Run work off the main thread (e.g. reading device identifiers).
    func background(_ block: @escaping () -> Void) { queue.async(execute: block) }

    func send(path: String, body: [String: Any]) {
        guard
            let bodyData = try? JSONSerialization.data(withJSONObject: body),
            let bodyStr = String(data: bodyData, encoding: .utf8),
            let entryData = try? JSONSerialization.data(withJSONObject: ["url": base + path, "path": path, "body": bodyStr]),
            let entryStr = String(data: entryData, encoding: .utf8)
        else { return }
        storage.enqueue(entryStr)
        flush()
    }

    func flush() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let pending = self.storage.queued()
            guard !pending.isEmpty else { return }

            let group = DispatchGroup()
            let deliveredLock = NSLock()
            var delivered: [String] = []
            for entry in pending {
                group.enter()
                self.post(entry) { ok in
                    if ok { deliveredLock.lock(); delivered.append(entry); deliveredLock.unlock() }
                    group.leave()
                }
            }
            group.wait()
            // Removes exactly the delivered entries from whatever the queue
            // holds AT REMOVAL TIME, not an overwrite computed from the
            // `pending` snapshot read above — see Storage.removeDelivered.
            self.storage.removeDelivered(delivered)
        }
    }

    private func post(
        _ entry: String,
        isClockRetry: Bool = false,
        completion: @escaping (Bool) -> Void
    ) {
        guard
            let entryData = entry.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: entryData) as? [String: String],
            let urlStr = obj["url"], let url = URL(string: urlStr),
            let bodyData = obj["body"]?.data(using: .utf8)
        else { completion(true); return } // malformed entry → drop, don't loop forever
        let path = obj["path"] ?? urlStr

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 15
        // Signed HERE, at transmit, not at enqueue. A queued beacon may sit on
        // the device for days waiting for a network — the whole reason the queue
        // is persisted — and a signature minted at enqueue time would be far
        // outside the server's freshness window by the time it went out, so every
        // offline install would be refused. The event's own `ts` in the body
        // already carries when it happened; this timestamp only proves the
        // REQUEST is fresh.
        let now = Int64(Date().timeIntervalSince1970) + storage.clockOffsetSeconds
        if let signature = Signer.header(secret: appSecret, body: bodyData, epochSeconds: now) {
            request.setValue(signature, forHTTPHeaderField: Signer.headerName)
        }

        session.dataTask(with: request) { _, response, error in
            if let error = error {
                self.report(path: path, delivered: false, error: "\(error)")
                completion(false) // network error → retry
                return
            }
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            let corrected = self.learnClockOffset(from: http)

            // A 401 is normally permanent (bad secret) and would be dropped by
            // the `code < 500` rule below. It is also exactly what a badly-skewed
            // device clock produces, and dropping the install for that would be
            // silent loss on the handsets least able to report it. So if this
            // response also taught us a new offset, re-sign once — once only, or
            // a genuinely wrong secret becomes an infinite retry.
            if code == 401 && corrected && !isClockRetry {
                self.post(entry, isClockRetry: true, completion: completion)
                return
            }

            // 2xx delivered; 4xx = server rejected (bad/duplicate) → drop; 5xx → retry.
            let delivered = code < 500
            self.report(path: path, delivered: delivered, error: delivered ? nil : "HTTP \(code)")
            completion(delivered)
        }.resume()
    }

    /// Learn the device→server clock delta from the response's `Date` header.
    /// Returns true when the correction actually moved, which is what makes a
    /// 401 worth exactly one retry.
    private func learnClockOffset(from response: HTTPURLResponse?) -> Bool {
        // `value(forHTTPHeaderField:)`, NOT `allHeaderFields["Date"]`: the latter
        // is an exact-case dictionary lookup, and HTTP/2 lowercases every header
        // name on the wire. Behind an HTTP/2 edge the key is `date`, so the
        // dictionary form would silently never match — and the failure is
        // invisible, because a missing offset just means clock correction quietly
        // stops working for the handsets that need it most.
        guard let header = response?.value(forHTTPHeaderField: "Date") else { return false }
        let formatter = DateFormatter()
        // Fixed POSIX locale and GMT: RFC 7231's date format is not localized,
        // and a device in a non-Gregorian calendar locale would otherwise fail
        // to parse a perfectly valid header.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let serverDate = formatter.date(from: header) else { return false }

        let offset = Int64(serverDate.timeIntervalSince1970 - Date().timeIntervalSince1970)
        let previous = storage.clockOffsetSeconds
        guard abs(offset - previous) >= Transport.clockSkewThresholdSeconds else { return false }
        storage.clockOffsetSeconds = offset
        return true
    }

    private func report(path: String, delivered: Bool, error: String?) {
        if Roas.logLevel >= .debug || (!delivered && Roas.logLevel >= .error) {
            os_log(
                "%{public}@ -> %{public}@%{public}@",
                log: Transport.log,
                type: delivered ? .debug : .error,
                path,
                delivered ? "delivered" : (error ?? "failed"),
                delivered ? "" : " (will retry)"
            )
        }
        Roas.deliveryCallback?(path, delivered, error)
    }
}
