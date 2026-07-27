import XCTest
@testable import AgentCore

/// The external deploy gate, exercised with REAL Curve25519 keys (via MythosCrypto). The whole point is
/// that a promotion verdict is UNFORGEABLE: it requires both internal readiness AND a valid external
/// Ed25519 attestation BOUND to this exact build and not yet consumed. Fail-closed at every gate.
final class FleetPromotionGateTests: XCTestCase {

    private struct Holder { let keyID: String; let priv: Data; let pubB64: String }

    private func holder(_ id: String) -> Holder {
        let kp = MythosCrypto.ed25519GenerateKeyPair()
        return Holder(keyID: id, priv: kp.privateRaw, pubB64: kp.publicRaw.base64EncodedString())
    }

    private func verifier(_ holders: Holder...) -> AttestationVerifier {
        AttestationVerifier(trusted: holders.map { .init(keyID: $0.keyID, publicKeyB64: $0.pubB64) })
    }

    private func signedApproval(_ h: Holder, build: String, nonce: String = "n1", note: String = "ok") -> SignedApproval {
        let approval = PromotionApproval(buildID: build, approverKeyID: h.keyID, nonce: nonce, approvedAtEpoch: 1, note: note)
        return try! SignedApproval.make(approval: approval, privateKeyRaw: h.priv)
    }

    // MARK: the happy path — internally ready + valid external attestation for THIS build

    func testPromotesWhenReadyAndValidlyAttestedForThisBuild() {
        let h = holder("K1")
        let signed = signedApproval(h, build: "B1")
        let d = FleetPromotionGate.decide(integrationBuildID: "B1", internallyReady: true,
                                          attestation: signed, verifier: verifier(h), consumedApprovals: [])
        XCTAssertTrue(d.promotable)
        XCTAssertEqual(d.verdict, .promote(buildID: "B1"))
    }

    // MARK: fail-closed gates

    func testRefusesWhenNotInternallyReady() {
        let h = holder("K1")
        let d = FleetPromotionGate.decide(integrationBuildID: "B1", internallyReady: false,
                                          attestation: signedApproval(h, build: "B1"), verifier: verifier(h), consumedApprovals: [])
        XCTAssertFalse(d.promotable)
        XCTAssertTrue(d.refusalReason?.contains("not internally ready") ?? false)
    }

    func testRefusesWhenNoAttestation() {
        let d = FleetPromotionGate.decide(integrationBuildID: "B1", internallyReady: true,
                                          attestation: nil, verifier: verifier(holder("K1")), consumedApprovals: [])
        XCTAssertTrue(d.refusalReason?.contains("no external attestation") ?? false)
    }

    func testRefusesUnpinnedKey() {
        let signer = holder("K1")
        // Verifier pins a DIFFERENT holder; the signer's key is unknown → fail closed.
        let d = FleetPromotionGate.decide(integrationBuildID: "B1", internallyReady: true,
                                          attestation: signedApproval(signer, build: "B1"),
                                          verifier: verifier(holder("K2")), consumedApprovals: [])
        XCTAssertTrue(d.refusalReason?.contains("unpinned key") ?? false)
    }

    func testEmptyTrustSetRefusesEverything() {
        let h = holder("K1")
        let v = AttestationVerifier(trusted: [])
        XCTAssertTrue(v.isEmpty)
        let d = FleetPromotionGate.decide(integrationBuildID: "B1", internallyReady: true,
                                          attestation: signedApproval(h, build: "B1"), verifier: v, consumedApprovals: [])
        XCTAssertFalse(d.promotable, "no pinned key ⇒ nothing trusts")
    }

    func testRefusesTamperedPayload() {
        let h = holder("K1")
        let signed = signedApproval(h, build: "B1", note: "original")
        // Keep the signature, swap the approval payload (note changed) → signature no longer matches.
        let tampered = SignedApproval(
            approval: PromotionApproval(buildID: "B1", approverKeyID: "K1", nonce: "n1", approvedAtEpoch: 1, note: "TAMPERED"),
            signatureB64: signed.signatureB64)
        let d = FleetPromotionGate.decide(integrationBuildID: "B1", internallyReady: true,
                                          attestation: tampered, verifier: verifier(h), consumedApprovals: [])
        XCTAssertTrue(d.refusalReason?.contains("did not verify") ?? false)
    }

    func testRefusesMalformedSignature() {
        let h = holder("K1")
        let bad = SignedApproval(approval: PromotionApproval(buildID: "B1", approverKeyID: "K1", nonce: "n1", approvedAtEpoch: 1),
                                 signatureB64: "!!!not base64!!!")
        let d = FleetPromotionGate.decide(integrationBuildID: "B1", internallyReady: true,
                                          attestation: bad, verifier: verifier(h), consumedApprovals: [])
        XCTAssertTrue(d.refusalReason?.contains("malformed") ?? false)
    }

    // MARK: replay protection

    func testRefusesCrossBuildReplay() {
        let h = holder("K1")
        // A valid approval for B1, presented to promote a DIFFERENT build B2.
        let d = FleetPromotionGate.decide(integrationBuildID: "B2", internallyReady: true,
                                          attestation: signedApproval(h, build: "B1"), verifier: verifier(h), consumedApprovals: [])
        XCTAssertTrue(d.refusalReason?.contains("not the integration build") ?? false,
                      "an approval for B1 can never promote B2")
    }

    func testRefusesAlreadyConsumedApproval() {
        let h = holder("K1")
        let signed = signedApproval(h, build: "B1", nonce: "used")
        let consumed: Set<String> = [FleetPromotionGate.replayKey(for: signed.approval)]
        let d = FleetPromotionGate.decide(integrationBuildID: "B1", internallyReady: true,
                                          attestation: signed, verifier: verifier(h), consumedApprovals: consumed)
        XCTAssertTrue(d.refusalReason?.contains("already consumed") ?? false)
    }

    func testReplayKeyIsSourceScoped() {
        let a = PromotionApproval(buildID: "B", approverKeyID: "K1", nonce: "N", approvedAtEpoch: 1)
        let b = PromotionApproval(buildID: "B", approverKeyID: "K2", nonce: "N", approvedAtEpoch: 1)
        XCTAssertNotEqual(FleetPromotionGate.replayKey(for: a), FleetPromotionGate.replayKey(for: b),
                          "two attesters can't collide on the same nonce string")
    }

    // MARK: the verifier directly

    func testVerifierValidAndUnknownAndMalformed() {
        let h = holder("K1")
        let v = verifier(h)
        if case .valid(let ver) = v.verify(signedApproval(h, build: "B1")) {
            XCTAssertEqual(ver.keyID, "K1")
        } else { XCTFail("expected valid") }
        XCTAssertEqual(verifier(holder("K2")).verify(signedApproval(h, build: "B1")), .unknownKey)
        let malformed = SignedApproval(approval: PromotionApproval(buildID: "B1", approverKeyID: "K1", nonce: "n", approvedAtEpoch: 1),
                                       signatureB64: "@@@")
        XCTAssertEqual(v.verify(malformed), .malformed)
    }

    func testBadPinIsDroppedNotTrusted() {
        // A pin with non-Ed25519 bytes is dropped at setup → the verifier is empty → fail closed.
        let v = AttestationVerifier(trusted: [.init(keyID: "K1", publicKeyB64: Data([1, 2, 3]).base64EncodedString())])
        XCTAssertTrue(v.isEmpty, "a malformed public-key pin is not trusted")
    }
}
