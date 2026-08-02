import XCTest
import AgentCore
@testable import Kist

final class ConfidenceReportTests: XCTestCase {
    private func rec(_ tool: String, _ ok: Bool) -> ActionRecord {
        ActionRecord(tool: tool, argsFingerprint: tool, success: ok)
    }

    func testNoActionsYieldsNilReport() {
        let report = TrajectoryAnalyzer.analyze([])
        XCTAssertNil(ConfidenceReport.compute(report: report, grounded: true))
    }

    func testCleanGroundedRunHitsCeiling() {
        let report = TrajectoryAnalyzer.analyze([rec("read_file", true), rec("edit_file", true)])
        let conf = ConfidenceReport.compute(report: report, grounded: true)
        XCTAssertNotNil(conf)
        // 0.95 ceiling, clamped ≤ 0.98 — no drag.
        XCTAssertEqual(conf!.score, 0.95, accuracy: 0.0001)
        XCTAssertTrue(conf!.pending.isEmpty, "a clean grounded run should have no drag factors")
    }

    func testMatchesLegacyFormulaExactly() {
        // Legacy: 0.95 - rate*0.4 - (healthy?0:0.15) - (grounded?0:0.15), clamped [0.30,0.98].
        // 1 failure of 2 = rate 0.5 → -0.2; not grounded → -0.15. Two calls, no runaway/loop issue
        // (identical repeats needed for that), so healthy. Expected 0.95-0.2-0.15 = 0.60.
        let traj = [rec("run_command", true), rec("run_command", false)]
        let report = TrajectoryAnalyzer.analyze(traj)
        let conf = ConfidenceReport.compute(report: report, grounded: false)!
        let legacy = min(0.98, max(0.30, 0.95 - report.failureRate * 0.4 - (report.healthy ? 0 : 0.15) - 0.15))
        XCTAssertEqual(conf.score, legacy, accuracy: 0.0001)
    }

    func testPendingFactorsCarryRaiseActions() {
        let report = TrajectoryAnalyzer.analyze([rec("run_command", false)])
        let conf = ConfidenceReport.compute(report: report, grounded: false)!
        // Reliability + Grounding should both be dragging and each carry a concrete raise action.
        let labels = Set(conf.pending.map { $0.label })
        XCTAssertTrue(labels.contains("Reliability"))
        XCTAssertTrue(labels.contains("Grounding"))
        for f in conf.pending { XCTAssertFalse(f.raise.isEmpty, "pending factor \(f.label) must say how to raise it") }
    }

    func testBatteryBarIsGreenWhenHigh() {
        let report = TrajectoryAnalyzer.analyze([rec("read_file", true)])
        let conf = ConfidenceReport.compute(report: report, grounded: true)!
        let bar = conf.bar(width: 10, color: true)
        XCTAssertTrue(bar.contains("\u{001B}[92;1m"), "high confidence bar should use the green battery code")
        // color:false must emit NO escapes (mono / screen-reader safety).
        XCTAssertFalse(conf.bar(width: 10, color: false).contains("\u{001B}"))
    }

    func testBreakdownNamesFactorsAndRaisePath() {
        let report = TrajectoryAnalyzer.analyze([rec("run_command", false)])
        let conf = ConfidenceReport.compute(report: report, grounded: false)!
        let text = conf.renderBreakdown(color: false)
        XCTAssertTrue(text.contains("Reliability"))
        XCTAssertTrue(text.contains("Grounding"))
        XCTAssertTrue(text.contains("raise:"))
        XCTAssertTrue(text.contains("why"))
    }

    // The dashboard's confidence bar was previously printed with NO color in renderCompact — the
    // regression this whole change fixes. Pin it: the battery code must appear in BOTH renders.
    func testDashboardCompactAndFullBothColorTheConfidenceBar() {
        let report = TrajectoryAnalyzer.analyze([rec("read_file", true)])
        let conf = ConfidenceReport.compute(report: report, grounded: true)!
        let dash = StatusDashboard(minds: [.init(name: "Kist", role: "Captain")], confidenceReport: conf)
        for (label, out) in [("compact", dash.renderCompact(color: true)), ("full", dash.render(color: true))] {
            XCTAssertTrue(out.contains("\u{001B}[92;1m"), "\(label) render must color the confidence bar green")
            XCTAssertTrue(out.contains("/confidence for why"), "\(label) render must point to the dig-in command")
        }
    }

    func testNeonHeadersAreColoredInFullRender() {
        let dash = StatusDashboard(
            minds: [.init(name: "Kist", role: "Captain")],
            tasks: [.init(title: "T", state: .pending)])
        let out = dash.render(color: true)
        XCTAssertTrue(out.contains("\u{001B}[96;1m"), "Active Minds header should be neon cyan")
        XCTAssertTrue(out.contains("\u{001B}[95;1m"), "Build Queue header should be neon magenta")
    }

    func testConfidenceCommandsAreCompletable() {
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/confidence"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/why"))
    }

    func testRecoveryProjectionReturnsToBaseAfterScoreClamp() {
        let trajectory = (0..<6).map { _ in rec("read_file", false) }
        let report = TrajectoryAnalyzer.analyze(trajectory, maxIterations: 6)
        let confidence = ConfidenceReport.compute(report: report, grounded: false)!
        XCTAssertEqual(confidence.score, 0.30, accuracy: 0.0001)
        XCTAssertTrue(
            confidence.renderBreakdown(color: false).contains("raise confidence to ~95%"),
            "clearing every penalty returns to the 95% base, not 98% from adding penalties to a clamped score")
    }

    func testHealthRaiseHintsFollowAnalyzerOrderAndDeduplicate() {
        let trajectory = (0..<6).map { _ in rec("read_file", false) }
        let report = TrajectoryAnalyzer.analyze(trajectory, maxIterations: 6)
        let confidence = ConfidenceReport.compute(report: report, grounded: true)!
        let health = confidence.factors.first { $0.label == "Health" }!
        XCTAssertEqual(
            health.raise,
            "resolve the trajectory issue(s) — break the repeated identical action; "
                + "fix the burst of failing calls; narrow the plan so it finishes within budget; "
                + "make a real change instead of read-only spinning")
    }

    // Codex finding 4: the summary block gained ANSI — color:false (mono / NO_COLOR / screen reader)
    // must still emit ZERO escapes, and color:true must carry the neon section header.
    func testSummaryHonorsColorFlag() {
        let traj = [rec("run_command", false)]
        let plain = KistREPL.renderSimpleSummary(projectRoot: "/tmp", spans: [], trajectory: traj, color: false)
        XCTAssertFalse(plain.contains("\u{001B}"), "mono/NO_COLOR summary must emit no escape sequences")
        XCTAssertTrue(plain.contains("Summary"))
        let colored = KistREPL.renderSimpleSummary(projectRoot: "/tmp", spans: [], trajectory: traj, color: true)
        XCTAssertTrue(colored.contains("\u{001B}[96;1m"), "colored summary header should be neon cyan")
    }
}
