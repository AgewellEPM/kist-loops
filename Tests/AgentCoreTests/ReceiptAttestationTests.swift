import XCTest
@testable import AgentCore

/// The Ed25519 ISSUER-SIGNATURE tier — the cross-org trust upgrade. Pins the unforgeability guarantee: a
/// `.valid` verdict exists only when a real signature checks out against a PINNED public key, bound to THIS
/// change's digest and a `pass` verdict. Everything else fails closed.
final class ReceiptAttestationTests: XCTestCase {
    private let digest = "abc123deadbeef"
    private func approval(digest: String, verdict: String = "pass", keyID: String = "issuer1") -> ReceiptApproval {
        ReceiptApproval(diffDigest: digest, verdict: verdict, issuerKeyID: keyID,
                        nonce: "n1", approvedAtEpoch: 1_700_000_000, note: "test")
    }
    private func pair() -> MythosCrypto.Ed25519KeyPair { MythosCrypto.ed25519GenerateKeyPair() }
    private func verifier(_ keyID: String, _ pub: Data) -> ReceiptAttestationVerifier {
        ReceiptAttestationVerifier(trusted: [.init(keyID: keyID, publicKeyB64: pub.base64EncodedString())])
    }

    func testValidSignatureFromPinnedIssuerVerifies() throws {
        let kp = pair()
        let attested = try AttestedReceipt.make(approval: approval(digest: digest), privateKeyRaw: kp.privateRaw)
        if case .valid(let v) = verifier("issuer1", kp.publicRaw).verify(attested, diffDigest: digest) {
            XCTAssertEqual(v.keyID, "issuer1")
        } else { XCTFail("a valid signature from a pinned issuer must verify") }
    }

    func testUnpinnedIssuerIsUnknownKey() throws {
        let kp = pair()
        let attested = try AttestedReceipt.make(approval: approval(digest: digest), privateKeyRaw: kp.privateRaw)
        // Verifier pins a DIFFERENT issuer id → unknownKey (fail closed).
        XCTAssertEqual(verifier("other", kp.publicRaw).verify(attested, diffDigest: digest), .unknownKey)
        // And an EMPTY store is unknownKey for everything.
        XCTAssertTrue(ReceiptAttestationVerifier(trusted: []).isEmpty)
        XCTAssertEqual(ReceiptAttestationVerifier(trusted: []).verify(attested, diffDigest: digest), .unknownKey)
    }

    func testWrongKeyIsBadSignature() throws {
        let signer = pair(), attacker = pair()
        let attested = try AttestedReceipt.make(approval: approval(digest: digest), privateKeyRaw: signer.privateRaw)
        // Pin the attacker's pubkey under the issuer id the approval names → signature won't verify.
        XCTAssertEqual(verifier("issuer1", attacker.publicRaw).verify(attested, diffDigest: digest), .badSignature)
    }

    func testSignatureForDifferentDigestIsRejected() throws {
        let kp = pair()
        let attested = try AttestedReceipt.make(approval: approval(digest: digest), privateKeyRaw: kp.privateRaw)
        XCTAssertEqual(verifier("issuer1", kp.publicRaw).verify(attested, diffDigest: "OTHER-CHANGE"), .digestMismatch)
    }

    func testNonPassVerdictIsRejected() throws {
        let kp = pair()
        let attested = try AttestedReceipt.make(approval: approval(digest: digest, verdict: "fail"),
                                                privateKeyRaw: kp.privateRaw)
        XCTAssertEqual(verifier("issuer1", kp.publicRaw).verify(attested, diffDigest: digest), .notPass)
    }

    func testTamperedApprovalBreaksSignature() throws {
        let kp = pair()
        var attested = try AttestedReceipt.make(approval: approval(digest: digest), privateKeyRaw: kp.privateRaw)
        // Swap the approval to a different change while keeping the old signature → badSignature (payload changed).
        attested = AttestedReceipt(approval: approval(digest: "SWAPPED"), signatureB64: attested.signatureB64)
        let v = verifier("issuer1", kp.publicRaw).verify(attested, diffDigest: "SWAPPED")
        XCTAssertEqual(v, .badSignature, "editing the approval must invalidate the detached signature")
    }

    func testMalformedSignatureIsRejected() throws {
        let kp = pair()
        let attested = AttestedReceipt(approval: approval(digest: digest), signatureB64: "!!!not base64!!!")
        XCTAssertEqual(verifier("issuer1", kp.publicRaw).verify(attested, diffDigest: digest), .malformed)
    }

    /// Codex gate7 LOW: non-canonical base64 (extra padding) or a wrong-length signature must be rejected — no
    /// covert byte channel in `signatureB64`.
    func testNonCanonicalSignatureEncodingIsRejected() throws {
        let kp = pair()
        let good = try AttestedReceipt.make(approval: approval(digest: digest), privateKeyRaw: kp.privateRaw)
        // Append stray padding: decodes to the same bytes, but is not the canonical encoding.
        let padded = AttestedReceipt(approval: good.approval, signatureB64: good.signatureB64 + "==")
        XCTAssertEqual(verifier("issuer1", kp.publicRaw).verify(padded, diffDigest: digest), .malformed)
        // A 32-byte (wrong length) blob base64'd is not a 64-byte Ed25519 signature.
        let shortSig = AttestedReceipt(approval: good.approval, signatureB64: Data(count: 32).base64EncodedString())
        XCTAssertEqual(verifier("issuer1", kp.publicRaw).verify(shortSig, diffDigest: digest), .malformed)
    }

