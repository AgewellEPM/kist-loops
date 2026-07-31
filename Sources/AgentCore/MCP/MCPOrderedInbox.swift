import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Lock-guarded handoff between the stdout reader and the connection actor.
///
/// The reader synchronously enqueues its observations here; only the first enqueue
/// into an idle inbox schedules the actor drain. The drain owns all JSON framing and
/// connection state.
///
/// The byte limit covers the aggregate queued `Data`, not just an individual callback.
/// Once a stream end or overflow is queued the inbox is terminal and rejects later
/// observations. An overflow keeps already-accepted bytes ahead of the failure
/// marker, but never retains the bytes that crossed the bound.
final class MCPOrderedInbox: @unchecked Sendable {
    enum EndReason: Equatable {
        case stdoutEOF
        case primaryExitDrained
        case primaryExitDrainLimitExceeded
        case primaryExitDrainDeadlineExceeded
        case stdoutReadFailure
    }

    enum Event: Equatable {
        case bytes(Data)
        case end(EndReason)
        case overflow(byteLimit: Int, eventLimit: Int)
    }

    struct EnqueueOutcome: Equatable {
        let accepted: Bool
        let shouldScheduleDrain: Bool
        let overflowed: Bool
    }

    private let lock = NSLock()
    private let byteLimit: Int
    private let eventLimit: Int
    private var events: [Event] = []
    private var head = 0
    private var queuedBytes = 0
    private var drainScheduled = false
    private var terminalQueued = false

    init(byteLimit: Int, eventLimit: Int = 4_096) {
        precondition(byteLimit > 0, "MCP inbox byte limit must be positive")
        precondition(eventLimit > 0, "MCP inbox event limit must be positive")
        self.byteLimit = byteLimit
        self.eventLimit = eventLimit
    }

    func enqueue(bytes: Data) -> EnqueueOutcome {
        precondition(!bytes.isEmpty, "empty pipe reads are EOF observations")
        lock.lock()
        defer { lock.unlock() }

        guard !terminalQueued else {
            return EnqueueOutcome(accepted: false, shouldScheduleDrain: false, overflowed: false)
        }

        let shouldSchedule = armDrainIfNeeded()
        guard bytes.count <= byteLimit - queuedBytes,
              events.count - head < eventLimit else {
            // Fail closed without retaining the callback that crossed the aggregate
            // byte/event bound. Previously accepted observations remain ahead of
            // the marker. The event cap prevents millions of tiny Data values from
            // consuming unbounded array/object overhead while staying under bytes.
            terminalQueued = true
            events.append(.overflow(byteLimit: byteLimit, eventLimit: eventLimit))
            return EnqueueOutcome(accepted: false, shouldScheduleDrain: shouldSchedule, overflowed: true)
        }

        events.append(.bytes(bytes))
        queuedBytes += bytes.count
        assert(queuedBytes <= byteLimit, "aggregate MCP inbox bound exceeded")
        return EnqueueOutcome(accepted: true, shouldScheduleDrain: shouldSchedule, overflowed: false)
    }

    func enqueue(end reason: EndReason) -> EnqueueOutcome {
        lock.lock()
        defer { lock.unlock() }

        guard !terminalQueued else {
            return EnqueueOutcome(accepted: false, shouldScheduleDrain: false, overflowed: false)
        }
        terminalQueued = true
        let shouldSchedule = armDrainIfNeeded()
        events.append(.end(reason))
        return EnqueueOutcome(accepted: true, shouldScheduleDrain: shouldSchedule, overflowed: false)
    }

    /// Called only by the connection actor's single drain method.
    func next() -> Event? {
        lock.lock()
        defer { lock.unlock() }

        guard head < events.count else {
            events.removeAll(keepingCapacity: true)
            head = 0
            drainScheduled = false
            return nil
        }

        let event = events[head]
        head += 1
        if case .bytes(let data) = event {
            queuedBytes -= data.count
            assert(queuedBytes >= 0, "MCP inbox byte accounting underflow")
        }
        if head > 64, head * 2 >= events.count {
            events.removeFirst(head)
            head = 0
        }
        return event
    }

