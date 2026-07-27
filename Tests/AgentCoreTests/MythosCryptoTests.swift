import XCTest
import Foundation
@testable import AgentCore

/// Verifies swift-crypto resolves + links + the exact ops the fleet trust layer needs work
/// cross-platform: HMAC-SHA256 (forge seal), SHA256 (chain hash), Ed25519 (deploy gate).
final class MythosCryptoTests: XCTestCase {

    private func d(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - HMAC-SHA256

    func testHMACDeterministicAndVerifies() {
        let key = d("seal-key"), msg = d("agent E2 done: green")
        let tag = MythosCrypto.hmacSHA256(key: key, message: msg)
        XCTAssertEqual(tag.count, 32)
        XCTAssertEqual(tag, MythosCrypto.hmacSHA256(key: key, message: msg))   // deterministic
        XCTAssertTrue(MythosCrypto.hmacSHA256Valid(key: key, message: msg, tag: tag))
    }

    func testHMACRejectsTamperAndWrongKey() {
        let key = d("k"), msg = d("m")
        let tag = MythosCrypto.hmacSHA256(key: key, message: msg)
        XCTAssertFalse(MythosCrypto.hmacSHA256Valid(key: key, message: d("m-TAMPERED"), tag: tag))
        XCTAssertFalse(MythosCrypto.hmacSHA256Valid(key: d("other-key"), message: msg, tag: tag))
        XCTAssertFalse(MythosCrypto.hmacSHA256Valid(key: key, message: msg, tag: d("not-a-tag")))
    }

    // MARK: - SHA256

    func testSHA256() {
        let h = MythosCrypto.sha256(d("chain-entry-1"))
        XCTAssertEqual(h.count, 32)
        XCTAssertEqual(h, MythosCrypto.sha256(d("chain-entry-1")))           // deterministic
        XCTAssertNotEqual(h, MythosCrypto.sha256(d("chain-entry-2")))        // different input → different hash
    }

    // MARK: - Ed25519

    func testEd25519SignVerifyRoundTrip() throws {
        let kp = MythosCrypto.ed25519GenerateKeyPair()
        let msg = d("promote build cc3f352 to main")
        let sig = try MythosCrypto.ed25519Sign(message: msg, privateKeyRaw: kp.privateRaw)
        XCTAssertTrue(MythosCrypto.ed25519Verify(signature: sig, message: msg, publicKeyRaw: kp.publicRaw))
    }

    func testEd25519RejectsTamperWrongKeyAndGarbage() throws {
        let kp = MythosCrypto.ed25519GenerateKeyPair()
        let other = MythosCrypto.ed25519GenerateKeyPair()
        let msg = d("promote build A")
        let sig = try MythosCrypto.ed25519Sign(message: msg, privateKeyRaw: kp.privateRaw)
        XCTAssertFalse(MythosCrypto.ed25519Verify(signature: sig, message: d("promote build B"), publicKeyRaw: kp.publicRaw))
        XCTAssertFalse(MythosCrypto.ed25519Verify(signature: sig, message: msg, publicKeyRaw: other.publicRaw))
        XCTAssertFalse(MythosCrypto.ed25519Verify(signature: sig, message: msg, publicKeyRaw: d("garbage")))  // fail-closed
    }

    func testTwoKeyPairsDiffer() {
        XCTAssertNotEqual(MythosCrypto.ed25519GenerateKeyPair(), MythosCrypto.ed25519GenerateKeyPair())
    }
}
