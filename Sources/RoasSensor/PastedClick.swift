import Foundation

/// The answer to ``Roas/claimPastedClick(_:)`` and
/// ``Roas/handlePastedClick(_:completion:)``.
///
/// - ``matched``: the install now carries the website click the visitor tapped
///   (a smart banner or a "Download the app" link) — and so the ad that brought
///   them to the website, when there was one.
/// - ``reason`` (when not matched): `no_link` (the clipboard held none of our
///   links), `claimed` (another device already used this one), `expired`,
///   `already_attributed` (the install already has a source of its own),
///   `too_late` (more than 7 days after install), `done` (already asked once),
///   `unavailable` (not configured, or not iOS) or `offline` (try again later).
/// - ``channel`` / ``campaign``: the source the install took, when matched.
public struct PastedClickResult {
    public let matched: Bool
    public let reason: String
    public let channel: String
    public let campaign: String

    static func notMatched(_ reason: String) -> PastedClickResult {
        PastedClickResult(matched: false, reason: reason, channel: "", campaign: "")
    }
}

/// iOS web to app by clipboard: the pure half, testable on the macOS host.
///
/// The App Store passes nothing from a tap on a website to the app it installs,
/// so roas.js copies the tapped link — with a one-time code, `rs_pb` — to the
/// clipboard on iPhone. On first open the app hands the code to
/// `/mobile/paste-click`, and the install takes that exact click's source.
enum PastedClick {
    static let param = "rs_pb"
    /// A tap older than this cannot be what brought the install; stop asking.
    static let claimWindow: TimeInterval = 7 * 24 * 3600
    /// `no_install` right after configure usually means the install beacon is
    /// still queued: try again this many times, this far apart, in-session.
    static let inSessionRetries = 3
    static let retryDelay: TimeInterval = 5

    /// The code inside a pasted link, or nil when the text is not one of ours.
    /// Only the parameter is trusted, never the host: the code is checked by the
    /// server against the click it was minted for, so a stray match is harmless.
    static func code(in text: String?) -> String? {
        guard let text = text, !text.isEmpty, text.count <= 4096 else { return nil }
        let pattern = "[?&]\(param)=([A-Za-z0-9_-]{16,32})(?:[&#\\s]|$)"
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// Whether an answer settles the matter (never ask again) or is worth one
    /// more try on a later launch. `no_install` means the install beacon has not
    /// reached the server yet, and a nil answer is a network failure: both are
    /// temporary. Everything else is final, so the app never shows the paste
    /// prompt twice for the same outcome.
    static func isFinal(matched: Bool, reason: String?) -> Bool {
        if matched { return true }
        guard let reason = reason else { return false }
        return reason != "no_install"
    }

    /// Too long after install to still be the tap that brought it.
    static func tooLate(installAnchor: TimeInterval, now: TimeInterval) -> Bool {
        installAnchor > 0 && now - installAnchor > claimWindow
    }
}
