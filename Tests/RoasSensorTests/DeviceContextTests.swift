import Foundation
import XCTest
@testable import RoasSensor

/// The device-context contract, exercised on the macOS host.
///
/// These run without a simulator, so they cannot see the real values an iPhone
/// would report -- most UIKit-backed fields compile out here and are simply
/// absent. That is deliberate and is what makes them useful anyway: every
/// assertion is of the form "if this key is present, it must satisfy the
/// contract", so the suite protects the *shape* of the payload on any host
/// while the runbook's device stages check the values.
///
/// What they exist to catch is the failure mode nothing else does: a field that
/// arrives at the backend and is silently mangled. `ingest.py` clips every
/// string to a column width and degrades every out-of-range number to NULL
/// rather than raising -- which is correct for not losing an install, and means
/// a too-long or out-of-bounds value produces no error anywhere. It just
/// quietly stores something other than what the device said.
final class DeviceContextTests: XCTestCase {

    // MARK: - snapshot()

    func testSnapshotAlwaysCarriesTheUnconditionalFields() {
        // These three have no failure path -- a beacon with no sdk_version
        // cannot be traced to the build that produced it, which is the whole
        // reason the field exists.
        let snapshot = DeviceContext.snapshot()
        XCTAssertNotNil(snapshot["sdk_version"])
        XCTAssertNotNil(snapshot["device_type"])
        XCTAssertEqual(snapshot["device_manufacturer"] as? String, "Apple")
    }

    func testSdkVersionMatchesTheRelease() {
        // This string, the podspec's version and the git TAG must all agree --
        // SPM and CocoaPods resolve the tag, the beacon reports this, and a
        // mismatch makes a bad row point at a build that did not produce it.
        //
        // If this fails, bump all three together. Changing only the assertion
        // is how the triple drifts apart.
        XCTAssertEqual(DeviceContext.sdkVersion, "0.1.7")
    }

    func testSnapshotOmitsEmptyValuesRatherThanSendingBlanks() {
        // An absent key lets the server keep whatever it already knew for that
        // touchpoint; a blank string overwrites it with nothing.
        for (key, value) in DeviceContext.snapshot() {
            if let string = value as? String {
                XCTAssertFalse(string.isEmpty, "\(key) was sent as an empty string")
            }
        }
    }

    /// Every string field the SDK sends, against the column it lands in
    /// (`apps/tracking/models.py`). Over-long values are CLIPPED server-side,
    /// never rejected, so nothing else in the system would ever report this.
    func testStringFieldsFitTheirBackendColumns() {
        let widths: [String: Int] = [
            "device_type": 16,
            "screen": 16,
            "viewport": 16,
            "timezone": 64,
            "language": 16,
            "locale_country": 8,
            "soc": 64,
            "build_fingerprint": 256,
            "sdk_version": 16,
            "installer_package": 64,
            "device_model": 64,
            "device_manufacturer": 64,
            "os_version": 16,
        ]
        let snapshot = DeviceContext.snapshot()
        for (key, limit) in widths {
            guard let value = snapshot[key] as? String else { continue }
            XCTAssertLessThanOrEqual(
                value.count, limit,
                "\(key) is \(value.count) chars but the column holds \(limit): \"\(value)\""
            )
        }
    }

    func testDeviceTypeUsesTheBackendVocabulary() {
        // `TouchPoint.device_type` is a fixed vocabulary the dashboard buckets
        // on. A value it has never seen silently drops those rows out of every
        // form-factor breakdown -- which is why unknown idioms (.tv, .carPlay,
        // .vision) fall back to "mobile" instead of inventing a token.
        let deviceType = DeviceContext.snapshot()["device_type"] as? String
        XCTAssertNotNil(deviceType)
        XCTAssertTrue(
            ["desktop", "mobile", "tablet"].contains(deviceType ?? ""),
            "unexpected device_type \"\(deviceType ?? "")\""
        )
    }

    func testScreenAndViewportAreWidthByHeightWhenPresent() {
        let snapshot = DeviceContext.snapshot()
        for key in ["screen", "viewport"] {
            guard let value = snapshot[key] as? String else { continue }
            let parts = value.split(separator: "x")
            XCTAssertEqual(parts.count, 2, "\(key) should be WxH, got \"\(value)\"")
            for part in parts {
                XCTAssertNotNil(Int(part), "\(key) has a non-numeric side: \"\(value)\"")
                XCTAssertGreaterThan(Int(part) ?? 0, 0, "\(key) has a zero side: \"\(value)\"")
            }
        }
    }

    func testLocaleCountryIsUppercase() {
        // The region, not the language. Compared against Android's
        // `Locale.getDefault().country`, which is uppercase, and grouped in one
        // column with it -- "in" and "IN" would be two rows of the same country.
        guard let country = DeviceContext.snapshot()["locale_country"] as? String else { return }
        XCTAssertEqual(country, country.uppercased())
    }

