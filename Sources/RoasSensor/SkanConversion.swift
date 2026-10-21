import Foundation

/// Keeps SKAdNetwork conversion values from going backwards by accident.
///
/// Under SKAdNetwork 4 (iOS 16.1+) Apple accepts a LOWER value than the one
/// already set. That exists for apps that deliberately re-encode, but for an app
/// that calls `Roas.updateConversionValue` on each event it is a trap: a
/// purchase reported as 63 on day one, then an "engaged" 10 on day two, tells
/// the ad network the install never purchased. So within one conversion window
/// a value only ever moves up, unless the caller explicitly opts in with
/// `allowDecrease`.
///
/// Apple's windows, measured from the install's first registration:
/// 0–2 days, 3–7 days, 8–35 days. Each window gets its own postback, so the
/// "highest so far" resets when a new one opens. The fine value only reaches
/// the first window's postback (the later two carry the coarse value alone),
/// but it is still tracked per window, because Apple's API takes one either way.
///
/// Pure and clock-free, so it is tested on the macOS host like `SessionTracker`.
struct SkanWindowState: Equatable {
    /// 0, 1 or 2; -1 = nothing recorded yet.
    var window: Int = -1
    /// Highest fine value sent in `window`; -1 = none.
    var fine: Int = -1
    /// Highest coarse rank sent in `window` (0 low, 1 medium, 2 high); -1 = none.
    var coarse: Int = -1
    /// The window was locked early (`lockWindow`); Apple ignores further updates.
    var locked: Bool = false
}

enum SkanValueGuard {
    static let firstWindowEnd: TimeInterval = 2 * 24 * 3600
    static let secondWindowEnd: TimeInterval = 7 * 24 * 3600
    static let lastWindowEnd: TimeInterval = 35 * 24 * 3600

    /// Which window `elapsed` seconds after registration falls in, or nil once
    /// the last one has closed (an update then reaches no postback at all).
    static func window(elapsed: TimeInterval) -> Int? {
        if elapsed < firstWindowEnd { return 0 }  // includes a clock that went backwards
        if elapsed < secondWindowEnd { return 1 }
        if elapsed < lastWindowEnd { return 2 }
        return nil
    }

    /// The backend schema's names → rank. Unknown input is nil, never a guess.
    static func coarseRank(_ name: String?) -> Int? {
        switch name?.lowercased() {
        case "low": return 0
        case "medium", "mid": return 1
        case "high": return 2
        default: return nil
        }
    }

    static func coarseName(_ rank: Int) -> String? {
        switch rank {
        case 0: return "low"
        case 1: return "medium"
        case 2: return "high"
        default: return nil
        }
    }

    struct Decision: Equatable {
        /// Whether to call Apple at all.
        let send: Bool
        let fine: Int
        /// Coarse rank to send with it, nil = none ever set in this window.
        let coarse: Int?
        let lockWindow: Bool
        /// What to persist (only when `send`).
        let state: SkanWindowState
    }

    static func decide(
        state current: SkanWindowState,
        window: Int,
        fine: Int,
        coarse: Int?,
        lockWindow: Bool,
        allowDecrease: Bool
    ) -> Decision {
        var state = current
        if state.window != window {
            state = SkanWindowState(window: window)
        }
        if state.locked {
            return Decision(send: false, fine: state.fine, coarse: nil, lockWindow: false, state: state)
        }
        let nextFine = allowDecrease ? fine : max(fine, state.fine)
        let nextCoarse: Int?
        if let coarse = coarse {
            nextCoarse = allowDecrease ? coarse : max(coarse, state.coarse)
        } else {
            // Re-send the coarse value already set: on iOS 16.1+ a fine-only
            // update is not guaranteed to keep it, and losing it silences the
            // small campaigns that only ever report coarse.
            nextCoarse = state.coarse >= 0 ? state.coarse : nil
        }
        let changed = nextFine != state.fine || (nextCoarse ?? -1) != state.coarse || lockWindow
        guard changed else {
            return Decision(send: false, fine: state.fine, coarse: nextCoarse, lockWindow: false, state: current)
        }
        state.fine = nextFine
        state.coarse = nextCoarse ?? -1
        state.locked = lockWindow
        return Decision(send: true, fine: nextFine, coarse: nextCoarse, lockWindow: lockWindow, state: state)
    }
}
