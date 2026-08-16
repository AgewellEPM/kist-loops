import XCTest
@testable import AgentCore

final class RunCommandStructuredInputTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "run-command-structured-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let fixture = "#!/bin/sh\nprintf 'fixture-output\\n'\nexit 1\n"
        try fixture.write(toFile: root + "/exit-one", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: root + "/exit-one")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func context() -> ToolContext {
        ToolContext(projectRoot: root,
                    shell: ShellPolicy(enabled: true, autoApprove: true))
    }

    func testStdinIsPassedByteForByteWithoutShellInterpretation() async throws {
        let payload = "$(touch should-not-exist); `uname`; a|b && c > escaped\nline-two\u{0}tail"
        let result = try await RunCommandTool().execute(arguments: [
            "executable": "/bin/cat",
            "args": [],
            "stdin": payload,
        ], context: context())

        XCTAssertTrue(result.success, result.error ?? result.output)
        XCTAssertEqual(result.output, payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/should-not-exist"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/escaped"))
    }

    func testExplicitlyAllowedExitOneSucceedsAndReturnsOutput() async throws {
        let result = try await RunCommandTool().execute(arguments: [
            "executable": "./exit-one",
            "allowed_exit_codes": [1],
        ], context: context())

        XCTAssertTrue(result.success, result.error ?? result.output)
        XCTAssertEqual(result.metadata["exit_code"], "1")
        XCTAssertEqual(result.metadata["semantic_status"], "expected_domain_status")
        XCTAssertEqual(result.metadata["verification_eligible"], "false")
        XCTAssertEqual(result.metadata["sandboxed"], "true")
        XCTAssertEqual(result.metadata["stdout_truncated"], "false")
        XCTAssertEqual(result.metadata["stderr_truncated"], "false")
        XCTAssertEqual(result.metadata["output_truncated"], "false")
        XCTAssertTrue(result.output.contains("fixture-output"))

        let effect = ToolEffectCatalog.observe(
            tool: "run_command",
            arguments: ["executable": "swift", "args": ["test"], "allowed_exit_codes": [1]],
            outcomeMetadata: result.metadata)
        XCTAssertEqual(effect.verification, .nonVerifyingCommand)
    }

    func testDefaultExitPolicyFailsButPreservesOutputAndStreams() async throws {
        let result = try await RunCommandTool().execute(arguments: [
            "executable": "./exit-one",
        ], context: context())

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.metadata["exit_code"], "1")
        XCTAssertEqual(result.metadata["stdout"], "fixture-output\n")
        XCTAssertEqual(result.metadata["stderr"], "")
        XCTAssertTrue(result.output.contains("fixture-output"))
    }

    func testHighLevelExecutionExposesTruncationMetadata() async throws {
        let result = try await RunCommandTool().execute(arguments: [
            "executable": "/usr/bin/yes",
            "args": ["kist"],
            "timeout": 10,
        ], context: context())

        XCTAssertEqual(result.metadata["sandboxed"], "true")
        XCTAssertEqual(result.metadata["stdout_truncated"], "true")
        XCTAssertEqual(result.metadata["stderr_truncated"], "false")
        XCTAssertEqual(result.metadata["output_truncated"], "true")
    }

    #if canImport(Darwin)
    func testHighLevelExecutionReportsAppliedSandbox() async throws {
        let confined = ToolContext(
            projectRoot: root,
            shell: ShellPolicy(enabled: true, autoApprove: true),
            sandbox: .confined())
        let result = try await RunCommandTool().execute(arguments: [
            "executable": "/bin/cat",
            "args": [],
            "stdin": "sandbox-proof",
        ], context: confined)

        XCTAssertTrue(result.success, result.error ?? result.output)
        XCTAssertEqual(result.metadata["sandboxed"], "true")
        XCTAssertEqual(result.metadata["output_truncated"], "false")
    }
    #endif

    func testMalformedStructuredFieldsFailClosed() async throws {
        let cases: [[String: Any]] = [
            ["executable": "/bin/cat", "working_directory": "."],
            ["executable": "/bin/cat", "args": "not-an-array"],
            ["executable": "/bin/cat", "stdin": true],
            ["executable": "/bin/cat", "stdin": String(repeating: "x", count: RunCommandTool.maxStdinBytes + 1)],
            ["executable": "/bin/cat", "allowed_exit_codes": []],
            ["executable": "/bin/cat", "allowed_exit_codes": [0, 0]],
            ["executable": "/bin/cat", "allowed_exit_codes": [-1]],
            ["executable": "/bin/cat", "allowed_exit_codes": [256]],
            ["executable": "/bin/cat", "allowed_exit_codes": ["0"]],
            ["executable": "/bin/cat", "allowed_exit_codes": [0], "background": true],
            ["executable": "/bin/cat", "stdin": "x", "background": true],
        ]

        for arguments in cases {
            let result = try await RunCommandTool().execute(arguments: arguments, context: context())
            XCTAssertFalse(result.success, "unexpected acceptance: \(arguments)")
        }
    }
}
