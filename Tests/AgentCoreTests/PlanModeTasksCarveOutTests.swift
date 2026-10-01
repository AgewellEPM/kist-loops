import XCTest
@testable import AgentCore

/// LOOP 2 FIX (2026-08-01): plan-mode research/coordination specialists (self-heal-researcher and the
/// domain specialists) carry `tasks` in their allowlist but run with permissionMode "plan". Plan mode
/// must let them READ the shared board (to ground a proposal) while still blocking board WRITES — the
/// contradiction that previously left them unable to act at all. `isReadOnlyTasksCall` is the single
/// gate both planModeBlock call sites (structured + native loop) route through.
final class PlanModeTasksCarveOutTests: XCTestCase {

    func testReadOnlyTasksActionsAllowedInPlanMode() {
        for action in ["list", "map", "validate", "check"] {
            XCTAssertTrue(HeadlessAgentLoop.isReadOnlyTasksCall(tool: "tasks", args: ["action": action]),
                          "tasks \(action) is a pure read — must be allowed in plan mode")
        }
    }

    func testDefaultActionIsListAndAllowed() {
        // ManageTasksTool defaults a missing action to `list` (a read); the gate must mirror that.
        XCTAssertTrue(HeadlessAgentLoop.isReadOnlyTasksCall(tool: "tasks", args: [:]))
    }

    func testActionNormalizationMirrorsManageTasksTool() {
        // ManageTasksTool lowercases + the gate trims; case/whitespace must not smuggle a read through
        // as a write or vice-versa.
        XCTAssertTrue(HeadlessAgentLoop.isReadOnlyTasksCall(tool: "tasks", args: ["action": "  LIST "]))
        XCTAssertFalse(HeadlessAgentLoop.isReadOnlyTasksCall(tool: "tasks", args: ["action": "DONE"]))
    }

    /// Multi-site invariant: EVERY mutating subaction is asserted individually, so a future action added
    /// to ManageTasksTool that isn't classified fails HERE rather than silently escaping plan mode.
    func testEveryWritingTasksActionStaysBlockedInPlanMode() {
        for action in ["add", "start", "done", "complete", "block", "update", "evidence", "clear"] {
            XCTAssertFalse(HeadlessAgentLoop.isReadOnlyTasksCall(tool: "tasks", args: ["action": action]),
                           "tasks \(action) MUTATES the board — must stay blocked in plan mode")
        }
    }

    func testNonTasksToolsAreNeverTreatedAsReadOnlyTasks() {
        XCTAssertFalse(HeadlessAgentLoop.isReadOnlyTasksCall(tool: "edit_file", args: ["action": "list"]))
        XCTAssertFalse(HeadlessAgentLoop.isReadOnlyTasksCall(tool: "run_command", args: [:]))
    }
}
