import XCTest
@testable import RoasSensor

/// Byte-for-byte parity with the backend's `apps/tracking/signing.py` (and with
/// the Android `Signer.kt`, which pins the same vector).
///
/// The expected value was produced by calling `signing.sign()` on the server, so
/// this fails the moment the Swift MAC drifts from the Python one. That drift is
/// the worst possible failure mode for this feature: every beacon from every iOS
/// build would start returning 401, and only for customers who had switched
/// enforcement on — so it would surface as one tenant's installs vanishing, not
/// as anything that looks like a signing bug.
final class SignerParityTests: XCTestCase {

    private let secret = "s3cret-for-tests"
    private let body = Data(#"{"site":"abc","vid":"rs123"}"#.utf8)
    private let timestamp: Int64 = 1_754_300_000

    func testHeaderMatchesTheBackend() {
        XCTAssertEqual(
            Signer.header(secret: secret, body: body, epochSeconds: timestamp),
            "t=1754300000,v1=b33efdc904392639df4d8efd56ea603a802a2e24aa8a00a8ede94711d9dce2c1"
        )
    }

    func testTheTimestampIsInsideTheMacNotBesideIt() {
        // If the timestamp were merely sent alongside the digest, an attacker
        // could replay a captured beacon forever by rewriting `t`. Changing it
        // must change the signature.
        let a = Signer.header(secret: secret, body: body, epochSeconds: timestamp)
        let b = Signer.header(secret: secret, body: body, epochSeconds: timestamp + 1)
        XCTAssertNotEqual(a, b)
    }

    func testTheBodyIsCovered() {
        let tampered = Data(#"{"site":"abc","vid":"rs124"}"#.utf8)
        XCTAssertNotEqual(
            Signer.header(secret: secret, body: body, epochSeconds: timestamp),
            Signer.header(secret: secret, body: tampered, epochSeconds: timestamp)
        )
    }

    func testNoSecretMeansNoHeaderRatherThanAnEmptyOne() {
        // An app that hasn't adopted signing must send NO header. An empty or
        // garbage one would read as INVALID server-side and be refused outright,
        // instead of as MISSING — which is what keeps old builds working.
        XCTAssertNil(Signer.header(secret: nil, body: body, epochSeconds: timestamp))
        XCTAssertNil(Signer.header(secret: "", body: body, epochSeconds: timestamp))
    }
}
