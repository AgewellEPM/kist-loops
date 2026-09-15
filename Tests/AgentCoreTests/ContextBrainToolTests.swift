import XCTest
@testable import AgentCore

final class ContextBrainToolTests: XCTestCase {
    private func makeRoot() throws -> String {
        let raw = NSTemporaryDirectory() + "context-brain-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        return ToolContext.canonicalize(raw)!
    }

    private func write(_ root: String, _ path: String, _ text: String) throws {
        let full = root + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: true, encoding: .utf8)
    }

    func testIndexSearchGetAndCoverage() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root, "Sources/App.swift", """
        struct ReplayLedger {
            func appendSafely() {}
        }
        """)
        try write(root, "Tests/AppTests.swift", "func testReplayLedger() {}\n")
        try write(root, ".build/generated.swift", "let ignored = true\n")
        try write(root, "Library/Mobile Documents/generated.swift", "let privateAppState = true\n")
        try write(root, ".cache/toolchain/generated.swift", "let cachedToolchain = true\n")
        try write(root, ".android/sdk/generated.swift", "let downloadedSDK = true\n")
        try Data([0, 159, 255]).write(to: URL(fileURLWithPath: root + "/asset.bin"))

        let tool = ContextBrainTool()
        let context = ToolContext(projectRoot: root)

        let index = try await tool.execute(arguments: ["action": "index", "chunk_chars": 40], context: context)
        XCTAssertTrue(index.success, index.error ?? "")
        XCTAssertTrue(index.output.contains("Sources/App.swift"))
        XCTAssertTrue(index.output.contains("Tests/AppTests.swift"))
        XCTAssertTrue(index.output.contains("asset.bin"))
        XCTAssertFalse(index.output.contains(".build/generated.swift"))
        XCTAssertFalse(index.output.contains("Library/Mobile Documents/generated.swift"))
        XCTAssertFalse(index.output.contains(".cache/toolchain/generated.swift"))
        XCTAssertFalse(index.output.contains(".android/sdk/generated.swift"))

        let search = try await tool.execute(arguments: ["action": "search", "query": "ReplayLedger"], context: context)
        XCTAssertTrue(search.success, search.error ?? "")
        XCTAssertTrue(search.output.contains("Sources/App.swift:L1-"))

        let get = try await tool.execute(arguments: [
            "action": "get",
            "id": "Sources/App.swift:L1-L3",
        ], context: context)
        XCTAssertTrue(get.success, get.error ?? "")
        XCTAssertTrue(get.output.contains("struct ReplayLedger"))

        let coverage = try await tool.execute(arguments: ["action": "coverage", "max_chars": 80, "chunk_chars": 40],
                                              context: context)
        XCTAssertTrue(coverage.success, coverage.error ?? "")
        XCTAssertTrue(coverage.output.contains("Batch 1"))
        XCTAssertTrue(coverage.output.contains("Sources/App.swift"))
        XCTAssertTrue(coverage.output.contains("Metadata-only files"))
    }

    func testIndexAndSignatureFailClosedAtWalkEntryBudget() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for index in 0..<8 {
            try write(root, "Sources/File\(index).swift", "let value\(index) = \(index)\n")
        }

        XCTAssertThrowsError(try ContextBrainIndex.build(
            root: root, maxWalkEntries: 4, skipDirectories: [])) { error in
            XCTAssertTrue(String(describing: error).contains("entry budget exceeded"))
        }
        XCTAssertThrowsError(try ContextBrainIndex.sourceSignature(
            root: root, maxWalkEntries: 4, skipDirectories: [])) { error in
            XCTAssertTrue(String(describing: error).contains("entry budget exceeded"))
        }
    }

    func testGetRequiresChunkIdFromCurrentIndex() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root, "Sources/App.swift", "line one\nline two\nline three\n")

        let result = try await ContextBrainTool().execute(arguments: [
            "action": "get",
            "id": "Sources/App.swift:L1-L999",
        ], context: ToolContext(projectRoot: root))

        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("not in the current context index"), result.error ?? "")
    }

    func testSearchRanksCompleteEvidenceAndShowsItsMatchingPassage() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root, "noise.txt", String(repeating: "provider ", count: 500))
        try write(root, "Sources/Events.swift", String(repeating: "// routine setup\n", count: 80)
                  + "func providerAttemptReplayCanary() {}\n")
        let result = try await ContextBrainTool().execute(arguments: [
            "action": "search", "query": "provider attempt replay", "limit": 1
        ], context: ToolContext(projectRoot: root))
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Sources/Events.swift:L1-"), result.output)
        XCTAssertTrue(result.output.contains("providerAttemptReplayCanary"), result.output)
        XCTAssertFalse(result.output.contains("noise.txt"), result.output)
    }

    func testCacheInvalidatesWhenSourceTreeChanges() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root, "Sources/App.swift", "let staleMarker = true\n")

        let tool = ContextBrainTool()
        let context = ToolContext(projectRoot: root)
        let stale = try await tool.execute(arguments: [
            "action": "search",
            "query": "staleMarker",
        ], context: context)
        XCTAssertTrue(stale.success, stale.error ?? "")
        XCTAssertTrue(stale.output.contains("staleMarker"))

        try write(root, "Sources/App.swift", "let freshMarkerWithDifferentSize = true\n")
        let fresh = try await tool.execute(arguments: [
            "action": "search",
            "query": "freshMarkerWithDifferentSize",
        ], context: context)
        XCTAssertTrue(fresh.success, fresh.error ?? "")
        XCTAssertTrue(fresh.output.contains("freshMarkerWithDifferentSize"))
    }

    func testOversizedFilesStayMetadataOnly() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root, "huge.txt", String(repeating: "needle ", count: 400))

        let tool = ContextBrainTool()
        let context = ToolContext(projectRoot: root)
        let index = try await tool.execute(arguments: [
            "action": "index",
            "max_file_bytes": 1000,
        ], context: context)
        XCTAssertTrue(index.success, index.error ?? "")
        XCTAssertTrue(index.output.contains("huge.txt"))
        XCTAssertTrue(index.output.contains("too_large_for_inline_index"))

        let search = try await tool.execute(arguments: [
            "action": "search",
            "query": "needle",
            "max_file_bytes": 1000,
        ], context: context)
        XCTAssertTrue(search.success, search.error ?? "")
        XCTAssertTrue(search.output.contains("No context chunks matched query"))

        let get = try await tool.execute(arguments: [
            "action": "get",
            "path": "huge.txt",
            "max_file_bytes": 1000,
        ], context: context)
        XCTAssertFalse(get.success)
        XCTAssertTrue((get.error ?? "").contains("too_large_for_inline_index"), get.error ?? "")
    }

    func testAggregateIndexBudgetKeepsLaterFilesMetadataOnly() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root, "a.txt", "alphaMarker " + String(repeating: "a", count: 590))
        try write(root, "b.txt", "betaMarker " + String(repeating: "b", count: 590))

        let tool = ContextBrainTool()
        let context = ToolContext(projectRoot: root)
        let index = try await tool.execute(arguments: [
            "action": "index",
            "max_total_bytes": 1_000,
        ], context: context)
        XCTAssertTrue(index.success, index.error ?? "")
        XCTAssertTrue(index.output.contains("a.txt"))
        XCTAssertTrue(index.output.contains("b.txt"))
        XCTAssertTrue(index.output.contains("index_total_byte_budget_exceeded"))

        let alpha = try await tool.execute(arguments: [
            "action": "search",
            "query": "alphaMarker",
            "max_total_bytes": 1_000,
        ], context: context)
        XCTAssertTrue(alpha.success, alpha.error ?? "")
        XCTAssertTrue(alpha.output.contains("a.txt"))

        let beta = try await tool.execute(arguments: [
            "action": "search",
            "query": "betaMarker",
            "max_total_bytes": 1_000,
        ], context: context)
        XCTAssertTrue(beta.success, beta.error ?? "")
        XCTAssertTrue(beta.output.contains("No context chunks matched query"))
    }

    func testSymlinkedFilesAndDirectoriesAreNotIndexedOrLeaked() async throws {
        let root = try makeRoot()
        let external = NSTemporaryDirectory() + "context-brain-external-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: external, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: external)
        }
        try write(root, "real.txt", "ordinary project text")
        try "externalSecretMarker".write(toFile: external + "/secret.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root + "/link-file.txt",
                                                   withDestinationPath: external + "/secret.txt")
        try FileManager.default.createSymbolicLink(atPath: root + "/link-dir",
                                                   withDestinationPath: external)

        let tool = ContextBrainTool()
        let context = ToolContext(projectRoot: root)
        let index = try await tool.execute(arguments: ["action": "index"], context: context)
        XCTAssertTrue(index.success, index.error ?? "")
        XCTAssertTrue(index.output.contains("real.txt"))
        XCTAssertFalse(index.output.contains("link-file.txt"))
        XCTAssertFalse(index.output.contains("link-dir"))
        XCTAssertFalse(index.output.contains("externalSecretMarker"))

        let search = try await tool.execute(arguments: [
            "action": "search",
            "query": "externalSecretMarker",
        ], context: context)
        XCTAssertTrue(search.success, search.error ?? "")
        XCTAssertTrue(search.output.contains("No context chunks matched query"))

        let get = try await tool.execute(arguments: [
            "action": "get",
            "path": "link-file.txt",
        ], context: context)
        XCTAssertFalse(get.success)
        XCTAssertTrue((get.error ?? "").contains("not in the current context index"), get.error ?? "")
    }

    func testCoverageListsEveryChunkInBatch() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for idx in 0..<45 {
            let suffix = String(format: "%02d", idx)
            try write(root, "Sources/File\(suffix).swift", "let value\(suffix) = \(idx)")
        }

        let coverage = try await ContextBrainTool().execute(arguments: [
            "action": "coverage",
            "max_chars": 200_000,
        ], context: ToolContext(projectRoot: root))

        XCTAssertTrue(coverage.success, coverage.error ?? "")
        XCTAssertTrue(coverage.output.contains("Batch 1 · 45 chunk(s)"))
        XCTAssertTrue(coverage.output.contains("Sources/File00.swift:L1-L1"))
        XCTAssertTrue(coverage.output.contains("Sources/File44.swift:L1-L1"))
        XCTAssertTrue(coverage.output.contains(#"get: context_brain(action="get", id="Sources/File44.swift:L1-L1")"#))
        XCTAssertTrue(coverage.output.contains("VERIFICATION: 1 batch(es), 45 retrievable chunk(s)"))
        XCTAssertTrue(coverage.output.contains("This coverage output is only the plan"))
        XCTAssertFalse(coverage.output.contains("more chunk(s) in this batch"))
    }

    func testContextBrainIsReadOnlyAcrossSafetyGates() async {
        XCTAssertEqual(ReversibilityClassifier.assess(tool: "context_brain",
                                                      args: ["action": "index"],
                                                      projectRoot: NSTemporaryDirectory()), .safe)

        let decision = AuthorizationScopeEngine.evaluate("diagnose why my server has high latency")
        XCTAssertEqual(decision.gate, .planOnly)
        let registry = ToolRegistry([NoopContextTool(name: "context_brain")])
        let result = await registry.execute(name: "context_brain", arguments: ["action": "index"],
                                            context: ToolContext(projectRoot: NSTemporaryDirectory(),
                                                                 authorizationScope: decision))
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertTrue(HeadlessAgentLoop.readOnlyTools.contains("context_brain"))
    }

    func testToolContractAdvertisesContextBrainForLargeContextWork() {
        let contract = ToolContractBook.render(tools: ToolRegistry([ContextBrainTool()]))
        XCTAssertTrue(contract.contains("Context/RAG"))
        XCTAssertTrue(contract.contains("context_brain"))
        XCTAssertTrue(contract.contains("coverage"))
        XCTAssertTrue(contract.contains("hot-load"))
    }
}

private struct NoopContextTool: AgentTool {
    let name: String
    var description: String { "noop context tool" }
    var parameters: [ToolParameter] { [] }
    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        ToolResult(success: true, output: "ok")
    }
}
