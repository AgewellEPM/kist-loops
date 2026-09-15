import XCTest
import Foundation
@testable import AgentCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class BackgroundJobLifecycleTests: XCTestCase {
    private var root: URL!
    private var store: BackgroundJobStore!
    private let environment = ["PATH": "/usr/bin:/bin"]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("background-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = BackgroundJobStore()
    }

    override func tearDownWithError() throws {
        XCTAssertTrue(store.killAll(), "all test commands must finish process-group cleanup")
        try FileManager.default.removeItem(at: root)
    }

    private func start(_ script: String, timeout: Int = 30) throws -> BackgroundJobStore.Job {
        let id = try XCTUnwrap(store.start(launchPath: "/bin/sh", args: ["-c", script], cwd: root.path,
                                          env: environment, command: "test fixture", timeoutSeconds: timeout))
        return try XCTUnwrap(store.job(id))
    }

    private func waitForFile(_ name: String, timeout: Double = 3) -> URL? {
        let file = root.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: file.path) { return file }
            usleep(20_000)
        }
        return nil
    }

    private func assertGone(_ pid: Int32, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if kill(pid, 0) == -1 && errno == ESRCH { return }
            usleep(20_000)
        }
        // Cleanup a failed assertion as well; the PID belongs to this freshly observed fixture.
        _ = kill(pid, SIGKILL)
        XCTFail("fixture process \(pid) survived cleanup", file: file, line: line)
    }

    func testChattyJobKeepsNewestOutputAndPollingReleasesIt() throws {
        let emitted = BackgroundJobStore.maxOutputBytes * 3
        let job = try start("yes output | head -c \(emitted); printf 'LATEST-END\\n'")
        XCTAssertEqual(job.completion.wait(timeout: .now() + .seconds(5)), .success)
        XCTAssertEqual(job.exitCode, 0, "crossing the retained-output limit must not kill an ordinary watcher")
        XCTAssertLessThanOrEqual(job.retainedOutputBytes, BackgroundJobStore.maxOutputBytes)
        let output = job.readNew(maxBytes: BackgroundJobStore.maxOutputBytes + 128)
        XCTAssertTrue(output.contains("background output truncated"))
        XCTAssertTrue(output.hasSuffix("LATEST-END\n"), "newest output must survive the bounded queue")
        XCTAssertEqual(job.retainedOutputBytes, 0)
        XCTAssertEqual(job.readNew(), "", "polling must not replay consumed output")
    }

    func testNormalReturnCleansChildThatClosedOutput() throws {
        let job = try start("(exec >/dev/null 2>&1; sleep 30) & echo $! > child.pid; exit 0")
        let pidFile = try XCTUnwrap(waitForFile("child.pid"))
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(job.completion.wait(timeout: .now() + .seconds(5)), .success)
        assertGone(pid)
        XCTAssertEqual(store.runningCount(), 0)
    }

    func testStopEscalatesAndCleansAnIgnoringProcessGroup() throws {
        let job = try start("trap '' TERM; sleep 30 & echo $! > child.pid; echo $$ > leader.pid; wait")
        let child = try XCTUnwrap(waitForFile("child.pid"))
        let leader = try XCTUnwrap(waitForFile("leader.pid"))
        let childPID = try XCTUnwrap(Int32(String(contentsOf: child).trimmingCharacters(in: .whitespacesAndNewlines)))
        let leaderPID = try XCTUnwrap(Int32(String(contentsOf: leader).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(store.kill(job.id))
        assertGone(childPID)
        assertGone(leaderPID)
        XCTAssertEqual(store.runningCount(), 0)
        XCTAssertTrue(job.readNew().contains("background job cancelled"))
    }

    func testFiniteBackgroundTimeoutIsVisibleAndCleansChildren() throws {
        let job = try start("sleep 30 & echo $! > child.pid; wait", timeout: 1)
        let child = try XCTUnwrap(waitForFile("child.pid"))
        let pid = try XCTUnwrap(Int32(String(contentsOf: child).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(job.completion.wait(timeout: .now() + .seconds(5)), .success)
        assertGone(pid)
        XCTAssertTrue(job.readNew().contains("timed out after 1s"))
        XCTAssertNotEqual(job.exitCode, 0)
    }

    func testFinishedJobRetentionIsBounded() throws {
        var ids: [String] = []
        for _ in 0..<(BackgroundJobStore.maxFinishedJobs + 5) {
            let job = try start("exit 0")
            ids.append(job.id)
            XCTAssertEqual(job.completion.wait(timeout: .now() + .seconds(3)), .success)
        }
        XCTAssertEqual(store.runningCount(), 0)
        XCTAssertEqual(store.list().count, BackgroundJobStore.maxFinishedJobs)
        XCTAssertNil(store.job(ids[0]))
        XCTAssertNotNil(store.job(try XCTUnwrap(ids.last)))
    }

    func testBackgroundStdinIsClosedAndLaunchFailureReleasesSlot() throws {
        let job = try start("cat")
        XCTAssertEqual(job.completion.wait(timeout: .now() + .seconds(3)), .success)
        XCTAssertEqual(job.exitCode, 0)
        XCTAssertNil(store.start(launchPath: "/nonexistent/kist-fixture", args: [], cwd: root.path,
                                env: environment, command: "missing executable"))
        let deadline = Date().addingTimeInterval(2)
        while store.runningCount() > 0 && Date() < deadline { usleep(20_000) }
        XCTAssertEqual(store.runningCount(), 0)
    }
}

final class RunCommandLifecycleCancellationTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("command-cancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testCancellationBeforeLaunchPreventsSideEffects() async {
        let directory = root.path
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await RunCommandTool.spawnAndCollect(
                launchPath: "/bin/sh", launchArgs: ["-c", "echo unwanted > marker"], cwd: directory, timeout: 30)
        }
        let result = await task.value
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.metadata["cancelled"], "true")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
    }

    func testCancellationWaitsForChildCleanupEvenWhenLeaderExitsZero() async throws {
        let directory = root.path
        let pidFile = root.appendingPathComponent("child.pid")
        let task = Task {
            await RunCommandTool.spawnAndCollect(
                launchPath: "/bin/sh", launchArgs: ["-c", "trap 'exit 0' TERM; sleep 30 & echo $! > child.pid; wait"],
                cwd: directory, timeout: 30)
        }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: pidFile.path) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let started = Date()
        task.cancel()
        let result = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.metadata["cancelled"], "true")
        XCTAssertEqual(result.metadata["verification_eligible"], "false")
        XCTAssertEqual(result.metadata["exit_code"], "0", "child must receive TERM and run its exit-zero trap")
        XCTAssertEqual(result.error, "command cancelled")
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        let goneDeadline = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0 && Date() < goneDeadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        let gone = kill(pid, 0) == -1 && errno == ESRCH
        if !gone { _ = kill(pid, SIGKILL) }
        XCTAssertTrue(gone, "cancelled command must not leave its child alive")
    }

    func testPublicRunnerDrainsStderrAndReportsTruncation() async {
        let result = await BoundedProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", "trap '' TERM; yes error 1>&2"], cwd: root.path,
            environment: ["PATH": "/usr/bin:/bin"], timeoutSeconds: 5, maximumOutputBytes: 4_096)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.outputTruncated)
        XCTAssertFalse(result.stderr.isEmpty)
        XCTAssertFalse(result.timedOut)
    }

    func testChildRestoresTERMWhenParentIgnoresIt() {
        let previous = signal(SIGTERM, SIG_IGN)
        defer { _ = signal(SIGTERM, previous) }
        let outcome = ProcessGroupRunner.run(
            launchPath: "/bin/sh",
            launchArgs: ["-c", "trap 'echo TERM-HANDLED; exit 0' TERM; while :; do sleep 1; done"],
            cwd: root.path, env: ["PATH": "/usr/bin:/bin"], timeoutSeconds: 1,
            capPerStream: 4_096, graceSeconds: 1)
        XCTAssertTrue(outcome.timedOut)
        XCTAssertEqual(outcome.exitCode, 0, "the child must be able to install and execute its TERM trap")
        XCTAssertTrue(outcome.stdout.contains("TERM-HANDLED"))
    }

    func testPublicRunnerPassesStdinAndExitCode() async {
        let input = Data("stdin payload\n".utf8)
        let result = await BoundedProcessRunner.run(
            executable: "/bin/cat", arguments: [], cwd: root.path, environment: [:],
            timeoutSeconds: 5, maximumOutputBytes: 4_096, stdin: input)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout, String(decoding: input, as: UTF8.self))
    }
}
