import Foundation
import XCTest
@testable import AgentCore

final class PlanSupportingCommandReceiptTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-support-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/Fixtures",
                                                withIntermediateDirectories: true)
        try "valid".write(toFile: root + "/Fixtures/valid.txt", atomically: true, encoding: .utf8)
        try "invalid".write(toFile: root + "/Fixtures/invalid.txt", atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    func testFiveStructuredCommandsProduceTypedSecretSafeObligationEvidence() async throws {
        let secretStdin = "api_key=abcdefghijklmnop"
        let plan = ExecutablePlan(goal: "verify all inputs", steps: [
            PlanStep(id: "build", intent: "build", tool: "run_command",
                     argumentsJSON: #"{"executable":"swift","args":["test"],"allowed_exit_codes":[0]}"#),
            PlanStep(id: "fixture-valid", intent: "valid file", tool: "run_command",
                     argumentsJSON: #"{"executable":"fixture-check","args":["--input","Fixtures/valid.txt"],"allowed_exit_codes":[0]}"#),
            PlanStep(id: "fixture-invalid", intent: "invalid file", tool: "run_command",
                     argumentsJSON: #"{"executable":"fixture-check","args":["--input","Fixtures/invalid.txt"],"allowed_exit_codes":[1]}"#),
            PlanStep(id: "stdin-valid", intent: "valid stdin", tool: "run_command",
                     argumentsJSON: "{\"executable\":\"stdin-check\",\"args\":[],\"stdin\":\"\(secretStdin)\",\"allowed_exit_codes\":[0]}"),
            PlanStep(id: "stdin-invalid", intent: "invalid stdin", tool: "run_command",
                     argumentsJSON: #"{"executable":"stdin-check","args":["--invalid"],"stdin":"bad-input","allowed_exit_codes":[1]}"#),
        ])
        let execution = await PlanExecutor(
            tools: ToolRegistry([SupportingRunCommandTool()]),
            context: ToolContext(projectRoot: root)
        ).execute(plan)

        XCTAssertTrue(execution.success)
        let captures = execution.attemptResults.compactMap(\.commandExecutionCapture)
        XCTAssertEqual(captures.count, 5)
        guard captures.count == 5 else { return }
        XCTAssertEqual(captures.map(\.actualExitCode), [0, 0, 1, 0, 1])
        XCTAssertTrue(captures[2].success)
        XCTAssertFalse(captures[2].verificationEligible,
                       "an accepted exit 1 is supporting domain evidence, never a verifier")
        XCTAssertEqual(captures[2].semanticStatus, "expected_domain_status")
        XCTAssertTrue(captures[3].hasStandardInput)
        XCTAssertEqual(captures[3].standardInputByteCount, secretStdin.utf8.count)
        XCTAssertNotEqual(captures[3].standardInputDigest, secretStdin)
        XCTAssertFalse(captures[3].boundedRedactedOutputExcerpt.contains(secretStdin))
        XCTAssertTrue(captures[3].boundedRedactedOutputExcerpt.contains(SecretMasker.marker))

        let contract = PlanExecuteCompletionContract.derive(canonicalRequest:
            "verification-only: build and test valid and invalid fixture inputs and structured stdin; do not edit")
        let requirements: [PlanExecuteLoop.FunctionalEvidenceRequirement] = [
            .init(input: .fixtureFile, validity: .valid, expectedExitCode: 0,
                  requiresLineNumberEvidence: false),
            .init(input: .fixtureFile, validity: .invalid, expectedExitCode: 1,
                  requiresLineNumberEvidence: true),
            .init(input: .standardInput, validity: .valid, expectedExitCode: 0,
                  requiresLineNumberEvidence: false),
            .init(input: .standardInput, validity: .invalid, expectedExitCode: 1,
                  requiresLineNumberEvidence: false),
        ]
        let obligations = PlanExecuteLoop.requiredSupportingObligations(
            completionContract: contract, requirements: requirements)
        let obligationsFingerprint = PlanExecuteLoop.supportingObligationsFingerprint(obligations)
        let receipts = zip(execution.attemptResults, captures).enumerated().map { offset, pair in
            PlanExecuteLoop.bindSupportingCommandReceipt(
                pair.1, stepID: pair.0.stepId, ordinal: offset + 1,
                mutationFrontierOrdinal: nil, contractID: "contract-1",
                missionInstanceID: "mission",
                completionContract: contract, requirements: requirements,
                requiredObligations: obligations, obligationsFingerprint: obligationsFingerprint,
                executionPolicyFingerprint: "policy-1", workspaceManifestDigest: "manifest-1",
                projectRoot: root)
        }
        XCTAssertEqual(Set(receipts.flatMap(\.satisfiedObligationIDs)), Set(obligations.map(\.id)))
        XCTAssertTrue(receipts.allSatisfy(\.hasValidEvidenceDigest))
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(receipts), encoding: .utf8))
        XCTAssertFalse(encoded.contains(secretStdin), "typed evidence must never persist raw stdin")
    }

    func testDurableReceiptRoundTripPreservesReplanOrderingAndFinalBinding() throws {
        let commandArguments: [String: Any] = ["executable": "swift", "args": ["test"]]
        let trustedReference = makePlanTestTrustedCommandReference(
            arguments: commandArguments, stdout: "passed", exitCode: 0)
        let capture = PlanCommandExecutionCapture(
            executable: "swift", argv: ["test"], workingDirectory: ".",
            hasStandardInput: false, standardInputDigest: nil, standardInputByteCount: 0,
            allowedExitCodes: [0], actualExitCode: 0, wasSignalled: false, timedOut: false,
            semanticStatus: "clean_exit", verificationEligible: true, success: true,
            argsFingerprint: "args", commandFingerprint: "command", outputDigest: "output",
            trustedCommandReference: trustedReference,
            boundedRedactedOutputExcerpt: "passed",
            effectObservation: .init(verification: .buildOrTest), executionPhase: 1,
            completedAt: Date(timeIntervalSince1970: 10), governedWorkspaceDigest: "workspace")
        let contract = PlanExecuteCompletionContract.derive(
            canonicalRequest: "verification-only: run build; no edits")
        let obligations = PlanExecuteLoop.requiredSupportingObligations(
            completionContract: contract, requirements: [])
        let fingerprint = PlanExecuteLoop.supportingObligationsFingerprint(obligations)
        let first = PlanExecuteLoop.bindSupportingCommandReceipt(
            capture, stepID: "old-plan-build", ordinal: 2, mutationFrontierOrdinal: 1,
            contractID: "contract", missionInstanceID: "mission", completionContract: contract,
            requirements: [],
            requiredObligations: obligations, obligationsFingerprint: fingerprint,
            executionPolicyFingerprint: "policy", workspaceManifestDigest: "manifest",
            projectRoot: root)
        let second = PlanExecuteLoop.bindSupportingCommandReceipt(
            capture, stepID: "replacement-plan-build", ordinal: 5, mutationFrontierOrdinal: 1,
            contractID: "contract", missionInstanceID: "mission", completionContract: contract,
            requirements: [],
            requiredObligations: obligations, obligationsFingerprint: fingerprint,
            executionPolicyFingerprint: "policy", workspaceManifestDigest: "manifest",
            projectRoot: root)
        var durable = DurablePlanInvocationReceipt(
            stepID: "replacement-plan-build", tool: "run_command", success: true,
            output: "passed", metadata: ["exit_code": "0"],
            effectObservation: .init(verification: .buildOrTest), executionPhase: 5,
            argsFingerprint: "args")
        durable.supportingCommandReceipt = second
        let decoded = try JSONDecoder().decode(
            DurablePlanInvocationReceipt.self, from: JSONEncoder().encode(durable))
        XCTAssertEqual(decoded.supportingCommandReceipt, second)
        XCTAssertTrue(decoded.supportingCommandReceipt?.hasValidEvidenceDigest == true)

        var final = PlanFinalVerificationReceipt(
            missionInstanceID: "mission",
            contractID: "contract", stepID: "final-replay", tool: "run_command",
            invocation: .init(executable: "swift", argv: ["test"], workingDirectory: ".",
                              hasStandardInput: false, standardInputDigest: nil),
            commandFingerprint: "command", expectedExitCode: 0, actualExitCode: 0,
            outputDigest: "output", boundedRedactedOutputExcerpt: "passed",
            governedWorkspaceDigest: "workspace",
            completionContractFingerprint: contract.fingerprint,
            executionPolicyFingerprint: "policy", verifiedAt: Date(timeIntervalSince1970: 20),
            freshAfterMutationFrontier: true, captureOrdinal: 6, mutationFrontierOrdinal: 1,
            obligationsFingerprint: fingerprint, workspaceManifestDigest: "manifest",
            trustedCommandReference: trustedReference)
        final.evidenceDigest = final.computedEvidenceDigest
        let encodedFinal = try JSONEncoder().encode(final)
        let decodedFinal = try JSONDecoder().decode(
            PlanFinalVerificationReceipt.self, from: encodedFinal)
        XCTAssertEqual(decodedFinal, final)
        XCTAssertTrue(decodedFinal.hasValidEvidenceDigest)
        XCTAssertEqual(decodedFinal.obligationsFingerprint, fingerprint)
        XCTAssertEqual(decodedFinal.workspaceManifestDigest, "manifest")
        XCTAssertEqual(decodedFinal.captureOrdinal, 6)
        XCTAssertTrue(final.validatesBinding(
            missionInstanceID: "mission", contractID: "contract",
            completionContractFingerprint: contract.fingerprint,
            obligationsFingerprint: fingerprint, executionPolicyFingerprint: "policy",
            workspaceManifestDigest: "manifest", governedWorkspaceDigest: "workspace"))
        XCTAssertTrue([first, second].allSatisfy {
            $0.validatesBinding(
                missionInstanceID: "mission", contractID: "contract",
                completionContractFingerprint: contract.fingerprint,
                obligationsFingerprint: fingerprint, executionPolicyFingerprint: "policy",
                workspaceManifestDigest: "manifest", governedWorkspaceDigest: "workspace",
                requiredObligationIDs: Set(obligations.map(\.id)),
                beforeFinalCaptureOrdinal: final.captureOrdinal)
        })
        XCTAssertEqual([first, second].map(\.captureOrdinal), [2, 5])
        XCTAssertLessThan(second.captureOrdinal, final.captureOrdinal)
    }
}

private struct SupportingRunCommandTool: AgentTool {
    let name = "run_command"
    let description = "typed supporting command test double"
    let parameters: [ToolParameter] = []

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let allowed = (arguments["allowed_exit_codes"] as? [Int])
            ?? (arguments["allowed_exit_codes"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue }
            ?? [0]
        let exit = allowed == [1] ? 1 : 0
        let executable = arguments["executable"] as? String ?? ""
        let stdin = arguments["stdin"] as? String
        let output = stdin ?? (exit == 1 ? "line 1: invalid input" : "passed")
        let metadata = [
            "exit_code": String(exit), "stdout": output, "stderr": "",
            "allowed_exit_codes": allowed.map(String.init).joined(separator: ","),
            "exit_code_allowed": "true", "timed_out": "false", "was_signalled": "false",
            "verification_eligible": String(executable == "swift" && exit == 0),
            "semantic_status": exit == 0 ? "clean_exit" : "expected_domain_status",
        ]
        return makePlanTestTrustedCommandResult(
            arguments: arguments, output: output, metadata: metadata, exitCode: exit)
    }
}
