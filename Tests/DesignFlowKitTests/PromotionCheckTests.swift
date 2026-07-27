import XCTest
import AgentCore
@testable import DesignFlowKit

/// The DRY deploy-gate consultation. Proves the two-tier model wires correctly and
/// stays fail-closed: internal readiness comes from the sealed chain; the GO path
/// requires a genuine EXTERNAL Ed25519 signature (operator keypair — never minted
/// by DesignFlow).
final class PromotionCheckTests: XCTestCase {
    override func setUp() { super.setUp(); ForgeSeal.forceEphemeralKeyForTesting() }
    override func tearDown() { ForgeSeal.resetCacheForTesting(); super.tearDown() }

    private func readyLedger() throws -> StageSignoffLedger {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID().uuidString).jsonl")
        let ledger = StageSignoffLedger(fileURL: url)
        try ledger.append(projectID: "p", stage: .uiDesigner, artifactPath: "a", commitSHA: "s0", artifactHash: "ah", committedPaths: ["a"], atEpoch: 1)
        try ledger.append(projectID: "p", stage: .developer, artifactPath: "b", commitSHA: "s1", artifactHash: "ah", committedPaths: ["b"], atEpoch: 2)
        return ledger
    }

    // An operator (NOT DesignFlow) mints a keypair, signs an approval, pins the public key.
    private func operatorApproval(buildID: String, keyID: String = "op", nonce: String = "n1")
        throws -> (SignedApproval, AttestationVerifier.TrustedKey) {
        let kp = MythosCrypto.ed25519GenerateKeyPair()
        let approval = PromotionApproval(buildID: buildID, approverKeyID: keyID, nonce: nonce, approvedAtEpoch: 10)
        let signed = try SignedApproval.make(approval: approval, privateKeyRaw: kp.privateRaw)
        let pin = AttestationVerifier.TrustedKey(keyID: keyID, publicKeyB64: kp.publicRaw.base64EncodedString())
        return (signed, pin)
    }

    func testInternalReadinessRequiresFullPipelineBoundToHead() throws {
        // readyLedger has stages [.uiDesigner, .developer], last commit short "s1".
        let ready = try readyLedger()
        let stages: [AgentKind] = [.uiDesigner, .developer]

        // Full expected stages + HEAD that starts with the last commit ⇒ ready.
        XCTAssertTrue(PromotionCheck.internallyReady(ready, expectedStages: stages, headSHA: "s1deadbeef"))
        // Truncated expectation (fewer stages than the ledger) ⇒ NOT ready.
        XCTAssertFalse(PromotionCheck.internallyReady(ready, expectedStages: [.uiDesigner], headSHA: "s1deadbeef"))
        // Wrong/extra stages ⇒ NOT ready.
        XCTAssertFalse(PromotionCheck.internallyReady(ready, expectedStages: [.uiDesigner, .designAnalyst, .developer], headSHA: "s1deadbeef"))
        // HEAD does not bind to the final signoff's commit (stale/copied ledger) ⇒ NOT ready.
        XCTAssertFalse(PromotionCheck.internallyReady(ready, expectedStages: stages, headSHA: "OTHERsha"))
        // Empty ledger ⇒ NOT ready.
        let empty = StageSignoffLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).jsonl"))
        XCTAssertFalse(PromotionCheck.internallyReady(empty, expectedStages: stages, headSHA: "s1deadbeef"))
    }

    func testNotReadyRefusesEvenWithValidAttestation() throws {
        let (signed, pin) = try operatorApproval(buildID: "build-1")
        let d = PromotionCheck.decide(buildID: "build-1", internallyReady: false,
                                      attestation: signed, pins: [pin], consumedApprovals: [])
        XCTAssertFalse(d.promotable)
        XCTAssertTrue(d.refusalReason?.contains("not internally ready") ?? false)
    }

    func testReadyButNoAttestationRefuses() {
        let d = PromotionCheck.decide(buildID: "build-1", internallyReady: true,
                                      attestation: nil, pins: [], consumedApprovals: [])
        XCTAssertFalse(d.promotable)
        XCTAssertTrue(d.refusalReason?.contains("no external attestation") ?? false)
    }

    func testUnpinnedKeyRefusesFailClosed() throws {
        let (signed, _) = try operatorApproval(buildID: "build-1")
        // Valid signature but NO pinned keys ⇒ unknownKey ⇒ refuse.
        let d = PromotionCheck.decide(buildID: "build-1", internallyReady: true,
                                      attestation: signed, pins: [], consumedApprovals: [])
        XCTAssertFalse(d.promotable)
        XCTAssertTrue(d.refusalReason?.contains("unpinned key") ?? false)
    }

    func testWrongBuildIDRefusesCrossBuildReplay() throws {
        let (signed, pin) = try operatorApproval(buildID: "build-OTHER")
        let d = PromotionCheck.decide(buildID: "build-1", internallyReady: true,
                                      attestation: signed, pins: [pin], consumedApprovals: [])
        XCTAssertFalse(d.promotable)
        XCTAssertTrue(d.refusalReason?.contains("not the integration build") ?? false)
    }

    func testConsumedApprovalRefusesReplay() throws {
        let (signed, pin) = try operatorApproval(buildID: "build-1")
        let replay = FleetPromotionGate.replayKey(for: signed.approval)
        let d = PromotionCheck.decide(buildID: "build-1", internallyReady: true,
                                      attestation: signed, pins: [pin], consumedApprovals: [replay])
        XCTAssertFalse(d.promotable)
        XCTAssertTrue(d.refusalReason?.contains("already consumed") ?? false)
    }

    func testGenuineExternalApprovalPromotes() throws {
        let (signed, pin) = try operatorApproval(buildID: "build-1")
        let d = PromotionCheck.decide(buildID: "build-1", internallyReady: true,
                                      attestation: signed, pins: [pin], consumedApprovals: [])
        XCTAssertTrue(d.promotable, "genuine external sig + pinned key + matching build + fresh ⇒ GO")
        if case let .promote(buildID) = d.verdict { XCTAssertEqual(buildID, "build-1") }
        else { XCTFail("expected .promote") }
    }

    func testOperatorFileParsingRoundTrips() throws {
        let (signed, pin) = try operatorApproval(buildID: "build-1")
        let approvalJSON = String(data: try JSONEncoder().encode(signed), encoding: .utf8)!
        let pinsJSON = String(data: try JSONEncoder().encode(
            [PromotionCheck.PinDTO(keyID: pin.keyID, publicKeyB64: pin.publicKeyB64)]), encoding: .utf8)!

        let parsedApproval = PromotionCheck.parseApproval(approvalJSON)
        let parsedPins = PromotionCheck.parsePins(pinsJSON)
        XCTAssertNotNil(parsedApproval)
        XCTAssertEqual(parsedPins.count, 1)
        // Parsed inputs still produce GO — the file path is faithful.
        let d = PromotionCheck.decide(buildID: "build-1", internallyReady: true,
                                      attestation: parsedApproval, pins: parsedPins, consumedApprovals: [])
        XCTAssertTrue(d.promotable)
        // Garbage in ⇒ fail-soft empty/nil ⇒ fail-closed.
        XCTAssertNil(PromotionCheck.parseApproval("{not json"))
        XCTAssertEqual(PromotionCheck.parsePins("garbage").count, 0)
    }
}
