import Foundation
import XCTest
@testable import RoasSensor

/// The parts of the beacon that are a contract with something outside this
/// SDK -- the backend's parser, or the Android SDK that fills the same columns.
///
/// Both kinds of breakage are silent. A malformed `ts` is not rejected: it
/// degrades to ingest time, so the install still lands, just on the wrong day.
/// A taxonomy that drifts from Android's does not error either -- it produces a
/// second event name for the same behaviour, and the report that groups both
/// quietly splits in half.
final class BeaconContractTests: XCTestCase {

    // MARK: - ts

    /// The exact shape `ingest._occurred_at` feeds to Django's
    /// `parse_datetime`. Anything else falls back to the server clock.
    private let isoPattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"

    func testNowIsoMatchesTheFormatTheServerParses() {
        let stamp = Roas.nowIso(offsetSeconds: 0)
        XCTAssertNotNil(
            stamp.range(of: isoPattern, options: .regularExpression),
            "\"\(stamp)\" is not the UTC ISO-8601 shape the backend parses"
        )
    }

    func testNowIsoRoundTripsToAboutNow() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let parsed = formatter.date(from: Roas.nowIso(offsetSeconds: 0)) else {
            return XCTFail("emitted a timestamp ISO8601DateFormatter cannot parse")
        }
        // Generous, because CI hosts are slow -- the failure this catches is a
        // timezone or epoch mistake measured in hours, not a second of drift.
        XCTAssertEqual(parsed.timeIntervalSinceNow, 0, accuracy: 120)
    }

    func testNowIsoAppliesTheServerClockCorrection() {
        // The whole point of storing the offset. A handset with a badly wrong
        // clock is the same handset most likely to be queueing beacons offline,
        // and the server REJECTS a ts more than five minutes ahead or ninety
        // days old -- so an uncorrected stamp on those devices silently reverts
        // to exactly the ingest-time behaviour this replaced.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard
            let base = formatter.date(from: Roas.nowIso(offsetSeconds: 0)),
            let shifted = formatter.date(from: Roas.nowIso(offsetSeconds: 3600))
        else {
            return XCTFail("emitted a timestamp ISO8601DateFormatter cannot parse")
        }
        XCTAssertEqual(shifted.timeIntervalSince(base), 3600, accuracy: 120)
    }

    func testNowIsoHandlesANegativeOffset() {
        // A device ahead of the server is just as common as one behind it, and
        // Int64 arithmetic on a negative offset is the easy thing to get wrong.
        let stamp = Roas.nowIso(offsetSeconds: -7200)
        XCTAssertNotNil(stamp.range(of: isoPattern, options: .regularExpression))
    }

    func testNowIsoIsGregorianRegardlessOfDeviceCalendar() {
        // Pinned to en_US_POSIX for the same reason Transport pins it when
        // parsing the Date header: a device set to a Buddhist or Japanese
        // calendar would otherwise format a year (2569, or 令和7) that the
        // server cannot parse -- and the failure is invisible, because an
        // unparseable ts silently becomes ingest time.
        let year = Int(Roas.nowIso(offsetSeconds: 0).prefix(4))
        XCTAssertNotNil(year)
        XCTAssertGreaterThanOrEqual(year ?? 0, 2020)
        XCTAssertLessThan(year ?? 0, 2100)
    }

    // MARK: - Taxonomy parity with Android

    func testEventTaxonomyMatchesAndroid() {
        // Mirrors `RoasEvent.kt`. One dashboard groups both platforms, so an
        // event key that exists on one and not the other is a funnel step that
        // appears to have no iOS users -- or no Android ones.
        let android: Set<String> = [
            "view_content",
            "add_to_cart",
            "add_to_wishlist",
            "begin_checkout",
            "search",
            "lead",
            "sign_up",
            "login",
            "start_trial",
            "subscribe",
            "level_start",
            "level_complete",
            "tutorial_complete",
            "share",
            "custom",
        ]
        XCTAssertEqual(Set(RoasEvent.allCases.map(\.rawValue)), android)
    }

    func testPropertyKeysMatchAndroid() {
        // Mirrors `RoasProps.kt` and the Dart constants in roas_flutter. The
        // keys stay free-form for callers, but reporting can only group by one
        // it can predict: one app sending `sku`, another `product_id` and a
        // third `item_id` produces three columns that mean the same thing and
        // join to nothing.
        XCTAssertEqual(RoasProps.productId, "product_id")
        XCTAssertEqual(RoasProps.productName, "product_name")
        XCTAssertEqual(RoasProps.category, "category")
        XCTAssertEqual(RoasProps.quantity, "quantity")
        XCTAssertEqual(RoasProps.price, "price")
        XCTAssertEqual(RoasProps.currency, "currency")
        XCTAssertEqual(RoasProps.query, "query")
        XCTAssertEqual(RoasProps.source, "source")
    }

    // MARK: - Location

    func testLocationIsAbsentOrCoarseButNeverPrecise() {
        // The SDK declares no location permission and never prompts, so on the
        // macOS host and in a fresh simulator this returns nil -- the expected
        // path, and the one that must not crash or trigger a prompt.
        //
        // Written to tolerate a value rather than assert nil, because a test
        // host that HAS been granted location (a device where the runner app
        // was authorized) is a legitimate environment and must not turn this
        // red. What matters either way is the guarantee that survives: the
        // value leaves the device rounded to ~1.1km, so the precise coordinate
        // never travels at all.
        guard let (latitude, longitude) = DeviceLocation.read() else { return }
        XCTAssertEqual(latitude, (latitude * 100).rounded() / 100, accuracy: 0.000_001)
        XCTAssertEqual(longitude, (longitude * 100).rounded() / 100, accuracy: 0.000_001)
        // The bounds `ingest._float_or_none` enforces -- outside them the
        // server stores NULL, so sending anything else is sending nothing.
        XCTAssertTrue((-90.0...90.0).contains(latitude))
        XCTAssertTrue((-180.0...180.0).contains(longitude))
    }
}
