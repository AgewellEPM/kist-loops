import XCTest
import Foundation
@testable import AgentCore

/// Security: a hijacked agent must not be able to spawn unbounded background processes. The store
/// caps concurrently-running jobs and refuses `start` past the ceiling.
final class BackgroundJobStoreTests: XCTestCase {

    /// Spin (bounded) until the store drains to zero live jobs — termination is async, so a bare
    /// killAll() doesn't immediately zero runningCount(). Keeps the singleton test hermetic.
    private func waitUntilDrained(_ store: BackgroundJobStore, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while store.runningCount() > 0 && Date() < deadline { usleep(20_000) }
    }

    func testBackgroundJobCapBoundsConcurrency() {
        let store = BackgroundJobStore.shared
        store.killAll(); waitUntilDrained(store)          // hermetic clean slate
        XCTAssertEqual(store.runningCount(), 0, "precondition: store drained before the test")
        var ids: [String] = []
        defer { for id in ids { _ = store.kill(id) }; store.killAll(); waitUntilDrained(store) }

        // Spawn well past the cap; each successful start is a long-lived sleep. We must never exceed
        // the ceiling, and the loop must stop getting ids once we hit it.
        for _ in 0..<(BackgroundJobStore.maxConcurrentRunning + 5) {
            guard let id = store.start(launchPath: "/bin/sleep", args: ["30"],
                                       cwd: NSTemporaryDirectory(), env: [:], command: "sleep") else { break }
            ids.append(id)
        }

        XCTAssertEqual(ids.count, BackgroundJobStore.maxConcurrentRunning,
                       "exactly cap jobs should start from a drained store")
        XCTAssertLessThanOrEqual(store.runningCount(), BackgroundJobStore.maxConcurrentRunning,
                                 "running jobs must never exceed the cap")
        XCTAssertNil(store.start(launchPath: "/bin/sleep", args: ["30"],
                                 cwd: NSTemporaryDirectory(), env: [:], command: "sleep"),
                     "at the cap, a further start must be refused (returns nil)")
    }

    /// Regression for the reserve-race: many CONCURRENT starts (like a plan executor's task group)
    /// must not collectively blow past the cap. Without atomic check-and-reserve, all would observe
    /// "< cap" before any insert and over-spawn.
    func testConcurrentStartsNeverExceedCap() {
        let store = BackgroundJobStore.shared
        store.killAll(); waitUntilDrained(store)
        XCTAssertEqual(store.runningCount(), 0, "precondition: drained")
        let lock = NSLock()
        var ids: [String] = []
        defer { for id in ids { _ = store.kill(id) }; store.killAll(); waitUntilDrained(store) }

        // Fire 4× the cap starts in parallel.
        DispatchQueue.concurrentPerform(iterations: BackgroundJobStore.maxConcurrentRunning * 4) { _ in
            if let id = store.start(launchPath: "/bin/sleep", args: ["30"],
                                    cwd: NSTemporaryDirectory(), env: [:], command: "sleep") {
                lock.lock(); ids.append(id); lock.unlock()
            }
        }

        XCTAssertEqual(ids.count, BackgroundJobStore.maxConcurrentRunning,
                       "atomic reservation must admit EXACTLY the cap, no matter the concurrency")
        XCTAssertEqual(store.runningCount(), BackgroundJobStore.maxConcurrentRunning)
    }

    /// Owner-scoping: an agent (owner B) must not see or kill a job launched by owner A.
    func testJobsAreScopedByOwner() {
        let store = BackgroundJobStore.shared
        store.killAll(); waitUntilDrained(store)
        let ownerA = "/tmp/worktree-A", ownerB = "/tmp/worktree-B"
        guard let idA = store.start(launchPath: "/bin/sleep", args: ["30"],
                                    cwd: NSTemporaryDirectory(), env: [:], command: "sleep", owner: ownerA) else {
            return XCTFail("could not start job for owner A")
        }
        defer { _ = store.kill(idA, owner: ownerA); store.killAll(); waitUntilDrained(store) }

        // Owner B is blind to A's job.
        XCTAssertNil(store.job(idA, owner: ownerB), "owner B must not see owner A's job")
        XCTAssertTrue(store.list(owner: ownerB).isEmpty, "owner B's list must not include A's job")
        XCTAssertFalse(store.kill(idA, owner: ownerB), "owner B must not kill owner A's job")

        // Owner A still controls its own job.
        XCTAssertNotNil(store.job(idA, owner: ownerA))
        XCTAssertEqual(store.list(owner: ownerA).count, 1)
    }
}
