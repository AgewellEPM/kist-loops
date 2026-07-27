import XCTest
@testable import AgentCore

/// The governor is what lets the loop run long enough to FINISH hard tasks while still stopping a genuine
/// spin. Its most important property: it does NOT stop a long-but-progressing run — only loops, failure
/// spikes, and the absolute ceiling stop it.
final class ProgressGovernorTests: XCTestCase {

    func rec(_ tool: String, _ args: String = "a", _ ok: Bool = true) -> ActionRecord {
        ActionRecord(tool: tool, argsFingerprint: args, success: ok)
    }
    /// A long, varied, mostly-successful trajectory — real progress on a hard task.
    func productive(_ n: Int) -> [ActionRecord] {
        (0..<n).map { i in rec(["read_file","edit_file","run_command","search_code","apply_patch"][i % 5], "step\(i)") }
    }

    let gov = ProgressGovernor(hardCeiling: 60, stuckRepeat: 5)

    func testLongButProgressingRunKeepsGoing() {
        // 40 varied productive steps — this is EXACTLY the case the old flat cap killed.
        XCTAssertEqual(gov.decide(iteration: 40, trajectory: productive(40)), .cont)
    }

    func testStopsAtHardCeiling() {
        if case .stopCeiling = gov.decide(iteration: 60, trajectory: productive(60)) {} else { XCTFail("expected ceiling") }
    }

    func testStopsOnRepeatedIdenticalAction() {
        let traj = productive(10) + Array(repeating: rec("edit_file", "same"), count: 5)
        if case .stopStuck = gov.decide(iteration: 15, trajectory: traj) {} else { XCTFail("expected stuck") }
    }

    func testStopsOnCyclicLoop() {
        // read A -> test -> read A -> test ... repeated — the alternating spin
        let cycle = (0..<6).flatMap { _ in [rec("read_file","A"), rec("run_command","T")] }
        if case .stopStuck = gov.decide(iteration: 20, trajectory: productive(8) + cycle) {} else { XCTFail("expected stuck") }
    }

    func testStopsOnSustainedFailureSpike() {
        let failing = Array(repeating: rec("run_command", "x", false), count: 10)
            .enumerated().map { rec("run_command", "x\($0.offset)", false) }  // distinct args, all failing
        if case .stopStuck = gov.decide(iteration: 12, trajectory: failing) {} else { XCTFail("expected failure spike stop") }
    }

    func testShortLoopBelowStuckBarKeepsGoing() {
        // repeated 3× — the in-loop nudge fires here; the governor must NOT hard-stop yet (give recovery a chance)
        let traj = productive(6) + Array(repeating: rec("edit_file", "same"), count: 3)
        XCTAssertEqual(gov.decide(iteration: 9, trajectory: traj), .cont)
    }

    func testEarlyFailuresDoNotDoomARecoveredRun() {
        // first steps failed, but the recent window is all healthy progress → keep going
        let early = Array(repeating: rec("run_command", "boom", false), count: 4)
        XCTAssertEqual(gov.decide(iteration: 20, trajectory: early + productive(16)), .cont)
    }

    func testTooLittleHistoryKeepsGoing() {
        XCTAssertEqual(gov.decide(iteration: 2, trajectory: productive(2)), .cont)
    }

    func testCeilingIsTheOnlyCapOnHealthyWork() {
        // 59 productive steps, under a 60 ceiling → still going; the governor never stops honest long work
        XCTAssertEqual(gov.decide(iteration: 59, trajectory: productive(59)), .cont)
    }

    // Codex regression: after a recovery reset, the STALE stuck-pattern must not re-stop the run.
    func testAnalyzeFromSkipsStaleStuckPrefix() {
        let stalePrefix = Array(repeating: rec("edit_file", "same"), count: 6)   // the loop that triggered recovery
        let afterReset = productive(6)                                           // varied new work since
        let traj = stalePrefix + afterReset
        // Without the cursor the stale loop is still in-window and WOULD stop:
        if case .stopStuck = gov.decide(iteration: 12, trajectory: traj) {} else { XCTFail("stale loop stops w/o cursor") }
        // With analyzeFrom at the reset, only the healthy post-reset work is judged → keep going:
        XCTAssertEqual(gov.decide(iteration: 12, trajectory: traj, analyzeFrom: stalePrefix.count), .cont)
    }

    func testAnalyzeFromStillStopsOnAFreshLoopAfterRecovery() {
        // recovered, then got stuck AGAIN on new actions → really stop
        let prefix = productive(6)
        let freshLoop = Array(repeating: rec("run_command", "again"), count: 5)
        if case .stopStuck = gov.decide(iteration: 12, trajectory: prefix + freshLoop, analyzeFrom: prefix.count) {}
        else { XCTFail("a fresh loop after recovery must still stop") }
    }

    func testAnalyzeFromWithTooFewNewActionsKeepsGoing() {
        // right after the reset only a couple new actions exist → not enough to judge → give recovery its chance
        let traj = Array(repeating: rec("edit_file", "same"), count: 6) + [rec("read_file"), rec("write_file")]
        XCTAssertEqual(gov.decide(iteration: 10, trajectory: traj, analyzeFrom: 6), .cont)
    }

    func testRecoverySteeringDemandsADifferentApproach() {
        let s = ProgressGovernor.recoverySteering(reason: "repeated edit_file 5×").lowercased()
        XCTAssertTrue(s.contains("stop"))
        XCTAssertTrue(s.contains("different"))       // the whole point: abandon, don't tweak
        XCTAssertTrue(s.contains("goal"))            // re-anchor on the goal
    }
}