    /// Relinquish one bounded actor drain without losing the single-scheduled-drain
    /// invariant. If events remain, the current scheduled slot transfers directly
    /// to one successor task. If empty, producers are allowed to arm a new drain.
    func continueDrainAfterYield(localWorkPending: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if localWorkPending {
            assert(drainScheduled,
                   "local protocol work lost its scheduled actor drain")
            return true
        }
        if head < events.count { return true }
        events.removeAll(keepingCapacity: true)
        head = 0
        drainScheduled = false
        return false
    }

    /// Release queued storage and reject any callback racing with shutdown.
    func closeAndDiscard() {
        lock.lock()
        events.removeAll(keepingCapacity: false)
        head = 0
        queuedBytes = 0
        terminalQueued = true
        drainScheduled = false
        lock.unlock()
    }

    // Test observations. Both are lock-protected because tests intentionally race
    // callback-like producers.
    var bufferedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queuedBytes
    }

    var hasScheduledDrain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return drainScheduled
    }

    private func armDrainIfNeeded() -> Bool {
        if drainScheduled { return false }
        drainScheduled = true
        return true
    }
}

/// A single blocking stdout reader with an ordered, bounded primary-exit drain.
///
/// The waitid process monitor is only a signal: it never declares EOF itself.
/// Once signalled, this reader drains every byte already readable from the kernel
/// and emits `.primaryExitDrained` on the first idle poll. That removes the previous
/// fixed grace-period race while still handling a descendant that inherited stdout.
/// A continuously-writing descendant is bounded independently by byte and monotonic
/// wall-clock ceilings, so both flooding and sub-poll-interval trickles terminate.
///
/// Every lifecycle signal carries a generation token. Shutdown first requests stop,
/// then awaits the serial queue barrier, so no old reader callback can reach a later
/// generation after shutdown returns.
final class MCPOrderedPipePump: @unchecked Sendable {
    struct Generation: Equatable, Sendable {
        fileprivate let value: UInt64
    }

    private struct State {
        var nextGeneration: UInt64 = 1
        var activeGeneration: Generation?
        var activeDescriptor: Int32 = -1
        var stopRequested = false
        var primaryProcessTerminated = false
        var quiescent = true
    }

    private static let pollIntervalMilliseconds: Int32 = 50
    private static let readChunkBytes = 64 * 1_024

    private let queue: DispatchQueue
    private let lock = NSLock()
    private let inbox: MCPOrderedInbox
    private let primaryExitDrainByteLimit: Int
    private let primaryExitDrainTimeoutNanoseconds: UInt64
    private var state = State()

    init(
        label: String,
        inbox: MCPOrderedInbox,
        primaryExitDrainByteLimit: Int,
        primaryExitDrainTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        precondition(primaryExitDrainByteLimit > 0,
                     "MCP primary-exit drain limit must be positive")
        precondition(primaryExitDrainTimeoutNanoseconds > 0,
                     "MCP primary-exit drain timeout must be positive")
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.inbox = inbox
        self.primaryExitDrainByteLimit = primaryExitDrainByteLimit
        self.primaryExitDrainTimeoutNanoseconds =
            primaryExitDrainTimeoutNanoseconds
    }

    /// Starts one reader generation. The pipe's writer may not exist yet; this lets
    /// callers install a generation-bound termination handler before spawning.
    func start(
        handle: FileHandle,
        scheduleDrain: @escaping @Sendable () -> Void
    ) -> Generation {
        start(
            descriptor: handle.fileDescriptor,
            closeDescriptor: { try? handle.close() },
            scheduleDrain: scheduleDrain)
    }

    /// Raw-descriptor entry point used by the posix_spawn transport. Ownership
    /// transfers to the pump and is released before waitUntilStopped returns.
    func start(
        descriptor: Int32,
        scheduleDrain: @escaping @Sendable () -> Void
    ) -> Generation {
        start(
            descriptor: descriptor,
            closeDescriptor: { MCPDescriptor.closeOnce(descriptor) },
            scheduleDrain: scheduleDrain)
    }

