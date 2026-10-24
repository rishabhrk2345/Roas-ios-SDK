import Foundation

/// Turns whatever a host app put in `Roas.track(properties:)` into something
/// `JSONSerialization` will accept.
///
/// `properties` is `[String: Any]`, so `["at": Date()]`, `["link": url]` or
/// `["ratio": 0.0 / 0.0]` all compile. `JSONSerialization.data(withJSONObject:)`
/// does not throw a Swift error for them: it raises an Objective-C
/// `NSInvalidArgumentException` ("Invalid type in JSON write", "Invalid number
/// value (NaN) in JSON write"), which `try?` cannot catch, so one such value
/// crashed the customer's app on a tracking call. An SDK must never be the
/// reason an app crashes, so every value is cleaned before it is serialised:
///
/// - `String`, `Bool` and finite numbers pass through unchanged.
/// - `NaN` and infinity are dropped: there is no JSON for them, and a made-up
///   stand-in (0, a string) would be read as a real figure.
/// - `Date` becomes ISO-8601 in UTC (`2026-10-23T09:30:00Z`), `URL` its
///   `absoluteString`.
/// - Dictionaries and arrays are cleaned recursively; a non-string dictionary
///   key becomes its description.
/// - `nil` (an Optional inside the dictionary) is dropped; `NSNull` is kept.
/// - Anything else becomes `String(describing:)`, so an enum or a custom type
///   still arrives as something readable rather than taking the event with it.
///
/// The same rules as Android's `JsonProps.kt`, so one `track` call made from
/// both platforms stores the same props.
enum JSONSafe {
    /// Deeper than any real properties dictionary. The cap exists for a
    /// self-containing `NSMutableArray`/`NSMutableDictionary`, which would
    /// otherwise recurse until the stack overflows: the crash this file is for.
    static let maxDepth = 8

    static func object(_ dictionary: [String: Any]) -> [String: Any] {
        object(dictionary as [AnyHashable: Any], depth: 0)
    }

    private static func object(_ dictionary: [AnyHashable: Any], depth: Int) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, raw) in dictionary {
            let name = (key.base as? String) ?? String(describing: key.base)
            if let clean = value(raw, depth: depth + 1) { out[name] = clean }
        }
        return out
    }

    /// One value, cleaned; nil means "leave it out".
    static func value(_ raw: Any, depth: Int = 0) -> Any? {
        guard depth <= maxDepth else { return nil }

        // An Optional boxed in `Any`: `["coupon": maybeCode]` with a nil code.
        let mirror = Mirror(reflecting: raw)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return nil }
            return value(wrapped, depth: depth)
        }

        switch raw {
        case is NSNull:
            return NSNull()
        case let string as String:
            return string
        case let date as Date:
            return iso8601(date)
        case let url as URL:
            return url.absoluteString
        case let number as NSNumber:
            // Bool, Int, Double, Float and Decimal all arrive here on Apple
            // platforms. NaN and infinity are the only numbers JSON refuses.
            return number.doubleValue.isFinite ? number : nil
        case let double as Double:
            return double.isFinite ? double : nil
        case let float as Float:
            return float.isFinite ? float : nil
        case is Bool, is Int, is Int8, is Int16, is Int32, is Int64,
             is UInt, is UInt8, is UInt16, is UInt32, is UInt64:
            return raw
        case let dictionary as [AnyHashable: Any]:
            return object(dictionary, depth: depth)
        case let array as [Any]:
            return array.compactMap { value($0, depth: depth + 1) }
        default:
            return String(describing: raw)
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
