import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import AgentCore

final class RunCommandStdinPathTests: XCTestCase {
    private var root = ""
    private var external = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "run-command-stdin-path-\(UUID().uuidString)"
        external = NSTemporaryDirectory() + "run-command-stdin-external-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/fixtures", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: external, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: external)
    }

    private func context() -> ToolContext {
        ToolContext(projectRoot: root, shell: ShellPolicy(enabled: true, autoApprove: true))
    }

    private func write(_ data: Data, _ relativePath: String = "fixtures/valid.ndjson") throws {
        let path = root + "/" + relativePath
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    }

    func testGovernedPathPassesExactBytesWithoutShellAndRecordsOnlyRelativeEvidence() async throws {
        let payload = Data("{\"value\":\"$(touch pwned); a|b && c > escaped\"}\nnext\u{0}tail".utf8)
        try write(payload)

        let result = try await RunCommandTool().execute(arguments: [
            "executable": "/bin/cat",
            "args": [],
            "stdin_path": "fixtures/valid.ndjson",
        ], context: context())

        XCTAssertTrue(result.success, result.error ?? result.output)
        XCTAssertEqual(Data(result.output.utf8), payload)
        XCTAssertEqual(result.metadata["stdin_source_kind"], "governed_path")
        XCTAssertEqual(result.metadata["stdin_relative_path"], "fixtures/valid.ndjson")
        XCTAssertEqual(result.metadata["stdin_byte_count"], String(payload.count))
        XCTAssertEqual(result.metadata["stdin_sha256"], RunCommandTool.sha256(payload))
        XCTAssertFalse(result.metadata.values.contains(where: { $0.contains(root) }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/pwned"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/escaped"))
    }

    func testPathIsRelativeToStructuredCWDAndReceiptPathIsProjectRelative() async throws {
        let payload = Data("{\"ok\":true}\n".utf8)
        try write(payload, "sub/fixtures/valid.ndjson")
        let result = try await RunCommandTool().execute(arguments: [
            "executable": "/bin/cat", "args": [], "cwd": "sub",
            "stdin_path": "fixtures/valid.ndjson",
        ], context: context())

        XCTAssertTrue(result.success, result.error ?? result.output)
        XCTAssertEqual(result.metadata["stdin_relative_path"], "sub/fixtures/valid.ndjson")
        XCTAssertEqual(Data(result.output.utf8), payload)
    }

    func testTraversalAbsoluteMutualExclusionRawShellAndBackgroundFailClosed() async throws {
        try write(Data("x".utf8))
        let cases: [[String: Any]] = [
            ["executable": "/bin/cat", "stdin_path": "../outside"],
            ["executable": "/bin/cat", "stdin_path": external + "/outside"],
            ["executable": "/bin/cat", "stdin": "x", "stdin_path": "fixtures/valid.ndjson"],
            ["command": "cat", "shell": true, "stdin_path": "fixtures/valid.ndjson"],
            ["executable": "/bin/cat", "background": true, "stdin_path": "fixtures/valid.ndjson"],
        ]
        for arguments in cases {
            let result = try await RunCommandTool().execute(arguments: arguments, context: context())
            XCTAssertFalse(result.success, "unexpected acceptance: \(arguments)")
        }
    }

    func testSymlinkLeafAncestorAndSpecialFileAreRejected() async throws {
        try Data("outside".utf8).write(to: URL(fileURLWithPath: external + "/secret"))
        try FileManager.default.createSymbolicLink(
            atPath: root + "/fixtures/leaf-link", withDestinationPath: external + "/secret")
        try FileManager.default.createSymbolicLink(
            atPath: root + "/fixtures/dir-link", withDestinationPath: external)
        XCTAssertEqual(mkfifo(root + "/fixtures/pipe", 0o600), 0)

        for path in ["fixtures/leaf-link", "fixtures/dir-link/secret", "fixtures/pipe"] {
            let result = try await RunCommandTool().execute(arguments: [
                "executable": "/bin/cat", "stdin_path": path,
            ], context: context())
            XCTAssertFalse(result.success, "unexpected acceptance: \(path)")
        }
    }

    func testExactOneMiBCapAcceptedAndOneByteOverRejected() async throws {
        let atCap = Data(repeating: 0x78, count: RunCommandTool.maxStdinBytes)
        try write(atCap, "fixtures/at-cap")
        let accepted = try await RunCommandTool().execute(arguments: [
            "executable": "/usr/bin/wc", "args": ["-c"], "stdin_path": "fixtures/at-cap",
        ], context: context())
        XCTAssertTrue(accepted.success, accepted.error ?? accepted.output)
        XCTAssertEqual(accepted.metadata["stdin_byte_count"], String(RunCommandTool.maxStdinBytes))

        try write(Data(repeating: 0x79, count: RunCommandTool.maxStdinBytes + 1), "fixtures/over-cap")
        let rejected = try await RunCommandTool().execute(arguments: [
            "executable": "/usr/bin/wc", "args": ["-c"], "stdin_path": "fixtures/over-cap",
        ], context: context())
        XCTAssertFalse(rejected.success)
        XCTAssertTrue((rejected.error ?? rejected.output).contains("exceeds"))
    }

    func testChangedFixtureDigestRefusesBeforeProcessSpawn() async throws {
        let original = Data("{\"valid\":true}\n".utf8)
        try write(original)
        let marker = root + "/spawned"
        let consumer = "#!/bin/sh\ntouch \"\(marker)\"\ncat >/dev/null\n"
        try consumer.write(toFile: root + "/consumer", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/consumer")

        let first = try await RunCommandTool().execute(arguments: [
            "executable": "./consumer", "stdin_path": "fixtures/valid.ndjson",
        ], context: context())
        XCTAssertTrue(first.success, first.error ?? first.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
        try FileManager.default.removeItem(atPath: marker)
        try write(Data("{\"changed\":true}\n".utf8))

        let replay = try await RunCommandTool().execute(arguments: [
            "executable": "./consumer",
            "stdin_path": "fixtures/valid.ndjson",
            "expected_stdin_sha256": first.metadata["stdin_sha256"]!,
            "expected_stdin_byte_count": Int(first.metadata["stdin_byte_count"]!)!,
        ], context: context())
        XCTAssertFalse(replay.success)
        XCTAssertTrue((replay.error ?? replay.output).contains("changed since validation"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "digest mismatch must spawn nothing")
    }

    func testPersistedReplayRereadsGovernedPathAndRefusesChangedDigest() async throws {
        try write(Data("{\"original\":true}\n".utf8))
        let marker = root + "/durable-spawned"
        let consumer = "#!/bin/sh\ntouch \"\(marker)\"\ncat >/dev/null\n"
        try consumer.write(toFile: root + "/durable-consumer", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: root + "/durable-consumer")
        let arguments: [String: Any] = [
            "executable": "./durable-consumer", "args": [],
            "stdin_path": "fixtures/valid.ndjson", "allowed_exit_codes": [0],
        ]
        let tools = ToolRegistry([RunCommandTool()])
        let first = await tools.execute(name: "run_command", arguments: arguments, context: context())
        XCTAssertTrue(first.success, first.error ?? first.output)
        let source = try XCTUnwrap(PlanExecuteLoop.durableStandardInputSource(
            arguments: arguments, metadata: first.metadata))
        let capability = try XCTUnwrap(PlanExecuteLoop.replayCapabilityBinding(
            tool: "run_command", arguments: arguments, context: context(), tools: tools))
        let durableArguments = PlanExecuteLoop.durableCommandArguments(arguments, source: source)
        let canonical = PlanExecuteLoop.canonicalReceiptValue(durableArguments)
        let recipe = DurablePlanVerificationRecipe(
            id: "durable-path", sourcePlanID: "plan", stepID: "E1", tool: "run_command",
            resolvedExecutable: capability.resolvedExecutable, argv: [],
            workingDirectory: capability.workingDirectory, standardInputSource: source,
            allowedExitCodes: [0], canonicalArgumentsJSON: canonical,
            argsFingerprint: PlanExecuteLoop.commandFingerprint(arguments),
            commandFingerprint: PlanExecuteLoop.durableCommandFingerprint(
                tool: "run_command", canonicalArgumentsJSON: canonical, source: source),
            completionContractFingerprint: "completion", obligationsFingerprint: "obligations",
            executionPolicyFingerprint: "policy", workspaceManifestDigest: "manifest",
            proofWorkspaceDigest: "workspace", proofOutputDigest: "output", proofAt: Date(),
            capabilityFingerprint: capability.capabilityFingerprint,
            authorizationFingerprint: capability.authorizationFingerprint,
            toolSchemaFingerprint: capability.toolSchemaFingerprint,
            executableIdentity: capability.executableIdentity)
        let persisted = try JSONDecoder().decode(
            DurablePlanVerificationRecipe.self, from: JSONEncoder().encode(recipe))

        try FileManager.default.removeItem(atPath: marker)
        try write(Data("{\"changed\":true}\n".utf8))
        let decodedArguments = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(persisted.canonicalArgumentsJSON.utf8)) as? [String: Any])
        XCTAssertEqual(PlanExecuteLoop.canonicalReceiptValue(decodedArguments), persisted.canonicalArgumentsJSON)
        XCTAssertNil(RunCommandTool.argumentValidationIssue(decodedArguments, planPreflight: true))
        XCTAssertEqual(PlanExecuteLoop.commandFingerprint(decodedArguments), persisted.argsFingerprint)
        XCTAssertEqual(PlanExecuteLoop.durableCommandFingerprint(
            tool: persisted.tool, canonicalArgumentsJSON: persisted.canonicalArgumentsJSON,
            source: try XCTUnwrap(persisted.standardInputSource)), persisted.commandFingerprint)
        let restoredCapability = try XCTUnwrap(PlanExecuteLoop.replayCapabilityBinding(
            tool: persisted.tool, arguments: decodedArguments, context: context(), tools: tools))
        XCTAssertEqual(restoredCapability.capabilityFingerprint, persisted.capabilityFingerprint)
        XCTAssertEqual(restoredCapability.workingDirectory, persisted.workingDirectory)
        let replay = try XCTUnwrap(PlanExecuteLoop.restoreVerificationReplay(
            persisted, completionContractFingerprint: "completion",
            obligationsFingerprint: "obligations", executionPolicyFingerprint: "policy",
            workspaceManifestDigest: "manifest", context: context(), tools: tools))
        let refused = await tools.execute(
            name: replay.tool, arguments: replay.arguments, context: context())

        XCTAssertFalse(refused.success)
        XCTAssertTrue((refused.error ?? refused.output).contains("changed since validation"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker),
                       "persisted replay digest mismatch must spawn nothing")
    }

    func testAuthorizationDenialHappensBeforeStdinPathOpen() async throws {
        try Data("outside".utf8).write(to: URL(fileURLWithPath: external + "/secret"))
        try FileManager.default.createSymbolicLink(
            atPath: root + "/fixtures/would-fail-if-opened", withDestinationPath: external + "/secret")
        let scope = AuthorizationScopeEngine.evaluate("diagnose why my server has high latency")
        XCTAssertEqual(scope.gate, .planOnly)
        let gatedContext = ToolContext(
            projectRoot: root, shell: ShellPolicy(enabled: true, autoApprove: true),
            authorizationScope: scope)
        let result = await ToolRegistry([RunCommandTool()]).execute(
            name: "run_command",
            arguments: ["executable": "/bin/cat", "stdin_path": "fixtures/would-fail-if-opened"],
            context: gatedContext)

        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("authorization scope"), result.error ?? "")
        XCTAssertFalse((result.error ?? "").contains("path escapes"),
                       "a denied invocation must not reach confined file open")
    }

    func testExactLivePlanShapeConvergesOnManifestBackedStdinPath() throws {
        try write(Data("{\"valid\":true}\n".utf8))
        let arguments = """
        {"executable":"/bin/cat","args":[],"cwd":".","stdin_path":"fixtures/valid.ndjson","allowed_exit_codes":[0]}
        """
        let plan = ExecutablePlan(goal: "exercise valid stdin", steps: [
            PlanStep(id: "E3", intent: "exercise valid stdin", tool: "run_command",
                     argumentsJSON: arguments),
        ])
        let requirement = PlanExecuteLoop.FunctionalEvidenceRequirement(
            input: .standardInput, validity: .valid, expectedExitCode: 0,
            requiresLineNumberEvidence: false)

        XCTAssertEqual(PlanExecuteLoop.functionalEvidencePlanPreflight(
            [requirement], plan: plan, projectRoot: root), [])
    }
}
