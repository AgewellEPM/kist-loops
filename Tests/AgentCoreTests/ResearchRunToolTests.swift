import XCTest
@testable import AgentCore

final class ResearchRunToolTests: XCTestCase {
    private func makeRoot() throws -> String {
        let raw = NSTemporaryDirectory() + "research-run-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        return ToolContext.canonicalize(raw)!
    }

    func testResearchRunLedgerRecordsGatherersAndSynthesizesReport() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let calls = ResearchCallLog()
        let tool = ResearchRunTool(
            search: { args, _ in
                await calls.record("search")
                return ToolResult(success: true,
                                  output: "1. Source\n   URL: https://example.com/source\n   Snippet: useful",
                                  metadata: ["engine": "test"])
            },
            fetch: { args, _ in
                await calls.record("fetch")
                return ToolResult(success: true, output: "Fetched primary source", metadata: ["url": "\(args["url"] ?? "")"])
            },
            browse: { _, _ in
                await calls.record("browse")
                return ToolResult(success: true, output: "Rendered browser state", metadata: ["engine": "stub"])
            },
            visual: { _, _ in
                await calls.record("visual")
                return ToolResult(success: true, output: "Visual verify PASS\nReport: .kist/visual-runs/case1/attempt-01-report.md",
                                  metadata: ["report": ".kist/visual-runs/case1/attempt-01-report.md"])
            },
            contextBrain: { _, _ in
                await calls.record("context")
                return ToolResult(success: true, output: "Context search match", metadata: ["chunks": "1"])
            }
        )
        let registry = ToolRegistry([tool])
        let context = ToolContext(projectRoot: root)

        let start = await registry.execute(name: "research_run", arguments: [
            "action": "start",
            "goal": "research browser evidence",
            "run_id": "case1",
        ], context: context)
        XCTAssertTrue(start.success, start.error ?? start.output)
        XCTAssertEqual(start.metadata["run_id"], "case1")

        for args in [
            ["action": "search", "run_id": "case1", "query": "browser evidence"],
            ["action": "fetch", "run_id": "case1", "url": "https://example.com/source"],
            ["action": "browse", "run_id": "case1", "url": "https://example.com/app"],
            ["action": "visual", "run_id": "case1", "goal": "candidate matches reference", "candidate": "shot.png"],
            ["action": "context", "run_id": "case1", "query": "ResearchRunTool"],
        ] {
            let result = await registry.execute(name: "research_run", arguments: args, context: context)
            XCTAssertTrue(result.success, result.error ?? result.output)
            XCTAssertNotNil(result.metadata["evidence_id"])
        }

        let synth = await registry.execute(name: "research_run", arguments: [
            "action": "synthesize",
            "run_id": "case1",
        ], context: context)

        XCTAssertTrue(synth.success, synth.error ?? "")
        XCTAssertTrue(synth.output.contains("# Research Dossier"))
        XCTAssertTrue(synth.output.contains("[E002]"))
        let recordedCalls = await calls.all()
        XCTAssertEqual(recordedCalls, ["search", "fetch", "browse", "visual", "context"])

        let evidence = ResearchRunStore.loadEvidence(projectRoot: root, runID: "case1")
        XCTAssertEqual(evidence.map(\.kind), ["research_plan", "web_search", "fetch_url", "browse", "visual_verify", "context_brain"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/research-runs/case1/report.md"))
        let status = try ResearchRunStore.renderStatus(projectRoot: root, runID: "case1")
        XCTAssertTrue(status.contains("Research case1 · synthesized"))
    }

    func testRunIDTraversalIsRejected() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let result = await ToolRegistry([ResearchRunTool(
            search: { _, _ in .failure("unused") },
            fetch: { _, _ in .failure("unused") },
            browse: { _, _ in .failure("unused") },
            contextBrain: { _, _ in .failure("unused") }
        )]).execute(name: "research_run", arguments: [
            "action": "start",
            "goal": "x",
            "run_id": "../escape",
        ], context: ToolContext(projectRoot: root))

        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("run_id"))
        XCTAssertTrue(ResearchRunStore.loadEvidence(projectRoot: root, runID: "../escape").isEmpty)
        XCTAssertTrue(ResearchRunStore.loadHeartbeats(projectRoot: root, runID: "../escape").isEmpty)
    }

    func testSynthesisFailsClosedWhenOnlyTheResearchPlanExists() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let registry = ToolRegistry([ResearchRunTool(
            search: { _, _ in .failure("offline") },
            fetch: { _, _ in .failure("offline") },
            browse: { _, _ in .failure("offline") },
            contextBrain: { _, _ in .failure("no matches") }
        )])
        let context = ToolContext(projectRoot: root)
        let start = await registry.execute(name: "research_run", arguments: [
            "action": "start", "goal": "current evidence", "run_id": "empty-case",
        ], context: context)
        XCTAssertTrue(start.success)

        let synth = await registry.execute(name: "research_run", arguments: [
            "action": "synthesize", "run_id": "empty-case",
        ], context: context)

        XCTAssertFalse(synth.success)
        XCTAssertTrue((synth.error ?? synth.output).contains("no grounded evidence"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root + "/.kist/research-runs/empty-case/report.md"))
    }

    func testModelSuppliedEvidenceCannotForgeAGroundedKindOrUnlockSynthesis() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let registry = ToolRegistry([ResearchRunTool(
            search: { _, _ in .failure("unused") },
            fetch: { _, _ in .failure("unused") },
            browse: { _, _ in .failure("unused") },
            contextBrain: { _, _ in .failure("unused") }
        )])
        let context = ToolContext(projectRoot: root)
        _ = await registry.execute(name: "research_run", arguments: [
            "action": "start", "goal": "truth", "run_id": "forgery-case",
        ], context: context)
        let note = await registry.execute(name: "research_run", arguments: [
            "action": "add_evidence", "run_id": "forgery-case", "kind": "web_search",
            "title": "fabricated", "text": "invented source",
        ], context: context)
        XCTAssertTrue(note.success)
        XCTAssertEqual(ResearchRunStore.loadEvidence(projectRoot: root, runID: "forgery-case").last?.kind,
                       "manual_observation")
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "research_run",
            arguments: ["action": "add_evidence"],
            outcomeMetadata: note.metadata).progress, .none)

        let synth = await registry.execute(name: "research_run", arguments: [
            "action": "synthesize", "run_id": "forgery-case",
        ], context: context)
        XCTAssertFalse(synth.success)
        XCTAssertTrue((synth.error ?? synth.output).contains("no grounded evidence"))
    }
}

private actor ResearchCallLog {
    private var values: [String] = []
    func record(_ value: String) { values.append(value) }
    func all() -> [String] { values }
}
