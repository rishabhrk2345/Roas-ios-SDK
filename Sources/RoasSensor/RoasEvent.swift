import Foundation

/// Funnel / behaviour events — the app equivalent of `roas.track()`. Never revenue
/// (revenue enters only through the signed RevenueCat/Stripe webhook, because an
/// app binary can be tampered with). Covers commerce and game funnels; anything
/// not listed uses `.custom` with a name.
/// `CaseIterable` so `BeaconContractTests` can assert the whole taxonomy against
/// Android's, not just the cases someone remembered to list. A case added on one
/// platform and not the other produces two event names for one behaviour, and
/// the funnel that groups both silently splits.
public enum RoasEvent: String, CaseIterable {
    case viewContent = "view_content"
    case addToCart = "add_to_cart"
    case addToWishlist = "add_to_wishlist"
    case beginCheckout = "begin_checkout"
    case search = "search"
    case lead = "lead"
    case signUp = "sign_up"
    case login = "login"
    case startTrial = "start_trial"
    case subscribe = "subscribe"
    case levelStart = "level_start"
    case levelComplete = "level_complete"
    case tutorialComplete = "tutorial_complete"
    case share = "share"
    case custom = "custom"
}
