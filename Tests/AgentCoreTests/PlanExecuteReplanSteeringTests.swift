import XCTest
@testable import AgentCore

/// Failed-step replan steering (0.17.63): the run_command output tail travels with the failure, and
/// a clean non-zero exit the plan did not allow gets explicit "diagnostic run" guidance — three
/// identical "run the tests to identify the failure" plans (allowed_exit_codes [0], on a suite that
/// was failing on purpose) used to burn every replan without ever reaching the fix.
final class PlanExecuteReplanSteeringTests: XCTestCase {
    private func failedRun(_ output: String) -> PlanExecution {
        PlanExecution(
            success: false,
            stepResults: [
                StepResult(stepId: "E1", tool: "run_command", success: false, output: output, error: output),
            ],
            outputs: [:], failedStepId: "E1")
    }

    func testUnallowedNonZeroExitGetsDiagnosticGuidanceAndTheOutputTail() {
        let output = "exit code 1; allowed exit codes: [0] — output tail: FAIL: test_add (test_calc.TestCalc) ⏎ AssertionError: -1 != 5 ⏎ FAILED (failures=1)"
        let prompt = PlanExecuteLoop.replanFromFailure(goal: "fix the failing tests", exec: failedRun(output))
        XCTAssertTrue(prompt.contains("FAILED at step E1"), prompt)
        XCTAssertTrue(prompt.contains("AssertionError: -1 != 5"), "the diagnosis reaches the planner: \(prompt)")
        XCTAssertTrue(prompt.contains("allowed_exit_codes (e.g. [0, 1])"), prompt)
        XCTAssertTrue(prompt.contains("make the fix first"), prompt)
        XCTAssertTrue(prompt.contains("Never re-emit the identical failed step"), prompt)
    }

    func testOtherFailuresGetNoExitCodeGuidance() {
        let prompt = PlanExecuteLoop.replanFromFailure(
            goal: "g", exec: failedRun("executable not found or not executable: nasm"))
        XCTAssertFalse(prompt.contains("allowed_exit_codes (e.g."), prompt)
        XCTAssertTrue(prompt.contains("Never re-emit the identical failed step"), prompt)
        XCTAssertNil(PlanExecuteLoop.diagnosticExitCodeGuidance(failedOutput: "connection reset"))
    }

    func testLongOutputKeepsTheFirstSixHundredCharacters() {
        let output = "exit code 1; allowed exit codes: [0] — output tail: " + String(repeating: "x", count: 700) + "END"
        let prompt = PlanExecuteLoop.replanFromFailure(goal: "g", exec: failedRun(output))
        XCTAssertTrue(prompt.contains(String(repeating: "x", count: 500)), "more than the old 300-char window survives")
        XCTAssertFalse(prompt.contains("xEND"), "still bounded")
    }
}
