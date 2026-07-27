import XCTest
@testable import AgentCore

/// Tool-error spiral detection — the tail-of-identical-failures signal and the corrective steer. Pure.
final class ToolSpiralDetectorTests: XCTestCase {

    private func rec(_ tool: String, _ fp: String, _ ok: Bool) -> ActionRecord {
        ActionRecord(tool: tool, argsFingerprint: fp, success: ok)
    }

    func testDetectsThreeIdenticalFailures() {
        let t = [rec("edit_file", "path=x", false), rec("edit_file", "path=x", false), rec("edit_file", "path=x", false)]
        let s = ToolSpiralDetector.detect(t)
        XCTAssertEqual(s?.tool, "edit_file")
        XCTAssertEqual(s?.count, 3)
        XCTAssertEqual(s?.signature, "edit_file|path=x")
    }

    func testNoSpiralWhenLastSucceeded() {
        let t = [rec("edit_file", "path=x", false), rec("edit_file", "path=x", false), rec("edit_file", "path=x", true)]
        XCTAssertNil(ToolSpiralDetector.detect(t), "a success at the tail means it's not currently spiraling")
    }

    func testNoSpiralBelowThreshold() {
        let t = [rec("edit_file", "path=x", false), rec("edit_file", "path=x", false)]
        XCTAssertNil(ToolSpiralDetector.detect(t), "2 < default minRepeats(3)")
    }

    func testStreakCountsOnlyTheIdenticalTail() {
        // Earlier unrelated work then a fresh 3-deep identical-failure tail.
        let t = [rec("read_file", "a", true), rec("run_command", "ls", true),
                 rec("edit_file", "path=y", false), rec("edit_file", "path=y", false), rec("edit_file", "path=y", false)]
        let s = ToolSpiralDetector.detect(t)
        XCTAssertEqual(s?.count, 3)
        XCTAssertEqual(s?.tool, "edit_file")
    }

    func testDifferentArgsBreakTheSpiral() {
        // Same tool, but the model VARIED the args each time → not an identical-call spiral (it's trying).
        let t = [rec("edit_file", "path=a", false), rec("edit_file", "path=b", false), rec("edit_file", "path=c", false)]
        XCTAssertNil(ToolSpiralDetector.detect(t))
    }

    func testSuccessInTailBreaksStreak() {
        let t = [rec("edit_file", "x", false), rec("edit_file", "x", true), rec("edit_file", "x", false)]
        XCTAssertNil(ToolSpiralDetector.detect(t), "only 1 failure at the very tail")
    }

    func testSteerNamesCallErrorAndForbidsRepeat() {
        let steer = ToolSpiralDetector.steer(tool: "edit_file", count: 4,
                                             error: "no such file: /bad/path.swift",
                                             validTools: ["read_file", "make_dir"])
        XCTAssertTrue(steer.contains("edit_file"))
        XCTAssertTrue(steer.contains("4 times"))
        XCTAssertTrue(steer.contains("no such file"))
        XCTAssertTrue(steer.lowercased().contains("do not call"))
        XCTAssertTrue(steer.contains("read_file"))
    }
}
