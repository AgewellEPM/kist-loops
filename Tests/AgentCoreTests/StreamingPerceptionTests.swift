import XCTest
@testable import AgentCore

final class StreamingPerceptionTests: XCTestCase {

    /// A capture that returns a UNIQUE frame each tick (simulates a changing screen), so frame-dedup
    /// doesn't skip perceive. Each test gets its own counter.
    private func varyingCapture() -> StreamingPerception.Capture {
        let c = Counter()
        return { c.bump(); return (Data([UInt8(c.value & 0xFF)]), 10, 10) }
    }

    // MARK: - Change heuristic (pure)

    func testChangedIgnoresTrivialWordingJitter() {
        XCTAssertFalse(StreamingPerception.changed("a main menu with new game and load", "the main menu with new game and load buttons"))
    }

    func testChangedDetectsRealSceneChange() {
        XCTAssertTrue(StreamingPerception.changed("the main menu with new game, load, options", "a desert wasteland with a character and rocks"))
    }

    func testChangedEmptyStringsAreNotAChange() {
        XCTAssertFalse(StreamingPerception.changed("", ""))
    }

    func testTokensKeepDigitsSoHudDeltaCounts() {
        XCTAssertTrue(StreamingPerception.tokens("hp 5").contains("5"))
        // A single-digit HUD change must register as a change (council: digit blind spot).
        XCTAssertTrue(StreamingPerception.changed("hp 5 ammo 12", "hp 6 ammo 12"))
        XCTAssertTrue(StreamingPerception.changed("5", "6"))
    }

    // MARK: - Whole-word watch match (the unanimous HIGH)

    func testWatchMatchesWholeWordOnly() {
        XCTAssertTrue(StreamingPerception.watchMatches("Yes.", "yes"))
        XCTAssertTrue(StreamingPerception.watchMatches("the answer is YES", "yes"))
        XCTAssertFalse(StreamingPerception.watchMatches("yesterday was fine", "yes"))   // no false positive
        XCTAssertFalse(StreamingPerception.watchMatches("the eyes have it", "yes"))
        XCTAssertFalse(StreamingPerception.watchMatches("no, not visible", "yes"))
    }

    func testWatchMatchesMultiWordPhrase() {
        XCTAssertTrue(StreamingPerception.watchMatches("the main menu is shown", "main menu"))
        XCTAssertTrue(StreamingPerception.watchMatches("the main   menu", "main  menu"))   // whitespace normalized
    }

    // MARK: - Engine ticks

    func testFirstTickEmitsInitialStateChange() async {
        let p = StreamingPerception(capture: varyingCapture(), perceive: { _ in "the main menu" })
        await p.tick()
        let events = await p.drainEvents()
        let latest = await p.latestObservation()?.text
        XCTAssertTrue(events.contains { $0.kind == .changed && $0.detail == "initial state" })
        XCTAssertEqual(latest, "the main menu")
    }

    func testChangeEventFiresWhenSceneChanges() async {
        let box = Box(["the main menu screen", "a desert wasteland with a person"])
        let p = StreamingPerception(capture: varyingCapture(), perceive: { _ in box.next() })
        await p.tick()      // menu (initial-state change)
        await p.tick()      // wasteland → change
        let events = await p.drainEvents()
        XCTAssertEqual(events.filter { $0.kind == .changed }.count, 2)   // initial + scene change
    }

    func testWatchEmitsAppearedEvent() async {
        let p = StreamingPerception(capture: varyingCapture(), perceive: { _ in "yes" }, watches: ["yes"])
        await p.tick()
        let events = await p.drainEvents()
        XCTAssertTrue(events.contains { $0.kind == .appeared && $0.detail == "yes" })
    }

    func testInitSanitizesEmptyWatchSoNoFalseAppeared() async {
        // An empty/whitespace watch would substring-match every frame; init must drop it.
        let p = StreamingPerception(capture: varyingCapture(), perceive: { _ in "anything at all" }, watches: ["", "   "])
        await p.tick()
        let events = await p.drainEvents()
        XCTAssertFalse(events.contains { $0.kind == .appeared })
    }

    func testIdenticalFrameSkipsPerceive() async {
        let calls = Counter()
        // Constant frame bytes across ticks → perceive runs ONCE, not per tick.
        let p = StreamingPerception(capture: { (Data([7]), 4, 4) }, perceive: { _ in calls.bump(); return "static" })
        await p.tick(); await p.tick(); await p.tick()
        let frames = await p.frameCount()
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(frames, 1)
    }

    func testDrainClearsEvents() async {
        let p = StreamingPerception(capture: varyingCapture(), perceive: { _ in "yes" }, watches: ["yes"])
        await p.tick()
        _ = await p.drainEvents()
        let second = await p.drainEvents()
        XCTAssertTrue(second.isEmpty)
    }

