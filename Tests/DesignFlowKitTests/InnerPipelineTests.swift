import XCTest
@testable import DesignFlowKit

/// End-to-end inner-loop behavior with a real git workspace on disk but a stub LLM.
/// Proves the two things that matter: (1) a well-behaved pipeline produces + commits
/// an artifact for every stage, and (2) a stage that writes nothing is BLOCKED
/// fail-closed and the pipeline stops — no downstream stage runs.
final class InnerPipelineTests: XCTestCase {
    private func tempWorkspace() -> GitWorkspace {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true)
        return GitWorkspace(root: url)
    }

    private func cleanup(_ ws: GitWorkspace) { try? FileManager.default.removeItem(at: ws.root) }

    /// An agent that deliberately produces no artifact — simulates a stage that
    /// claims done but writes nothing. The gate must catch it.
    struct SilentAgent: Agent {
        let kind: AgentKind
        func produce(context: PipelineContext, workspace: GitWorkspace) async throws -> String {
            "I did the work, trust me"  // returns text but writes NO file
        }
    }

    func testFullPipelineProducesAndCommitsEveryStage() async throws {
        let ws = tempWorkspace(); defer { cleanup(ws) }
        let agents = AgentFactory.agents(for: .full, llm: StubLLMClient())
        let result = await InnerPipeline().run(brief: "accessible intake form builder",
                                               agents: agents, workspace: ws)

        XCTAssertTrue(result.completed, "reason: \(result.blockReason ?? "none")")
        XCTAssertEqual(result.artifacts.count, Pipeline.full.agents.count)
        // Every accepted stage carries a sealed, chain-intact signoff.
        XCTAssertEqual(result.signoffs.count, Pipeline.full.agents.count)
        XCTAssertTrue(result.signoffChainIntact, "signoff chain must be intact")
        for (i, stage) in Pipeline.full.agents.enumerated() {
            XCTAssertEqual(result.signoffs[i].stage, stage, "\(stage.displayName): signoff missing/misordered")
            XCTAssertTrue(result.signoffs[i].sealValid, "\(stage.displayName): signoff seal invalid")
        }
        // Per-stage assertions: each declared stage has a committed artifact on disk.
        for stage in Pipeline.full.agents {
            let artifact = result.artifacts.first { $0.stage == stage }
            XCTAssertNotNil(artifact, "\(stage.displayName): no artifact recorded")
            XCTAssertNotNil(artifact?.commitSHA, "\(stage.displayName): not committed")
            let path = ws.root.appendingPathComponent(stage.artifactPath).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                          "\(stage.displayName): artifact missing on disk")
        }
    }

    func testSilentStageBlocksFailClosedAndStopsPipeline() async throws {
        let ws = tempWorkspace(); defer { cleanup(ws) }
        // Designer real (writes), Analyst silent (writes nothing), Developer should NEVER run.
        let agents: [Agent] = [
            PromptAgent(kind: .uiDesigner, llm: StubLLMClient(), system: "s", makeUser: { _ in "u" }),
            SilentAgent(kind: .designAnalyst),
            PromptAgent(kind: .developer, llm: StubLLMClient(), system: "s", makeUser: { _ in "u" }),
        ]
        let result = await InnerPipeline().run(brief: "x", agents: agents, workspace: ws)

        XCTAssertFalse(result.completed, "silent stage must block the pipeline")
        XCTAssertEqual(result.blockedStage, .designAnalyst)
        XCTAssertEqual(result.artifacts.count, 1, "only the designer's artifact should exist")
        XCTAssertEqual(result.artifacts.first?.stage, .uiDesigner)
        // Developer must not have produced its artifact — the loop stopped.
        let devPath = ws.root.appendingPathComponent(AgentKind.developer.artifactPath).path
        XCTAssertFalse(FileManager.default.fileExists(atPath: devPath),
                       "developer ran despite upstream block — fail-closed violated")
    }

    /// Codex regression: a REUSED workspace pre-seeded with a prior run's artifact
    /// must not let a silent stage pass on the stale file. The stage does no work
    /// this run, the file already exists — the freshness gate must still block.
    func testStalePriorArtifactInReusedWorkspaceCannotSatisfyGate() async throws {
        let ws = tempWorkspace(); defer { cleanup(ws) }
        try ws.initialize()
        // Simulate a prior run having written this stage's artifact.
        try ws.write("stale analysis from a prior run", to: AgentKind.designAnalyst.artifactPath)

        // This run: analyst is silent (writes nothing). Stale file is present.
        let agents: [Agent] = [SilentAgent(kind: .designAnalyst)]
        let result = await InnerPipeline().run(brief: "reused", agents: agents, workspace: ws)

        XCTAssertFalse(result.completed, "stale artifact must not satisfy the gate")
        XCTAssertEqual(result.blockedStage, .designAnalyst)
        XCTAssertEqual(result.artifacts.count, 0, "no stage produced fresh work")
        XCTAssertTrue(result.blockReason?.contains("FRESH") ?? false,
                      "block reason should cite freshness: \(result.blockReason ?? "")")
    }

    /// The ClaimReconciler backing: an artifact that exists on disk and is fresh
    /// (so ArtifactGate passes) but is gitignored — it never lands in the committed
    /// merge-set. The fleet's reconciler must block it. This is the hole an on-disk
    /// check alone cannot see.
    func testGitignoredArtifactBlockedByClaimReconciler() async throws {
        let ws = tempWorkspace(); defer { cleanup(ws) }
        try ws.initialize()
        // Ignore the UI Designer's artifact directory, then commit the ignore rule.
        try ws.write("design/\n", to: ".gitignore")
        _ = try ws.commit("add gitignore")

        // A real agent that genuinely writes design/analysis.md — but it's ignored.
        let agents: [Agent] = [
            PromptAgent(kind: .uiDesigner, llm: StubLLMClient(), system: "s", makeUser: { _ in "u" })
        ]
        let result = await InnerPipeline().run(brief: "gitignored", agents: agents, workspace: ws)

        XCTAssertFalse(result.completed, "an artifact that won't merge must not pass the gate")
        XCTAssertEqual(result.blockedStage, .uiDesigner)
        // A gitignored artifact stages nothing ⇒ no new commit ⇒ blocked fail-closed
        // (either by the no-committed-change guard or the per-stage reconciler).
        let reason = result.blockReason ?? ""
        XCTAssertTrue(reason.contains("no committed change") || reason.contains("claim reconciliation"),
                      "must block on missing committed work: \(reason)")
    }

    /// Codex BLOCKER-1: generated code that does not compile must BLOCK at the Build
    /// Architect, never report COMPLETE. Uses a stub that returns invalid Swift.
    struct InvalidSwiftClient: LLMClient {
        func complete(system: String, user: String) async throws -> String { "this is <not> valid swift {{{" }
    }
    func testInvalidGeneratedCodeBlocksAtBuildArchitect() async throws {
        let ws = tempWorkspace(); defer { cleanup(ws) }
        let agents = AgentFactory.agents(for: .full, llm: InvalidSwiftClient())
        let result = await InnerPipeline().run(brief: "x", agents: agents, workspace: ws)
        XCTAssertFalse(result.completed, "non-compiling code must not complete")
        XCTAssertEqual(result.blockedStage, .buildArchitect)
        XCTAssertTrue(result.blockReason?.contains("did not build") ?? false, result.blockReason ?? "")
    }

    /// Codex HIGH-4: a stage that makes NO new commit (identical re-output on a reused
    /// workspace) did no committed work and MUST be blocked — it can't mint a signoff
    /// off a prior run's committed paths. (This reverses an earlier test that wrongly
    /// asserted "completes" — that expectation was defending the hole.)
    func testIdenticalReoutputOnReusedWorkspaceIsBlocked() async throws {
        let ws = tempWorkspace(); defer { cleanup(ws) }
        let r1 = await InnerPipeline().run(
            brief: "same", agents: AgentFactory.agents(for: .designAndAnalysis, llm: StubLLMClient()), workspace: ws)
        XCTAssertTrue(r1.completed, "run 1: \(r1.blockReason ?? "")")

        // Second run, SAME workspace, deterministic stub ⇒ byte-identical artifacts ⇒
        // no git diff ⇒ commit() returns nil ⇒ the no-committed-change guard blocks.
        let r2 = await InnerPipeline().run(
            brief: "same", agents: AgentFactory.agents(for: .designAndAnalysis, llm: StubLLMClient()), workspace: ws)
        XCTAssertFalse(r2.completed, "a stage with no new committed work must block")
        XCTAssertEqual(r2.blockedStage, .uiDesigner)
        XCTAssertTrue(r2.blockReason?.contains("no committed change") ?? false, r2.blockReason ?? "")
    }

    func testSubsetPipelineRunsOnlyItsStages() async throws {
        let ws = tempWorkspace(); defer { cleanup(ws) }
        let agents = AgentFactory.agents(for: .designAndAnalysis, llm: StubLLMClient())
        let result = await InnerPipeline().run(brief: "y", agents: agents, workspace: ws)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.artifacts.map(\.stage), [.uiDesigner, .designAnalyst])
        // Developer artifact must NOT exist for this recipe.
        let devPath = ws.root.appendingPathComponent(AgentKind.developer.artifactPath).path
        XCTAssertFalse(FileManager.default.fileExists(atPath: devPath))
    }
}
