import XCTest
@testable import Kist

/// The non-terminal parts of esc-to-interrupt: the disabled (pipe/test) path just runs the work, and
/// the transcript shuttle box round-trips. The raw-mode ESC watcher itself needs a real TTY and is
/// covered by the loop-cancellation test in AgentCore.
final class InterruptibleTurnTests: XCTestCase {

    func testDisabledJustRunsWorkAndReturnsValue() async {
        var ran = false
        let result = await InterruptibleTurn.run(enabled: false) {
            ran = true
            return 42
        }
        XCTAssertTrue(ran)
        XCTAssertEqual(result, 42)
    }

    func testDisabledDoesNotFireOnInterrupt() async {
        var interrupted = false
        _ = await InterruptibleTurn.run(enabled: false, onInterrupt: { interrupted = true }) { "ok" }
        XCTAssertFalse(interrupted)
    }

    func testMutableBoxRoundTrips() {
        let box = MutableBox([1, 2, 3])
        XCTAssertEqual(box.value, [1, 2, 3])
        box.value.append(4)
        XCTAssertEqual(box.value, [1, 2, 3, 4])
    }

    // StdinArbiter (Codex BLOCKER fix): an interactor read must pause the esc watcher and restore the
    // pre-watch mode around it. With no watcher registered, withStdin is a plain passthrough.
    func testArbiterPassthroughWithoutWatcher() {
        StdinArbiter.shared.unregisterWatcher()
        var ran = false
        let r = StdinArbiter.shared.withStdin { ran = true; return 7 }
        XCTAssertTrue(ran); XCTAssertEqual(r, 7)
    }

    func testArbiterSuspendsWatcherAroundRead() {
        let a = StdinArbiter.shared
        let logLock = NSLock(); var log: [String] = []
        func append(_ s: String) { logLock.lock(); log.append(s); logLock.unlock() }
        a.registerWatcher(suspend: { append("suspend") }, resume: { append("resume") })
        defer { a.unregisterWatcher() }
        // Simulate the watcher's read loop: spins until a pause is requested, then acks by exiting.
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while a.watcherMayRead() { usleep(2000) }
            done.signal()
        }
        a.withStdin { append("body") }
        done.wait()
        logLock.lock(); let final = log; logLock.unlock()
        XCTAssertEqual(final, ["suspend", "body", "resume"],
                       "interactor read must be bracketed by watcher suspend/resume")
    }
}
