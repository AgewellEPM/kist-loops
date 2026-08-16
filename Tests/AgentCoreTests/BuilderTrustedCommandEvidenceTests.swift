import Foundation
import XCTest
@testable import AgentCore

final class BuilderTrustedCommandEvidenceTests: XCTestCase {
    private let contractFingerprint = String(repeating: "a", count: 64)
    private let subjectDigest = String(repeating: "b", count: 64)
    private var root = ""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trusted-command-evidence-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func context(allow: Set<String> = []) -> ToolContext {
        ToolContext(
            projectRoot: root,
            shell: ShellPolicy(enabled: true, autoApprove: true, allow: allow))
    }

    private func binding(stage: BuilderExecutionStage = .verification) throws
        -> BuilderTrustedTelemetryBinding {
        try BuilderTrustedTelemetryBinding(
            contractFingerprint: contractFingerprint,
            nodeID: "trusted-command-test", attempt: 1, stage: stage)
    }

    private func receipt(
        reference: BuilderTrustedCommandReference,
        outputDigest: String? = nil,
        argsFingerprint: String? = nil
    ) -> BuilderCommandEvidenceReceipt {
        BuilderCommandEvidenceReceipt.boundPrehashed(
            tool: "run_command",
            verifierStatus: reference.exitCode == 0 ? .passed : .executed,
            exitCode: reference.exitCode,
            allowedExitCodes: "0",
            semanticStatus: reference.exitCode == 0 ? "clean_exit" : "failed",
            argsFingerprint: argsFingerprint ?? reference.gateArgumentsDigest,
            outputDigest: outputDigest ?? reference.stdoutDigest,
            boundedRedactedOutputExcerpt: "command output",
            subjectDigestAfter: subjectDigest,
            contractFingerprint: contractFingerprint,
            trustedCommandReference: reference)
    }

    func testRegistryRunCommandRetainsTrustedReferenceAcrossGCDTaskLocalLoss() async throws {
        let arguments: [String: Any] = [
            "executable": "/usr/bin/printf",
            "args": ["%s", "gcd-telemetry-ok"],
        ]
        let registry = ToolRegistry([RunCommandTool()])
        let context = context(allow: ["printf"])
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: try binding(), registerBudgetAuthority: false) {
                await registry.execute(name: "run_command", arguments: arguments, context: context)
            }
        let result = try captured.0.get()
        let reference = try XCTUnwrap(result.trustedCommandReference)
        let commands = captured.1.filter { $0.kind == .command }

