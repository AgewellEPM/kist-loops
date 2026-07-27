import XCTest
@testable import AgentCore

/// Pins the headless event-sink seam (Mythos P0 step 1). The runtime is not yet wired to it;
/// these prove the seam types behave so the migration can route emission through them safely.
final class RuntimeEventTests: XCTestCase {

    func testRecordingSinkCapturesEventsInOrder() {
        let sink = RecordingEventSink()
        sink.emit(.stateChanged(.analyzing))
        sink.emit(.planReady(summary: "do X", stepCount: 3))
        sink.emit(.usage(promptTokens: 10, completionTokens: 2, estimated: false))
        sink.emit(.actionStarted(index: 0, tool: "run_command", description: "build"))
        sink.emit(.actionFinished(index: 0, success: true, output: "ok", error: nil))
        sink.emit(.stateChanged(.completed))
        sink.emit(.completed(summary: "done"))

        XCTAssertEqual(sink.events.count, 7)
        XCTAssertEqual(sink.states, [.analyzing, .completed])
        guard case let .planReady(summary, stepCount) = sink.events[1] else { return XCTFail() }
        XCTAssertEqual(summary, "do X"); XCTAssertEqual(stepCount, 3)
        guard case let .usage(prompt, completion, estimated) = sink.events[2] else { return XCTFail() }
        XCTAssertEqual(prompt, 10); XCTAssertEqual(completion, 2); XCTAssertFalse(estimated)
        guard case let .actionFinished(idx, ok, out, err) = sink.events[4] else { return XCTFail() }
        XCTAssertEqual(idx, 0); XCTAssertTrue(ok); XCTAssertEqual(out, "ok"); XCTAssertNil(err)
    }

    func testRecordingSinkIsConcurrencySafe() {
        // The loop may emit from any task; the lock must serialize without losing events.
        let sink = RecordingEventSink()
        let n = 1000
        DispatchQueue.concurrentPerform(iterations: n) { i in
            sink.emit(.tokenDelta("t\(i)"))
        }
        XCTAssertEqual(sink.events.count, n)
    }

    func testAutoApproveInteractor() async {
        let it = AutoApproveInteractor()
        let approved = await it.requestApproval(planSummary: "anything")
        let answer = await it.requestInput(question: "anything")
        XCTAssertTrue(approved)
        XCTAssertEqual(answer, "")
    }

    func testNullSinkSwallowsEvents() {
        let sink = NullEventSink()
        sink.emit(.failed("x"))   // must not crash / no-op
    }

    func testRuntimeStateIsStringBacked() {
        // Stable raw values matter (a host may persist/transport them).
        XCTAssertEqual(RuntimeState.executing.rawValue, "executing")
        XCTAssertEqual(RuntimeState.allCases.count, 7)
    }
}
