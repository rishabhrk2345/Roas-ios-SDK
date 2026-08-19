import Foundation

/// The property keys ROASSensor understands in `Roas.track`. The Swift twin of
/// `RoasProps.kt`; the Flutter bridge exposes the same constants to Dart, so a
/// team shipping both platforms sends one vocabulary from three languages.
///
/// ## Why a convention, when `properties` is a free-form dictionary
///
/// It stays free-form on purpose — an app should be able to record anything it
/// finds useful without waiting for an SDK release. But reporting can only
/// group by a key it can predict. One app sending `sku`, another `product_id`
/// and a third `item_id` produces three columns that mean the same thing and
/// join to nothing, and the mistake is invisible until someone tries to ask
/// "which product do people add and then not buy?" months of data later.
///
/// So: use these keys where they fit, add your own freely alongside them.
/// Nothing here is enforced — an unrecognised key is stored and returned
/// exactly as sent — but a product funnel can only be built from `productId`.
///
/// ## The one that actually matters
///
/// `productId` should be **the same identifier the purchase will arrive with**
/// — for RevenueCat that is the store product id, for Stripe the price or
/// product id. That is what lets an `addToCart` be lined up against the
/// purchase that did or did not follow it. A friendly name in `productName` is
/// for display only and should never be used as the join key: names get
/// edited, translated, and reused.
///
/// ```swift
/// Roas.track(.addToCart, properties: [
///     RoasProps.productId: "piano_course_annual",
///     RoasProps.productName: "Annual Piano Course",
///     RoasProps.quantity: 1,
///     RoasProps.price: 4999,        // minor units, see below
///     RoasProps.currency: "INR",
/// ])
/// ```
///
/// ## Money in an event is never revenue
///
/// `price` is reporting colour only. Anything a device claims about money is
/// unverifiable — the console is open to anyone — so no ROAS numerator reads
/// it; revenue enters solely through the signed webhook or the marketer's own
/// server. Send it for funnel context, never expecting it to appear in ROAS.
public enum RoasProps {

    /// Store product id. **Must match what the purchase will report** (the
    /// RevenueCat/StoreKit product id), or the funnel cannot line the two up.
    public static let productId = "product_id"

    /// Display name. Never a join key — names change, ids do not.
    public static let productName = "product_name"

    /// Grouping for reports, e.g. "courses".
    public static let category = "category"

    public static let quantity = "quantity"

    /// Minor units (paise/cents), so an integer stays exact. Reporting only —
    /// see the type doc: an event never contributes to revenue.
    public static let price = "price"

    /// ISO-4217, e.g. "INR".
    public static let currency = "currency"

    /// Free-text, for `RoasEvent.search`.
    public static let query = "query"

    /// Where in the app this happened ("home", "product_detail") — the same
    /// event from a carousel and a detail page are different behaviours.
    public static let source = "source"
}
