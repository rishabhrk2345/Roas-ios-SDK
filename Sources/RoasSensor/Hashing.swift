import Foundation
import CryptoKit

/// PII hashing, mirrored **BYTE-FOR-BYTE** from the backend `security.py`
/// (`hash_email` / `normalize_phone` / `hash_phone`), the web SDK `hash.ts`, and
/// the Android SDK `Hashing.kt`. Email/phone are hashed on-device so the raw
/// value never leaves the phone; the server matches on the hash.
///
/// Break this parity and identity matching silently fails — verified by
/// `HashingParityTests` against vectors generated from the backend.
enum Hashing {
    static let minPhoneDigits = 7

    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Unsalted SHA-256 of the trimmed, lowercased email (Meta CAPI form).
    static func hashEmail(_ email: String?) -> String {
        let normalized = (email ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? "" : sha256Hex(normalized)
    }

    /// Unsalted SHA-256 of the normalized phone (leading `+` kept). Returns "" for
    /// fewer than 7 digits so a garbled number never becomes a matchable key.
    static func hashPhone(_ phone: String?) -> String {
        let normalized = normalizePhone(phone)
        let digitCount = normalized.reduce(0) { $0 + (($1 >= "0" && $1 <= "9") ? 1 : 0) }
        return digitCount < minPhoneDigits ? "" : sha256Hex(normalized)
    }

    /// NFKC-normalize → fold Arabic-Indic (U+0660–0669) and Extended/Persian
    /// (U+06F0–06F9) digits to ASCII → keep only ASCII digits and `+`.
    static func normalizePhone(_ phone: String?) -> String {
        let nfkc = (phone ?? "").precomposedStringWithCompatibilityMapping // NFKC
        var result = ""
        for scalar in nfkc.unicodeScalars {
            let v = scalar.value
            if v >= 0x0660 && v <= 0x0669 {
                result.unicodeScalars.append(UnicodeScalar(0x30 + (v - 0x0660))!)
            } else if v >= 0x06F0 && v <= 0x06F9 {
                result.unicodeScalars.append(UnicodeScalar(0x30 + (v - 0x06F0))!)
            } else if (v >= 0x30 && v <= 0x39) || v == 0x2B { // ASCII 0-9 or '+'
                result.unicodeScalars.append(scalar)
            }
            // everything else is dropped, matching re.sub(r"[^0-9+]", "")
        }
        return result
    }
}
