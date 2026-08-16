import XCTest
import AgentCore
@testable import Kist

final class CoboloBuilderCompositionTests: XCTestCase {
    func testCoboloGraphIsTheSingleTypedOrchestrationChain() throws {
        let graph = try KistRunner.coboloBuilderGraph(
            root: "/tmp/project", goal: "build payroll", target: "src/payroll.cbl")
        XCTAssertEqual(graph.nodes.map(\.id), [
            "research", "symbolic-peel", "council",
            "task-board-projection", "cobolo-execution",
        ])
        XCTAssertEqual(graph.nodes[1].dependencies, ["research"])
        XCTAssertEqual(graph.nodes[2].dependencies, ["symbolic-peel"])
        XCTAssertEqual(graph.nodes[3].dependencies, ["council"])
        XCTAssertEqual(graph.nodes[4].dependencies, ["task-board-projection"])
        XCTAssertFalse(graph.nodes.contains { $0.id == "build" })
        XCTAssertTrue(graph.nodes.prefix(4).allSatisfy {
            !$0.resources.contains(where: { $0.access == .write })
        })
        XCTAssertEqual(graph.nodes[4].resources.map(\.path), ["src/payroll.cbl"])
        let policy = KistRunner.builderCoboloGraphPolicy()
        XCTAssertTrue(graph.nodes.prefix(4).allSatisfy {
            policy.executionClass(for: $0.id) == .readOnly
        })
        XCTAssertEqual(policy.executionClass(for: "cobolo-execution"), .mutation)
    }

    func testCaptainDecisionReceiptIsDeterministicAndRouteBound() {
        let options = KistOptions.parse([
            "--cobolo", "--cobol-target", "payroll.cbl",
            "--cobol-expect", "OK", "build payroll",
        ])
        let launch = KistRunner.builderCompatibilityLaunch(for: options)
        let first = KistRunner.builderCaptainDecisionReceipt(
            contractID: "builder", goal: "build payroll", launch: launch)
        let second = KistRunner.builderCaptainDecisionReceipt(
            contractID: "builder", goal: "build payroll", launch: launch)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.digest, second.digest)
        XCTAssertNotEqual(first.digest, KistRunner.builderCaptainDecisionReceipt(
            contractID: "builder", goal: "build another payroll", launch: launch).digest)
    }

    func testCouncilBoardProjectionMintsVersionedHandoffWithoutBecomingAcceptance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cobolo-board-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let council = KistRunner.AutonomyCouncilDecision(
            finalPlan: """
            | Status | Task | Owner | Acceptance |
            |---|---|---|---|
            | Ready | ACTION: Implement payroll | builder | COBOL compiles |
            | Test | TEST: Run payroll | critic | stdout is OK |
            """,
            builderBrief: "Implement and verify payroll",
            artifactPath: ".mythos/council/payroll.md",
            digest: BuilderEvidenceDigest.sha256("council-artifact"))
        let dossier = KistRunner.AutonomyMissionDossier(
            text: "dossier", paths: [], council: council)

        let projection = try XCTUnwrap(KistRunner.runAutonomyTaskBoardProjectionStage(
            goal: "build payroll", dossier: dossier,
            builderContractID: "builder", root: root.path))
        XCTAssertEqual(projection.lineage.version, 1)
        XCTAssertEqual(projection.lineage.taskIDs, ["task-1", "task-2"])
        XCTAssertTrue(projection.stage.passed)
        XCTAssertTrue(projection.stage.evidence.contains("not acceptance truth"))
        let observed = PlanStore(projectRoot: root.path).load()
        XCTAssertEqual(observed.tasks.count, 2)
        XCTAssertFalse(observed.tasks.allSatisfy { $0.status == .done })
    }

    func testPrescriptiveContractIsExactTargetAndRejectsTampering() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cobolo-contract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let options = KistOptions.parse([
            "--cobolo", "--cobol-target", "payroll.cbl",
            "--cobol-expect", "OK", "build payroll",
        ])
        let identities = coboloIdentityPlanFixture()
        let sealed = coboloExecutionContractFixture(
            root: root.path, options: options, identityPlan: identities)
        XCTAssertEqual(sealed.contract.mutations.map(\.path), ["payroll.cbl"])
        XCTAssertEqual(Set(sealed.contract.criteria.map(\.id)), Set([
            "cobolo-lineage", "cobolo-target", "cobolo-compile", "cobolo-runtime",
            "cobolo-semantic-review", "cobolo-promotion-review",
        ]))
        XCTAssertNoThrow(try KistRunner.coboloValidateExecutionContract(
            sealed, builderContractID: "test-builder",
            builderNodeID: "cobolo-execution", target: "payroll.cbl",
            identityPlan: identities))

        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(sealed)) as? [String: Any])
        object["fingerprint"] = BuilderEvidenceDigest.sha256("tampered")
        let tampered = try JSONDecoder().decode(
            SealedBuilderExecutionContract.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try KistRunner.coboloValidateExecutionContract(
            tampered, target: "payroll.cbl", identityPlan: identities))
    }

    func testResumeRejectsMissingOrDriftedBuilderLineage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cobolo-resume-lineage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let options = KistOptions.parse([
            "--cobolo", "--cobol-target", "payroll.cbl",
            "--cobol-expect", "OK", "build payroll",
        ])
        let identities = coboloIdentityPlanFixture()
        let expected = coboloExecutionContractFixture(
            root: root.path, options: options, identityPlan: identities)
        let drifted = coboloExecutionContractFixture(
            root: root.path, options: options, identityPlan: identities,
            captainSeed: "different-captain")
        XCTAssertThrowsError(try KistRunner.coboloValidateResumeLineage(
            persisted: nil, expected: expected))
        XCTAssertThrowsError(try KistRunner.coboloValidateResumeLineage(
            persisted: drifted, expected: expected))
        XCTAssertNoThrow(try KistRunner.coboloValidateResumeLineage(
            persisted: expected, expected: expected))
    }
}
