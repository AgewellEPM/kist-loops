import Foundation

/// Always-on perception: owns a `StreamingPerception` session and drives it in the BACKGROUND so the
/// agent has continuous "eyes" it can query (or be woken by) across turns, instead of re-perceiving from
/// scratch each step. The agent says "watch the screen for X", keeps working, and polls state / reacts to
/// events whenever it wants.
///
/// SINGLE-LOOP by construction (council-hardened): the monitor OWNS its background Task and a `generation`
/// token. `begin` cancels any prior task, bumps the generation, and starts exactly one loop; a superseded
/// loop's `pumpOnce(generation:)` returns false so it retires immediately (it never keeps ticking a
/// replaced session, and two `start`s can't race). `stop` cancels the task AND clears the flag. `maxTicks`
/// is a hard ceiling so an unattended watch can't capture forever.
///
/// Designed for deterministic tests: `pumpOnce()` is the unit of work (driven directly), and the loop's
/// sleep + the Task spawn are injectable, so the whole engine is exercised without real timers or flaky
/// background scheduling.
public actor PerceptionMonitor {

    public struct Snapshot: Sendable, Equatable {
        public let running: Bool
        public let ticks: Int
        public let latest: String?
        public let events: [StreamingPerception.Event]
    }

    /// Spawns the background loop and hands back a handle the monitor can cancel.
    public typealias Spawn = @Sendable (@escaping @Sendable () async -> Void) -> Task<Void, Never>

    private var session: StreamingPerception?
    private var running = false
    private var generation = 0
    private var task: Task<Void, Never>?

    public init() {}

    /// Start (or replace) a watch. Cancels any prior loop, bumps the generation, and spawns exactly one
    /// owned background loop for this session. `spawn` is injectable (tests pass a no-op and drive manually).
    public func begin(session s: StreamingPerception,
                      intervalNanos: UInt64 = 1_000_000_000,
                      maxTicks: Int = 300,
                      sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) },
                      spawn: Spawn = { Task.detached(operation: $0) }) {
        task?.cancel()
        generation += 1
        let gen = generation
        session = s
        running = true
        task = spawn { [weak self] in
            await self?.runLoop(generation: gen, intervalNanos: intervalNanos, maxTicks: maxTicks, sleep: sleep)
        }
    }

    /// Stop the current watch: clear the flag AND cancel the background task (not merely advisory).
    public func stop() {
        running = false
        task?.cancel()
        task = nil
    }

    public func isRunning() -> Bool { running }

    /// One background step, guarded by generation: ticks only if this is still the CURRENT watch. A loop
    /// from a superseded `begin` gets false here and retires — never touching the replaced session.
    @discardableResult
    func pumpOnce(generation gen: Int) async -> Bool {
        guard running, generation == gen, let session else { return false }
        await session.tick()
        return running && generation == gen
    }

    /// Test/utility direct pump against the current generation.
    @discardableResult
    public func pumpOnce() async -> Bool { await pumpOnce(generation: generation) }

    /// The background loop: pump, sleep, repeat — until stopped, cancelled, superseded, or `maxTicks`.
    func runLoop(generation gen: Int, intervalNanos: UInt64, maxTicks: Int,
                 sleep: @escaping @Sendable (UInt64) async -> Void) async {
        var ticks = 0
        while ticks < maxTicks, !Task.isCancelled, await pumpOnce(generation: gen) {
            ticks += 1
            if ticks < maxTicks, !Task.isCancelled { await sleep(intervalNanos) }
        }
        // Only THIS loop (if it's still the current generation) ends the watch — a superseded loop must
        // not clear a newer watch's running flag.
        if generation == gen { running = false }
    }

    public func snapshot() async -> Snapshot {
        guard let session else { return Snapshot(running: running, ticks: 0, latest: nil, events: []) }
        let ticks = await session.frameCount()
        let latest = await session.latestObservation()?.text
        let events = await session.drainEvents()   // single consumer: the agent's `state` poll
        return Snapshot(running: running, ticks: ticks, latest: latest, events: events)
    }
}
