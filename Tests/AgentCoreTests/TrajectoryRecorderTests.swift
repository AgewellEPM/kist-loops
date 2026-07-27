import XCTest
@testable import AgentCore

final class TrajectoryRecorderTests: XCTestCase {

    func testRecordSnapshotReset() {
        let r = TrajectoryRecorder()
        r.record(tool: "read_file", argsFingerprint: "a", success: true)
        r.record(tool: "edit_file", argsFingerprint: "b", success: false)
        XCTAssertEqual(r.snapshot().count, 2)
        XCTAssertEqual(r.snapshot()[1].success, false)
        r.reset()
        XCTAssertTrue(r.snapshot().isEmpty)
    }

    func testFeedsTrajectoryAnalyzerEndToEnd() {
        let r = TrajectoryRecorder()
        for _ in 0..<3 { r.record(tool: "edit_file", argsFingerprint: "same", success: true) }
        let report = TrajectoryAnalyzer.analyze(r.snapshot())
        XCTAssertEqual(report.issues.first?.kind, .runawayLoop)   // recorder → analyzer pipeline works
    }

    func testConcurrentRecordsAreCounted() async {
        let r = TrajectoryRecorder()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 { group.addTask { r.record(tool: "t", argsFingerprint: "\(i)", success: true) } }
        }
        XCTAssertEqual(r.snapshot().count, 100)   // lock-guarded, no lost updates
    }
}
