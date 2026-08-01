import XCTest
@testable import AgentCore

/// The two dogfood-found fixes: (1) a raw-shell-denied command is routed to the SAFE executable+args form
/// (not misreported as "shell is off"), and (2) a failed command with no output explains WHY.
final class CapabilityDenialSteerTests: XCTestCase {

    // #1 — the exact denial the live run hit must route to structured executable+args.
    func testRawApprovalDenialRoutesToStructured() {
        let steer = HeadlessAgentLoop.capabilityDenialSteer(
            error: "shell command denied: raw shell commands require interactive approval (unavailable here); use executable+args instead",
            tools: .headless(), shellEnabled: true)
        let s = try! XCTUnwrap(steer)
        XCTAssertTrue(s.contains("executable"))
        XCTAssertTrue(s.lowercased().contains("args"))
        XCTAssertTrue(s.contains("\"swift\""), "gives a concrete build/test example")
        XCTAssertFalse(s.contains("Shell is OFF"), "must NOT mislead the model that shell is off")
        XCTAssertFalse(s.lowercased().contains("custom_tool") && !s.contains("do NOT"), "steers AWAY from custom_tool")
    }

    // A genuine shell-off denial still gets the file-tool advice.
    func testShellOffDenialStillAdvisesFileTools() {
        let steer = HeadlessAgentLoop.capabilityDenialSteer(
            error: "shell is disabled in this session", tools: .headless(), shellEnabled: false)
        let s = try! XCTUnwrap(steer)
        XCTAssertTrue(s.contains("Shell is OFF"))
        XCTAssertTrue(s.contains("write_file"))
    }

    func testNonDenialErrorReturnsNil() {
        XCTAssertNil(HeadlessAgentLoop.capabilityDenialSteer(
            error: "file not found: foo.txt", tools: .headless(), shellEnabled: true))
    }

    // #2 — a command that fails silently must not leave the agent blind.
    func testFailedCommandWithNoOutputExplainsWhy() async {
        let r = await RunCommandTool.spawnAndCollect(
            launchPath: "/usr/bin/false", launchArgs: [], cwd: NSTemporaryDirectory(), timeout: 10)
        XCTAssertFalse(r.success)
        // An empty non-zero exit must EXPLAIN itself — the message names it as a commonly-NORMAL result
        // (e.g. `which`/`grep`/`test` matched nothing) rather than a bare "exit code 1" or a false
        // "sandbox/resource kill" cry.
        let e = r.error ?? ""
        XCTAssertTrue(e.contains("no output") && e.contains("NORMAL"),
                      "an empty non-zero exit must explain itself, not just 'exit code 1': \(e)")
    }
}
