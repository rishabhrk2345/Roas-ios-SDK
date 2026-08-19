import CommonCrypto
import Foundation

/// HMAC-SHA256 beacon signing — the iOS twin of `Signer.kt`.
///
/// A native app sends no `Origin` header, so the collector has no way to tell a
/// real install from a `curl` carrying the (public) site key. Signing raises
/// that from "read the key off a network trace" to "reverse-engineer the app".
///
/// Honest about the ceiling: the secret ships inside the IPA and any embedded
/// secret is extractable. What it buys is that scripted abuse stops working, a
/// captured beacon can't be replayed later (the timestamp is inside the MAC),
/// and an extracted secret is recoverable — the customer rotates it and every
/// build carrying the old one stops verifying.
///
/// Wire format mirrors the Stripe webhook scheme the backend already verifies:
///
///     X-Roas-Signature: t=<epoch seconds>,v1=<hex>
///     signed payload   = "<t>." + raw body bytes
///
/// CommonCrypto rather than CryptoKit: CryptoKit needs iOS 13, and this SDK
/// still supports older deployment targets. There is no third-party dependency
/// either way.
enum Signer {

    /// Named `headerName`, not `header`, because the function below is also
    /// called `header` — Swift can usually tell a stored property from a method
    /// by context, but "usually" is not a property worth relying on for the one
    /// line that decides whether a beacon is authenticated.
    static let headerName = "X-Roas-Signature"

    /// The header value for `body` at `epochSeconds`, or nil when no secret was
    /// configured (an app that hasn't adopted signing — the server treats a
    /// missing signature as an old build until the customer enforces).
    static func header(secret: String?, body: Data, epochSeconds: Int64) -> String? {
        guard let secret = secret, !secret.isEmpty,
              let keyData = secret.data(using: .utf8),
              let prefix = "\(epochSeconds).".data(using: .utf8)
        else { return nil }

        var message = prefix
        message.append(body)

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        keyData.withUnsafeBytes { keyBytes in
            message.withUnsafeBytes { messageBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    keyBytes.baseAddress, keyData.count,
                    messageBytes.baseAddress, message.count,
                    &digest
                )
            }
        }
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "t=\(epochSeconds),v1=\(hex)"
    }
}