    private func start(
        descriptor: Int32,
        closeDescriptor: @escaping @Sendable () -> Void,
        scheduleDrain: @escaping @Sendable () -> Void
    ) -> Generation {
        lock.lock()
        precondition(state.activeGeneration == nil,
                     "MCP stdout pump started before its previous generation quiesced")
        let generation = Generation(value: state.nextGeneration)
        state.nextGeneration &+= 1
        state.activeGeneration = generation
        state.activeDescriptor = descriptor
        state.stopRequested = false
        state.primaryProcessTerminated = false
        state.quiescent = false
        lock.unlock()

        queue.async { [self] in
            run(
                generation: generation,
                descriptor: descriptor,
                closeDescriptor: closeDescriptor,
                scheduleDrain: scheduleDrain
            )
        }
        return generation
    }

    func primaryProcessDidTerminate(generation: Generation) {
        lock.lock()
        if state.activeGeneration == generation, !state.stopRequested {
            state.primaryProcessTerminated = true
        }
        lock.unlock()
    }

    func requestStop(generation: Generation) {
        lock.lock()
        if state.activeGeneration == generation {
            state.stopRequested = true
        }
        lock.unlock()
    }

    /// Queue barrier: after this returns, the generation's descriptor is closed and
    /// it can no longer enqueue bytes or terminal observations.
    func waitUntilStopped(generation: Generation) async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
        // If a caller accidentally waits on a stale token, the barrier is still
        // useful; the identity assertion catches a reader that outlived its slot.
        assertStopped(generation: generation)
    }

    private func assertStopped(generation: Generation) {
        lock.lock()
        assert(state.activeGeneration != generation,
               "MCP stdout reader queue drained without clearing its generation")
        lock.unlock()
    }

    var isQuiescent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.quiescent
    }

    var descriptorForTesting: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return state.activeDescriptor
    }

    private func run(
        generation: Generation,
        descriptor: Int32,
        closeDescriptor: @escaping @Sendable () -> Void,
        scheduleDrain: @escaping @Sendable () -> Void
    ) {
        defer {
            closeDescriptor()
            finish(generation: generation)
        }

        var pollState = pollfd(
            fd: descriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        var primaryExitBytes = 0
        var primaryExitDeadline: UInt64?

        while true {
            let beforePoll = snapshot(generation: generation)
            guard beforePoll.isActive, !beforePoll.stopRequested else { return }
            if beforePoll.primaryProcessTerminated, primaryExitDeadline == nil {
                primaryExitDeadline = addingWithoutOverflow(
                    DispatchTime.now().uptimeNanoseconds,
                    primaryExitDrainTimeoutNanoseconds
                )
            }
            if let primaryExitDeadline,
               DispatchTime.now().uptimeNanoseconds >= primaryExitDeadline {
                publish(
                    end: .primaryExitDrainDeadlineExceeded,
                    scheduleDrain: scheduleDrain
                )
                return
            }

            pollState.revents = 0
            let ready = platformPoll(
                &pollState,
                timeoutMilliseconds: Self.pollIntervalMilliseconds
            )
            if ready == 0 {
                let afterPoll = snapshot(generation: generation)
                guard afterPoll.isActive, !afterPoll.stopRequested else { return }
                // Exit may become observable while this poll is already waiting.
                // That interval is not proof of post-exit idleness: a descendant
                // can legitimately publish tail bytes just after it. Require one
                // complete idle poll that began with the primary known dead.
                if beforePoll.primaryProcessTerminated,
                   afterPoll.primaryProcessTerminated {
                    publish(
                        end: .primaryExitDrained,
                        scheduleDrain: scheduleDrain
                    )
                    return
                }
                continue
            }
            if ready < 0 {
                if errno == EINTR { continue }
                let current = snapshot(generation: generation)
                if current.isActive, !current.stopRequested {
                    publish(end: .stdoutReadFailure, scheduleDrain: scheduleDrain)
                }
                return
            }

            var bytes = [UInt8](repeating: 0, count: Self.readChunkBytes)
            let count = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return platformRead(
                    descriptor,
                    buffer: baseAddress,
                    byteCount: buffer.count
                )
            }
            if count > 0 {
                let current = snapshot(generation: generation)
                guard current.isActive, !current.stopRequested else { return }

                if current.primaryProcessTerminated {
                    if primaryExitDeadline == nil {
                        primaryExitDeadline = addingWithoutOverflow(
                            DispatchTime.now().uptimeNanoseconds,
                            primaryExitDrainTimeoutNanoseconds
                        )
                    }
                    let remaining = primaryExitDrainByteLimit - primaryExitBytes
                    if remaining <= 0 {
                        publish(
                            end: .primaryExitDrainLimitExceeded,
                            scheduleDrain: scheduleDrain
                        )
                        return
                    }
                    if count > remaining {
                        if remaining > 0 {
                            let prefix = Data(bytes.prefix(remaining))
                            guard publish(bytes: prefix, scheduleDrain: scheduleDrain) else {
                                return
                            }
                        }
                        publish(
                            end: .primaryExitDrainLimitExceeded,
                            scheduleDrain: scheduleDrain
                        )
                        return
                    }
                    primaryExitBytes += count
                }

                let data = Data(bytes.prefix(count))
                guard publish(bytes: data, scheduleDrain: scheduleDrain) else {
                    return
                }
                continue
            }
            if count == 0 {
                let current = snapshot(generation: generation)
                if current.isActive, !current.stopRequested {
                    publish(end: .stdoutEOF, scheduleDrain: scheduleDrain)
                }
                return
            }
            if errno == EINTR || errno == EAGAIN { continue }
            let current = snapshot(generation: generation)
            if current.isActive, !current.stopRequested {
                publish(end: .stdoutReadFailure, scheduleDrain: scheduleDrain)
            }
            return
        }
    }

    private func publish(
        bytes: Data,
        scheduleDrain: @escaping @Sendable () -> Void
    ) -> Bool {
        let outcome = inbox.enqueue(bytes: bytes)
        assert(!(outcome.accepted && outcome.overflowed),
               "MCP stdout read cannot both accept and reject a chunk")
        if outcome.shouldScheduleDrain {
            scheduleDrain()
        }
        return outcome.accepted
    }

    private func publish(
        end reason: MCPOrderedInbox.EndReason,
        scheduleDrain: @escaping @Sendable () -> Void
    ) {
        let outcome = inbox.enqueue(end: reason)
        assert(!outcome.overflowed, "MCP stdout end cannot consume inbox bytes")
        if outcome.shouldScheduleDrain {
            scheduleDrain()
        }
    }

    private func snapshot(
        generation: Generation
    ) -> (isActive: Bool, stopRequested: Bool, primaryProcessTerminated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (
            state.activeGeneration == generation,
            state.stopRequested,
            state.primaryProcessTerminated
        )
    }

    private func finish(generation: Generation) {
        lock.lock()
        if state.activeGeneration == generation {
            state.activeGeneration = nil
            state.activeDescriptor = -1
            state.stopRequested = false
            state.primaryProcessTerminated = false
            state.quiescent = true
        }
        lock.unlock()
    }

    private func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }

    private func platformPoll(
        _ descriptor: UnsafeMutablePointer<pollfd>,
        timeoutMilliseconds: Int32
    ) -> Int32 {
#if canImport(Darwin)
        Darwin.poll(descriptor, 1, timeoutMilliseconds)
#elseif canImport(Glibc)
        Glibc.poll(descriptor, 1, timeoutMilliseconds)
#else
        -1
#endif
    }

    private func platformRead(
        _ descriptor: Int32,
        buffer: UnsafeMutableRawPointer,
        byteCount: Int
    ) -> Int {
#if canImport(Darwin)
        Darwin.read(descriptor, buffer, byteCount)
#elseif canImport(Glibc)
        Glibc.read(descriptor, buffer, byteCount)
#else
        -1
#endif
    }
}
