import XCTest
@testable import AgentCore

/// The offline COBOL specialist tool (Phase D, 2026-08-07): a strong agent calls this to get COBOL
/// from the local cobol-jeeves model, since that model writes COBOL but can't drive the agent loop.
final class CobolGenerateToolTests: XCTestCase {

    func testMetadataAndContract() {
        let tool = CobolGenerateTool(providers: ProviderRegistry(providers: ProviderCatalog.all,
                                                                 keyStore: NullKeyStoreForCobolTool()))
        XCTAssertEqual(tool.name, "cobol_generate")
        XCTAssertTrue(tool.description.lowercased().contains("cobol"))
        XCTAssertTrue(tool.description.lowercased().contains("offline"))
        XCTAssertTrue(tool.parameters.contains { $0.name == "request" && $0.required })
        XCTAssertTrue(tool.parameters.contains { $0.name == "existing" && !$0.required })
    }

    // Phase 1 (self-verify): an `expect` param + a bounded self-heal loop that compiles/runs and
    // REFUSES to succeed on broken or wrong COBOL.
    func testHasOptionalExpectParam() {
        let tool = CobolGenerateTool(providers: ProviderRegistry(providers: ProviderCatalog.all,
                                                                 keyStore: NullKeyStoreForCobolTool()))
        XCTAssertTrue(tool.parameters.contains { $0.name == "expect" && !$0.required })
        XCTAssertEqual(CobolGenerateTool.maxAttempts, 3, "original + two self-heals, bounded cost")
    }

    func testMissingCompilerFailsBeforeGenerationOrMutation() async throws {
        let root = try temporaryRoot()
        let calls = CobolToolCallCounter()
        let tool = makeTool(environment: [:], command: { _, _ in
            .failure("cobc executable not found")
        }, source: { _, _, _, _ in
            calls.increment(); return "IDENTIFICATION DIVISION."
        })
        let result = try await tool.execute(arguments: ["request": "hello", "path": "hello.cbl"],
                                            context: ToolContext(projectRoot: root.path))
        XCTAssertFalse(result.success)
        XCTAssertEqual(calls.value, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hello.cbl").path))
        XCTAssertEqual(result.metadata["compiled"], "false")
    }

    func testSourceOnlyGenerationHasConcreteLocalProvenanceAndDoesNotRunCommands() async throws {
        let calls = CobolToolCallCounter()
        let source = "IDENTIFICATION DIVISION.\nPROGRAM-ID. HELLO.\nSTOP RUN."
        let tool = makeTool(environment: [:], command: { _, _ in
            calls.increment(); return .failure("must not run")
        }, source: { _, _, _, _ in source })
        let result = try await tool.execute(arguments: ["request": "hello"],
                                            context: ToolContext(projectRoot: NSTemporaryDirectory()))
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output, source)
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(result.metadata["provider"], "cobol")
        XCTAssertEqual(result.metadata["model"], "cobol-jeeves-ft:latest")
        XCTAssertEqual(result.metadata["offline"], "true")
        XCTAssertEqual(result.metadata["endpoint"], "http://127.0.0.1:11434")
        XCTAssertNotNil(result.metadata["source_sha256"])
        XCTAssertEqual(result.metadata["compiled"], "false")
        XCTAssertEqual(result.metadata["ran"], "false")
        XCTAssertEqual(result.metadata["expect_met"], "false")
        XCTAssertEqual(result.metadata["verification_eligible"], "false")
    }