        XCTAssertTrue(result.success, result.error ?? result.output)
        XCTAssertTrue(reference.isValid)
        XCTAssertNotNil(reference.effectiveEnvironmentDigest)
        XCTAssertNil(reference.sandboxProfileDigest)
        XCTAssertEqual(reference.gateArgumentsDigest, AuditLog.digest(arguments).1)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.commandReference, reference)
        XCTAssertTrue(BuilderTrustedTelemetry.commandEvidenceMatches(
            [receipt(reference: reference)], observations: captured.1,
            contractFingerprint: contractFingerprint, subjectDigest: subjectDigest))
    }

    func testPublicForgeryCannotCarryReferenceAndTamperedReferenceIsRejected() async throws {
        let arguments: [String: Any] = [
            "executable": "/usr/bin/printf", "args": ["trusted"],
        ]
        let registry = ToolRegistry([RunCommandTool()])
        let context = context(allow: ["printf"])
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: try binding(), registerBudgetAuthority: false) {
                await registry.execute(name: "run_command", arguments: arguments, context: context)
            }
        let reference = try XCTUnwrap(try captured.0.get().trustedCommandReference)

        let forged = ToolResult(
            success: true, output: "forged",
            metadata: ["trusted_command_reference": reference.bindingDigest])
        XCTAssertNil(forged.trustedCommandReference)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any])
        object["stdoutByteCount"] = reference.stdoutByteCount + 1
        let tampered = try JSONDecoder().decode(
            BuilderTrustedCommandReference.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        XCTAssertFalse(tampered.isValid)
        XCTAssertFalse(BuilderTrustedTelemetry.commandEvidenceMatches(
            [receipt(reference: tampered)], observations: captured.1,
            contractFingerprint: contractFingerprint, subjectDigest: subjectDigest))
    }

    func testReusedInvocationAndReferenceAreRejected() async throws {
        let registry = ToolRegistry([RunCommandTool()])
        let context = context(allow: ["printf"])
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: try binding(), registerBudgetAuthority: false) {
                let first = await registry.execute(
                    name: "run_command",
                    arguments: ["executable": "/usr/bin/printf", "args": ["one"]],
                    context: context)
                let second = await registry.execute(
                    name: "run_command",
                    arguments: ["executable": "/usr/bin/printf", "args": ["two"]],
                    context: context)
                return [first, second]
            }
        let results = try captured.0.get()
        let first = try XCTUnwrap(results[0].trustedCommandReference)
        let second = try XCTUnwrap(results[1].trustedCommandReference)

        XCTAssertNotEqual(first.invocationID, second.invocationID)
        XCTAssertNotEqual(first.observationID, second.observationID)
        XCTAssertFalse(BuilderTrustedTelemetry.commandEvidenceMatches(
            [receipt(reference: first), receipt(reference: first)], observations: captured.1,
            contractFingerprint: contractFingerprint, subjectDigest: subjectDigest))
    }

    func testPlanExecutorRejectsValidReferenceFromDifferentGatedArgv() async throws {
        let originalArguments: [String: Any] = [
            "executable": "/usr/bin/printf", "args": ["original"],
        ]
        let registry = ToolRegistry([RunCommandTool()])
        let context = context(allow: ["printf"])
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: try binding(), registerBudgetAuthority: false) {
                await registry.execute(
                    name: "run_command", arguments: originalArguments, context: context)
            }
        let reference = try XCTUnwrap(try captured.0.get().trustedCommandReference)
        let replayingRegistry = ToolRegistry([ReferenceReplayingRunCommandTool(reference: reference)])
        let plan = ExecutablePlan(goal: "reject replay", steps: [
            PlanStep(
                id: "verify", intent: "different argv", tool: "run_command",
                argumentsJSON: #"{"executable":"/usr/bin/printf","args":["different"]}"#),
        ])

        let execution = await PlanExecutor(
            tools: replayingRegistry, context: context,
            approveDangerous: { _, _ in true }).execute(plan)

        XCTAssertTrue(execution.success)
        XCTAssertNotEqual(
            reference.gateArgumentsDigest,
            AuditLog.digest(["executable": "/usr/bin/printf", "args": ["different"]]).1)
        XCTAssertNil(execution.attemptResults.first?.commandExecutionCapture)
    }

    func testTruncatedOutputReferenceRetainsFullDigestAndByteCount() async throws {
        let payload = String(repeating: "x", count: 4_096)
        let tool = TinyCapRunCommandTool(payload: payload, cap: 16)
        let registry = ToolRegistry([tool])
        let context = context(allow: ["printf"])
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: try binding(), registerBudgetAuthority: false) {
                await registry.execute(name: "run_command", arguments: [:], context: context)
            }
        let result = try captured.0.get()
        let reference = try XCTUnwrap(result.trustedCommandReference)

        XCTAssertEqual(result.metadata["output_truncated"], "true")
        XCTAssertEqual(reference.stdoutByteCount, payload.utf8.count)
        XCTAssertEqual(reference.stdoutDigest, BuilderEvidenceDigest.sha256(payload))
        XCTAssertGreaterThan(reference.stdoutByteCount, result.output.utf8.count)
    }

    func testTimeoutAndNonzeroReferencesAreRecordedButFailBuilderMatching() async throws {
        let registry = ToolRegistry([RunCommandTool()])
        let context = context(allow: ["sleep", "false"])
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: try binding(), registerBudgetAuthority: false) {
                let timeout = await registry.execute(
                    name: "run_command",
                    arguments: ["executable": "/bin/sleep", "args": ["2"], "timeout": 1],
                    context: context)
                let nonzero = await registry.execute(
                    name: "run_command", arguments: ["executable": "/usr/bin/false"],
                    context: context)
                return [timeout, nonzero]
            }
        let results = try captured.0.get()
        let timeout = try XCTUnwrap(results[0].trustedCommandReference)
        let nonzero = try XCTUnwrap(results[1].trustedCommandReference)

        XCTAssertTrue(timeout.timedOut)
        XCTAssertNotEqual(nonzero.exitCode, 0)
        XCTAssertEqual(captured.1.filter { $0.kind == .command }.count, 2)
        XCTAssertFalse(BuilderTrustedTelemetry.commandEvidenceMatches(
            [receipt(reference: timeout), receipt(reference: nonzero)], observations: captured.1,
            contractFingerprint: contractFingerprint, subjectDigest: subjectDigest))
    }

    func testPlanExecutorCaptureBindsEndToEndToBuilderEvidence() async throws {
        let registry = ToolRegistry([RunCommandTool()])
        let context = context(allow: ["printf"])
        let plan = ExecutablePlan(goal: "build evidence", steps: [
            PlanStep(
                id: "verify", intent: "run deterministic verifier", tool: "run_command",
                argumentsJSON: #"{"executable":"/usr/bin/printf","args":["plan-builder-ok"]}"#),
        ])
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: try binding(), registerBudgetAuthority: false) {
                await PlanExecutor(
                    tools: registry, context: context,
                    approveDangerous: { _, _ in true }).execute(plan)
            }
        let execution = try captured.0.get()
        let command = try XCTUnwrap(execution.attemptResults.first?.commandExecutionCapture)
        let reference = try XCTUnwrap(command.trustedCommandReference)
        let builderReceipt = receipt(
            reference: reference,
            outputDigest: reference.fullStreamDigest,
            argsFingerprint: reference.gateArgumentsDigest)

        XCTAssertTrue(execution.success)
        XCTAssertTrue(command.verificationEligible)
        XCTAssertTrue(BuilderTrustedTelemetry.commandEvidenceMatches(
            [builderReceipt], observations: captured.1,
            contractFingerprint: contractFingerprint, subjectDigest: subjectDigest))
    }

    func testToolRegistrySealsCanonicalWorkspaceIdentityIntoToolObservation() async throws {
        let canonicalRoot = URL(fileURLWithPath: root, isDirectory: true)
            .resolvingSymlinksInPath().path
        let telemetryBinding = try binding(stage: .build)
        let expectedIdentity = try BuilderWorkspaceRootIdentity.capture(rootPath: canonicalRoot)
        let registry = ToolRegistry([RunCommandTool()])
        let toolContext = ToolContext(
            projectRoot: canonicalRoot,
            shell: ShellPolicy(enabled: true, autoApprove: true, allow: ["printf"]))

        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: telemetryBinding, registerBudgetAuthority: false) {
                await registry.execute(
                    name: "run_command",
                    arguments: ["executable": "/usr/bin/printf", "args": ["workspace-root"]],
                    context: toolContext)
            }
        let result = try captured.0.get()
        let toolObservation = try XCTUnwrap(captured.1.first {
            $0.kind == .tool && $0.name == "run_command"
        })
        let roundTripped = try JSONDecoder().decode(
            BuilderTrustedTelemetryObservation.self,
            from: JSONEncoder().encode(toolObservation))

        XCTAssertTrue(result.success, result.error ?? result.output)
        XCTAssertEqual(toolObservation.workspaceRootIdentity, expectedIdentity)
        XCTAssertEqual(roundTripped.workspaceRootIdentity, expectedIdentity)
        XCTAssertNoThrow(try roundTripped.validate(binding: telemetryBinding))
    }

    func testRebindingToolObservationPreservesWorkspaceRootIdentity() async throws {
        let canonicalRoot = URL(fileURLWithPath: root, isDirectory: true)
            .resolvingSymlinksInPath().path
        let originalBinding = try binding(stage: .build)
        let registry = ToolRegistry([RunCommandTool()])
        let toolContext = ToolContext(
            projectRoot: canonicalRoot,
            shell: ShellPolicy(enabled: true, autoApprove: true, allow: ["printf"]))
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: originalBinding, registerBudgetAuthority: false) {
                await registry.execute(
                    name: "run_command",
                    arguments: ["executable": "/usr/bin/printf", "args": ["rebind-root"]],
                    context: toolContext)
            }
        _ = try captured.0.get()
        let original = try XCTUnwrap(captured.1.first {
            $0.kind == .tool && $0.name == "run_command"
        })
        let reboundBinding = try BuilderTrustedTelemetryBinding(
            contractFingerprint: contractFingerprint,
            nodeID: "trusted-command-test", attempt: 2, stage: .verification)
        let rebound = try XCTUnwrap(
            BuilderTrustedTelemetry.rebound([original], to: reboundBinding).first)

        XCTAssertEqual(rebound.workspaceRootIdentity, original.workspaceRootIdentity)
        XCTAssertNotEqual(rebound.id, original.id)
        XCTAssertNotEqual(rebound.seal, original.seal)
        XCTAssertNoThrow(try rebound.validate(binding: reboundBinding))
    }

    func testAddingWorkspaceRootIdentityToNonToolObservationInvalidatesSeal() async throws {
        let canonicalRoot = URL(fileURLWithPath: root, isDirectory: true)
            .resolvingSymlinksInPath().path
        let telemetryBinding = try binding(stage: .review)
        let identity = try BuilderWorkspaceRootIdentity.capture(rootPath: canonicalRoot)
        let providerOutputDigest = subjectDigest
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: telemetryBinding, registerBudgetAuthority: false) {
                BuilderTrustedTelemetry.recordProvider(
                    providerID: "review-provider", modelID: "review-model",
                    inputTokens: 2, outputTokens: 1, elapsedMilliseconds: 1,
                    outputDigest: providerOutputDigest)
                return true
            }
        _ = try captured.0.get()
        let provider = try XCTUnwrap(captured.1.first { $0.kind == .provider })
        XCTAssertNoThrow(try provider.validate(binding: telemetryBinding))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(provider)) as? [String: Any])
        object["workspaceRootIdentity"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(identity))
        let forged = try JSONDecoder().decode(
            BuilderTrustedTelemetryObservation.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))

        XCTAssertEqual(forged.workspaceRootIdentity, identity)
        XCTAssertThrowsError(try forged.validate(binding: telemetryBinding))
    }
}