    func testFailedCaptureKeepsLastStateAndNoEvent() async {
        let p = StreamingPerception(capture: { nil }, perceive: { _ in "should not run" }, watches: ["x"])
        await p.tick()
        let latest = await p.latestObservation()
        let events = await p.drainEvents()
        let frames = await p.frameCount()
        XCTAssertNil(latest)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(frames, 0)
    }

    func testFailedPerceiveDoesNotAdvanceFrame() async {
        struct E: Error {}
        let p = StreamingPerception(capture: varyingCapture(), perceive: { _ in throw E() })
        await p.tick()
        let frames = await p.frameCount()
        let latest = await p.latestObservation()
        XCTAssertEqual(frames, 0)
        XCTAssertNil(latest)
    }
}

final class WaitForScreenToolTests: XCTestCase {

    private func ctx() -> ToolContext { ToolContext(projectRoot: NSTemporaryDirectory()) }
    private func varyingCapture() -> StreamingPerception.Capture {
        let c = Counter()
        return { c.bump(); return (Data([UInt8(c.value & 0xFF)]), 10, 10) }
    }

    func testAppearsAfterSeveralChecks() async throws {
        let box = Box(["no", "no", "yes", "yes"])
        let cap = varyingCapture()
        let tool = WaitForScreenTool(
            makeSession: { _ in StreamingPerception(capture: cap, perceive: { _ in box.next() }, watches: ["yes"]) },
            sleepBetweenChecks: { })
        let r = try await tool.execute(arguments: ["condition": "the menu", "timeout_checks": 10], context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.metadata["appeared"], "true")
        XCTAssertEqual(r.metadata["checks"], "3")   // appeared on the 3rd frame
    }

    func testTimesOutWhenNeverAppears() async throws {
        let cap = varyingCapture()
        let tool = WaitForScreenTool(
            makeSession: { _ in StreamingPerception(capture: cap, perceive: { _ in "no" }, watches: ["yes"]) },
            sleepBetweenChecks: { })
        let r = try await tool.execute(arguments: ["condition": "a unicorn", "timeout_checks": 4], context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.metadata["appeared"], "false")
        XCTAssertEqual(r.metadata["checks"], "4")
    }

    func testChecksCountIsLoopIndexNotPerceivedFrames() async throws {
        // Repeated frames (A,A,A,B) → dedup perceives only A and B, but the condition appears on the
        // 4th CHECK. The reported count must be the check index (4), not frameCount (2).
        let bytes = Box(["1", "1", "1", "2"])   // three identical frames then a new one
        let tool = WaitForScreenTool(
            makeSession: { _ in
                StreamingPerception(
                    capture: { let b = UInt8(bytes.next())!; return (Data([b]), 5, 5) },
                    perceive: { data in data == Data([2]) ? "yes" : "no" },
                    watches: ["yes"])
            },
            sleepBetweenChecks: { })
        let r = try await tool.execute(arguments: ["condition": "the thing", "timeout_checks": 10], context: ctx())
        XCTAssertEqual(r.metadata["appeared"], "true")
        XCTAssertEqual(r.metadata["checks"], "4")   // loop index, not perceived-frame count (2)
    }

    func testNoSleepAfterFinalCheck() async throws {
        let sleeps = Counter()
        let cap = varyingCapture()
        let tool = WaitForScreenTool(
            makeSession: { _ in StreamingPerception(capture: cap, perceive: { _ in "no" }, watches: ["yes"]) },
            sleepBetweenChecks: { sleeps.bump() })
        _ = try await tool.execute(arguments: ["condition": "x", "timeout_checks": 5], context: ctx())
        XCTAssertEqual(sleeps.value, 4)   // 5 checks → 4 inter-check sleeps, none after the last
    }

    func testEmptyConditionFails() async throws {
        let tool = WaitForScreenTool(
            makeSession: { _ in StreamingPerception(capture: self.varyingCapture(), perceive: { _ in "no" }) },
            sleepBetweenChecks: { })
        let r = try await tool.execute(arguments: ["condition": "   "], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("empty") ?? false)
    }

    func testChecksBudgetIsClamped() async throws {
        let ticks = Counter()
        let tool = WaitForScreenTool(
            makeSession: { _ in StreamingPerception(capture: { ticks.bump(); return (Data([UInt8(ticks.value & 0xFF)]), 1, 1) }, perceive: { _ in "no" }, watches: ["yes"]) },
            sleepBetweenChecks: { })
        _ = try await tool.execute(arguments: ["condition": "x", "timeout_checks": 9999], context: ctx())
        XCTAssertEqual(ticks.value, WaitForScreenTool.maxChecks)   // clamped to 120
    }
}

/// Tiny scripted-sequence helper for deterministic perceive() outputs across ticks.
private final class Box: @unchecked Sendable {
    private var items: [String]
    private var i = 0
    private let lock = NSLock()
    init(_ items: [String]) { self.items = items }
    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        let v = items[min(i, items.count - 1)]; i += 1; return v
    }
}

private final class Counter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
