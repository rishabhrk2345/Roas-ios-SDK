import Foundation

/// How much the SDK writes to the console. Defaults to `.error` — enough to
/// see a device that can never deliver anything, without spamming every
/// successful beacon in a release build.
public enum RoasLogLevel: Int, Comparable {
    case none = 0
    case error = 1
    case debug = 2

    public static func < (lhs: RoasLogLevel, rhs: RoasLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
