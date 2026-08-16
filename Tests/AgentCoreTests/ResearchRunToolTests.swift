import XCTest
@testable import AgentCore

private actor ResearchArgumentsLog {
    private var values: [[String: Any]] = []
    func record(_ value: [String: Any]) { values.append(value) }
    func all() -> [[String: Any]] { values }
}

final class ResearchRunToolTests: XCTestCase {
    private func makeRoot() throws -> String {
        let raw = NSTemporaryDirectory() + "research-run-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        return ToolContext.canonicalize(raw)!
    }

    func testLimitIsDeclaredValidatedAndForwarded() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let tool = ResearchRunTool(
            search: { args, _ in
                guard args["limit"] as? Int == 5 else {
                    return .failure("limit was not forwarded")
                }
                return ToolResult(success: true,
                                  output: "1. Source\nURL: https://example.com")
            },
            fetch: { _, _ in .failure("unused") },
            browse: { _, _ in .failure("unused") },
            contextBrain: { _, _ in .failure("unused") }
        )
        XCTAssertTrue(tool.parameters.contains { $0.name == "limit" })
        let registry = ToolRegistry([tool])
        let context = ToolContext(projectRoot: root)
        let start = await registry.execute(
            name: "research_run",
            arguments: ["action": "start", "goal": "limits", "run_id": "limits"],
            context: context)
        XCTAssertTrue(start.success, start.error ?? start.output)

        let valid = await registry.execute(
            name: "research_run",
            arguments: ["action": "search", "run_id": "limits", "query": "test", "limit": 5],
            context: context)
        XCTAssertTrue(valid.success, valid.error ?? valid.output)

        let invalid = await registry.execute(
            name: "research_run",
            arguments: ["action": "search", "run_id": "limits", "query": "test", "limit": 11],
            context: context)
        XCTAssertFalse(invalid.success)
        XCTAssertTrue((invalid.error ?? invalid.output).contains("1 through 10"))
    }

    func testContextExactChunkRetrievalIsBoundedAndPersisted() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let calls = ResearchArgumentsLog()
        let tool = ResearchRunTool(
            search: { _, _ in .failure("unused") },
            fetch: { _, _ in .failure("unused") },
            browse: { _, _ in .failure("unused") },
            contextBrain: { args, _ in
                await calls.record(args)
                return ToolResult(success: true, output: "test.sh:L1-L2\n\n#!/bin/sh\nprintf ok")
            })
        let registry = ToolRegistry([tool])
        let context = ToolContext(projectRoot: root)
        _ = await registry.execute(name: "research_run", arguments: [
            "action": "start", "goal": "exact local evidence", "run_id": "exact-context",
        ], context: context)

        let result = await registry.execute(name: "research_run", arguments: [
            "action": "context", "run_id": "exact-context",
            "context_id": "test.sh:L1-L2", "max_chars": 24_000,
        ], context: context)

        XCTAssertTrue(result.success, result.error ?? result.output)
        let recorded = await calls.all()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0]["action"] as? String, "get")
        XCTAssertEqual(recorded[0]["id"] as? String, "test.sh:L1-L2")
        XCTAssertEqual(recorded[0]["max_chars"] as? Int, 24_000)
        let evidence = ResearchRunStore.loadEvidence(projectRoot: root, runID: "exact-context")
        XCTAssertEqual(evidence.last?.kind, "context_brain")
        XCTAssertTrue(evidence.last?.text.contains("printf ok") ?? false)
    }

    func testSupplementalEstateEvidenceCannotSubstituteForPrimaryResearchEvidence() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try ResearchRunStore(projectRoot: root, goal: "public evidence", runID: "supplemental")
        try store.appendEvidence(kind: "estate_search", title: "Local estate",
                                 text: "An unrelated local file matched.")
        try store.appendEvidence(kind: "symbolic_peel", title: "Proof template",
                                 text: "A symbolic proof was generated.")

        XCTAssertThrowsError(try store.synthesize()) { error in
            XCTAssertTrue(String(describing: error).contains("no usable primary evidence"))
        }
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
                return ToolResult(success: true, output: "Fetched primary source", metadata: [
                    "url": "\(args["url"] ?? "")", "status": "200",
                ])
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

    func testFetchNarrowsHostAndPersistsVerifiedStatusAndDigest() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let tool = ResearchRunTool(
            search: { _, _ in .failure("unused") },
            fetch: { args, _ in
                XCTAssertEqual(args["allowed_hosts"] as? [String], ["docs.example.com"])
                XCTAssertEqual(args["max_bytes"] as? Int, 64_000)
                return ToolResult(
                    success: true,
                    output: "Primary manual says GnuCOBOL DISPLAY writes the requested text.",
                    metadata: ["status": "206", "url": "https://docs.example.com/manual"])
            },
            browse: { _, _ in .failure("unused") },
            contextBrain: { _, _ in .failure("unused") })
        let registry = ToolRegistry([tool])
        let context = ToolContext(projectRoot: root)
        _ = await registry.execute(name: "research_run", arguments: [
            "action": "start", "goal": "GnuCOBOL DISPLAY", "run_id": "bound-fetch",
        ], context: context)

        let fetched = await registry.execute(name: "research_run", arguments: [
            "action": "fetch", "run_id": "bound-fetch",
            "url": "https://docs.example.com/manual", "max_bytes": 64_000,
        ], context: context)
        XCTAssertTrue(fetched.success, fetched.error ?? fetched.output)

        let evidence = ResearchRunStore.loadEvidence(projectRoot: root, runID: "bound-fetch")
        let primary = try XCTUnwrap(ResearchEvidencePolicy.verifiedPrimarySources(in: evidence).first)
        XCTAssertEqual(primary.httpStatus, 206)
        XCTAssertEqual(primary.contentSHA256, BuilderEvidenceDigest.sha256(primary.text))
        let report = try ResearchRunStore.open(projectRoot: root, runID: "bound-fetch").synthesize()
        XCTAssertTrue(report.contains("HTTP 206 · partial · SHA-256 \(primary.contentSHA256)"))
    }

    func testTimedOutFetchCannotBecomePrimaryEvidence() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let registry = ToolRegistry([ResearchRunTool(
            search: { _, _ in .failure("unused") },
            fetch: { _, _ in .failure("public-web aggregate request timed out") },
            browse: { _, _ in .failure("unused") },
            contextBrain: { _, _ in .failure("unused") })])
        let context = ToolContext(projectRoot: root)
        _ = await registry.execute(name: "research_run", arguments: [
            "action": "start", "goal": "primary", "run_id": "timeout-fetch",
        ], context: context)
        let result = await registry.execute(name: "research_run", arguments: [
            "action": "fetch", "run_id": "timeout-fetch", "url": "https://docs.example.com",
        ], context: context)

        XCTAssertFalse(result.success)
        XCTAssertTrue(ResearchEvidencePolicy.verifiedPrimarySources(
            in: ResearchRunStore.loadEvidence(projectRoot: root, runID: "timeout-fetch")).isEmpty)
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