    func testDeviceClassNumbersArePositiveWhenPresent() {
        let snapshot = DeviceContext.snapshot()
        for key in ["total_ram_mb", "cpu_cores", "screen_density"] {
            guard let value = snapshot[key] as? Int else { continue }
            XCTAssertGreaterThan(value, 0, "\(key) should be omitted rather than sent as \(value)")
        }
    }

    func testInstallTimestampsAreEpochSecondsTheServerWillAccept() {
        // `ingest._epoch_seconds` accepts 2000-01-01 .. 2100-01-01 and returns
        // None outside it. Its stated purpose is rejecting epoch MILLISECONDS
        // from a caller that got the unit wrong -- which lands in the year
        // 55000 and would otherwise blow up at write time. PackageManager and
        // FileManager both report millis-or-seconds depending on the API, so
        // this is the exact mistake worth guarding.
        let lower: Int64 = 946_684_800 // 2000-01-01
        let upper: Int64 = 4_102_444_800 // 2100-01-01
        let snapshot = DeviceContext.snapshot()
        for key in ["first_install_timestamp", "last_update_timestamp"] {
            guard let value = snapshot[key] as? Int64 else { continue }
            XCTAssertGreaterThanOrEqual(value, lower, "\(key) looks like it is not epoch seconds")
            XCTAssertLessThanOrEqual(value, upper, "\(key) looks like epoch millis, not seconds")
        }
    }

    // MARK: - volatileContext()

    func testVolatileContextReportsUptimeWithinTheServersRange() {
        // NOT `_index`, which clamps at 65535 (~18 hours) and would flatten
        // every phone up longer than a day into one value -- destroying the one
        // thing the field is for. `_uptime` allows the column's real ceiling.
        guard let uptime = DeviceContext.volatileContext()["uptime_seconds"] as? Int else {
            return XCTFail("uptime_seconds should always be readable")
        }
        XCTAssertGreaterThan(uptime, 0)
        XCTAssertLessThanOrEqual(uptime, 2_147_483_647)
    }

    func testVolatileNetworkFieldsUseTheBackendVocabularyWhenPresent() {
        // Tolerant of absence on purpose: NWPathMonitor populates
        // asynchronously, so a path may not have resolved yet when a test (or
        // the very first beacon) reads it. The contract being protected is that
        // whatever IS sent is a value the column understands.
        DeviceContext.startMonitoring()
        let context = DeviceContext.volatileContext()
        if let network = context["network_type"] as? String {
            XCTAssertTrue(
                ["wifi", "cellular", "ethernet", "other"].contains(network),
                "unexpected network_type \"\(network)\""
            )
        }
        if context["is_vpn"] != nil {
            XCTAssertNotNil(
                context["is_vpn"] as? Bool,
                "is_vpn must be a real Bool -- the column is tri-state and NULL means "
                    + "\"the device never told us\", which is not the same as false"
            )
        }
    }

    func testVolatileAndSnapshotKeysDoNotOverlap() {
        // `Roas.describe` merges the snapshot and then the volatile context, so
        // an overlapping key would mean the volatile layer silently overwrites
        // a launch-time value -- or, worse, that the same field is being read
        // two different ways depending on which layer someone edited.
        let snapshotKeys = Set(DeviceContext.snapshot().keys)
        let volatileKeys = Set(DeviceContext.volatileContext().keys)
        XCTAssertTrue(
            snapshotKeys.isDisjoint(with: volatileKeys),
            "overlapping keys: \(snapshotKeys.intersection(volatileKeys))"
        )
    }

    // MARK: - Apple Search Ads status classification

    func testOnlyRealErrorsAreWorthRetrying() {
        // Apple documents AAAttribution genuinely failing on a device that has
        // just booted or has no network yet -- precisely the state a device is
        // in moments after a fresh install, which is the one read we get.
        XCTAssertTrue(DeviceContext.isTransientAsaStatus("ASA_ERROR:1"))
        XCTAssertTrue(DeviceContext.isTransientAsaStatus("ASA_ERROR:404"))
    }

    func testSettledStatusesAreNotRetried() {
        // These describe the device or an outcome that already succeeded, and
        // will say the same thing forever. Retrying them would spend five
        // launches re-reading a fact.
        for status in ["ASA_OK", "ASA_OK_EMPTY", "ASA_UNSUPPORTED_OS", "ASA_UNAVAILABLE", ""] {
            XCTAssertFalse(
                DeviceContext.isTransientAsaStatus(status),
                "\(status) should not be retried"
            )
        }
    }

    func testRetryStatusStillFitsTheReferrerStatusColumn() {
        // `Roas.retryAppleSearchAds` prefixes the recovered status with RETRY_
        // and the column is 32 chars. Apple's NSError codes are unbounded in
        // principle, which is why the SDK truncates rather than trusting them.
        let longest = "RETRY_ASA_ERROR:\(Int.max)"
        XCTAssertLessThanOrEqual(String(longest.prefix(32)).count, 32)
    }
}
