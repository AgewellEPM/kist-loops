import XCTest
@testable import AgentCore

/// Regression: a command whose CHILD flushes stderr slightly after the leader exits (exactly how swiftc
/// under `swift test` emits compile errors) must NOT lose that output to the process-group teardown —
/// otherwise the agent sees build successes (stdout) but is blind to build/test FAILURES (stderr).
/// (Absolute paths + shell builtins so the scrubbed-PATH child env doesn't flake the test.)
final class StderrCaptureProbe: XCTestCase {
    func testLeaderStderrCaptured() async {
        let r = await RunCommandTool.spawnAndCollect(
            launchPath: "/bin/sh", launchArgs: ["-c", "echo leader-err >&2; exit 1"],
            cwd: NSTemporaryDirectory(), timeout: 10)
        XCTAssertTrue(r.output.contains("leader-err"), "basic stderr capture: \(r.output)")
    }
    func testLateChildStderrSurvivesGroupTeardown() async {
        let r = await RunCommandTool.spawnAndCollect(
            launchPath: "/bin/sh", launchArgs: ["-c", "( /bin/sleep 0.3; echo late-child-err >&2 ) & exit 1"],
            cwd: NSTemporaryDirectory(), timeout: 10)
        XCTAssertTrue(r.output.contains("late-child-err"),
                      "late child stderr must survive the group grace (swift test's compile errors): '\(r.output)'")
    }
    func testRunawayChildStillReaped() async {
        let r = await RunCommandTool.spawnAndCollect(
            launchPath: "/bin/sh", launchArgs: ["-c", "( /bin/sleep 30 ) & echo done; exit 0"],
            cwd: NSTemporaryDirectory(), timeout: 10)
        XCTAssertTrue(r.output.contains("done"), "returns promptly, doesn't hang on the orphan: \(r.output)")
    }
}
