import XCTest
@testable import AgentCore

final class BuildStatusReportTests: XCTestCase {
    private func rec(_ tool: String, success: Bool, _ eff: ToolEffectObservation) -> ActionRecord {
        ActionRecord(tool: tool, argsFingerprint: "", success: success, effectObservation: eff)
    }

    // An empty turn: nothing generated, nothing applied → NOT COMPLETE.
    func testEmptyTurnIsNotComplete() {
        let s = BuildStatusReport(trajectory: [])
        XCTAssertFalse(s.patchGenerated)
        XCTAssertFalse(s.patchApplied)
        XCTAssertEqual(s.filesChanged, 0)
        XCTAssertFalse(s.isComplete)
        XCTAssertTrue(s.render(color: false).contains("NOT COMPLETE"))
    }

    // The "I will apply the patch" gap: a mutation was ATTEMPTED but not confirmed applied.
    func testGeneratedButNotAppliedIsNotComplete() {
        let s = BuildStatusReport(trajectory: [
            rec("edit_file", success: false, ToolEffectObservation(mutation: .source, mutationEvidence: .mayMutate))
        ])
        XCTAssertTrue(s.patchGenerated)
        XCTAssertFalse(s.patchApplied, "a failed/unconfirmed mutation is not an applied patch")
        XCTAssertFalse(s.isComplete)
    }

    // The laundering gap Luke hit: patch applied, but NO build/test ran → still NOT COMPLETE.
    func testAppliedButUnverifiedIsNotComplete() {
        let s = BuildStatusReport(trajectory: [
            rec("edit_file", success: true, ToolEffectObservation(mutation: .source))   // confirmed
        ])
        XCTAssertTrue(s.patchApplied)
        XCTAssertEqual(s.filesChanged, 1)
        XCTAssertFalse(s.buildOrTestRan)
        XCTAssertFalse(s.isComplete, "applied but not built/tested must read NOT COMPLETE")
        XCTAssertTrue(s.render(color: false).contains("NOT COMPLETE"))
    }

    // Full contract satisfied: applied + built/tested + board → COMPLETE.
    func testAppliedAndVerifiedAndBoardedIsComplete() {
        let s = BuildStatusReport(trajectory: [
            rec("apply_patch", success: true, ToolEffectObservation(mutation: .source)),
            rec("edit_file", success: true, ToolEffectObservation(mutation: .source)),
            rec("run_command", success: true, ToolEffectObservation(verification: .buildOrTest)),
            rec("tasks", success: true, ToolEffectObservation(progress: .taskBoard)),
        ])
        XCTAssertTrue(s.patchApplied)
        XCTAssertEqual(s.filesChanged, 2)
        XCTAssertTrue(s.buildOrTestRan)
        XCTAssertTrue(s.boardUpdated)
        XCTAssertTrue(s.isComplete)
        let out = s.render(color: false)
        XCTAssertTrue(out.contains("COMPLETE") && !out.contains("NOT COMPLETE"))
        XCTAssertTrue(out.contains("🔧 BUILD STATUS"))
    }

    // Codex P2: a build/test that ran BEFORE the final edit does not prove the change → NOT COMPLETE.
    func testVerificationBeforeLastMutationDoesNotCount() {
        let s = BuildStatusReport(trajectory: [
            rec("run_command", success: true, ToolEffectObservation(verification: .buildOrTest)),
            rec("edit_file", success: true, ToolEffectObservation(mutation: .source)),   // edit AFTER the build
        ])
        XCTAssertTrue(s.patchApplied)
        XCTAssertFalse(s.buildOrTestRan, "verification before the final mutation must not count")
        XCTAssertFalse(s.isComplete)
    }

    // A failed build/test does not count as verification.
    func testFailedBuildDoesNotCountAsVerified() {
        let s = BuildStatusReport(trajectory: [
            rec("edit_file", success: true, ToolEffectObservation(mutation: .source)),
            rec("run_command", success: false, ToolEffectObservation(verification: .buildOrTest)),
        ])
        XCTAssertFalse(s.buildOrTestRan)
        XCTAssertFalse(s.isComplete)
    }
}
