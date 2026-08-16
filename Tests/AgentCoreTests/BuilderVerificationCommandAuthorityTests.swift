import Foundation
import XCTest
@testable import AgentCore

final class BuilderVerificationCommandAuthorityTests: XCTestCase {
    private let contractFingerprint = String(repeating: "a", count: 64)
    private var root = ""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("builder-verification-authority-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private var arguments: [String: Any] {
        [
            "executable": "/usr/bin/printf",
            "args": ["%s", "SEALED_VERIFIER_OK"],
            "cwd": ".",
            "timeout": 30,
            "allowed_exit_codes": [0],
        ]
    }

    private func authorizedResult() async throws -> ToolResult {
        let binding = try BuilderTrustedTelemetryBinding(
            contractFingerprint: contractFingerprint,
            nodeID: "plan-execute-build", attempt: 1, stage: .build)
        let registry = ToolRegistry([RunCommandTool()])
        let context = ToolContext(
            projectRoot: root,
            shell: ShellPolicy(enabled: true, autoApprove: true, allow: ["printf"]))
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: binding, registerBudgetAuthority: false) {
                let result = await registry.execute(
                    name: "run_command", arguments: self.arguments, context: context)
                return result.authorizingBuilderContractVerification(arguments: self.arguments)
            }
        return try captured.0.get()
    }

    private func insideScope<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T)
        async throws -> T {
        let binding = try BuilderTrustedTelemetryBinding(
            contractFingerprint: contractFingerprint,
            nodeID: "plan-execute-build", attempt: 1, stage: .build)
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: binding, registerBudgetAuthority: false, operation: operation)
        return try captured.0.get()
    }

    func testExactSealedCommandCompletesPlanExecuteVerificationOnce() async throws {
        let result = try await authorizedResult()
        let effect = try await insideScope {
            ToolRegistry([]).effectObservation(
                name: "run_command", arguments: self.arguments, result: result)
        }
        XCTAssertEqual(effect.mutation, .none)
        XCTAssertEqual(effect.verification, .buildOrTest)

        let trajectory = [
            ActionRecord(
                tool: "write_file", argsFingerprint: "path=Sources/App.swift", success: true,
                effectObservation: ToolEffectObservation(mutation: .source)),
            ActionRecord(
                tool: "run_command", argsFingerprint: "sealed", success: true,
                effectObservation: effect),
        ]
        XCTAssertTrue(CompletionVerifier().check(
            trajectory: trajectory, canRunCommands: true,
            expectedOutcome: .mutation).isAccept)

        let replay = try await insideScope {
            ToolRegistry([]).effectObservation(
                name: "run_command", arguments: self.arguments, result: result)
        }
        XCTAssertNotEqual(replay.verification, .buildOrTest,
                          "a consumed verification authority must not be replayable")
    }

    func testWrongCommandDoesNotConsumeOrInheritAuthority() async throws {
        let result = try await authorizedResult()
        var wrong = arguments
        wrong["args"] = ["%s", "DIFFERENT"]
        let wrongEffect = try await insideScope {
            ToolRegistry([]).effectObservation(
                name: "run_command", arguments: wrong, result: result)
        }
        XCTAssertNotEqual(wrongEffect.verification, .buildOrTest)

        let exactEffect = try await insideScope {
            ToolRegistry([]).effectObservation(
                name: "run_command", arguments: self.arguments, result: result)
        }
        XCTAssertEqual(exactEffect.verification, .buildOrTest,
                       "a wrong-command probe must not consume the exact authority")
    }

    func testTamperedResultAndPlainMetadataCannotForgeAuthority() async throws {
        let authorized = try await authorizedResult()
        let altered = ToolResult(
            success: true, output: authorized.output + "tampered", error: nil,
            metadata: authorized.metadata,
            trustedCommandReference: authorized.trustedCommandReference,
            trustedBuilderVerification: authorized.trustedBuilderVerification)
        let alteredEffect = try await insideScope {
            ToolRegistry([]).effectObservation(
                name: "run_command", arguments: self.arguments, result: altered)
        }
        XCTAssertNotEqual(alteredEffect.verification, .buildOrTest)

        let pythonArguments: [String: Any] = [
            "executable": "python3", "args": ["test_plan.py"], "cwd": ".",
        ]
        let forged = ToolResult(
            success: true, output: "PASS",
            metadata: [
                "verification_eligible": "true",
                "builder_contract_verification": "true",
            ])
        let forgedEffect = ToolRegistry([]).effectObservation(
            name: "run_command", arguments: pythonArguments, result: forged)
        XCTAssertEqual(forgedEffect.mutation, .unknownTarget)
        XCTAssertEqual(forgedEffect.verification, .nonVerifyingCommand)
    }
}
