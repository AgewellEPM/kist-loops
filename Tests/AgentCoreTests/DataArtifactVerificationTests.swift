import XCTest
@testable import AgentCore

final class DataArtifactVerificationTests: XCTestCase {
    func testDataSupportingEvidenceRequiresObservedNonSourceMutation() {
        let build = PlanExecuteCompletionContract.derive(canonicalRequest: "Create card.json")
        let checkOnly = PlanExecuteCompletionContract.derive(canonicalRequest: "verification-only: run tests; do not edit")
        let data = write("card.json").observedEffects
        XCTAssertTrue(PlanExecuteLoop.permitsDataArtifactEvidence(contract: build, effects: [data]))
        XCTAssertFalse(PlanExecuteLoop.permitsDataArtifactEvidence(contract: checkOnly, effects: [data]))
        XCTAssertFalse(PlanExecuteLoop.permitsDataArtifactEvidence(contract: build, effects: []))
        for source in [write("main.py").observedEffects, ToolEffectObservation(mutation: .unknownTarget)] {
            XCTAssertFalse(PlanExecuteLoop.permitsDataArtifactEvidence(contract: build, effects: [data, source]))
        }
    }

    func testSmallGoalReviewHasBudgetForVisibleVerdict() {
        XCTAssertEqual(PlanExecuteLoop.goalReviewSettings.maxTokens, 512)
        XCTAssertTrue(PlanExecuteLoop.goalReviewSettings.disableThinking)
        XCTAssertFalse(PlanExecuteLoop.goalReviewSettings.geminiBuiltins)
    }

    func testConcurrentDataWriteCannotGetAReplayReceiptFromSameWave() {
        let plan = ExecutablePlan(goal: "create card", steps: [
            PlanStep(id: "E1", intent: "write", tool: "write_file", argumentsJSON: #"{"path":"card.json","content":"{}"}"#),
            PlanStep(id: "E2", intent: "check", tool: "run_command", argumentsJSON: #"{"executable":"python3","args":["-m","json.tool","card.json"]}"#)
        ])
        let results = [
            StepResult(stepId: "E1", tool: "write_file", success: true, output: "written", error: nil,
                effectObservation: write("card.json").observedEffects, executionPhase: 1),
            StepResult(stepId: "E2", tool: "run_command", success: true, output: "{}", error: nil,
                effectObservation: check(["-m", "json.tool", "card.json"]).observedEffects, executionPhase: 1)
        ]
        let exec = PlanExecution(success: true, stepResults: results, outputs: [:], failedStepId: nil)
        let records = PlanExecuteLoop.verifyTrajectory(plan: plan, exec: exec)
        XCTAssertEqual(records.last?.observedEffects.verification, .nonVerifyingCommand)
        XCTAssertNil(CompletionVerifier().hostReceiptReplayRequest(in: records))
    }

    private func write(_ path: String, success: Bool = true) -> ActionRecord {
        ActionRecord(tool: "write_file", argsFingerprint: "path=\(path)", success: success,
            effectObservation: ToolEffectCatalog.observe(tool: "write_file", arguments: ["path": path],
                outcomeMetadata: ["changed": "true"]))
    }
    private func check(_ args: [String], success: Bool = true) -> ActionRecord {
        let arguments: [String: Any] = ["executable": "python3", "args": args]
        return ActionRecord(tool: "run_command", argsFingerprint: ToolEffectCatalog.commandFingerprint(arguments),
            success: success, effectObservation: ToolEffectCatalog.observe(tool: "run_command", arguments: arguments))
    }

    func testJSONDataValidationCanBindReceiptWithoutClaimingSourceVerification() {
        let validation = check(["-m", "json.tool", "card.json"])
        XCTAssertEqual(validation.observedEffects.mutation, .none)
        XCTAssertEqual(validation.observedEffects.verification, .dataValidation)
        let trajectory = [write("card.json"), validation]
        let verifier = CompletionVerifier()
        XCTAssertTrue(verifier.check(trajectory: trajectory, canRunCommands: true, expectedOutcome: .mutation).isAccept)
        XCTAssertNotNil(verifier.hostReceiptReplayRequest(in: trajectory))
        for source in ["main.py", "package.json", "unknown"] {
            let mixed = [write(source), write("card.json"), validation]
            XCTAssertFalse(verifier.check(trajectory: mixed, canRunCommands: true).isAccept, source)
            XCTAssertNil(verifier.hostReceiptReplayRequest(in: mixed), source)
        }
    }

    func testFailedAndStaleDataChecksCannotAuthorizeCurrentArtifact() {
        let verifier = CompletionVerifier()
        XCTAssertNil(verifier.hostReceiptReplayRequest(in: [write("card.json"), check(["-m", "json.tool", "card.json"], success: false)]))
        let stale = [write("card.json"), check(["-m", "json.tool", "card.json"]), write("card.json")]
        XCTAssertNotNil(verifier.invalidatedVerification(in: stale))
        XCTAssertFalse(verifier.check(trajectory: stale, canRunCommands: true).isAccept)
    }

    func testOnlyLiteralReadOnlyJSONCommandQualifies() {
        for args in [["-m", "json.tool"], ["-m", "json.tool", "-"],
                     ["-m", "json.tool", "in.json", "out.json"], ["-c", "print('ok')"],
                     ["-m", "json.tool", "main.py"], ["-m", "json.tool", "--help.json"]] {
            XCTAssertNotEqual(check(args).observedEffects.verification, .dataValidation, "\(args)")
        }
        XCTAssertNotEqual(CommandClassifier.observe(arguments: ["command": "python3 -m json.tool card.json || true"]).verification, .dataValidation)
        XCTAssertNotEqual(CommandClassifier.observe(arguments: ["executable": "python3", "args": ["-m", "json.tool", "card.json"], "command": "echo ok"]).verification, .dataValidation)
    }
}
