import XCTest
@testable import RoasSensor

/// `PastedClick`: reading the website's click code back off the clipboard.
/// Exercised on the macOS host — parsing and the retry rule are pure; the
/// UIPasteboard read they gate is not.
final class PastedClickTests: XCTestCase {

    func testTheCodeIsReadFromTheCopiedLink() {
        let link = "https://core.roassensor.com/api/tracking/c/sb-abc?rs_banner=7&rs_pb=AbCdEf0123456789_-xy"
        XCTAssertEqual(PastedClick.code(in: link), "AbCdEf0123456789_-xy")
    }

    func testTheCodeMayBeFirstOrFollowedByMoreParams() {
        XCTAssertEqual(PastedClick.code(in: "https://x.test/c/a?rs_pb=AbCdEf0123456789xy&utm=1"), "AbCdEf0123456789xy")
        XCTAssertEqual(PastedClick.code(in: "see https://x.test/c/a?rs_pb=AbCdEf0123456789xy now"), "AbCdEf0123456789xy")
    }

    func testAnythingElseIsNotACode() {
        XCTAssertNil(PastedClick.code(in: nil))
        XCTAssertNil(PastedClick.code(in: ""))
        XCTAssertNil(PastedClick.code(in: "https://example.com/?q=hello"))
        XCTAssertNil(PastedClick.code(in: "https://x.test/c/a?rs_pb=short"), "fewer than 16 characters")
        XCTAssertNil(PastedClick.code(in: "https://x.test/c/a?rs_pb=has spaces in it 1234"))
        XCTAssertNil(PastedClick.code(in: "https://x.test/c/a?xrs_pb=AbCdEf0123456789xy"), "only the exact parameter")
        XCTAssertNil(PastedClick.code(in: String(repeating: "a", count: 5000)), "a huge paste is not parsed")
    }

    func testOnlyATemporaryAnswerIsRetried() {
        XCTAssertTrue(PastedClick.isFinal(matched: true, reason: nil))
        XCTAssertFalse(PastedClick.isFinal(matched: false, reason: nil), "a network failure tries again later")
        XCTAssertFalse(PastedClick.isFinal(matched: false, reason: "no_install"), "the install beacon has not landed yet")
        XCTAssertTrue(PastedClick.isFinal(matched: false, reason: "claimed"))
        XCTAssertTrue(PastedClick.isFinal(matched: false, reason: "expired"))
        XCTAssertTrue(PastedClick.isFinal(matched: false, reason: "already_attributed"))
    }

    func testAskingStopsSevenDaysAfterInstall() {
        let installed: TimeInterval = 1_000_000
        XCTAssertFalse(PastedClick.tooLate(installAnchor: installed, now: installed + 6 * 24 * 3600))
        XCTAssertTrue(PastedClick.tooLate(installAnchor: installed, now: installed + 8 * 24 * 3600))
        XCTAssertFalse(PastedClick.tooLate(installAnchor: 0, now: installed), "no anchor yet is not too late")
    }
}
