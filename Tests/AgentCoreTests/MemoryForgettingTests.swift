import XCTest
@testable import AgentCore

/// Q7 forgetting: hygienic retention with receipts, and governance right-to-delete with a
/// residual-scan proof. Receipts must never re-persist the forgotten content.
final class MemoryForgettingTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "forgetting-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        root = try XCTUnwrap(ToolContext.canonicalize(root))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: root) }

    private func screen(_ count: Int = 1) -> MemoryAdmissionScreen {
        let gate = MemoryAdmissionGate(hostProject: "/host", authorizedProjects: [])
        let candidates = (0..<count).map { index in
            MemoryAdmissionCandidate(
                entry: AgentMemoryEntry(id: "c\(index)", title: "t", text: "content",
                                        locator: "/x", observedAt: Date()),
                provenance: .historyEvent, sourceProject: "/host")
        }
        return gate.screen(candidates, at: Date())
    }

    // MARK: - Hygienic retention

    func testRetentionSweepRemovesOnlyExpiredRecordsAndWritesReceipt() throws {
        let now = Date()
        let old = now.addingTimeInterval(-86_400 * 100)
        XCTAssertNil(MemoryAdmissionAuditLog.record(screen: screen(), query: "q-old",
                                                    hostRoot: root, at: old))
        XCTAssertNil(MemoryAdmissionAuditLog.record(screen: screen(), query: "q-new",
                                                    hostRoot: root, at: now))
        let store = MemoryReactivationStore(hostRoot: root)
        let context = MemoryRecurrenceContext.derive(failureDetails: ["frobnicate marker"])
        XCTAssertNil(store.record(locator: "/a", context: context, query: "q", at: old))
        XCTAssertNil(MemoryReactivationStore(hostRoot: root)
            .record(locator: "/b", context: context, query: "q", at: now))

        let sweep = MemoryForgetting.retentionSweep(hostRoot: root, at: now)
        XCTAssertEqual(sweep.receipt.removed.count, 2, "exactly the two expired records leave")
        XCTAssertEqual(Set(sweep.receipt.removed.map(\.store)), ["admission", "reactivation"])
        let confined = try ConfinedRoot(root: root, readOnly: true)
        XCTAssertEqual(try confined.entries(MemoryAdmissionAuditLog.directory).count, 1,
                       "the fresh admission record survives")
        XCTAssertEqual(try confined.entries(MemoryReactivationStore.directory).count, 1,
                       "the fresh overlay survives")
        XCTAssertEqual(try confined.entries(MemoryForgetting.receiptDirectory).count, 1,
                       "a retention sweep that removed records leaves a receipt")
        // Idempotence: a second sweep removes nothing and writes no second receipt.
        let again = MemoryForgetting.retentionSweep(hostRoot: root, at: now)
        XCTAssertTrue(again.receipt.removed.isEmpty)
        XCTAssertEqual(try confined.entries(MemoryForgetting.receiptDirectory).count, 1)
    }

    // MARK: - Governance forgetting

    func testGovernanceForgetPurgesAllStoresAndProvesRemoval() throws {
        let now = Date()
        ProjectMemory(root: root).recordEpisode(Episode(
            goal: "treat patient record", success: true,
            summary: "diagnosis was SecretDiagnosisX7 confirmed", at: now.addingTimeInterval(-3_600)))
        ProjectMemory(root: root).recordEpisode(Episode(
            goal: "unrelated work", success: true, summary: "nothing sensitive here",
            at: now.addingTimeInterval(-1_800)))
        let procedures = ProcedureStore(projectRoot: root)
        let sensitive = try XCTUnwrap(procedures.deposit(
            title: "Handle the X7 case", task: "respond to SecretDiagnosisX7 findings",
            steps: "escalate SecretDiagnosisX7 to the specialist", source: "s:1",
            at: now.addingTimeInterval(-7_200)).procedure)
        _ = procedures.reinforce(id: sensitive.id, verifiedSource: "s:2",
                                 at: now.addingTimeInterval(-3_600))
        _ = procedures.deposit(title: "Rotate keys", task: "expired certificate",
                               steps: "generate then swap", source: "s:3", at: now)
        let overlayContext = MemoryRecurrenceContext.derive(
            failureDetails: ["SecretDiagnosisX7 recurred in intake"])
        XCTAssertNil(MemoryReactivationStore(hostRoot: root)
            .record(locator: "/episodes", context: overlayContext, query: "q", at: now))

        let result = MemoryForgetting.forget(term: "SecretDiagnosisX7", hostRoot: root, at: now)
        let receipt = try XCTUnwrap(result.receipt)
        XCTAssertEqual(receipt.residualClean, true, "deletion must be proven, not assumed")
        XCTAssertEqual(receipt.requestSHA256,
                       BuilderEvidenceDigest.sha256("secretdiagnosisx7"))
        XCTAssertEqual(Set(receipt.removed.map(\.store)),
                       ["episodes", "procedures", "reactivation"])

        let confined = try ConfinedRoot(root: root, readOnly: true)
        let episodes = String(decoding: try confined.readStableData(
            ".mythos/memory/episodes.jsonl", maxBytes: 1_000_000), as: UTF8.self)
        XCTAssertFalse(episodes.lowercased().contains("secretdiagnosisx7"))
        XCTAssertTrue(episodes.contains("nothing sensitive here"),
                      "unrelated episodes must survive the purge")
        let procedureFiles = try confined.entries(ProcedureStore.directory).map(\.name)
        XCTAssertFalse(procedureFiles.contains { $0.hasPrefix(sensitive.id) },
                       "every version of a forgotten procedure must leave")
        XCTAssertEqual(procedureFiles.count, 1, "the unrelated procedure survives")
        XCTAssertEqual(try confined.entries(MemoryReactivationStore.directory).count, 0)

        // The receipt itself must not re-persist the forgotten content.
        let receiptNames = try confined.entries(MemoryForgetting.receiptDirectory)
            .filter { !$0.isDir }.map(\.name)
        XCTAssertEqual(receiptNames.count, 1)
        let receiptBytes = String(decoding: try confined.readStableData(
            MemoryForgetting.receiptDirectory + "/" + receiptNames[0], maxBytes: 64_000), as: UTF8.self)
        XCTAssertFalse(receiptBytes.lowercased().contains("secretdiagnosisx7"),
                       "a receipt that stores the term defeats the deletion it documents")
    }

    func testForgetRefusesUnsafelyShortTerms() {
        let result = MemoryForgetting.forget(term: " x7 ", hostRoot: root, at: Date())
        XCTAssertNil(result.receipt)
        XCTAssertFalse(result.issues.isEmpty)
    }

    func testResidualScanDetectsPlantedContent() throws {
        XCTAssertFalse(MemoryForgetting.residualContains(term: "plantedmarker", hostRoot: root))
        let confined = try ConfinedRoot(root: root)
        _ = try confined.createDataIfMissing(
            ProcedureStore.directory + "/planted-v000001.json",
            Data("{\"note\":\"PlantedMarker lives here\"}".utf8), createParents: true)
        XCTAssertTrue(MemoryForgetting.residualContains(term: "plantedmarker", hostRoot: root),
                      "the proof scan must actually find residue")
    }

    // MARK: - End to end: forgotten means unreachable, even via reactivation

    private func identity(_ access: AgentMemoryAccess) -> AgentRunIdentity {
        AgentRunIdentity(runID: "prior", parentRunID: nil, rootRunID: "prior",
                         sessionID: access.sessionID, role: "researcher", project: access.project,
                         executionRoot: root)
    }

    func testForgottenEpisodeCannotReturnThroughRecallOrReactivation() throws {
        let now = Date()
        ProjectMemory(root: root).recordEpisode(Episode(
            goal: "fix frobnicateDeploy pipeline", success: true,
            summary: "E1234_TIMEOUT registry mirror fix",
            at: now.addingTimeInterval(-86_400 * 400)))
        let access = try AgentMemoryAccess(projectRoot: root)
        try access.history.append(agent: identity(access), kind: "failed",
                                  detail: "frobnicateDeploy hit E1234_TIMEOUT again", at: now)
        // Reactivate first so a schema-2 overlay bound to the episode exists.
        let before = try access.recall(query: "unrelated docs question", at: now)
        XCTAssertEqual(before.reactivatedCandidates, 1, "setup: reactivation must occur")
        let confined = try ConfinedRoot(root: root, readOnly: true)
        XCTAssertGreaterThanOrEqual(try confined.entries(MemoryReactivationStore.directory).count, 1)

        let result = MemoryForgetting.forget(term: "E1234_TIMEOUT registry mirror",
                                             hostRoot: root, at: now)
        XCTAssertEqual(result.receipt?.residualClean, true)
        XCTAssertEqual(try confined.entries(MemoryReactivationStore.directory).count, 0,
                       "overlays bound to the forgotten episode must be purged with it")

        let after = try access.recall(query: "unrelated docs question", at: now)
        XCTAssertFalse(after.entries.contains { $0.text.contains("E1234_TIMEOUT") },
                       "forgotten content must be unreachable even when its situation recurs")
        XCTAssertEqual(after.reactivatedCandidates, 0)
    }
}
