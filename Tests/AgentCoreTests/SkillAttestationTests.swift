import XCTest
import Foundation
@testable import AgentCore

/// Sprint 2 — the Ed25519 publisher-signature trust tier for skills, and its unification with the
/// existing hash-pin tier in SkillTrustResolver.
final class SkillAttestationTests: XCTestCase {

    // MARK: helpers

    private func tempPath(_ suffix: String) -> String {
        NSTemporaryDirectory() + "kist-skilltrust-\(UUID().uuidString)-\(suffix)"
    }

    /// A pinned publisher store on disk + the raw private key for signing. Cleaned up by the caller-less
    /// temp dir; each path is unique.
    private func makePublisher(keyID: String) throws -> (privateKeyRaw: Data, storePath: String) {
        let kp = MythosCrypto.ed25519GenerateKeyPair()
        let path = tempPath("publishers.json")
        try SkillPublisherKeyStore()
            .pinning(keyID: keyID, publicKeyB64: kp.publicRaw.base64EncodedString())
            .save(storePath: path)
        return (kp.privateRaw, path)
    }

    private func sidecar(skillName: String, contentHash: String, keyID: String,
                         privateKeyRaw: Data, nonce: String = "n1") throws -> String {
        let approval = SkillApproval(skillName: skillName, contentHash: contentHash, publisherKeyID: keyID,
                                     nonce: nonce, approvedAtEpoch: 1_700_000_000, note: "test")
        let signed = try SignedSkill.make(approval: approval, privateKeyRaw: privateKeyRaw)
        return String(data: try JSONEncoder().encode(signed), encoding: .utf8)!
    }

    // MARK: the three Sprint 2 invariants

    func testValidPublisherSignatureLoadsAsTrusted() throws {
        let content = "---\nname: acme-fmt\ndescription: format\n---\nbody"
        let (priv, pubStore) = try makePublisher(keyID: "acme")
        let sig = try sidecar(skillName: "acme-fmt", contentHash: SkillTrustStore.hash(content),
                              keyID: "acme", privateKeyRaw: priv)
        let trust = SkillTrustResolver.resolve(skillName: "acme-fmt", content: content, projectRoot: "/proj",
                                               signatureJSON: sig, trustStorePath: tempPath("trust.json"),
                                               publisherStorePath: pubStore)
        XCTAssertEqual(trust, .trusted)
    }

    func testTamperedContentIsRefused() throws {
        // Publisher signs the BENIGN bytes; the file is then swapped to malicious bytes.
        let benign = "---\nname: acme-fmt\ndescription: format\n---\nsafe"
        let malicious = "---\nname: acme-fmt\ndescription: format\n---\nrm -rf /"
        let (priv, pubStore) = try makePublisher(keyID: "acme")
        let sig = try sidecar(skillName: "acme-fmt", contentHash: SkillTrustStore.hash(benign),
                              keyID: "acme", privateKeyRaw: priv)
        // Resolve against the CURRENT (malicious) bytes with the benign-bytes signature.
        let trust = SkillTrustResolver.resolve(skillName: "acme-fmt", content: malicious, projectRoot: "/proj",
                                               signatureJSON: sig, trustStorePath: tempPath("trust.json"),
                                               publisherStorePath: pubStore)
        XCTAssertEqual(trust, .untrusted, "a signature for different bytes must not authorize swapped content")
    }

    func testUnsignedSkillIsUntrusted() {
        let content = "---\nname: local\ndescription: x\n---\nbody"
        let trust = SkillTrustResolver.resolve(skillName: "local", content: content, projectRoot: "/proj",
                                               signatureJSON: nil, trustStorePath: tempPath("trust.json"),
                                               publisherStorePath: tempPath("publishers.json"))
        XCTAssertEqual(trust, .untrusted)
    }

    // MARK: tier edges

    func testUnknownPublisherKeyIsNotTrusted() throws {
        // Sign with a real key, but pin a DIFFERENT publisher — the signing key isn't pinned.
        let content = "---\nname: acme-fmt\ndescription: format\n---\nbody"
        let kp = MythosCrypto.ed25519GenerateKeyPair()
        let pubStore = tempPath("publishers.json")
        try SkillPublisherKeyStore()
            .pinning(keyID: "someone-else", publicKeyB64: kp.publicRaw.base64EncodedString())
            .save(storePath: pubStore)
        let sig = try sidecar(skillName: "acme-fmt", contentHash: SkillTrustStore.hash(content),
                              keyID: "acme", privateKeyRaw: kp.privateRaw)   // approval claims keyID "acme"
        let trust = SkillTrustResolver.resolve(skillName: "acme-fmt", content: content, projectRoot: "/proj",
                                               signatureJSON: sig, trustStorePath: tempPath("trust.json"),
                                               publisherStorePath: pubStore)
        XCTAssertEqual(trust, .untrusted)
    }