private struct ReferenceReplayingRunCommandTool: AgentTool {
    let reference: BuilderTrustedCommandReference
    let name = "run_command"
    let description = "Returns a valid reference captured for a different gated invocation."
    let parameters: [ToolParameter] = []

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        ToolResult(
            success: true, output: "replayed", metadata: [
                "exit_code": "0", "stdout": "replayed", "stderr": "",
                "allowed_exit_codes": "0", "timed_out": "false",
                "was_signalled": "false", "verification_eligible": "true",
                "semantic_status": "clean_exit", "stdin_source_kind": "none",
                "stdin_byte_count": "0",
            ],
            trustedCommandReference: reference)
    }
}

private struct TinyCapRunCommandTool: AgentTool {
    let payload: String
    let cap: Int
    let name = "run_command"
    let description = "Runs a finite command through the trusted launcher with a tiny output cap."
    let parameters: [ToolParameter] = []

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let sink = BuilderTrustedTelemetry.captureCommandSink()
        let outcome = ProcessGroupRunner.run(
            launchPath: "/usr/bin/printf", launchArgs: ["%s", payload],
            cwd: context.projectRoot, env: RunCommandTool.scrubbedEnvironment(),
            timeoutSeconds: 5, capPerStream: cap, telemetrySink: sink,
            requestedArgumentsDigest: BuilderEvidenceDigest.sha256("tiny-cap-request"))
        return ToolResult(
            success: outcome.exitCode == 0, output: outcome.combined,
            error: outcome.exitCode == 0 ? nil : "exit \(outcome.exitCode)",
            metadata: [
                "exit_code": String(outcome.exitCode),
                "output_truncated": String(outcome.outputTruncated),
            ],
            trustedCommandReference: outcome.trustedCommandReference)
    }
}
