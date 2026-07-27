import XCTest
import Foundation
@testable import AgentCore

/// The worker↔supervisor sentinel contract + the in-process spawn seam (foundation; the supervisor
/// that polls these is Stage 2).
final class FleetSpawnTests: XCTestCase {

    private var dir: String!
    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "fleetspawn-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: dir) }

    private func waitFor(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 2.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    // MARK: - Sentinel: progress log

    func testProgressAppendAndReadRoundTrip() {
        FleetSentinel.appendProgress(FleetProgressEvent(step: 1, action: "edit", file: "a.swift", at: 100), inWorktree: dir)
        FleetSentinel.appendProgress(FleetProgressEvent(step: 2, action: "test", at: 101, note: "green"), inWorktree: dir)
        let events = FleetSentinel.readProgress(inWorktree: dir)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].action, "edit")
        XCTAssertEqual(events[0].file, "a.swift")
        XCTAssertEqual(events[1].step, 2)            // newest last
        XCTAssertEqual(events[1].note, "green")
        XCTAssertNil(events[1].file)
    }

    func testReadProgressFailSoft() {
        // Missing file → []; garbage lines skipped, valid ones survive.
        XCTAssertEqual(FleetSentinel.readProgress(inWorktree: dir).count, 0)
        let file = dir + "/" + FleetSentinel.progressFileName
        let good = #"{"step":1,"action":"x","at":1}"#
        try? Data("not json\n\(good)\n{also bad}\n".utf8).write(to: URL(fileURLWithPath: file))
        let events = FleetSentinel.readProgress(inWorktree: dir)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.action, "x")
    }

    func testProgressEventCodableRoundTrip() throws {
        let e = FleetProgressEvent(step: 3, action: "commit", file: "Core/Foo.swift", at: 42.5, note: "n")
        let back = try JSONDecoder().decode(FleetProgressEvent.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(back, e)
    }

    // MARK: - Sentinel: done marker

    func testDoneMarker() {
        XCTAssertFalse(FleetSentinel.isDone(inWorktree: dir))
        XCTAssertNil(FleetSentinel.doneSummary(inWorktree: dir))
        FleetSentinel.markDone(inWorktree: dir, summary: "wrote 2 files, tests green")
        XCTAssertTrue(FleetSentinel.isDone(inWorktree: dir))
        XCTAssertEqual(FleetSentinel.doneSummary(inWorktree: dir), "wrote 2 files, tests green")
    }

    // MARK: - In-process spawner

    func testInProcessSpawnerLaunchesWorkInBackground() async {
        let wt = GitWorktree(repo: "/repo", path: dir, branch: "mythos/bg", base: "abc")
        let spawner = InProcessAgentSpawner { _, worktree in
            try? await Task.sleep(nanoseconds: 150_000_000)
            try? Data("done".utf8).write(to: URL(fileURLWithPath: worktree.path + "/background.txt"))
            return "background complete"
        }

        let ok = await spawner.spawn(task: "slow work", worktree: wt)

        XCTAssertTrue(ok)
        XCTAssertFalse(FleetSentinel.isDone(inWorktree: dir), "spawn returns launch status, not work completion")
        let completed = await waitFor { FleetSentinel.isDone(inWorktree: self.dir) }
        XCTAssertTrue(completed)
        XCTAssertEqual(try? String(contentsOfFile: dir + "/background.txt", encoding: .utf8), "done")
    }

    func testInProcessSpawnerRunsWorkInWorktreeAndMarksDone() async {
        // The injected work writes a marker file inside the worktree + returns a summary. spawn must
        // launch it and then write the done sentinel when that background work completes.
        let wt = GitWorktree(repo: "/repo", path: dir, branch: "mythos/x", base: "abc")
        let spawner = InProcessAgentSpawner { task, worktree in
            try? Data(task.utf8).write(to: URL(fileURLWithPath: worktree.path + "/ran.txt"))
            return "did: \(task)"
        }
        let ok = await spawner.spawn(task: "build the thing", worktree: wt)
        XCTAssertTrue(ok)
        let completed = await waitFor { FleetSentinel.isDone(inWorktree: self.dir) }
        XCTAssertTrue(completed)
        XCTAssertEqual(try? String(contentsOfFile: dir + "/ran.txt", encoding: .utf8), "build the thing")
        XCTAssertTrue(FleetSentinel.isDone(inWorktree: dir))
        XCTAssertEqual(FleetSentinel.doneSummary(inWorktree: dir), "did: build the thing")
    }

    func testSpawnerWorkCanReportProgress() async {
        // A worker can append progress as it goes; the supervisor would read it live.
        let wt = GitWorktree(repo: "/repo", path: dir, branch: "mythos/y", base: "abc")
        let spawner = InProcessAgentSpawner { _, worktree in
            FleetSentinel.appendProgress(FleetProgressEvent(step: 1, action: "working", at: 1), inWorktree: worktree.path)
            return "ok"
        }
        _ = await spawner.spawn(task: "t", worktree: wt)
        let completed = await waitFor { FleetSentinel.isDone(inWorktree: self.dir) }
        XCTAssertTrue(completed)
        XCTAssertEqual(FleetSentinel.readProgress(inWorktree: dir).first?.action, "working")
        XCTAssertTrue(FleetSentinel.isDone(inWorktree: dir))
    }
}