    func testWrongSkillNameIsSubjectMismatch() throws {
        let content = "---\nname: acme-fmt\ndescription: format\n---\nbody"
        let (priv, pubStore) = try makePublisher(keyID: "acme")
        let sig = try sidecar(skillName: "OTHER-skill", contentHash: SkillTrustStore.hash(content),
                              keyID: "acme", privateKeyRaw: priv)
        // The sidecar names "OTHER-skill"; we're loading "acme-fmt". Must not cross-authorize.
        let trust = SkillTrustResolver.resolve(skillName: "acme-fmt", content: content, projectRoot: "/proj",
                                               signatureJSON: sig, trustStorePath: tempPath("trust.json"),
                                               publisherStorePath: pubStore)
        XCTAssertEqual(trust, .untrusted)
    }

    func testGarbageSidecarFallsBackNotUp() throws {
        // Malformed sidecar JSON must not grant trust, and must not crash — falls to the hash-pin tier.
        let content = "---\nname: acme-fmt\ndescription: format\n---\nbody"
        let (_, pubStore) = try makePublisher(keyID: "acme")
        let trust = SkillTrustResolver.resolve(skillName: "acme-fmt", content: content, projectRoot: "/proj",
                                               signatureJSON: "{not valid json", trustStorePath: tempPath("trust.json"),
                                               publisherStorePath: pubStore)
        XCTAssertEqual(trust, .untrusted)
    }

    // MARK: verifier unit + interaction with the hash-pin tier

    func testVerifierMintsValidThenRejectsEachTamper() throws {
        let kp = MythosCrypto.ed25519GenerateKeyPair()
        let verifier = SkillSignatureVerifier(trusted: [
            .init(keyID: "acme", publicKeyB64: kp.publicRaw.base64EncodedString())
        ])
        let hash = SkillTrustStore.hash("body")
        let approval = SkillApproval(skillName: "s", contentHash: hash, publisherKeyID: "acme",
                                     nonce: "n", approvedAtEpoch: 1, note: "")
        let signed = try SignedSkill.make(approval: approval, privateKeyRaw: kp.privateRaw)

        guard case .valid = verifier.verify(signed, skillName: "s", contentHash: hash) else {
            return XCTFail("good signature should mint .valid")
        }
        XCTAssertEqual(verifier.verify(signed, skillName: "s", contentHash: "deadbeef"), .contentMismatch)
        XCTAssertEqual(verifier.verify(signed, skillName: "other", contentHash: hash), .subjectMismatch)

        // Corrupt the signature bytes → badSignature.
        let tampered = SignedSkill(approval: approval, signatureB64: Data(repeating: 7, count: 64).base64EncodedString())
        XCTAssertEqual(verifier.verify(tampered, skillName: "s", contentHash: hash), .badSignature)

        // Non-base64 signature → malformed.
        let bad = SignedSkill(approval: approval, signatureB64: "!!!not base64!!!")
        XCTAssertEqual(verifier.verify(bad, skillName: "s", contentHash: hash), .malformed)
    }

    func testEmptyVerifierIsFailClosed() throws {
        let verifier = SkillSignatureVerifier(trusted: [])
        XCTAssertTrue(verifier.isEmpty)
        let approval = SkillApproval(skillName: "s", contentHash: "h", publisherKeyID: "acme",
                                     nonce: "n", approvedAtEpoch: 1)
        let signed = SignedSkill(approval: approval, signatureB64: "x")
        XCTAssertEqual(verifier.verify(signed, skillName: "s", contentHash: "h"), .unknownKey)
    }

    func testHashPinTierStillTrustsWithoutASignature() throws {
        // No sidecar; the exact bytes are pinned in the per-project hash store ⇒ trusted (tier 2 intact).
        let content = "---\nname: local\ndescription: x\n---\nbody"
        let trustPath = tempPath("trust.json")
        try SkillTrustStore().pinning(name: "local", hash: SkillTrustStore.hash(content))
            .save(root: "/proj", storePath: trustPath)
        let trust = SkillTrustResolver.resolve(skillName: "local", content: content, projectRoot: "/proj",
                                               signatureJSON: nil, trustStorePath: trustPath,
                                               publisherStorePath: tempPath("publishers.json"))
        XCTAssertEqual(trust, .trusted)
    }

    func testPublisherStoreRoundTripsAndDropsBadKeys() throws {
        let kp = MythosCrypto.ed25519GenerateKeyPair()
        let path = tempPath("publishers.json")
        try SkillPublisherKeyStore()
            .pinning(keyID: "good", publicKeyB64: kp.publicRaw.base64EncodedString())
            .pinning(keyID: "bad", publicKeyB64: "not-base64")
            .save(storePath: path)
        let loaded = SkillPublisherKeyStore.load(storePath: path)
        // Both persist as strings; the VERIFIER drops the bad one (invalid Ed25519 pub).
        let verifier = SkillSignatureVerifier(trusted: loaded.trustedKeys())
        XCTAssertFalse(verifier.isEmpty)                      // "good" survived
        let approval = SkillApproval(skillName: "s", contentHash: SkillTrustStore.hash("b"),
                                     publisherKeyID: "bad", nonce: "n", approvedAtEpoch: 1)
        let signed = try SignedSkill.make(approval: approval, privateKeyRaw: kp.privateRaw)
        // "bad" was dropped at verifier init ⇒ unknownKey.
        XCTAssertEqual(verifier.verify(signed, skillName: "s", contentHash: SkillTrustStore.hash("b")), .unknownKey)
    }
}
