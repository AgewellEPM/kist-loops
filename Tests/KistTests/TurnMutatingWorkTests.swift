import XCTest
import AgentCore
@testable import Kist

/// Regression (Codex, origin/main reconciliation): the turn-summary "did real work" predicate must count
/// the BROAD mutating set — a run_command / apply_patch turn is real work, NOT just file-write tools.
/// A merge briefly swapped this for Copilot.shouldReview (file-writes only), silently narrowing it.
final class TurnMutatingWorkTests: XCTestCase {

    private func rec(_ tool: String, _ success: Bool = true) -> ActionRecord {
        ActionRecord(tool: tool, argsFingerprint: "x", success: success)
    }

    func testShellAndPatchCountAsMutatingWork() {
        XCTAssertTrue(KistREPL.turnHasMutatingWork([rec("run_command")]), "a successful shell command is real work")
        XCTAssertTrue(KistREPL.turnHasMutatingWork([rec("apply_patch")]))
        XCTAssertTrue(KistREPL.turnHasMutatingWork([rec("write_file")]))
        XCTAssertTrue(KistREPL.turnHasMutatingWork([rec("notebook_edit")]))
    }

    func testBroaderThanCopilotReviewSet() {
        // Copilot.shouldReview only fires on file-diff mutations; the dashboard predicate is broader.
        XCTAssertFalse(Copilot.shouldReview(trajectory: [rec("run_command")]), "review is diff-only")
        XCTAssertTrue(KistREPL.turnHasMutatingWork([rec("run_command")]), "dashboard counts shell as work")
    }

    func testReadOnlyAndFailedDoNotCount() {
        XCTAssertFalse(KistREPL.turnHasMutatingWork([rec("read_file"), rec("search_code")]))
        XCTAssertFalse(KistREPL.turnHasMutatingWork([rec("run_command", false)]), "a FAILED command changed nothing")
        XCTAssertFalse(KistREPL.turnHasMutatingWork([]))
    }
}
