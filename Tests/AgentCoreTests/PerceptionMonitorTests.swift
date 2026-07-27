import XCTest
@testable import AgentCore

final class PerceptionMonitorTests: XCTestCase {

    private func varyingCapture() -> StreamingPerception.Capture {
        let c = Counter()
        return { c.bump(); return (Data([UInt8(c.value & 0xFF)]), 6, 6) }
    }
    private func session(_ text: String, watches: [String] = []) -> StreamingPerception {
        StreamingPerception(capture: varyingCapture(), perceive: { _ in text }, watches: watches)
    }
    /// A no-op spawn: returns a live-but-idle Task so `begin` doesn't run a real background loop — tests
    /// drive the monitor deterministically via `pumpOnce()`.
    private let noSpawn: PerceptionMonitor.Spawn = { _ in Task {} }

    func testPumpTicksWhileRunningAndStopsCleanly() async {
        let m = PerceptionMonitor()
        await m.begin(session: session("yes", watches: ["yes"]), spawn: noSpawn)
        let r1 = await m.pumpOnce(); let r2 = await m.pumpOnce()
        XCTAssertTrue(r1); XCTAssertTrue(r2)
        let snap = await m.snapshot()
        XCTAssertTrue(snap.running)
        XCTAssertEqual(snap.ticks, 2)
        XCTAssertTrue(snap.events.contains { $0.kind == .appeared && $0.detail == "yes" })
        await m.stop()
        let after = await m.pumpOnce()
        XCTAssertFalse(after)
        let stillRunning = await m.isRunning(); XCTAssertFalse(stillRunning)
    }

    func testRunLoopStopsWhenStoppedMidSleep() async {
        let m = PerceptionMonitor()
        await m.begin(session: session("frame"), spawn: noSpawn)   // sets running + generation 1
        let sleeps = Counter()
        // Drive the loop for THIS generation directly with a deterministic sleep that stops after 3.
        await m.runLoop(generation: 1, intervalNanos: 1, maxTicks: 999, sleep: { _ in
            sleeps.bump()
            if sleeps.value >= 3 { await m.stop() }
        })
        let snap = await m.snapshot()
        XCTAssertEqual(snap.ticks, 3)
        XCTAssertFalse(snap.running)
    }

    func testRunLoopHonorsMaxTicksCeiling() async {
        let m = PerceptionMonitor()
        await m.begin(session: session("frame"), spawn: noSpawn)
        await m.runLoop(generation: 1, intervalNanos: 1, maxTicks: 4, sleep: { _ in })
        let snap = await m.snapshot()
        XCTAssertEqual(snap.ticks, 4)
        XCTAssertFalse(snap.running)
    }

    func testSupersededLoopRetiresAndDoesNotTickReplacedSession() async {
        let m = PerceptionMonitor()
        await m.begin(session: session("first"), spawn: noSpawn)      // generation 1
        await m.begin(session: session("second"), spawn: noSpawn)     // generation 2 supersedes
        // A loop from generation 1 must immediately retire (no ticks on the new session).
        await m.runLoop(generation: 1, intervalNanos: 1, maxTicks: 100, sleep: { _ in })
        let snap = await m.snapshot()
        XCTAssertEqual(snap.ticks, 0)             // gen-1 loop never ticked gen-2's session
        XCTAssertTrue(snap.running)               // gen-2 watch is still live (gen-1 loop didn't clear it)
        XCTAssertEqual(snap.latest, nil)          // nothing pumped yet on gen 2
    }

    func testStopCancelsSoNewBeginIsClean() async {
        let m = PerceptionMonitor()
        await m.begin(session: session("a"), spawn: noSpawn)
        await m.stop()
        let running = await m.isRunning(); XCTAssertFalse(running)
        await m.begin(session: session("b"), spawn: noSpawn)
        let after = await m.isRunning(); XCTAssertTrue(after)
    }
}

final class WatchScreenToolTests: XCTestCase {

    private func ctx() -> ToolContext { ToolContext(projectRoot: NSTemporaryDirectory()) }
    private func varyingCapture() -> StreamingPerception.Capture {
        let c = Counter()
        return { c.bump(); return (Data([UInt8(c.value & 0xFF)]), 6, 6) }
    }
    private let noSpawn: PerceptionMonitor.Spawn = { _ in Task {} }

    func testStartAttachesAndStateReportsAppeared() async throws {
        let monitor = PerceptionMonitor()
        let tool = WatchScreenTool(
            monitor: monitor,
            makeSession: { watches in StreamingPerception(capture: self.varyingCapture(), perceive: { _ in "an enemy approaches" }, watches: watches) },
            spawn: noSpawn)
        let start = try await tool.execute(arguments: ["action": "start", "watch_for": "enemy, boss"], context: ctx())
        XCTAssertTrue(start.success)
        XCTAssertEqual(start.metadata["running"], "true")
        XCTAssertEqual(start.metadata["watch_for"], "2")

        await monitor.pumpOnce()   // drive the (no-op-spawned) loop manually
        let state = try await tool.execute(arguments: ["action": "state"], context: ctx())
        XCTAssertEqual(state.metadata["running"], "true")
        XCTAssertTrue(state.output.contains("APPEARED"))
        XCTAssertTrue(state.output.contains("enemy"))
    }

    func testStopEndsWatch() async throws {
        let monitor = PerceptionMonitor()
        let tool = WatchScreenTool(monitor: monitor, makeSession: { _ in StreamingPerception(capture: self.varyingCapture(), perceive: { _ in "x" }) }, spawn: noSpawn)
        _ = try await tool.execute(arguments: ["action": "start"], context: ctx())
        let stop = try await tool.execute(arguments: ["action": "stop"], context: ctx())
        XCTAssertEqual(stop.metadata["running"], "false")
        let running = await monitor.isRunning(); XCTAssertFalse(running)
    }

    func testStateWhenNotWatching() async throws {
        let tool = WatchScreenTool(monitor: PerceptionMonitor(), makeSession: { _ in StreamingPerception(capture: self.varyingCapture(), perceive: { _ in "x" }) }, spawn: noSpawn)
        let r = try await tool.execute(arguments: ["action": "state"], context: ctx())
        XCTAssertEqual(r.metadata["running"], "false")
        XCTAssertTrue(r.output.contains("Not watching"))
    }

    func testUnknownActionFails() async throws {
        let tool = WatchScreenTool(monitor: PerceptionMonitor(), makeSession: { _ in StreamingPerception(capture: self.varyingCapture(), perceive: { _ in "x" }) }, spawn: noSpawn)
        let r = try await tool.execute(arguments: ["action": "pause"], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("unknown watch_screen action") ?? false)
    }

    func testIntervalClamped() async throws {
        let tool = WatchScreenTool(
            monitor: PerceptionMonitor(),
            makeSession: { _ in StreamingPerception(capture: self.varyingCapture(), perceive: { _ in "x" }) },
            spawn: noSpawn)
        let r = try await tool.execute(arguments: ["action": "start", "interval_seconds": 9999], context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("every 30s"))
    }
}

private final class Counter: @unchecked Sendable {
    private var n = 0; private let lock = NSLock()
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
