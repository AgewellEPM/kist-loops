import XCTest
import AgentCore
@testable import Kist

/// R1 ESC semantics (2026-07-28): single ESC = interject (take over, checkpoint kept), double ESC =
/// hard cancel (checkpoint discarded), and the plan-execute plane — previously a cancellation dead
/// zone — stops cooperatively. See docs/CAPTAIN_UX_OVERHAUL_PLAN_2026_07_28.md § R1.
final class R1ESCSemanticsTests: XCTestCase {

    private func scan(_ script: [UInt8?]) -> InterruptibleTurn.WatchAction {
        var s = script[...]
        return InterruptibleTurn.scanOnce(readByte: { s.isEmpty ? nil : s.removeFirst() })
    }

    // MARK: - double-ESC state machine

    func testDoubleESCInOneBurstCancels() {
        XCTAssertEqual(scan([0x1B, 0x1B]), .cancel)
    }

    func testDoubleESCAcrossTicksCancels() {
        // First ESC, a quiet tick, second ESC inside the ~0.3s window.
        XCTAssertEqual(scan([0x1B, nil, 0x1B]), .cancel)
        XCTAssertEqual(scan([0x1B, nil, nil, 0x1B]), .cancel, "second ESC on the last window tick still cancels")
    }

    func testWindowExpiryIsSingleESC() {
        XCTAssertEqual(scan([0x1B]), .interject)
        // Window = follow-read timeout + 3 ticks (~0.4s). Four quiet ticks close it; an ESC
        // arriving after that must not retro-upgrade this scan to cancel (it starts a new scan).
        XCTAssertEqual(scan([0x1B, nil, nil, nil, nil, 0x1B]), .interject,
                       "an ESC AFTER the window closed must not retro-upgrade to cancel")
    }

    func testArrowDuringWindowIsSingleESCWithArrowSwallowed() {
        // ESC … then the user presses Up-arrow: the first ESC stands alone, the arrow is swallowed.
        XCTAssertEqual(scan([0x1B, nil, 0x1B, 0x5B, 0x41]), .interject)
        XCTAssertEqual(scan([0x1B, nil, 0x1B, 0x4F, 0x50]), .interject, "SS3 (F1) during window also swallowed")
    }

    func testOtherKeyDuringWindowIsSingleESC() {
        XCTAssertEqual(scan([0x1B, nil, 0x61]), .interject)
    }

    func testAltChordDuringWindowIsSingleESCNotCancel() {
        // Only a BARE double-ESC may trigger the destructive cancel path (review catch): a
        // second ESC followed by a printable byte is an Alt/Meta chord, not a double press.
        XCTAssertEqual(scan([0x1B, nil, 0x1B, 0x62]), .interject, "ESC then Alt-b must not hard-cancel")
        XCTAssertEqual(scan([0x1B, nil, 0x1B, 0x1B]), .cancel, "ESC-hammering still cancels")
    }

    func testArrowAloneStillNeverInterrupts() {
        XCTAssertEqual(scan([0x1B, 0x5B, 0x41]), .swallowedSequence)
    }

    // MARK: - flag stickiness

    func testCancelReasonIsSticky() async {
        let flag = InterruptFlag()
        await flag.set(.cancel)
        await flag.set(.interject)
        let r1 = await flag.reason
        XCTAssertEqual(r1, .cancel, "cancel must never downgrade to interject")

        let flag2 = InterruptFlag()
        await flag2.set(.interject)
        await flag2.set(.cancel)
        let r2 = await flag2.reason
        XCTAssertEqual(r2, .cancel, "interject may upgrade to cancel")
    }

    // MARK: - plan-execute plane: cooperative cancellation + wiring pins (SURFACES pattern)

