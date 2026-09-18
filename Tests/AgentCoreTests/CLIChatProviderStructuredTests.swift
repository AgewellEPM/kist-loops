import XCTest
@testable import AgentCore

final class CLIChatProviderStructuredTests: XCTestCase {
    private let schema = #"{"type":"object","additionalProperties":false,"required":["name"],"properties":{"name":{"type":"string"}}}"#

    func testClaudeArgumentsCarryCanonicalSchemaWithoutChangingTextArguments() throws {
        let provider = CLIChatProvider.claudeCode()
        let base = provider.argsForModel("sonnet")
        XCTAssertEqual(base[base.firstIndex(of: "--output-format")! + 1], "text")
        XCTAssertFalse(base.contains("--json-schema"))

        let canonical = try XCTUnwrap(CLIChatProvider.canonicalSchema(schema))
        let arguments = try CLIChatProvider.structuredArguments(
            providerID: provider.id, baseArguments: base,
            canonicalSchema: canonical, schemaPath: nil, resultPath: nil)
        let format = try XCTUnwrap(arguments.firstIndex(of: "--output-format"))
        let schemaFlag = try XCTUnwrap(arguments.firstIndex(of: "--json-schema"))
        XCTAssertEqual(arguments[format + 1], "json")
        XCTAssertEqual(arguments[schemaFlag + 1], canonical)
        XCTAssertEqual(arguments.filter { $0 == "--json-schema" }.count, 1)
    }

    func testClaudeParsesOnlySuccessfulStructuredEnvelopeAndAccountsUsage() throws {
        let raw = #"{"type":"result","subtype":"success","is_error":false,"result":"ignored prose","usage":{"input_tokens":4,"cache_creation_input_tokens":5,"cache_read_input_tokens":6,"output_tokens":7},"structured_output":{"name":"kist"}}"#
        let result = try CLIChatProvider.parseClaudeStructuredResult(raw)
        XCTAssertEqual(result.text, #"{"name":"kist"}"#)
        XCTAssertEqual(result.usage, TokenUsage(promptTokens: 15, completionTokens: 7))

        for invalid in [
            "```json\n\(raw)\n```",
            #"{"type":"result","subtype":"error","is_error":true,"structured_output":{"name":"bad"}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"not structured"}"#,
        ] {
            XCTAssertThrowsError(try CLIChatProvider.parseClaudeStructuredResult(invalid))
        }
    }

    func testClaudeFailureDiagnosticIsBoundedUsefulAndSecretFree() throws {
        let envelope: [String: Any] = [
            "type": "result",
            "subtype": "error_max_budget_usd",
            "is_error": true,
            "stop_reason": "tool_use",
            "result": "RAW_RESULT_SECRET",
            "prompt": "RAW_PROMPT_SECRET",
            "errors": [
                "Reached maximum budget; api_key=sk-live-supersecretvalue",
                ["code": "budget_exhausted", "message": String(repeating: "x", count: 5_000)],
                "third error must not be copied",
            ],
        ]
        let bytes = try JSONSerialization.data(withJSONObject: envelope)
        let raw = String(decoding: bytes, as: UTF8.self)

        XCTAssertThrowsError(try CLIChatProvider.parseClaudeStructuredResult(raw)) { error in
            guard let cli = error as? CLIProviderError,
                  case .invalidStructuredOutput(_, let detail) = cli else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("subtype=error_max_budget_usd"))
            XCTAssertTrue(detail.contains("is_error=true"))
            XCTAssertTrue(detail.contains("stop_reason=tool_use"))
            XCTAssertTrue(detail.contains("Reached maximum budget"))
            XCTAssertTrue(detail.contains("[REDACTED]"))
            XCTAssertLessThanOrEqual(detail.utf8.count, 768)
            XCTAssertFalse(detail.contains("supersecretvalue"))
            XCTAssertFalse(detail.contains("RAW_RESULT_SECRET"))
            XCTAssertFalse(detail.contains("RAW_PROMPT_SECRET"))
            XCTAssertFalse(detail.contains("third error"))
        }
    }

