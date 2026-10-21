import Foundation

/// The campaign and routing parameters stored when a user clicked a tracked
/// ad link before installing the app.
///
/// Returned by ``Roas/fetchDeferredDeepLink(_:)`` on first open when the
/// install can be attributed to a specific link.  All string fields are empty
/// when no value was stored on the click.
///
/// - ``deepLinkPath``: The in-app destination configured on the link (e.g.
///   `product?id=42`).  Empty when no path was set.
/// - ``channel``: The ad network (`utm_source`), e.g. `meta`, `google`.
/// - ``campaign``: The campaign name (`utm_campaign`).
/// - ``adName``: The ad / creative name (`utm_content`).
/// - ``medium``: The traffic medium (`utm_medium`), typically `cpc`.
public struct DeferredDeepLink {
    public let deepLinkPath: String
    public let channel: String
    public let campaign: String
    public let adName: String
    public let medium: String
}
