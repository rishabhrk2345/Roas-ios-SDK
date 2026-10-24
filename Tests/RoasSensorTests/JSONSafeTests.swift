import Foundation
import XCTest
@testable import RoasSensor

/// `Roas.track(properties:)` takes `[String: Any]`, and
/// `JSONSerialization.data(withJSONObject:)` raises an Objective-C exception
/// (which `try?` cannot catch) for a Date, a URL or a NaN, so one such value
/// crashed the host app. Each test feeds `JSONSafe` what a customer could pass
/// and then serialises the result for real: an invalid value left in would
/// crash this test process, which is the regression.
final class JSONSafeTests: XCTestCase {

    /// Serialise for real, after asserting the guard that protects it.
    private func roundTrip(_ dictionary: [String: Any]) throws -> [String: Any] {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(dictionary), "not valid JSON: \(dictionary)")
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testValuesThatUsedToCrashBecomeJSON() throws {
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        let url = URL(string: "https://example.com/p?q=1")!
        let raw: [String: Any] = [
            "at": date,
            "link": url,
            "nan": Double.nan,
            "inf": Double.infinity,
            "negInf": -Float.infinity,
        ]
        XCTAssertFalse(JSONSerialization.isValidJSONObject(raw), "the input really is the crashing kind")

        let out = try roundTrip(JSONSafe.object(raw))
        XCTAssertEqual(out["at"] as? String, "2026-10-14T17:46:40Z")
        XCTAssertEqual(out["link"] as? String, "https://example.com/p?q=1")
        XCTAssertNil(out["nan"], "NaN has no JSON form and is dropped, not invented")
        XCTAssertNil(out["inf"])
        XCTAssertNil(out["negInf"])
    }

    func testOrdinaryValuesPassThroughUnchanged() throws {
        let out = try roundTrip(JSONSafe.object([
            "sku": "ABC",
            "qty": 3,
            "price": 49.99,
            "gift": true,
            "none": NSNull(),
        ]))
        XCTAssertEqual(out["sku"] as? String, "ABC")
        XCTAssertEqual(out["qty"] as? Int, 3)
        XCTAssertEqual(out["price"] as? Double, 49.99)
        XCTAssertEqual(out["gift"] as? Bool, true)
        XCTAssertTrue(out["none"] is NSNull)
    }

    func testBoolStaysABoolean() throws {
        // Bool bridges to NSNumber; it must still be written as `true`, not 1.
        let data = try JSONSerialization.data(withJSONObject: JSONSafe.object(["gift": true]))
        XCTAssertEqual(String(data: data, encoding: .utf8), "{\"gift\":true}")
    }

    func testNestedContainersAreCleanedToo() throws {
        let out = try roundTrip(JSONSafe.object([
            "items": [["sku": "A", "added": Date(timeIntervalSince1970: 0)] as [String: Any], Double.nan, "x"] as [Any],
            "meta": ["ratio": Double.nan, "page": URL(string: "https://example.com")!, 7: "seven"] as [AnyHashable: Any],
        ]))
        let items = try XCTUnwrap(out["items"] as? [Any])
        XCTAssertEqual(items.count, 2, "the NaN element is dropped")
        XCTAssertEqual((items[0] as? [String: Any])?["added"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual(items[1] as? String, "x")
        let meta = try XCTUnwrap(out["meta"] as? [String: Any])
        XCTAssertNil(meta["ratio"])
        XCTAssertEqual(meta["page"] as? String, "https://example.com")
        XCTAssertEqual(meta["7"] as? String, "seven", "a non-string key becomes its description")
    }

    private struct Plan: CustomStringConvertible {
        let tier: String
        var description: String { "Plan(\(tier))" }
    }

    private enum Source { case onboarding }

    func testAnythingElseBecomesItsDescription() throws {
        let missing: String? = nil
        let present: Int? = 5
        let out = try roundTrip(JSONSafe.object([
            "plan": Plan(tier: "pro"),
            "source": Source.onboarding,
            "missing": missing as Any,
            "present": present as Any,
        ]))
        XCTAssertEqual(out["plan"] as? String, "Plan(pro)")
        XCTAssertEqual(out["source"] as? String, "onboarding")
        XCTAssertNil(out["missing"], "a nil Optional is left out")
        XCTAssertEqual(out["present"] as? Int, 5, "a non-nil Optional is unwrapped")
    }

    func testASelfContainingArrayDoesNotRecurseForever() throws {
        let loop = NSMutableArray()
        loop.add("a")
        loop.add(loop)
        _ = try roundTrip(JSONSafe.object(["loop": loop]))
    }
}
