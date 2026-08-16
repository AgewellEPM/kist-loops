import XCTest
import Foundation
@testable import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Proves the open HIGH is closed: on timeout (and on return) the WHOLE process group is
/// torn down, so a forked grandchild does not orphan. The `kill(pid,0)==ESRCH` assertion is
/// the discriminator — under the OLD PID-only `terminate()`, the backgrounded `sleep 30`
/// grandchild would still be alive (~29s left) and `kill` would return 0. So this test FAILS
/// if anyone reverts to single-PID kill.
final class ProcessGroupRunnerTests: XCTestCase {

    private var cwd: String!
    private let env = ["PATH": "/usr/bin:/bin"]

    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "pgr-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        cwd = ToolContext.canonicalize(base)
    }
    override func tearDownWithError() throws {
        if let cwd { try? FileManager.default.removeItem(atPath: cwd) }
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }
    private func isGone(_ pid: pid_t) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }
    private func waitGone(_ pid: pid_t, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if isGone(pid) { return true }; usleep(20_000) }
        return isGone(pid)
    }

    private func readGrandchildPID(_ file: String, timeout: TimeInterval = 5) -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = try? String(contentsOfFile: file, encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if let v = pid_t(t) { return v }
            }
            usleep(20_000)
        }
        return nil
    }

    // MARK: - The core invariant, over a multi-surface table (per multi-site discipline)

    func testTimeoutKillsForkedGrandchild() throws {
        // Each surface forks a backgrounded `sleep 30` grandchild and publishes its PID.
        let surfaces: [(name: String, script: (String) -> String)] = [
            ("background-amp", { pf in "sleep 30 & echo $! > '\(pf)'; echo ready; wait" }),
            ("nested-sh",      { pf in "sh -c 'sleep 30 & echo $! > \"\(pf)\"'; echo ready; sleep 5" }),
        ]

        for surface in surfaces {
            let pidfile = cwd + "/gc-\(surface.name).pid"
            // run() blocks: it spawns, times out at 1s, killpg SIGTERM→grace→SIGKILL, reaps, sweeps.
            let outcome = ProcessGroupRunner.run(
                launchPath: "/bin/sh", launchArgs: ["-c", surface.script(pidfile)],
                cwd: cwd, env: env, timeoutSeconds: 1, capPerStream: 100_000, graceSeconds: 1
            )
            XCTAssertTrue(outcome.timedOut, "[\(surface.name)] should report a timeout")

            guard let gc = readGrandchildPID(pidfile) else {
                return XCTFail("[\(surface.name)] grandchild never published its PID")
            }
            // The decisive check: a `sleep 30` grandchild is gone only because the GROUP was
            // killed. EPERM would mean alive-but-not-ours (sandbox) — also a failure here.
            XCTAssertTrue(waitGone(gc),
                "[\(surface.name)] grandchild \(gc) must be dead after group teardown; a PID-only kill would leave it alive")
        }
    }

    func testNormalReturnSweepsBackgroundGrandchild() throws {
        // No timeout, no `wait`: the shell exits immediately but leaves a backgrounded
        // `sleep 30`. The post-exit group sweep must still kill it so nothing orphans.
        let pidfile = cwd + "/gc-normal.pid"
        let o = ProcessGroupRunner.run(
            launchPath: "/bin/sh", launchArgs: ["-c", "sleep 30 & echo $! > '\(pidfile)'; echo ready"],
            cwd: cwd, env: env, timeoutSeconds: 10, capPerStream: 100_000)
        XCTAssertFalse(o.timedOut, "should exit normally, not time out")
        guard let gc = readGrandchildPID(pidfile) else { return XCTFail("grandchild never published its PID") }
        XCTAssertTrue(waitGone(gc), "background grandchild \(gc) must be swept on normal return")
    }

    func testOutputCapSweepsBackgroundGrandchild() throws {
        // Flood stdout past the cap (not a timeout): the cap callback tears the group down,
        // which must also take out the backgrounded grandchild.
        let pidfile = cwd + "/gc-cap.pid"
        let o = ProcessGroupRunner.run(
            launchPath: "/bin/sh", launchArgs: ["-c", "sleep 30 & echo $! > '\(pidfile)'; yes kist"],
            cwd: cwd, env: env, timeoutSeconds: 20, capPerStream: 2_000)
        XCTAssertFalse(o.timedOut, "cap (not timeout) should end the run")
        guard let gc = readGrandchildPID(pidfile) else { return XCTFail("grandchild never published its PID") }
        XCTAssertTrue(waitGone(gc), "grandchild \(gc) must be swept after the output cap tears the group down")
    }

    func testSetsidGrandchildIsAKnownResidual() throws {
        // DOCUMENTED LIMITATION, not a covered case: a grandchild that calls setsid() leaves
        // the process group and survives killpg. We assert the honest reality (it may survive)
        // rather than pretend the group approach catches it. cgroup-v2 / PID-ns is the upgrade.
        throw XCTSkip("setsid-escaped descendants survive killpg by design — tracked as a residual (cgroup-v2 future tier)")
    }

    // MARK: - Normal path

    func testCapturesStdoutAndExitZero() {
        let o = ProcessGroupRunner.run(launchPath: "/bin/sh", launchArgs: ["-c", "echo hello-kist"],
                                       cwd: cwd, env: env, timeoutSeconds: 10, capPerStream: 100_000)
        XCTAssertFalse(o.timedOut)
        XCTAssertEqual(o.exitCode, 0)
        XCTAssertTrue(o.combined.contains("hello-kist"), o.combined)
        XCTAssertFalse(o.stdoutTruncated)
        XCTAssertFalse(o.stderrTruncated)
        XCTAssertFalse(o.outputTruncated)
    }

    func testExitCodePropagates() {
        let o = ProcessGroupRunner.run(launchPath: "/bin/sh", launchArgs: ["-c", "exit 7"],
                                       cwd: cwd, env: env, timeoutSeconds: 10, capPerStream: 100_000)
        XCTAssertFalse(o.timedOut)
        XCTAssertEqual(o.exitCode, 7)
        XCTAssertFalse(o.wasSignalled, "a clean exit(7) is NOT a signal kill")
    }

    // A process KILLED BY A SIGNAL must report wasSignalled=true + 128+signal — the signature
    // RunCommandTool uses to tell an OS-sandbox/resource-limit kill apart from a clean non-zero exit.
    func testSignalKillSetsWasSignalled() {
        let o = ProcessGroupRunner.run(launchPath: "/bin/sh", launchArgs: ["-c", "kill -KILL $$"],
                                       cwd: cwd, env: env, timeoutSeconds: 10, capPerStream: 100_000)
        XCTAssertFalse(o.timedOut)
        XCTAssertTrue(o.wasSignalled, "SIGKILL must set wasSignalled")
        XCTAssertGreaterThanOrEqual(o.exitCode, 128, "signalled → 128+signal (got \(o.exitCode))")
    }

    // THE FIX (2026-08-01): a clean non-zero exit with no output (e.g. `which nasm` when nasm is
    // absent) must NOT be misreported as an OS-sandbox / resource-limit kill.
    func testRunCommandCleanNonZeroIsNotMisreportedAsKill() async {
        let r = await RunCommandTool.spawnAndCollect(launchPath: "/bin/sh", launchArgs: ["-c", "exit 1"],
                                                     cwd: cwd, timeout: 10)
        XCTAssertFalse(r.success)
        let err = (r.error ?? "").lowercased()
        XCTAssertFalse(err.contains("sandbox"), "clean exit 1 wrongly blamed on the sandbox: \(err)")
        XCTAssertFalse(err.contains("resource limit"), "clean exit 1 wrongly blamed on a resource limit: \(err)")
        XCTAssertTrue(err.contains("normal non-zero"), "should read as a normal non-zero result: \(err)")
    }

    // A genuine signal kill SHOULD still surface the sandbox/resource-limit framing.
    func testRunCommandSignalKillIsReportedAsSignal() async {
        let r = await RunCommandTool.spawnAndCollect(launchPath: "/bin/sh", launchArgs: ["-c", "kill -KILL $$"],
                                                     cwd: cwd, timeout: 10)
        XCTAssertFalse(r.success)
        let err = (r.error ?? "").lowercased()
        XCTAssertTrue(err.contains("signal") && err.contains("resource limit"),
                      "a real signal kill should name the signal + resource-limit cause: \(err)")
    }

    func testStderrIsCaptured() {
        let o = ProcessGroupRunner.run(launchPath: "/bin/sh", launchArgs: ["-c", "echo oops 1>&2"],
                                       cwd: cwd, env: env, timeoutSeconds: 10, capPerStream: 100_000)
        XCTAssertTrue(o.combined.contains("oops"), o.combined)
    }

    func testOutputIsByteCapped() {
        // Emit far more than the cap; combined must be bounded (+ small truncation slack).
        let o = ProcessGroupRunner.run(launchPath: "/bin/sh", launchArgs: ["-c", "yes kist | head -n 100000"],
                                       cwd: cwd, env: env, timeoutSeconds: 10, capPerStream: 2_000)
        XCTAssertLessThanOrEqual(o.combined.utf8.count, 2_000 + 100)
        XCTAssertTrue(o.stdoutTruncated)
        XCTAssertFalse(o.stderrTruncated)
        XCTAssertTrue(o.outputTruncated)
    }

    func testStderrAndAggregateTruncationAreReportedSeparately() {
        let stderr = ProcessGroupRunner.run(
            launchPath: "/bin/sh", launchArgs: ["-c", "yes error 1>&2"],
            cwd: cwd, env: env, timeoutSeconds: 10, capPerStream: 2_000)
        XCTAssertFalse(stderr.stdoutTruncated)
        XCTAssertTrue(stderr.stderrTruncated)
        XCTAssertTrue(stderr.outputTruncated)

        let aggregate = ProcessGroupRunner.run(
            launchPath: "/bin/sh",
            launchArgs: ["-c", "yes o | head -c 700; yes e | head -c 700 1>&2"],
            cwd: cwd, env: env, timeoutSeconds: 10, capPerStream: 1_000)
        XCTAssertFalse(aggregate.stdoutTruncated)
        XCTAssertFalse(aggregate.stderrTruncated)
        XCTAssertTrue(aggregate.outputTruncated)
    }

    func testTimeoutReportedForSimpleSleep() {
        let o = ProcessGroupRunner.run(launchPath: "/bin/sh", launchArgs: ["-c", "sleep 30"],
                                       cwd: cwd, env: env, timeoutSeconds: 1, capPerStream: 100_000, graceSeconds: 1)
        XCTAssertTrue(o.timedOut)
        XCTAssertNotEqual(o.exitCode, 0)
    }
}