    /// One pin per file the R1 change touches — a regression names its site.
    func testESCPlaneWiringStaysIntact() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func src(_ rel: String) throws -> String {
            try String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8)
        }

        // PlanExecuteLoop: loop-top, provider-error, meteredComplete pre-spend, post-executor, AND
        // post-verify (the review-caught missed 5th site) cancellation checks.
        let loop = try src("Sources/AgentCore/PlanExecuteLoop.swift")
        XCTAssertGreaterThanOrEqual(loop.components(separatedBy: "Task.isCancelled").count - 1, 5,
                                    "PlanExecuteLoop lost a cooperative cancellation site — ESC dead zone is back")
        XCTAssertTrue(loop.contains("interrupted by user (ESC)"), "cancellation must report as an interrupt, not a planner failure")
        XCTAssertTrue(loop.contains("interrupted: true"), "PlanOutcome must carry the structured interrupted flag")
        XCTAssertTrue(loop.contains("!outcome.interrupted"),
                      "PlanExecuteLoop.run must skip the episode record for interrupted runs (memory poisoning)")

        // PlanExecutor: wave-boundary check.
        let exec = try src("Sources/AgentCore/PlanExecutor.swift")
        XCTAssertTrue(exec.contains("Task.isCancelled"), "PlanExecutor lost its wave-boundary cancellation check")

        // KistRunner: plan-execute AND council AND research escalations run under the ESC watcher
        // (council/research were the review-caught sibling dead zones), and an interrupted plan
        // run must not book a false obstacle lesson.
        let runner = try src("Sources/Kist/KistRunner.swift")
        XCTAssertGreaterThanOrEqual(runner.components(separatedBy: "InterruptibleTurn.run").count - 1, 3,
                                    "an escalation surface (plan-execute/council/research) lost its ESC watcher")
        XCTAssertTrue(runner.contains("!pOut.interrupted"),
                      "runPlanExecute records failure lessons for user-interrupted runs again (memory poisoning)")

        // Both chat surfaces: ABANDON (not delete — panic ESC-hammering must be recoverable) +
        // pre-turn transcript restore on cancel ("dropping this turn" must mean dropped).
        for file in ["Sources/Kist/KistREPL.swift", "Sources/Kist/TUI/TUIConversation.swift"] {
            let text = try src(file)
            XCTAssertTrue(text.contains("LoopCheckpointStore().abandon"),
                          "\(file) no longer abandons the checkpoint on double-ESC")
            XCTAssertFalse(text.contains("LoopCheckpointStore().delete"),
                           "\(file) regressed to DESTRUCTIVE checkpoint deletion on double-ESC")
            XCTAssertTrue(text.contains("preTurnTranscript"),
                          "\(file) no longer restores the pre-turn transcript on double-ESC — the 'dropped' turn pollutes context")
        }
    }

    // MARK: - abandoned checkpoints: recoverable, but never clutter --resume

    func testAbandonedCheckpointHiddenFromResumableButKeptOnDisk() throws {
        let dir = NSTemporaryDirectory() + "r1-cp-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = LoopCheckpointStore(directory: dir)
        var cp = LoopCheckpoint(goal: "g", providerId: "p", model: nil, projectRoot: "/tmp", messages: [])
        cp.status = .paused
        try store.save(cp)
        XCTAssertEqual(store.resumable().map(\.id), [cp.id], "a paused checkpoint is resumable")

        store.abandon(id: cp.id)
        XCTAssertTrue(store.resumable().isEmpty, "an abandoned checkpoint must not clutter --list/--resume-last")
        let reloaded = try store.load(id: cp.id)
        XCTAssertEqual(reloaded.status, .abandoned, "the file is KEPT — explicit --resume <id> can revive it")
    }

    /// Functional: a cancelled task's PlanExecutor returns immediately with no steps run.
    func testPlanExecutorStopsAtWaveBoundaryWhenCancelled() async throws {
        let plan = ExecutablePlan(goal: "list", steps: [
            PlanStep(id: "s1", intent: "list", tool: "list_files"),
        ])
        let tmp = NSTemporaryDirectory() + "r1-exec-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let context = ToolContext(projectRoot: tmp)
        let task = Task {
            // Cancelled before execute is called → the wave-top check must fire before any step.
            await PlanExecutor(tools: .headless(), context: context).execute(plan)
        }
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.stepResults.isEmpty, "no step may launch after cancellation")
    }
}
