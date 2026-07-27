import XCTest
@testable import AgentCore

/// SIGNED TRUST BUNDLE: an org pins ONE root and distributes/rotates its issuer set via a root-signed bundle.
/// Pins the unforgeability + fail-closed invariants: a bundle is trusted only when its root signature checks out
/// against a PINNED root, and its effective issuer set honors the bundle's own revocations.
final class ReceiptTrustBundleTests: XCTestCase {
    private func bundle(root: String, issuers: [String: String], revoked: [String: String] = [:]) -> TrustBundle {
        TrustBundle(issuers: issuers, revoked: revoked, rootKeyID: root, issuedAtEpoch: 1_700_000_000)
    }
    private func verifier(_ keyID: String, _ pub: Data) -> TrustBundleVerifier {
        TrustBundleVerifier(trustedRoots: [.init(keyID: keyID, publicKeyB64: pub.base64EncodedString())])
    }

    func testValidBundleFromPinnedRootYieldsIssuers() throws {
        let root = MythosCrypto.ed25519GenerateKeyPair()
        let signed = try SignedTrustBundle.make(bundle: bundle(root: "r1", issuers: ["alice": "AAAA", "bob": "BBBB"]),
                                                rootPrivateKeyRaw: root.privateRaw)
        guard case .valid(let vb) = verifier("r1", root.publicRaw).verify(signed) else {
            return XCTFail("a bundle signed by a pinned root must verify")
        }
        XCTAssertEqual(Set(vb.trustedIssuerKeys().map { $0.keyID }), ["alice", "bob"])
    }

    func testUnknownRootFailsClosed() throws {
        let root = MythosCrypto.ed25519GenerateKeyPair()
        let signed = try SignedTrustBundle.make(bundle: bundle(root: "r1", issuers: ["alice": "AAAA"]),
                                                rootPrivateKeyRaw: root.privateRaw)
        XCTAssertEqual(verifier("other", root.publicRaw).verify(signed), .unknownRoot)
        XCTAssertTrue(TrustBundleVerifier(trustedRoots: []).isEmpty)
        XCTAssertEqual(TrustBundleVerifier(trustedRoots: []).verify(signed), .unknownRoot)
    }

    func testTamperedBundleBreaksRootSignature() throws {
        let root = MythosCrypto.ed25519GenerateKeyPair()
        var signed = try SignedTrustBundle.make(bundle: bundle(root: "r1", issuers: ["alice": "AAAA"]),
                                                rootPrivateKeyRaw: root.privateRaw)
        // Add an evil issuer while keeping the old signature → payload changed → badSignature.
        signed = SignedTrustBundle(bundle: bundle(root: "r1", issuers: ["alice": "AAAA", "evil": "ZZZZ"]),
                                   signatureB64: signed.signatureB64)
        XCTAssertEqual(verifier("r1", root.publicRaw).verify(signed), .badSignature)
    }

    func testWrongRootKeyIsBadSignature() throws {
        let signer = MythosCrypto.ed25519GenerateKeyPair(), attacker = MythosCrypto.ed25519GenerateKeyPair()
        let signed = try SignedTrustBundle.make(bundle: bundle(root: "r1", issuers: ["alice": "AAAA"]),
                                                rootPrivateKeyRaw: signer.privateRaw)
        XCTAssertEqual(verifier("r1", attacker.publicRaw).verify(signed), .badSignature)
    }

    func testBundleRevocationDropsIssuerFromEffectiveSet() throws {
        let root = MythosCrypto.ed25519GenerateKeyPair()
        let alicePub = MythosCrypto.ed25519GenerateKeyPair().publicRaw.base64EncodedString()
        let fp = ReceiptIssuerKeyStore.fingerprint(alicePub)!
        // Bundle lists alice as an issuer AND revokes her material → she must not appear in the effective set.
        let signed = try SignedTrustBundle.make(
            bundle: bundle(root: "r1", issuers: ["alice": alicePub, "bob": "BBBB"], revoked: ["alice": fp]),
            rootPrivateKeyRaw: root.privateRaw)
        guard case .valid(let vb) = verifier("r1", root.publicRaw).verify(signed) else { return XCTFail() }
        XCTAssertEqual(vb.trustedIssuerKeys().map { $0.keyID }, ["bob"], "a bundle-revoked issuer is dropped")
    }

    func testNonCanonicalBundleSignatureRejected() throws {
        let root = MythosCrypto.ed25519GenerateKeyPair()
        let signed = try SignedTrustBundle.make(bundle: bundle(root: "r1", issuers: ["alice": "AAAA"]),
                                                rootPrivateKeyRaw: root.privateRaw)
        let padded = SignedTrustBundle(bundle: signed.bundle, signatureB64: signed.signatureB64 + "==")
        XCTAssertEqual(verifier("r1", root.publicRaw).verify(padded), .malformed)
    }

    /// A bundle must NOT re-trust key MATERIAL that's locally revoked (burned) — even if the bundle lists it as a
    /// plain issuer with no revocation entry. The init fingerprint filter drops it under any alias.
    func testBundleCannotReTrustLocallyBurnedMaterial() {
        let alicePub = MythosCrypto.ed25519GenerateKeyPair().publicRaw.base64EncodedString()
        let local = ReceiptIssuerKeyStore().pinning(keyID: "alice", publicKeyB64: alicePub).revoking(keyID: "alice")
        let merged = local.addingBundle(issuers: ["alice": alicePub, "bob": "BBBB"], revoked: [:])
        let trusted = Set(merged.trustedKeys().map { $0.keyID })
        XCTAssertFalse(trusted.contains("alice"), "a bundle must not re-trust locally-burned material")
        XCTAssertTrue(trusted.contains("bob"), "an unrelated bundle issuer is still added")
        // Also: the same material under a DIFFERENT alias in the bundle is still dropped.
        let aliased = local.addingBundle(issuers: ["alice2": alicePub], revoked: [:])
        XCTAssertFalse(aliased.trustedKeys().contains { $0.keyID == "alice2" }, "burned material blocked under an alias too")
    }

    func testRootStoreRoundTripAndMerge() throws {
        let home = NSTemporaryDirectory() + "kist_root_\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/.config/kist/receipt-roots.json"
        try ReceiptRootKeyStore().pinning(keyID: "r1", publicKeyB64: "AAAA").save(storePath: path)
        XCTAssertEqual((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber, 0o600)
        XCTAssertEqual(ReceiptRootKeyStore.load(storePath: path).allPinned["r1"], "AAAA")
        // Local revocation WINS over a bundle that lists the same issuer.
        let local = ReceiptIssuerKeyStore().pinning(keyID: "alice", publicKeyB64: "AAAA").revoking(keyID: "alice")
        let merged = local.addingBundle(issuers: ["alice": "AAAA", "bob": "BBBB"], revoked: [:])
        XCTAssertNil(merged.publicKey(for: "alice"), "a locally-revoked issuer stays revoked even if a bundle lists it")
        XCTAssertEqual(merged.publicKey(for: "bob"), "BBBB")
    }
}
