import XCTest
import AgentCore
@testable import Kist

/// The dashboard consumes the shared effect observation: successful mutation/build commands are progress;
/// generic inspection and failed actions are not.
final class TurnMutatingWorkTests: XCTestCase {

    private func rec(_ tool: String, _ success: Bool = true) -> ActionRecord {
        ActionRecord(tool: tool, argsFingerprint: "x", success: success)
    }

    private func observed(_ tool: String, arguments: [String: Any], success: Bool = true,
                          metadata: [String: String]? = nil) -> ActionRecord {
        ActionRecord(tool: tool, argsFingerprint: TrajectoryAnalyzer.fingerprint(arguments),
                     success: success,
                     effectObservation: ToolEffectCatalog.observe(
                        tool: tool, arguments: arguments, outcomeMetadata: metadata))
    }

    func testBuildCommandAndPatchCountAsProgress() {
        XCTAssertFalse(KistREPL.turnHasMutatingWork([rec("run_command")]), "a generic shell command is not deliverable progress")
        XCTAssertTrue(KistREPL.turnHasMutatingWork([
            ActionRecord(tool: "run_command", argsFingerprint: "command=swift test", success: true)
        ]), "an executed build/test is deliverable progress")
        XCTAssertTrue(KistREPL.turnHasMutatingWork([
            observed("apply_patch", arguments: ["patch": "*** Begin Patch\n*** Update File: Sources/A.swift\n*** End Patch"],
                     metadata: ["changed": "true"])
        ]))
        XCTAssertTrue(KistREPL.turnHasMutatingWork([
            observed("write_file", arguments: ["path": "Sources/A.swift"], metadata: ["changed": "true"])
        ]))
        XCTAssertTrue(KistREPL.turnHasMutatingWork([
            observed("notebook_edit", arguments: ["path": "notebook.ipynb"], metadata: ["changed": "true"])
        ]))
    }

    func testTrivialCommandTriggersNeitherReviewNorProgress() {
        XCTAssertFalse(Copilot.shouldReview(trajectory: [rec("run_command")]), "review is diff-only")
        XCTAssertFalse(KistREPL.turnHasMutatingWork([rec("run_command")]), "dashboard ignores trivial shell inspection")
    }

    func testReadOnlyAndFailedDoNotCount() {
        XCTAssertFalse(KistREPL.turnHasMutatingWork([rec("read_file"), rec("search_code")]))
        XCTAssertFalse(KistREPL.turnHasMutatingWork([rec("run_command", false)]), "a FAILED command changed nothing")
        XCTAssertFalse(KistREPL.turnHasMutatingWork([]))
    }

    func testOnlyStateChangingTaskActionsMoveTheBoard() {
        let listed = observed("tasks", arguments: ["action": "list"])
        let added = observed("tasks", arguments: ["action": "add", "title": "Fix it"])
        let failed = observed("tasks", arguments: ["action": "done", "id": 1], success: false)

        XCTAssertFalse(KistREPL.turnWorkedBoard([listed]))
        XCTAssertTrue(KistREPL.turnWorkedBoard([added]))
        XCTAssertFalse(KistREPL.turnWorkedBoard([failed]))
    }
}