    func testKeyStoreRoundTripAndSecurity() throws {
        let home = NSTemporaryDirectory() + "kist_issuer_\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/.config/kist/receipt-issuers.json"
        let store = ReceiptIssuerKeyStore().pinning(keyID: "acme", publicKeyB64: "AAAA")
        try store.save(storePath: path)
        // Persisted 0600.
        let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let loaded = ReceiptIssuerKeyStore.load(storePath: path)
        XCTAssertEqual(loaded.publicKey(for: "acme"), "AAAA")
        XCTAssertFalse(loaded.isEmpty)
        XCTAssertTrue(loaded.unpinning(keyID: "acme").isEmpty)
        // Absent store ⇒ empty (fail-safe), never a crash.
        XCTAssertTrue(ReceiptIssuerKeyStore.load(storePath: home + "/nope.json").isEmpty)
    }

    /// Revocation: a revoked keyID is excluded from the verifier's trusted set, is not re-pinnable, and persists
    /// across save/load. Un-revoke lifts it. This is the rotation/compromise primitive.
    func testRevocationExcludesKeyAndBlocksRepin() throws {
        let home = NSTemporaryDirectory() + "kist_rev_\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/.config/kist/receipt-issuers.json"
        var store = ReceiptIssuerKeyStore().pinning(keyID: "acme", publicKeyB64: "AAAA")
        XCTAssertEqual(store.trustedKeys().count, 1)
        store = store.revoking(keyID: "acme")
        XCTAssertTrue(store.isRevoked("acme"))
        XCTAssertTrue(store.trustedKeys().isEmpty, "a revoked key must never reach the verifier")
        // Not re-pinnable while revoked.
        store = store.pinning(keyID: "acme", publicKeyB64: "BBBB")
        XCTAssertNil(store.publicKey(for: "acme"), "a revoked key can't be silently re-pinned")
        try store.save(storePath: path)
        // Revocation persists across load.
        let reloaded = ReceiptIssuerKeyStore.load(storePath: path)
        XCTAssertTrue(reloaded.isRevoked("acme"))
        // Un-revoke lifts it, then it can be pinned again.
        let restored = reloaded.unrevoking(keyID: "acme").pinning(keyID: "acme", publicKeyB64: "CCCC")
        XCTAssertEqual(restored.publicKey(for: "acme"), "CCCC")
        XCTAssertFalse(restored.isRevoked("acme"))
    }

    /// Codex gate8 MED: revocation burns the KEY MATERIAL (fingerprint), not just the keyID string — so the same
    /// public key can't be re-pinned under a new alias while it's revoked.
    func testRevocationBurnsKeyMaterialAcrossAliases() {
        let kp = MythosCrypto.ed25519GenerateKeyPair()
        let pub = kp.publicRaw.base64EncodedString()
        var store = ReceiptIssuerKeyStore().pinning(keyID: "acme", publicKeyB64: pub)
        store = store.revoking(keyID: "acme")
        XCTAssertTrue(store.isMaterialRevoked(publicKeyB64: pub))
        // Re-pinning the SAME bytes under a DIFFERENT alias is refused.
        store = store.pinning(keyID: "acme2", publicKeyB64: pub)
        XCTAssertNil(store.publicKey(for: "acme2"), "burned key material must not be re-pinnable under a new alias")
        XCTAssertTrue(store.trustedKeys().isEmpty)
        // A hand-built store listing the burned material under a fresh alias still drops it at init.
        let smuggled = ReceiptIssuerKeyStore(keys: ["acme2": pub],
                                             revoked: ["acme": ReceiptIssuerKeyStore.fingerprint(pub)!])
        XCTAssertTrue(smuggled.trustedKeys().isEmpty, "init must filter a burned fingerprint under any alias")
        // Un-revoke lifts the burn → the material can be pinned again.
        let ok = store.unrevoking(keyID: "acme").pinning(keyID: "acme2", publicKeyB64: pub)
        XCTAssertEqual(ok.publicKey(for: "acme2"), pub)
    }

    /// v1 store (no `revoked` field) loads cleanly as v2 with an empty revocation set.
    func testV1StoreLoadsWithoutRevokedField() throws {
        let home = NSTemporaryDirectory() + "kist_v1_\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/.config/kist/receipt-issuers.json"
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(#"{"version":1,"issuers":{"acme":"AAAA"}}"#.utf8).write(to: URL(fileURLWithPath: path))
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let loaded = ReceiptIssuerKeyStore.load(storePath: path)
        XCTAssertEqual(loaded.publicKey(for: "acme"), "AAAA")
        XCTAssertTrue(loaded.revokedKeyIDs.isEmpty)
    }
}