    func testCodexUsesPrivateSchemaAndFinalResponseFilesThenCleansThem() throws {
        let canonical = try XCTUnwrap(CLIChatProvider.canonicalSchema(schema))
        let files = try CLIStructuredRequestFiles(
            canonicalSchema: canonical, needsResultFile: true)
        let directory = files.directoryPath
        let schemaPath = files.schemaPath
        let resultPath = try XCTUnwrap(files.resultPath)
        defer { files.cleanup() }

        let schemaAttributes = try FileManager.default.attributesOfItem(atPath: schemaPath)
        XCTAssertEqual((schemaAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let provider = CLIChatProvider.codexCLI()
        let base = provider.argsForModel(provider.defaultModel)
        let arguments = try CLIChatProvider.structuredArguments(
            providerID: provider.id, baseArguments: base,
            canonicalSchema: canonical, schemaPath: schemaPath, resultPath: resultPath)
        let schemaFlag = try XCTUnwrap(arguments.firstIndex(of: "--output-schema"))
        let resultFlag = try XCTUnwrap(arguments.firstIndex(of: "--output-last-message"))
        XCTAssertEqual(arguments[schemaFlag + 1], schemaPath)
        XCTAssertEqual(arguments[resultFlag + 1], resultPath)
        XCTAssertTrue(arguments.contains("--json"))

        try Data(#"{"name":"kist"}"#.utf8).write(to: URL(fileURLWithPath: resultPath))
        let parsed = try CLIChatProvider.parseCodexStructuredResult(
            files.readResult(),
            eventOutput: """
            {"type":"item.completed","item":{"type":"agent_message","text":"IGNORE"}}
            {"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":3,"output_tokens":4}}
            """)
        XCTAssertEqual(parsed.text, #"{"name":"kist"}"#)
        XCTAssertEqual(parsed.usage, TokenUsage(promptTokens: 10, completionTokens: 4))

        files.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: schemaPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resultPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
    }

    func testCodexFinalResponseRejectsEventJSONLAndProse() throws {
        XCTAssertThrowsError(try CLIChatProvider.parseCodexStructuredResult(
            Data("{\"type\":\"item.completed\"}\n{\"name\":\"wrong\"}".utf8),
            eventOutput: ""))
        XCTAssertThrowsError(try CLIChatProvider.parseCodexStructuredResult(
            Data("Here is JSON: {\"name\":\"wrong\"}".utf8), eventOutput: ""))
    }

    func testCodexTextEventsPreserveSourceBytesAndCountCachedTokensOnce() throws {
        let source = "    first\nsecond\n"
        let message: [String: Any] = ["type": "item.completed", "item": [
            "type": "agent_message", "text": source]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        let events = line + "\n" + #"{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"output_tokens":122,"reasoning_output_tokens":100}}"#
        let result = try CLIChatProvider.parseCodexTextResult(events)
        XCTAssertEqual(result.text, source)
        XCTAssertTrue(result.usageReported)
        XCTAssertEqual(result.usage, TokenUsage(promptTokens: 24763, completionTokens: 122))
        XCTAssertThrowsError(try CLIChatProvider.parseCodexTextResult(line))
        XCTAssertThrowsError(try CLIChatProvider.parseCodexTextResult(events + "\n" + #"{"type":"turn.failed"}"#))
        XCTAssertThrowsError(try CLIChatProvider.parseCodexTextResult("untyped prose"))
        let missingUsage = try CLIChatProvider.parseCodexTextResult(
            line + "\n" + #"{"type":"turn.completed","usage":{}}"#)
        XCTAssertFalse(missingUsage.usageReported)
    }

    func testCodexExitDiagnosticUsesTypedErrorInsteadOfStdinBanner() {
        let diagnostic = CLIChatProvider.processFailureDiagnostic(
            stdout: #"{"type":"turn.failed","error":{"message":"Rate limit exceeded; api_key=sk-live-abcdef123456789"}}"#,
            stderr: "Reading prompt from stdin...\n")
        XCTAssertTrue(diagnostic.contains("Rate limit exceeded"))
        XCTAssertFalse(diagnostic.contains("Reading prompt"))
        XCTAssertFalse(diagnostic.contains("abcdef123456789"))
        let unrelated = CLIChatProvider.processFailureDiagnostic(
            stdout: #"{"type":"item.completed","item":{"type":"agent_message","text":"DO NOT COPY"}}"#,
            stderr: "actual process error")
        XCTAssertEqual(unrelated, "actual process error")
    }

    func testCLIProcessTimeoutAndCancellationTearDownTheProcessGroup() async throws {
        let started = Date()
        XCTAssertThrowsError(try CLIChatProvider.runToCompletion(
            binaryName: "/bin/sh", args: ["-c", "sleep 10"], stdin: "",
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp"],
            timeoutSeconds: 1, outputByteLimit: 1024)) { error in
            guard case CLIProviderError.timedOut = error else {
                return XCTFail("unexpected timeout error: \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        let flag = CancellationFlag()
        let cancellation = Task.detached { () throws -> String in
            try CLIChatProvider.runToCompletion(
                binaryName: "/bin/sh", args: ["-c", "sleep 10"], stdin: "",
                environment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp"],
                timeoutSeconds: 30, outputByteLimit: 1024,
                cancellationCheck: { flag.value })
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        flag.cancel()
        do {
            _ = try await cancellation.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
