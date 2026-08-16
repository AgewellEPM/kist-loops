import XCTest
import AgentCore
@testable import Kist

private struct SolApprovingCouncil: PromotionCouncil {
    func judge(_ ctx: PromotionContext, threshold: Int) async -> CouncilPromotionVerdict {
        CouncilPromotionVerdict(votes: [], isShipWorthy: true, threshold: threshold,
                                summary: "approved")
    }
}

final class SolBuilderAssuranceRegressionTests: XCTestCase {
    func testHighAssuranceGraphOrdersReceiptBoundPeelCouncilExecutionAndReview() throws {
        let plan = KistRunner.BuilderPreflightPlan(
            schemaVersion: 1, adapter: "mission",
            operations: [.init(kind: .create, path: "Sources/New.swift", preimageSHA256: nil)],
            verificationCommands: [.init(
                executable: "swift", arguments: ["test"], timeoutSeconds: 120)],
            partitions: [])
        let graph = try KistRunner.builderPlannedGraph(
            adapter: .mission, goal: "build safely", plan: plan)
        let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })

        XCTAssertEqual(graph.nodes.map { $0.id }, [
            "research", "symbolic-peel", "council", "task-board-projection",
            "execution", "independent-review",
        ])
        XCTAssertEqual(nodes["research"]?.dependencies, [])
        XCTAssertEqual(nodes["symbolic-peel"]?.dependencies, ["research"])
        XCTAssertEqual(nodes["council"]?.dependencies, ["symbolic-peel"])
        XCTAssertEqual(nodes["task-board-projection"]?.dependencies, ["council"])
        XCTAssertEqual(nodes["execution"]?.dependencies, ["task-board-projection"])
        XCTAssertEqual(nodes["independent-review"]?.dependencies, ["execution"])
        XCTAssertEqual(nodes["execution"]?.resources,
                       [BuilderResourceClaim(path: "Sources/New.swift", access: .write)])
        XCTAssertTrue(nodes["research"]?.resources.allSatisfy { $0.access == .read } == true)
        XCTAssertEqual(nodes["independent-review"]?.role, .reviewer)
    }

    func testSimulationAndExecutionConsumeMissionDossier() throws {
        let source = try builderSource()
        let council = stageBlock(source, stage: "council", next: "simulation").lowercased()
        let simulation = stageBlock(source, stage: "simulation", next: "trial").lowercased()
        let execution = stageBlock(source, stage: "execution", next: nil).lowercased()
        XCTAssertTrue(council.contains("dossier"), council)
        XCTAssertTrue(council.contains("runautonomycouncilstage"), council)
        XCTAssertTrue(simulation.contains("dossier"), simulation)
        XCTAssertTrue(simulation.contains("runautonomysimulationstage"), simulation)
        XCTAssertTrue(execution.contains("dossier"), execution)
        XCTAssertTrue(execution.contains("runautonomyexecutionstage"), execution)
    }

    func testVerifiedReadOnlyBypassRequiresExplicitAllowanceAndPassingExecution() async {
        let pipeline = ShipPipeline(council: SolApprovingCouncil())
        let evidence = verificationEvidence()
        let verifiedReadOnly = ShipPipeline.BuildResult(
            hadChanges: false, diffSummary: "no mutation", testsPassed: true,
            testSummary: "read-only oracle passed", signoffSummary: "verified", testsRan: true,
            verificationSubject: "/tmp/project", verificationDigest: "abc123",
            completionEvidence: evidence)
        let denied = await pipeline.review(goal: "explain", build: verifiedReadOnly)
        XCTAssertFalse(denied.canDeploy)
        XCTAssertNil(denied.verdict)
        let allowed = await pipeline.review(goal: "explain", build: verifiedReadOnly,
                                            allowVerifiedReadOnly: true)
        XCTAssertTrue(allowed.canDeploy)

        let unverified = ShipPipeline.BuildResult(
            hadChanges: false, diffSummary: "no mutation", testsPassed: true,
            testSummary: "nothing ran", signoffSummary: "none", testsRan: false)
        let refused = await pipeline.review(goal: "explain", build: unverified,
                                            allowVerifiedReadOnly: true)
        XCTAssertFalse(refused.canDeploy)
        XCTAssertNil(refused.verdict)
    }

    func testOnlyVerifiedAuditLaunchesMintReadOnlyPromotionCapability() throws {
        let lean = KistRunner.builderCompatibilityLaunch(
            for: KistOptions.parse(["what does parseChord do?"]))
        XCTAssertEqual(lean.adapter, .headless)
        XCTAssertTrue(lean.leanHeadless)
        XCTAssertFalse(lean.allowsVerifiedReadOnlyPromotion,
                       "an ordinary answer route is not an audit capability")

        let auditOptions = KistOptions.parse([
            "--yolo", "--plan-execute", "Audit the existing project read-only",
        ])
        let audit = KistRunner.builderCompatibilityLaunch(for: auditOptions)
        XCTAssertTrue(auditOptions.yolo)
        XCTAssertTrue(auditOptions.planExecute)
        XCTAssertEqual(audit.adapter, .planExecute)
        XCTAssertFalse(audit.leanHeadless, "pins the installed regression's exact route")
        XCTAssertEqual(KistRunner.builderCompletionMode(for: auditOptions.goal ?? ""),
                       .verificationOnly)
        XCTAssertTrue(audit.allowsVerifiedReadOnlyPromotion)

        let ordinaryPlan = KistRunner.builderCompatibilityLaunch(
            for: KistOptions.parse(["--yolo", "--plan-execute", "build it"]))
        XCTAssertEqual(ordinaryPlan.adapter, .planExecute)
        XCTAssertFalse(ordinaryPlan.allowsVerifiedReadOnlyPromotion)

        for arguments in [["--fleet", "Audit the project read-only"],
                          ["--loop", "Audit the project read-only"],
                          ["--mission", "Audit the project read-only"]] {
            XCTAssertFalse(KistRunner.builderCompatibilityLaunch(for: KistOptions.parse(arguments))
                .allowsVerifiedReadOnlyPromotion)
        }
        let source = try builderSource()
        XCTAssertEqual(source.components(separatedBy:
            "allowVerifiedReadOnly: launch.allowsVerifiedReadOnlyPromotion").count - 1, 1)
        XCTAssertFalse(source.contains(
            "allowVerifiedReadOnly: contract.effectiveCompletionMode"))
    }

    func testHeadlessYoloPlanExecuteVerificationOnlyPromotesUnchangedVerifiedWorkspace() async {
        let objective = "Audit the existing project read-only"
        let options = KistOptions.parse(["--yolo", "--plan-execute", objective])
        let launch = KistRunner.builderCompatibilityLaunch(for: options)
        let evidence = verificationEvidence()
        XCTAssertNil(evidence.validationFailure)
        XCTAssertEqual(launch.adapter, .planExecute)
        XCTAssertFalse(launch.leanHeadless)
        XCTAssertTrue(launch.allowsVerifiedReadOnlyPromotion)

        let build = ShipPipeline.BuildResult(
            hadChanges: false, diffSummary: "no mutation", testsPassed: true,
            testSummary: "five typed obligations passed", signoffSummary: "replay verified",
            testsRan: true, verificationSubject: "/tmp/project", verificationDigest: "abc123",
            completionEvidence: evidence)
        let decision = await ShipPipeline(council: SolApprovingCouncil()).review(
            goal: objective, build: build,
            allowVerifiedReadOnly: launch.allowsVerifiedReadOnlyPromotion)
        XCTAssertTrue(decision.canDeploy, decision.reason)
        XCTAssertNotNil(decision.verdict)
        XCTAssertEqual(decision.evidencePacketDigest, evidence.packetDigest)
    }

    private func verificationEvidence() -> PromotionCompletionEvidence {
        let fingerprint = "objective-sha"
        let command = BuilderCommandEvidenceReceipt.bound(
            tool: "run_command", verifierStatus: .passed, exitCode: 0,
            allowedExitCodes: "0", semanticStatus: "success",
            argsFingerprint: "executable=swift&args=[test]", output: "five obligations passed",
            subjectDigestAfter: "abc123", contractFingerprint: fingerprint)
        return PromotionCompletionEvidence(
            contractID: "contract", objectiveFingerprint: fingerprint,
            completionMode: .verificationOnly, verificationSubject: "/tmp/project",
            baselineDigest: "abc123", verifiedDigest: "abc123", reviewEntryDigest: "abc123",
            verifiedAt: Date(), commandReceipts: [command],
            hostChecks: [.init(name: "final", passed: true, details: "passed")],
            producerIdentities: ["anthropic:claude"], reviewerIdentity: "gemini:review")
    }

    private func builderSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let builderSurfaces = [
            "Sources/Kist/KistRunner+Builder.swift",
            "Sources/Kist/KistRunner+BuilderAdapters.swift",
            "Sources/Kist/KistRunner+BuilderPreflightV2.swift",
            "Sources/Kist/KistRunner+BuilderPipelineV2.swift",
            "Sources/Kist/KistRunner+BuilderVerificationV2.swift",
            "Sources/Kist/KistRunner+AutonomyMission.swift",
            "Sources/Kist/KistRunner+Cobolo.swift",
        ]
        return try builderSurfaces.map { path in
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }.joined(separator: "\n")
    }

    private func compact(_ source: String) -> String {
        source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func window(_ source: String, after marker: String, length: Int) -> String {
        guard let range = source.range(of: marker) else { return "" }
        return String(source[range.lowerBound...].prefix(length))
    }

    private func stageBlock(_ source: String, stage: String, next: String?) -> String {
        let marker = "case \"\(stage)\":"
        guard let start = source.range(of: marker) else { return "" }
        let tail = source[start.lowerBound...]
        if let next, let end = tail.range(of: "case \"\(next)\":") {
            return String(tail[..<end.lowerBound])
        }
        if let end = tail.range(of: "default:") {
            return String(tail[..<end.lowerBound])
        }
        return String(tail.prefix(5_000))
    }
}