    func testRuntimeExpectedTextWithNonzeroExitIsRejected() async throws {
        let root = try temporaryRoot()
        let tool = makeTool(environment: [:], command: { command, _ in
            if command.arguments == ["--version"] { return self.commandResult(stdout: "cobc 3") }
            if command.executable == "cobc" { return self.commandResult() }
            return self.commandResult(success: false, exitCode: 7, stdout: "EXPECTED")
        }, source: { _, _, _, _ in "IDENTIFICATION DIVISION.\nPROGRAM-ID. X.\nSTOP RUN." })
        let result = try await tool.execute(arguments: ["request": "x", "path": "x.cbl", "expect": "EXPECTED"],
                                            context: ToolContext(projectRoot: root.path))
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.metadata["ran"], "false")
        XCTAssertEqual(result.metadata["expect_met"], "false")
    }

    func testExpectationOnStderrOrTruncatedOutputIsRejected() {
        var stderrOnly = commandResult(stdout: "", stderr: "EXPECTED")
        XCTAssertNotNil(CobolGenerateTool.governedCommandIssue(stderrOnly, expectedStdout: "EXPECTED"))
        var metadata = stderrOnly.metadata
        metadata["stdout"] = "EXPECTED"
        metadata["output_truncated"] = "true"
        stderrOnly = ToolResult(success: true, output: "EXPECTED", metadata: metadata)
        XCTAssertNotNil(CobolGenerateTool.governedCommandIssue(stderrOnly, expectedStdout: "EXPECTED"))
    }

    func testRemoteAndHostnameOllamaEndpointsAreRejectedBeforeGeneration() async throws {
        for endpoint in ["http://localhost:11434", "http://192.168.1.2:11434",
                         "http://user@127.0.0.1:11434", "http://127.0.0.1:11434/api",
                         "http://127.0.0.1:11434?q=1"] {
            let calls = CobolToolCallCounter()
            let tool = makeTool(environment: ["OLLAMA_HOST": endpoint], command: { _, _ in
                calls.increment(); return self.commandResult()
            }, source: { _, _, _, _ in calls.increment(); return "COBOL" })
            let result = try await tool.execute(arguments: ["request": "x"],
                                                context: ToolContext(projectRoot: NSTemporaryDirectory()))
            XCTAssertFalse(result.success, endpoint)
            XCTAssertEqual(calls.value, 0, endpoint)
        }
        XCTAssertEqual(OllamaProvider.cobol().endpoint, "http://127.0.0.1:11434/api/chat")
    }

    func testHasOptionalPathParam() {
        let tool = CobolGenerateTool(providers: ProviderRegistry(providers: ProviderCatalog.all,
                                                                 keyStore: NullKeyStoreForCobolTool()))
        XCTAssertTrue(tool.parameters.contains { $0.name == "path" && !$0.required },
                      "an optional path lets the tool PERSIST the COBOL so the artifact can't be fabricated")
    }

    func testPathWriteAndSuccessfulRunCarryTruthfulVerificationMetadata() async throws {
        let root = try temporaryRoot()
        let tool = makeTool(environment: ["OLLAMA_HOST": "http://[::1]:11434"], command: { command, _ in
            command.executable == "cobc" ? self.commandResult(stdout: "compiled")
                : self.commandResult(stdout: "EXPECTED\n")
        }, source: { _, _, _, _ in "IDENTIFICATION DIVISION.\nPROGRAM-ID. X.\nSTOP RUN." })
        let result = try await tool.execute(arguments: ["request": "x", "path": "x.cbl", "expect": "EXPECTED"],
                                            context: ToolContext(projectRoot: root.path))
        XCTAssertTrue(result.success, result.error ?? result.output)
        XCTAssertEqual(result.metadata["endpoint"], "http://[::1]:11434")
        XCTAssertEqual(result.metadata["compiled"], "true")
        XCTAssertEqual(result.metadata["ran"], "true")
        XCTAssertEqual(result.metadata["expect_met"], "true")
        XCTAssertEqual(result.metadata["sandboxed"], "true")
        XCTAssertEqual(result.metadata["verification_eligible"], "true")
    }

    func testMissingRequestFailsClearly() async throws {
        let tool = CobolGenerateTool(providers: ProviderRegistry(providers: ProviderCatalog.all,
                                                                 keyStore: NullKeyStoreForCobolTool()))
        let r = try await tool.execute(arguments: [:], context: ToolContext(projectRoot: NSTemporaryDirectory()))
        XCTAssertFalse(r.success)
        XCTAssertTrue((r.error ?? r.output).contains("request"))
    }

    // Fence-stripping: the model is told not to fence, but small models sometimes do.
    func testStripCodeFences() {
        let fenced = "```cobol\nIDENTIFICATION DIVISION.\nPROGRAM-ID. HELLO.\n```"
        let out = CobolGenerateTool.stripCodeFences(fenced)
        XCTAssertTrue(out.contains("IDENTIFICATION DIVISION."))
        XCTAssertFalse(out.contains("```"))
        XCTAssertFalse(out.contains("cobol\n"), "the language tag line must be dropped")
        // No fences → unchanged.
        let plain = "IDENTIFICATION DIVISION.\nSTOP RUN."
        XCTAssertEqual(CobolGenerateTool.stripCodeFences(plain), plain)
    }

    // Pins the specialist stays OFFLINE — it must target the `cobol` provider and never fall back to cloud.
    func testTargetsCobolProviderNoFallback() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: repo.appendingPathComponent("Sources/AgentCore/Tools/CobolGenerateTool.swift"),
                             encoding: .utf8)
        XCTAssertTrue(src.contains("providerId: \"cobol\""), "must call the offline cobol provider")
        XCTAssertTrue(src.contains("allowFallback: false"), "must NOT silently fall back to a cloud model")
    }

    // Source pin: it's registered in the default tool set so a driving agent can actually call it.
    func testRegisteredInToolSet() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: repo.appendingPathComponent("Sources/Kist/KistRunner+Tools.swift"),
                             encoding: .utf8)
        XCTAssertTrue(src.contains("CobolGenerateTool(providers: registry)"),
                      "the COBOL specialist tool must be wired into the agent's tool set")
    }

    private func makeTool(environment: [String: String],
                          command: @escaping CobolGenerateTool.CommandExecutor,
                          source: @escaping CobolGenerateTool.SourceGenerator) -> CobolGenerateTool {
        CobolGenerateTool(providers: ProviderRegistry(providers: ProviderCatalog.all,
                                                       keyStore: NullKeyStoreForCobolTool()),
                          environment: { environment }, commandExecutor: command,
                          sourceGenerator: source)
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cobol-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func commandResult(success: Bool = true, exitCode: Int = 0,
                               stdout: String = "", stderr: String = "") -> ToolResult {
        ToolResult(success: success, output: stdout + stderr,
                   error: success ? nil : "exit \(exitCode)", metadata: [
                    "sandboxed": "true", "timed_out": "false", "was_signalled": "false",
                    "stdout_truncated": "false", "stderr_truncated": "false",
                    "output_truncated": "false", "verification_eligible": success && exitCode == 0 ? "true" : "false",
                    "exit_code": String(exitCode), "stdout": stdout, "stderr": stderr,
                   ])
    }
}

private final class CobolToolCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private struct NullKeyStoreForCobolTool: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}
