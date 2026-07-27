import XCTest
@testable import Kist
@testable import AgentCore

/// The great-loop carries the LAST build/test error forward across cycles so the model fixes THAT error
/// instead of rediscovering it (dogfood: a Swift Testing naming-collision compile error was lost every
/// fresh cycle → never converged). These pin when the error is surfaced and when it must NOT be.
final class LastCommandFailureTests: XCTestCase {

    private func rec(_ tool: String, _ ok: Bool, _ detail: String? = nil) -> ActionRecord {
        ActionRecord(tool: tool, argsFingerprint: "command=\(tool)", success: ok, failureDetail: detail)
    }

    func testSurfacesLastFailedRunCommandDetail() {
        let traj = [
            rec("write_file", true),
            rec("run_command", false, "error: use of 'multiply' refers to instance method rather than global function"),
        ]
        let f = KistRunner.lastCommandFailure(in: traj)
        XCTAssertNotNil(f)
        XCTAssertTrue(f!.contains("refers to instance method"))
    }

    func testNilWhenLastRunCommandSucceeded() {
        // A cycle that ended with a PASSING build/test must not push a stale earlier error forward.
        let traj = [
            rec("run_command", false, "error: earlier failure"),
            rec("edit_file", true),
            rec("run_command", true),   // fixed it → last run_command is green
        ]
        XCTAssertNil(KistRunner.lastCommandFailure(in: traj))
    }

    func testNilWhenNoRunCommand() {
        XCTAssertNil(KistRunner.lastCommandFailure(in: [rec("write_file", true), rec("read_file", true)]))
    }

    func testNilWhenFailureHasNoDetail() {
        XCTAssertNil(KistRunner.lastCommandFailure(in: [rec("run_command", false, nil)]))
    }

    func testUsesTheLastFailureNotAnEarlierOne() {
        let traj = [
            rec("run_command", false, "first error"),
            rec("run_command", false, "second error (the current one)"),
        ]
        XCTAssertEqual(KistRunner.lastCommandFailure(in: traj), "second error (the current one)")
    }
}
