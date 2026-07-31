import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import AgentCore

final class MCPServerConnectionOrderingTests: XCTestCase {
    private var temporaryDirectories: [String] = []
    private var descendantPIDs: [pid_t] = []

    override func tearDownWithError() throws {
        MCPLog.resetDiagnosticSink()
        for pid in descendantPIDs where pid > 1 {
            _ = kill(pid, SIGKILL)
        }
        descendantPIDs.removeAll()
        for path in temporaryDirectories {
            try? FileManager.default.removeItem(atPath: path)
        }
        temporaryDirectories.removeAll()
    }

    // MARK: - Callback-to-actor FIFO

    func testOrderedInbox_byteBoundariesHaveOneDrainAndPreserveFIFO() {
        let inbox = MCPOrderedInbox(byteLimit: 128)
        let first = inbox.enqueue(bytes: Data(#"{"json"#.utf8))
        let second = inbox.enqueue(bytes: Data(#"rpc":"2.0"}"#.utf8))
        let third = inbox.enqueue(bytes: Data([0x0A]))

        // This pins the old failure mode: later callback Tasks cannot get scheduled
        // independently and run ahead of the first callback.
        XCTAssertTrue(first.shouldScheduleDrain)
        XCTAssertFalse(second.shouldScheduleDrain)
        XCTAssertFalse(third.shouldScheduleDrain)

        XCTAssertEqual(inbox.next(), .bytes(Data(#"{"json"#.utf8)))
        XCTAssertEqual(inbox.next(), .bytes(Data(#"rpc":"2.0"}"#.utf8)))
        XCTAssertEqual(inbox.next(), .bytes(Data([0x0A])))
        XCTAssertNil(inbox.next())
        XCTAssertFalse(inbox.hasScheduledDrain)
    }

    func testOrderedInbox_stdoutEOFCallbackStaysBehindAcceptedTail() {
        let inbox = MCPOrderedInbox(byteLimit: 128)
        let tail = Data(#"{"id":1,"result":{}}"#.utf8)
        XCTAssertTrue(inbox.enqueue(bytes: tail).accepted)

        // Per-site regression assertion: the FileHandle empty-read callback maps to
        // stdoutEOF and cannot overtake bytes it already observed.
        let eof = inbox.enqueue(end: .stdoutEOF)
        XCTAssertTrue(eof.accepted)
        XCTAssertFalse(eof.shouldScheduleDrain)
        XCTAssertEqual(inbox.next(), .bytes(tail))
        XCTAssertEqual(inbox.next(), .end(.stdoutEOF))
        XCTAssertNil(inbox.next())
    }

    func testOrderedInbox_primaryExitDrainEndStaysBehindAcceptedTail() {
        let inbox = MCPOrderedInbox(byteLimit: 128)
        let tail = Data("tail".utf8)
        XCTAssertTrue(inbox.enqueue(bytes: tail).accepted)

        // Per-site regression assertion: the reader publishes primary-exit end
        // only after its final read, on the exact same FIFO as those tail bytes.
        let drained = inbox.enqueue(end: .primaryExitDrained)
        XCTAssertTrue(drained.accepted)
        XCTAssertFalse(drained.shouldScheduleDrain)
        XCTAssertEqual(inbox.next(), .bytes(tail))
        XCTAssertEqual(inbox.next(), .end(.primaryExitDrained))
        XCTAssertNil(inbox.next())
    }

    func testOrderedInbox_rejectsCallbacksAfterEitherTerminalSite() {
        for reason in [MCPOrderedInbox.EndReason.stdoutEOF, .primaryExitDrained] {
            let inbox = MCPOrderedInbox(byteLimit: 16)
            XCTAssertTrue(inbox.enqueue(end: reason).accepted, "terminal callback \(reason) accepted once")
            let late = inbox.enqueue(bytes: Data("late".utf8))
            XCTAssertFalse(late.accepted, "bytes after \(reason) must be rejected")
            XCTAssertFalse(late.shouldScheduleDrain)
            XCTAssertFalse(late.overflowed)
        }
    }

    func testOrderedInbox_aggregateOverflowIsBoundedAndFailsClosedInOrder() {
        let inbox = MCPOrderedInbox(byteLimit: 8)
        let accepted = inbox.enqueue(bytes: Data("12345".utf8))
        let overflow = inbox.enqueue(bytes: Data("6789".utf8))

        XCTAssertTrue(accepted.accepted)
        XCTAssertFalse(overflow.accepted)
        XCTAssertTrue(overflow.overflowed)
        XCTAssertLessThanOrEqual(inbox.bufferedByteCount, 8)
        XCTAssertEqual(inbox.next(), .bytes(Data("12345".utf8)))
        XCTAssertEqual(inbox.next(), .overflow(byteLimit: 8, eventLimit: 4_096))
        XCTAssertNil(inbox.next())

        let afterOverflow = inbox.enqueue(bytes: Data("x".utf8))
        XCTAssertFalse(afterOverflow.accepted, "overflow is terminal, not a lossy continuing mode")
    }

    func testOrderedInbox_tinyCallbackCountCannotBypassAggregateMemoryBound() {
        let inbox = MCPOrderedInbox(byteLimit: 1_024, eventLimit: 2)
        XCTAssertTrue(inbox.enqueue(bytes: Data([1])).accepted)
        XCTAssertTrue(inbox.enqueue(bytes: Data([2])).accepted)
        let overflow = inbox.enqueue(bytes: Data([3]))
        XCTAssertTrue(overflow.overflowed)
        XCTAssertEqual(inbox.bufferedByteCount, 2)
        XCTAssertEqual(inbox.next(), .bytes(Data([1])))
        XCTAssertEqual(inbox.next(), .bytes(Data([2])))
        XCTAssertEqual(inbox.next(), .overflow(byteLimit: 1_024, eventLimit: 2))
    }

    func testOrderedInbox_boundedDrainHandoffYieldsWithoutLosingSingleSchedule() {
        let inbox = MCPOrderedInbox(byteLimit: 1_024, eventLimit: 256)
        for byte in UInt8(0)..<UInt8(96) {
            let outcome = inbox.enqueue(bytes: Data([byte]))
            XCTAssertEqual(outcome.shouldScheduleDrain, byte == 0)
        }

        // Model one MCPServerConnection actor batch. The scheduled slot transfers
        // to exactly one successor instead of monopolizing the actor indefinitely.
        for _ in 0..<32 {
            XCTAssertNotNil(inbox.next())
        }
        XCTAssertTrue(inbox.continueDrainAfterYield())

        let racingProducer = inbox.enqueue(bytes: Data([96]))
        XCTAssertFalse(racingProducer.shouldScheduleDrain,
                       "a producer must not create a second drain during handoff")

        while inbox.next() != nil {}
        XCTAssertFalse(inbox.hasScheduledDrain)
        XCTAssertTrue(inbox.enqueue(bytes: Data([97])).shouldScheduleDrain,
                      "an idle inbox must be armable after the successor drains it")
    }

    func testOrderedInbox_localLineBacklogRetainsDrainSlotAcrossYield() {
        let inbox = MCPOrderedInbox(byteLimit: 128)
        XCTAssertTrue(inbox.enqueue(bytes: Data("many-lines".utf8)).shouldScheduleDrain)
        XCTAssertNotNil(inbox.next())

        XCTAssertTrue(inbox.continueDrainAfterYield(localWorkPending: true))
        XCTAssertTrue(inbox.hasScheduledDrain)
        XCTAssertFalse(inbox.enqueue(bytes: Data("later".utf8)).shouldScheduleDrain,
                       "pipe callbacks must not race a second drain with local line work")

        XCTAssertNotNil(inbox.next())
        XCTAssertNil(inbox.next())
        XCTAssertFalse(inbox.hasScheduledDrain)
    }

    // MARK: - Ordered pipe reader lifecycle

    func testPipePump_primaryExitDrainsLargeExactTailBeforeHeldOpenPipeEnds() async throws {
        let byteLimit = 512 * 1_024
        let inbox = MCPOrderedInbox(byteLimit: byteLimit)
        let pump = MCPOrderedPipePump(
            label: "test.mcp.stdout.exact-tail",
            inbox: inbox,
            primaryExitDrainByteLimit: byteLimit
        )
        let pipe = Pipe()
        suppressSIGPIPE(on: pipe.fileHandleForWriting)
        let generation = pump.start(
            handle: pipe.fileHandleForReading,
            scheduleDrain: {}
        )
        let expected = Data((0..<(256 * 1_024)).map { UInt8(truncatingIfNeeded: $0) })

        // This write is larger than normal pipe capacity. It cannot complete until
        // the reader has made progress, pinning the real blocking-read path.
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try pipe.fileHandleForWriting.write(contentsOf: expected)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        // Keep the writer open to model a descendant retaining the descriptor.
        // Primary exit must drain the exact kernel tail and terminate on idle.
        pump.primaryProcessDidTerminate(generation: generation)
        await pump.waitUntilStopped(generation: generation)
        XCTAssertTrue(pump.isQuiescent)
        try? pipe.fileHandleForWriting.close()

        let observed = drainInbox(inbox)
        XCTAssertEqual(observed.bytes, expected)
        XCTAssertEqual(observed.end, .primaryExitDrained)
    }

    func testPipePump_continuousDescendantIsBoundedAfterPrimaryExit() async {
        let drainLimit = 128 * 1_024
        let inbox = MCPOrderedInbox(byteLimit: 512 * 1_024)
        let pump = MCPOrderedPipePump(
            label: "test.mcp.stdout.continuous-descendant",
            inbox: inbox,
            primaryExitDrainByteLimit: drainLimit
        )
        let pipe = Pipe()
        suppressSIGPIPE(on: pipe.fileHandleForWriting)
        let generation = pump.start(
            handle: pipe.fileHandleForReading,
            scheduleDrain: {}
        )
        try? pipe.fileHandleForWriting.write(contentsOf: Data([0x78]))
        pump.primaryProcessDidTerminate(generation: generation)

        let writerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let chunk = Data(repeating: 0x78, count: 64 * 1_024)
            while true {
                do {
                    try pipe.fileHandleForWriting.write(contentsOf: chunk)
                } catch {
                    break
                }
            }
            writerFinished.signal()
        }

        await pump.waitUntilStopped(generation: generation)
        try? pipe.fileHandleForWriting.close()
        XCTAssertEqual(writerFinished.wait(timeout: .now() + 2), .success)

        let observed = drainInbox(inbox)
        XCTAssertLessThanOrEqual(observed.bytes.count, drainLimit + 1)
        XCTAssertEqual(observed.end, .primaryExitDrainLimitExceeded)
    }

    func testPipePump_trickleDescendantCannotEvadeAbsoluteExitDeadline() async {
        let inbox = MCPOrderedInbox(byteLimit: 512 * 1_024)
        let pump = MCPOrderedPipePump(
            label: "test.mcp.stdout.trickle-descendant",
            inbox: inbox,
            primaryExitDrainByteLimit: 512 * 1_024,
            primaryExitDrainTimeoutNanoseconds: 250_000_000
        )
        let pipe = Pipe()
        suppressSIGPIPE(on: pipe.fileHandleForWriting)
        let generation = pump.start(
            handle: pipe.fileHandleForReading,
            scheduleDrain: {}
        )
        let writerStarted = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var isFirst = true
            while true {
                do {
                    try pipe.fileHandleForWriting.write(contentsOf: Data([0x74]))
                    if isFirst {
                        isFirst = false
                        writerStarted.signal()
                    }
                    Thread.sleep(forTimeInterval: 0.001)
                } catch {
                    break
                }
            }
            writerFinished.signal()
        }
        XCTAssertEqual(writerStarted.wait(timeout: .now() + 2), .success)

        let started = Date()
        pump.primaryProcessDidTerminate(generation: generation)
        await pump.waitUntilStopped(generation: generation)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        try? pipe.fileHandleForWriting.close()
        XCTAssertEqual(writerFinished.wait(timeout: .now() + 2), .success)

        let observed = drainInbox(inbox)
        XCTAssertLessThan(observed.bytes.count, 2_000,
                          "deadline, not a huge byte budget, must bound trickle output")
        XCTAssertEqual(observed.end, .primaryExitDrainDeadlineExceeded)
    }

    func testPipePump_exitObservedMidPollRequiresFullPostExitIdlePoll() async {
        let inbox = MCPOrderedInbox(byteLimit: 1_024)
        let pump = MCPOrderedPipePump(
            label: "test.mcp.stdout.delayed-descendant-tail",
            inbox: inbox,
            primaryExitDrainByteLimit: 1_024)
        let pipe = Pipe()
        suppressSIGPIPE(on: pipe.fileHandleForWriting)
        let generation = pump.start(
            handle: pipe.fileHandleForReading,
            scheduleDrain: {})

        // Let the reader enter a pre-exit poll, report primary exit mid-poll, then
        // publish descendant tail after that first poll would have timed out.
        try? await Task.sleep(nanoseconds: 20_000_000)
        pump.primaryProcessDidTerminate(generation: generation)
        let delayedWrite = Task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            try? pipe.fileHandleForWriting.write(
                contentsOf: Data("delayed-tail".utf8))
        }

        await pump.waitUntilStopped(generation: generation)
        _ = await delayedWrite.result
        try? pipe.fileHandleForWriting.close()
        let observed = drainInbox(inbox)
        XCTAssertEqual(observed.bytes, Data("delayed-tail".utf8))
        XCTAssertEqual(observed.end, .primaryExitDrained)
    }

    func testPipePump_stopQuiescesAndStaleGenerationCannotEndNextReader() async throws {
        let inbox = MCPOrderedInbox(byteLimit: 1_024)
        let pump = MCPOrderedPipePump(
            label: "test.mcp.stdout.generations",
            inbox: inbox,
            primaryExitDrainByteLimit: 1_024
        )
        let firstPipe = Pipe()
        let first = pump.start(
            handle: firstPipe.fileHandleForReading,
            scheduleDrain: {}
        )
        pump.requestStop(generation: first)
        await pump.waitUntilStopped(generation: first)
        XCTAssertTrue(pump.isQuiescent)
        XCTAssertNil(inbox.next(), "an explicit stop must not synthesize protocol EOF")
        try? firstPipe.fileHandleForWriting.close()

        let secondPipe = Pipe()
        let second = pump.start(
            handle: secondPipe.fileHandleForReading,
            scheduleDrain: {}
        )
        pump.primaryProcessDidTerminate(generation: first)
        try secondPipe.fileHandleForWriting.write(contentsOf: Data("new-generation".utf8))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(pump.isQuiescent,
                       "a stale termination callback must not stop the active generation")
        try secondPipe.fileHandleForWriting.close()
        await pump.waitUntilStopped(generation: second)

        let observed = drainInbox(inbox)
        XCTAssertEqual(observed.bytes, Data("new-generation".utf8))
        XCTAssertEqual(observed.end, .stdoutEOF)
    }

    // MARK: - Nonblocking stdin writer lifecycle

    func testStdinWriter_blockedPeerHonorsDeadlineOffActor() async throws {
        let pipe = try MCPDescriptor.makePipe(
            nonBlockingRead: true,
            nonBlockingWrite: true)
        defer { MCPDescriptor.closeOnce(pipe.read) }
        let writer = try MCPNonblockingPipeWriter(
            descriptor: pipe.write,
            label: "test.mcp.stdin.deadline")
        let observed = LockedWriterOutcome()
        let token = UUID()
        let started = Date()

        writer.enqueue(
            token: token,
            data: Data(repeating: 0x78, count: 2 * 1_024 * 1_024),
            deadlineNanoseconds: monotonicDeadline(after: 200_000_000)
        ) { observed.set($0) }

        let completed = await waitUntil(
            { observed.snapshot() != nil },
            timeout: 1.5)
        XCTAssertTrue(completed,
                      "a full pipe must not pin the serial writer")
        switch observed.snapshot() {
        case .timedOut(partialWrite: true):
            break
        default:
            XCTFail("expected a partial-write timeout, got \(String(describing: observed.snapshot()))")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        await writer.waitUntilStopped()
    }

    func testStdinWriter_saturatedDeadlineCancellationWakesPollAndJoinedStopClosesDescriptor() async throws {
        let pipe = try MCPDescriptor.makePipe(
            nonBlockingRead: true,
            nonBlockingWrite: true)
        defer { MCPDescriptor.closeOnce(pipe.read) }
        let writer = try MCPNonblockingPipeWriter(
            descriptor: pipe.write,
            label: "test.mcp.stdin.cancel")
        let descriptor = writer.descriptorForTesting
        let observed = LockedWriterOutcome()
        let token = UUID()

        writer.enqueue(
            token: token,
            data: Data(repeating: 0x63, count: 2 * 1_024 * 1_024),
            deadlineNanoseconds: UInt64.max
        ) { observed.set($0) }
        try await Task.sleep(nanoseconds: 50_000_000)

        let cancelledAt = Date()
        writer.cancel(token)
        let completed = await waitUntil(
            { observed.snapshot() != nil },
            timeout: 1.0)
        XCTAssertTrue(completed,
                      "cancellation must wake a writer blocked in poll")
        switch observed.snapshot() {
        case .cancelled(partialWrite: true):
            break
        default:
            XCTFail("expected a partial-write cancellation, got \(String(describing: observed.snapshot()))")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 0.75)

        await writer.waitUntilStopped()
        errno = 0
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF,
                       "the joined writer barrier must return only after closing stdin")
    }

    func testStdinWriter_queuedCancellationAndDeadlineCompleteBehindBlockedFrame() async throws {
        let pipe = try MCPDescriptor.makePipe(
            nonBlockingRead: true,
            nonBlockingWrite: true)
        defer { MCPDescriptor.closeOnce(pipe.read) }
        let writer = try MCPNonblockingPipeWriter(
            descriptor: pipe.write,
            label: "test.mcp.stdin.queued-expiry")
        let blocked = LockedWriterOutcome()
        let cancelled = LockedWriterOutcome()
        let expired = LockedWriterOutcome()
        let rejected = LockedWriterOutcome()

        writer.enqueue(
            token: UUID(),
            data: Data(repeating: 0x61, count: 2 * 1_024 * 1_024),
            deadlineNanoseconds: UInt64.max
        ) { blocked.set($0) }
        let headStarted = await waitUntil(
            { self.descriptorIsReadable(pipe.read) },
            timeout: 1.0)
        XCTAssertTrue(
            headStarted,
            "the first frame must enter the pipe before testing queued work")

        let cancelledToken = UUID()
        writer.enqueue(
            token: cancelledToken,
            data: Data("cancel-me\n".utf8),
            deadlineNanoseconds: UInt64.max
        ) { cancelled.set($0) }
        writer.enqueue(
            token: UUID(),
            data: Data("expire-me\n".utf8),
            deadlineNanoseconds: monotonicDeadline(after: 75_000_000)
        ) { expired.set($0) }

        let cancelledAt = Date()
        writer.cancel(cancelledToken)
        let queuedWorkCompleted = await waitUntil(
            {
                cancelled.snapshot() != nil
                    && expired.snapshot() != nil
            },
            timeout: 1.0)
        XCTAssertTrue(
            queuedWorkCompleted,
            "queued cancellation and expiry must not wait behind a blocked write")
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 0.75)
        if case .cancelled(partialWrite: false) = cancelled.snapshot() {
            // Expected.
        } else {
            XCTFail("expected queued cancellation without a partial write")
        }
        if case .timedOut(partialWrite: false) = expired.snapshot() {
            // Expected.
        } else {
            XCTFail("expected queued deadline without a partial write")
        }
        XCTAssertNil(blocked.snapshot(),
                     "the head frame should still be blocked while queued work completes")

        writer.enqueue(
            token: UUID(),
            data: Data(repeating: 0x62, count: 2 * 1_024 * 1_024),
            deadlineNanoseconds: UInt64.max
        ) { rejected.set($0) }
        let rejectedPromptly = await waitUntil(
            { rejected.snapshot() != nil },
            timeout: 0.25)
        XCTAssertTrue(
            rejectedPromptly,
            "early removal must stay charged until its queue slot releases")
        if case .overflow = rejected.snapshot() {
            // Expected: queue closures still retain the cancelled/expired frames.
        } else {
            XCTFail("retained cancelled frames must preserve the hard byte bound")
        }

        await writer.waitUntilStopped()
        if case .closed = blocked.snapshot() {
            // Expected.
        } else {
            XCTFail("stopping should close the blocked head frame")
        }
    }

    func testStdinWriter_partialCancellationPoisonsAcceptedFramesBeforeTheyWrite() async throws {
        let pipe = try MCPDescriptor.makePipe(
            nonBlockingRead: true,
            nonBlockingWrite: true)
        defer { MCPDescriptor.closeOnce(pipe.read) }
        let writer = try MCPNonblockingPipeWriter(
            descriptor: pipe.write,
            label: "test.mcp.stdin.partial-poison")
        let partial = LockedWriterOutcome()
        let queued = LockedWriterOutcome()
        let partialToken = UUID()
        let marker = Data("SECOND-FRAME-MUST-NOT-WRITE\n".utf8)

        writer.enqueue(
            token: partialToken,
            data: Data(repeating: 0x41, count: 2 * 1_024 * 1_024),
            deadlineNanoseconds: UInt64.max
        ) { partial.set($0) }
        let partialStarted = await waitUntil(
            { self.descriptorIsReadable(pipe.read) },
            timeout: 1.0)
        XCTAssertTrue(
            partialStarted,
            "the cancelled frame must have a confirmed partial write")
        writer.enqueue(
            token: UUID(),
            data: marker,
            deadlineNanoseconds: UInt64.max
        ) { queued.set($0) }

        writer.cancel(partialToken)
        let poisoned = await waitUntil(
            {
                partial.snapshot() != nil
                    && queued.snapshot() != nil
            },
            timeout: 1.0)
        XCTAssertTrue(poisoned)
        if case .cancelled(partialWrite: true) = partial.snapshot() {
            // Expected.
        } else {
            XCTFail("expected cancellation to report the confirmed partial frame")
        }
        if case .closed = queued.snapshot() {
            // Expected.
        } else {
            XCTFail("a partial frame must atomically close every queued frame")
        }

        await writer.waitUntilStopped()
        let received = readAllAvailable(from: pipe.read)
        XCTAssertFalse(received.isEmpty)
        XCTAssertNil(received.range(of: marker),
                     "the queued frame was written after a partial-frame poison")
        XCTAssertTrue(received.allSatisfy { $0 == 0x41 })
    }

    // MARK: - Process teardown lifecycle

    func testStdioProcess_lateExitKeepsCallersBoundedAndReapsExactlyOnce() async {
        let harness = DelayedExitProcessHarness()
        let callbacks = LockedCounter()
        let process = MCPStdioProcess(
            pid: 424_242,
            terminationGraceSeconds: 0.02,
            killGraceSeconds: 0.02,
            operations: harness.operations)
        process.startMonitoring { callbacks.increment() }

        let started = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await process.shutdown() }
            }
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            1.0,
            "concurrent shutdown callers must share one finite TERM/KILL budget")
        XCTAssertTrue(process.boundedShutdownCompleteForTesting)
        XCTAssertFalse(process.reapCompleteForTesting)
        XCTAssertEqual(harness.signalSnapshot(), [SIGTERM, SIGKILL])
        XCTAssertEqual(harness.reapCount, 0)

        let repeatedAt = Date()
        await process.shutdown()
        XCTAssertLessThan(Date().timeIntervalSince(repeatedAt), 0.25)
        XCTAssertEqual(harness.signalSnapshot(), [SIGTERM, SIGKILL],
                       "repeated shutdown must not signal a possibly recycled group")

        harness.releaseExit()
        let eventuallyReaped = await waitUntil(
            {
                process.reapCompleteForTesting
                    && callbacks.value == 1
            },
            timeout: 1.0)
        XCTAssertTrue(
            eventuallyReaped,
            "the retained owner must perform the eventual reap after late exit")
        XCTAssertEqual(harness.reapCount, 1)

        await process.shutdown()
        XCTAssertEqual(harness.reapCount, 1,
                       "concurrent and repeated shutdown paths must share one waitpid")
    }

    // MARK: - Live stdio regression coverage

    func testLiveServer_fragmentedResponseLargerThan64KBCompletesHandshake() async throws {
        let script = try makeFakeServer()
        let connection = MCPServerConnection(
            config: MCPServerConfig(name: "fragmented", command: script, args: ["fragmented"])
        )
        do {
            try await connection.start()
            let alive = await connection.isAlive
            XCTAssertTrue(alive)
        } catch {
            await connection.shutdown()
            throw error
        }
        await connection.shutdown()
    }

    func testLiveServer_repeatedAndConcurrentFragmentedHandshakes() async throws {
        let script = try makeFakeServer()

        // Repeated launches catch stale inbox/scheduling state that a single launch
        // cannot expose.
        for index in 0..<3 {
            let connection = MCPServerConnection(
                config: MCPServerConfig(name: "repeat\(index)", command: script, args: ["fragmented"])
            )
            try await connection.start()
            let alive = await connection.isAlive
            XCTAssertTrue(alive)
            await connection.shutdown()
        }

        // Independent Foundation callback queues may schedule in any order. Each
        // connection must still perform exactly one correctly ordered actor drain.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let connection = MCPServerConnection(
                        config: MCPServerConfig(name: "concurrent\(index)", command: script, args: ["fragmented"])
                    )
                    do {
                        try await connection.start()
                        guard await connection.isAlive else {
                            await connection.shutdown()
                            throw LiveTestError.connectionNotAlive
                        }
                        await connection.shutdown()
                    } catch {
                        await connection.shutdown()
                        throw error
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    func testLiveServer_EOFAfterUnterminatedJSONTailDispatchesTailBeforeClose() async throws {
        let script = try makeFakeServer()
        let connection = MCPServerConnection(
            config: MCPServerConfig(name: "eof-tail", command: script, args: ["eof-tail"])
        )
        do {
            try await connection.start()
            let tools = try await connection.listTools()
            XCTAssertTrue(tools.isEmpty, "final JSON tail must resolve tools/list before EOF fails pending calls")
        } catch {
            await connection.shutdown()
            throw error
        }
        await connection.shutdown()
    }

    func testLiveServer_delayedDescendantTailAfterPrimaryExitCompletesRequest() async throws {
        let script = try makeFakeServer()
        let connection = MCPServerConnection(
            config: MCPServerConfig(
                name: "delayed-descendant-tail",
                command: script,
                args: ["delayed-descendant-tail"]),
            callTimeout: 2
        )
        do {
            try await connection.start()
            let tools = try await connection.listTools()
            XCTAssertTrue(tools.isEmpty,
                          "a pre-exit poll timeout discarded delayed descendant tail")
        } catch {
            await connection.shutdown()
            throw error
        }
        await connection.shutdown()
    }

    func testLiveServer_primaryExitDrainsLargeUnterminatedJSONTail() async throws {
        let script = try makeFakeServer()
        let connection = MCPServerConnection(
            config: MCPServerConfig(name: "exit-tail", command: script, args: ["exit-tail"])
        )
        do {
            try await connection.start()
            let tools = try await connection.listTools()
            XCTAssertTrue(tools.isEmpty,
                          "primary-exit drain must dispatch the complete delayed tail")
        } catch {
            await connection.shutdown()
            throw error
        }
        await connection.shutdown()
    }

    func testLiveServer_primaryExitDoesNotWaitForDescendantRetainedStdout() async throws {
        let script = try makeFakeServer()
        let connection = MCPServerConnection(
            config: MCPServerConfig(
                name: "descendant-fd",
                command: script,
                args: ["descendant-fd"]
            ),
            callTimeout: 2
        )
        do {
            try await connection.start()
            let started = Date()
            let tools = try await connection.listTools()
            XCTAssertTrue(tools.isEmpty)
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
                              "reader waited for the descendant's real pipe EOF")
        } catch {
            await connection.shutdown()
            throw error
        }
        let descendant = recordDescendantPID(for: script)
        if let descendant {
            let gone = await waitUntilProcessIsGone(descendant, timeout: 2.0)
            XCTAssertTrue(gone,
                          "reactive EOF cleanup left an ordinary process-group descendant alive")
        }
        await connection.shutdown()
    }

    func testLiveServer_lineLargerThan1MBFailsClosedWithoutEchoingBytes() async throws {
        let script = try makeFakeServer()
        let diagnostics = LockedStrings()
        MCPLog.installDiagnosticSink { diagnostics.append($0) }
        defer { MCPLog.resetDiagnosticSink() }

        let connection = MCPServerConnection(
            config: MCPServerConfig(name: "oversized", command: script, args: ["oversized"])
        )
        do {
            try await connection.start()
            XCTFail("an oversized JSON-RPC line must not initialize")
        } catch {
            // Expected: ingest closes the connection and resolves the pending
            // initialize continuation with serverClosed, rather than timing out.
        }
        let alive = await connection.isAlive
        XCTAssertFalse(alive)
        await connection.shutdown()

        let emitted = diagnostics.snapshot().joined()
        XCTAssertTrue(emitted.contains("exceeds") || emitted.contains("no newline"))
        XCTAssertFalse(emitted.contains("QQQQ"), "protocol rejection must not reflect rejected bytes")
        XCTAssertLessThan(emitted.utf8.count, 20_000, "diagnostics remain bounded on hostile input")
    }

    func testLiveServer_blockedStdinTimesOutWithoutPinningActorOrShutdown() async throws {
        let script = try makeFakeServer()
        let connection = MCPServerConnection(
            config: MCPServerConfig(
                name: "nonreading",
                command: script,
                args: ["nonreading"]),
            callTimeout: 1
        )
        try await connection.start()

        let started = Date()
        do {
            _ = try await connection.callTool(
                name: "blocked",
                arguments: [
                    "payload": String(repeating: "x", count: 3 * 1_024 * 1_024)
                ])
            XCTFail("a server that stopped reading stdin cannot answer")
        } catch MCPConnectionError.timeout(let method) {
            XCTAssertEqual(method, "tools/call")
        } catch {
            XCTFail("expected the bounded request timeout, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0,
                          "the actor was pinned by a blocking stdin write")

        let alive = await connection.isAlive
        XCTAssertFalse(alive,
                       "a partial timed-out JSON frame must retire the corrupted transport")
        let shutdownStarted = Date()
        await connection.shutdown()
        XCTAssertLessThan(Date().timeIntervalSince(shutdownStarted), 3.0,
                          "shutdown must wake and join the blocked writer")
    }

    func testLiveServer_callerCancellationRemovesPendingRequestPromptly() async throws {
        let script = try makeFakeServer()
        let connection = MCPServerConnection(
            config: MCPServerConfig(
                name: "no-response",
                command: script,
                args: ["no-response"]),
            callTimeout: 30
        )
        try await connection.start()

        let result = LockedCallOutcome()
        let call = Task {
            do {
                _ = try await connection.listTools()
                result.set(.success)
            } catch is CancellationError {
                result.set(.cancelled)
            } catch {
                result.set(.failure(error.localizedDescription))
            }
        }
        let marker = script + ".request.seen"
        let serverObservedRequest = await waitUntil({
            FileManager.default.fileExists(atPath: marker)
        }, timeout: 1.0)
        XCTAssertTrue(serverObservedRequest,
                      "fake server never observed tools/list")

        call.cancel()
        let cancellationCompleted = await waitUntil(
            { result.snapshot() != nil },
            timeout: 1.0)
        XCTAssertTrue(cancellationCompleted,
                      "caller cancellation left a checked continuation pending")
        switch result.snapshot() {
        case .cancelled:
            break
        default:
            XCTFail("expected CancellationError, got \(String(describing: result.snapshot()))")
        }

        await connection.shutdown()
        _ = await call.result
    }

    func testLiveServer_restartOfOneShotConnectionThrowsExplicitly() async throws {
        let script = try makeFakeServer()
        let connection = MCPServerConnection(
            config: MCPServerConfig(
                name: "one-shot",
                command: script,
                args: ["fragmented"])
        )
        try await connection.start()
        await connection.shutdown()

        do {
            try await connection.start()
            XCTFail("a stopped connection must not silently pretend to restart")
        } catch MCPConnectionError.cannotRestart {
            // Exact one-shot contract.
        } catch {
            XCTFail("expected cannotRestart, got \(error)")
        }
    }

    func testLiveServer_malformedStdoutFloodCoalescesDiagnosticsAndFailsClosed() async throws {
        let script = try makeFakeServer()
        let diagnostics = LockedStrings()
        MCPLog.installDiagnosticSink { diagnostics.append($0) }
        defer { MCPLog.resetDiagnosticSink() }
        let connection = MCPServerConnection(
            config: MCPServerConfig(
                name: "malformed-flood",
                command: script,
                args: ["malformed-flood"])
        )

        do {
            try await connection.start()
            XCTFail("repeated malformed stdout must fail the handshake")
        } catch {
            // Expected fail-closed path.
        }
        await connection.shutdown()

        let framingLines = diagnostics.snapshot().filter {
            $0.contains("non-JSON stdout") ||
            $0.contains("violated JSON-RPC stdout framing")
        }
        XCTAssertEqual(framingLines.count, 2,
                       "one initial and one terminal warning are the entire flood budget")
        XCTAssertLessThan(diagnostics.snapshot().joined().utf8.count, 12_000)
    }

    func testLiveServer_bannerWarnsOnceThenValidJSONRemainsUsable() async throws {
        let script = try makeFakeServer()
        let diagnostics = LockedStrings()
        MCPLog.installDiagnosticSink { diagnostics.append($0) }
        defer { MCPLog.resetDiagnosticSink() }
        let connection = MCPServerConnection(
            config: MCPServerConfig(
                name: "banner-then-valid",
                command: script,
                args: ["banner-then-valid"])
        )

        try await connection.start()
        let aliveAfterStart = await connection.isAlive
        XCTAssertTrue(aliveAfterStart)
        let tools = try await connection.listTools()
        XCTAssertTrue(tools.isEmpty)
        let aliveAfterList = await connection.isAlive
        XCTAssertTrue(aliveAfterList)
        await connection.shutdown()

        let lines = diagnostics.snapshot()
        XCTAssertEqual(
            lines.filter { $0.contains("non-JSON stdout") }.count,
            1,
            "multiple banner lines receive one connection-level warning")
        XCTAssertFalse(
            lines.contains { $0.contains("violated JSON-RPC stdout framing") },
            "a bounded startup banner must not close an otherwise valid server")
    }

    func testLiveServer_repeatedFailurePreservesFinalStderrTailAndClosesFD() async throws {
        let script = try makeFakeServer()
        let diagnostics = LockedStrings()
        MCPLog.installDiagnosticSink { diagnostics.append($0) }
        defer { MCPLog.resetDiagnosticSink() }

        for index in 0..<12 {
            let connection = MCPServerConnection(
                config: MCPServerConfig(
                    name: "stderr-exit-\(index)",
                    command: script,
                    args: ["stderr-exit"])
            )
            do {
                try await connection.start()
                XCTFail("stderr-exit must fail initialization")
            } catch {
                // Expected. start() performs definitive joined rollback.
            }
            await connection.shutdown()
        }
        XCTAssertGreaterThanOrEqual(
            diagnostics.snapshot().filter { $0.contains("fatal-stderr-marker") }.count,
            12,
            "each failing launch must drain stderr before surfacing its reason")

        let live = MCPServerConnection(
            config: MCPServerConfig(
                name: "stderr-fd",
                command: script,
                args: ["fragmented"])
        )
        try await live.start()
        let descriptor = await live.stderrDescriptorForTesting
        XCTAssertGreaterThan(descriptor, STDERR_FILENO)
        await live.shutdown()
        errno = 0
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF,
                       "shutdown returned before the stderr reader closed its descriptor")
    }

    func testManager_replacesDeadCachedConnectionInsteadOfReusingOneShotTransport() async {
        let config = MCPServerConfig(
            name: "replacement",
            command: "/not/used")
        let factory = ReplacementConnectionFactory()
        let manager = MCPClientManager(
            serversForTesting: [config],
            connectionFactory: { factory.make(config: $0) })

        _ = await manager.discoverAndWrapTools(projectRoot: "")
        XCTAssertEqual(factory.count, 1)
        _ = await manager.discoverAndWrapTools(projectRoot: "")
        XCTAssertEqual(factory.count, 2,
                       "the second discovery must replace the first dead connection")

        if let first = factory.connection(at: 0) {
            let shutdowns = await first.shutdownCount
            XCTAssertEqual(shutdowns, 1,
                           "replacement must definitively shut down the stale connection")
        } else {
            XCTFail("factory did not retain its first test connection")
        }
        await manager.shutdownAll()
    }

    func testManager_concurrentDiscoverySharesCancellationSafeStartupWithoutOrphan() async {
        let config = MCPServerConfig(
            name: "singleflight",
            command: "/not/used")
        let factory = ReplacementConnectionFactory(
            firstDiesAfterListing: false,
            startDelayNanoseconds: 150_000_000)
        let manager = MCPClientManager(
            serversForTesting: [config],
            connectionFactory: { factory.make(config: $0) })

        var discoveries: [Task<[RemoteMCPTool], Never>] = []
        for _ in 0..<16 {
            discoveries.append(Task {
                await manager.discoverAndWrapTools(projectRoot: "")
            })
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        discoveries[0].cancel()
        for discovery in discoveries {
            _ = await discovery.value
        }

        XCTAssertEqual(factory.count, 1,
                       "actor reentrancy must not spawn one connection per waiter")
        guard let connection = factory.connection(at: 0) else {
            XCTFail("factory did not retain the shared connection")
            return
        }
        let starts = await connection.startCount
        let shutdownsBeforeManagerShutdown = await connection.shutdownCount
        let aliveBeforeManagerShutdown = await connection.isAlive
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(shutdownsBeforeManagerShutdown, 0,
                       "a cancelled waiter must not tear startup down for peers")
        XCTAssertTrue(aliveBeforeManagerShutdown)

        await manager.shutdownAll()
        let shutdownsAfterManagerShutdown = await connection.shutdownCount
        let aliveAfterManagerShutdown = await connection.isAlive
        XCTAssertEqual(shutdownsAfterManagerShutdown, 1,
                       "the sole shared connection must have exactly one owner")
        XCTAssertFalse(aliveAfterManagerShutdown)
    }

    func testManager_shutdownDuringSharedStartupJoinsSoleConnectionWithoutPublishingOrphan() async {
        let config = MCPServerConfig(
            name: "startup-shutdown",
            command: "/not/used")
        let factory = ReplacementConnectionFactory(
            firstDiesAfterListing: false,
            startDelayNanoseconds: 150_000_000)
        let manager = MCPClientManager(
            serversForTesting: [config],
            connectionFactory: { factory.make(config: $0) })
        let diagnostics = LockedStrings()
        MCPLog.installDiagnosticSink { diagnostics.append($0) }
        defer { MCPLog.resetDiagnosticSink() }

        let discovery = Task {
            await manager.discoverAndWrapTools(projectRoot: "")
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        async let firstShutdown: Void = manager.shutdownAll()
        async let joinedShutdown: Void = manager.shutdownAll()
        _ = await (firstShutdown, joinedShutdown)
        _ = await discovery.value

        XCTAssertEqual(factory.count, 1)
        guard let connection = factory.connection(at: 0) else {
            XCTFail("factory did not retain the startup connection")
            return
        }
        let starts = await connection.startCount
        let shutdowns = await connection.shutdownCount
        let alive = await connection.isAlive
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(shutdowns, 1,
                       "both shutdown waiters must join one definitive cleanup")
        XCTAssertFalse(alive)
    }

    // MARK: - Diagnostic routing trust boundary

    func testDiagnosticSink_sanitizesANSIControlsBidiAndBoundsBeforeDelivery() {
        let diagnostics = LockedStrings()
        MCPLog.installDiagnosticSink { diagnostics.append($0) }
        defer { MCPLog.resetDiagnosticSink() }

        let dirty = "\u{001B}[31mRED\u{001B}[0m\u{0007}\rrewrite"
                    + "\u{202E}bidi\u{2028}line\u{2029}paragraph " +
                    String(repeating: "A", count: 20_000)
        MCPLog.warn(dirty)
        MCPLog.error("second")

        let lines = diagnostics.snapshot()
        XCTAssertEqual(lines.count, 2)
        let warning = lines[0]
        XCTAssertFalse(warning.contains("\u{001B}"))
        XCTAssertFalse(warning.contains("[31m"), "complete ANSI sequence must be removed, not just ESC")
        XCTAssertFalse(warning.contains("\u{0007}"))
        XCTAssertFalse(warning.contains("\r"))
        XCTAssertFalse(warning.contains("\u{202E}"))
        XCTAssertFalse(warning.contains("\u{2028}"))
        XCTAssertFalse(warning.contains("\u{2029}"))
        XCTAssertEqual(warning.filter { $0 == "\n" }.count, 1,
                       "a diagnostic must contain only its final framing newline")
        XCTAssertTrue(warning.contains("RED"))
        XCTAssertTrue(warning.contains("rewrite"))
        XCTAssertTrue(warning.contains("truncated"))
        XCTAssertLessThan(warning.utf8.count, 4_500)
    }

    func testDiagnosticSink_isExclusiveAndResetRestoresStderrRoute() {
        let stderr = LockedStrings()
        let sink = LockedStrings()
        let router = DiagnosticRouter { stderr.append($0) }

        router.install { sink.append($0) }
        router.deliver("sink-only\n")
        XCTAssertEqual(sink.snapshot(), ["sink-only\n"])
        XCTAssertTrue(stderr.snapshot().isEmpty, "installed sink must be exclusive")

        router.reset()
        router.deliver("stderr-again\n")
        XCTAssertEqual(stderr.snapshot(), ["stderr-again\n"])
        XCTAssertEqual(sink.snapshot(), ["sink-only\n"])
    }

    func testVerboseServerStderr_usesInstalledSinkAndSanitizesServerAndText() {
        let previous = ProcessInfo.processInfo.environment["KIST_MCP_LOG"]
        setenv("KIST_MCP_LOG", "1", 1)
        defer {
            if let previous {
                setenv("KIST_MCP_LOG", previous, 1)
            } else {
                unsetenv("KIST_MCP_LOG")
            }
            MCPLog.resetDiagnosticSink()
        }

        let diagnostics = LockedStrings()
        MCPLog.installDiagnosticSink { diagnostics.append($0) }
        MCPLog.serverStderr(
            server: "bad\u{202E}name",
            text: "\u{001B}]0;owned\u{0007}\u{001B}[32mmessage\u{001B}[0m\rrewrite"
        )

        let lines = diagnostics.snapshot()
        XCTAssertEqual(lines.count, 1)
        let line = lines[0]
        XCTAssertTrue(line.hasPrefix("[mcp STDERR]"))
        XCTAssertTrue(line.contains("message"))
        XCTAssertTrue(line.contains("rewrite"))
        XCTAssertFalse(line.contains("owned"), "OSC terminal command and contents must be removed")
        XCTAssertFalse(line.contains("[32m"))
        XCTAssertFalse(line.contains("\u{202E}"))
        XCTAssertFalse(line.contains("\r"))
    }

    // MARK: - Helpers

    private enum LiveTestError: Error {
        case connectionNotAlive
    }

    private func makeFakeServer() throws -> String {
        let directory = NSTemporaryDirectory() + "agentcore-mcp-order-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let path = directory + "/fake-mcp.sh"
        let source = #"""
        #!/bin/sh
        mode="$1"
        while IFS= read -r request; do
            id=$(printf '%s\n' "$request" | sed -E 's/.*"id"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/')
            case "$request" in
                *initialize*)
                    if [ "$mode" = "stderr-exit" ]; then
                        printf 'fatal-stderr-marker\n' >&2
                        exit 7
                    elif [ "$mode" = "banner-then-valid" ]; then
                        printf 'gateway starting\n'
                        printf 'loading provider registry\n'
                        printf 'ready\n'
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"fake","version":"1"}}}\n' "$id"
                    elif [ "$mode" = "malformed-flood" ]; then
                        count=0
                        while [ "$count" -lt 1000 ]; do
                            printf 'not-json\n'
                            count=$((count + 1))
                        done
                        sleep 30
                    elif [ "$mode" = "oversized" ]; then
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"padding":"' "$id"
                        dd if=/dev/zero bs=1024 count=1025 2>/dev/null | tr '\000' 'Q'
                        printf '"}}\n'
                    elif [ "$mode" = "fragmented" ]; then
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"fake","version":"1"},"padding":"' "$id"
                        dd if=/dev/zero bs=1024 count=70 2>/dev/null | tr '\000' 'x'
                        printf '"}}\n'
                    else
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"fake","version":"1"}}}\n' "$id"
                    fi
                    if [ "$mode" = "nonreading" ]; then
                        sleep 30
                    fi
                    ;;
                *tools*list*)
                    if [ "$mode" = "no-response" ]; then
                        printf 'seen\n' > "$0.request.seen"
                        sleep 30
                    elif [ "$mode" = "eof-tail" ]; then
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[]}}' "$id"
                        exit 0
                    elif [ "$mode" = "exit-tail" ]; then
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[],"padding":"' "$id"
                        dd if=/dev/zero bs=1024 count=512 2>/dev/null | tr '\000' 't'
                        printf '"}}'
                        exit 0
                    elif [ "$mode" = "descendant-fd" ]; then
                        (sleep 30) &
                        printf '%s\n' "$!" > "$0.descendant.pid"
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[]}}' "$id"
                        exit 0
                    elif [ "$mode" = "delayed-descendant-tail" ]; then
                        (
                            sleep 0.08
                            printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[]}}\n' "$id"
                        ) &
                        exit 0
                    else
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[]}}\n' "$id"
                    fi
                    ;;
                *tools*call*)
                    printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[]}}\n' "$id"
                    ;;
            esac
        done
        """#
        try source.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }

    @discardableResult
    private func recordDescendantPID(for script: String) -> pid_t? {
        let path = script + ".descendant.pid"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else {
            XCTFail("fake server did not record its retained-fd descendant")
            return nil
        }
        descendantPIDs.append(pid)
        return pid
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () -> Bool,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !predicate() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private func waitUntilProcessIsGone(
        _ pid: pid_t,
        timeout: TimeInterval
    ) async -> Bool {
        await waitUntil({
            errno = 0
            return kill(pid, 0) == -1 && errno == ESRCH
        }, timeout: timeout)
    }

    private func monotonicDeadline(after nanoseconds: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let (result, overflow) = now.addingReportingOverflow(nanoseconds)
        return overflow ? UInt64.max : result
    }

    private func descriptorIsReadable(_ descriptor: Int32) -> Bool {
        var state = pollfd(
            fd: descriptor,
            events: Int16(POLLIN),
            revents: 0)
#if canImport(Darwin)
        let result = Darwin.poll(&state, 1, 0)
#elseif canImport(Glibc)
        let result = Glibc.poll(&state, 1, 0)
#else
        let result: Int32 = -1
#endif
        return result > 0 && (state.revents & Int16(POLLIN)) != 0
    }

    private func readAllAvailable(from descriptor: Int32) -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
#if canImport(Darwin)
                Darwin.read(descriptor, bytes.baseAddress!, bytes.count)
#elseif canImport(Glibc)
                Glibc.read(descriptor, bytes.baseAddress!, bytes.count)
#else
                -1
#endif
            }
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0, errno == EINTR { continue }
            return result
        }
    }

    private func drainInbox(
        _ inbox: MCPOrderedInbox
    ) -> (bytes: Data, end: MCPOrderedInbox.EndReason?) {
        var bytes = Data()
        var end: MCPOrderedInbox.EndReason?
        while let event = inbox.next() {
            switch event {
            case .bytes(let chunk):
                bytes.append(chunk)
            case .end(let reason):
                end = reason
            case .overflow(let byteLimit, let eventLimit):
                XCTFail("unexpected inbox overflow (\(byteLimit) bytes / \(eventLimit) events)")
            }
        }
        return (bytes, end)
    }

    private func suppressSIGPIPE(on handle: FileHandle) {
#if canImport(Darwin)
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
#elseif canImport(Glibc)
        // Linux pipes have no per-descriptor F_SETNOSIGPIPE. XCTest owns this
        // process, so ignore SIGPIPE and assert write failure through EPIPE.
        _ = Glibc.signal(SIGPIPE, SIG_IGN)
#endif
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class LockedWriterOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MCPNonblockingPipeWriter.Outcome?

    func set(_ value: MCPNonblockingPipeWriter.Outcome) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func snapshot() -> MCPNonblockingPipeWriter.Outcome? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class DelayedExitProcessHarness: @unchecked Sendable {
    private let condition = NSCondition()
    private var exitReleased = false
    private var signals: [Int32] = []
    private var reaps = 0

    var operations: MCPStdioProcessOperations {
        MCPStdioProcessOperations(
            observeExit: { [self] _ in
                condition.lock()
                while !exitReleased {
                    condition.wait()
                }
                condition.unlock()
                return .exitedUnreaped
            },
            signalGroup: { [self] _, signalNumber in
                condition.lock()
                signals.append(signalNumber)
                condition.unlock()
            },
            reapPrimary: { [self] _ in
                condition.lock()
                reaps += 1
                condition.unlock()
                return true
            },
            pauseMicroseconds: { _ in })
    }

    func releaseExit() {
        condition.lock()
        exitReleased = true
        condition.broadcast()
        condition.unlock()
    }

    func signalSnapshot() -> [Int32] {
        condition.lock()
        defer { condition.unlock() }
        return signals
    }

    var reapCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return reaps
    }
}

private enum CallOutcome {
    case success
    case cancelled
    case failure(String)
}

private final class LockedCallOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CallOutcome?

    func set(_ value: CallOutcome) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func snapshot() -> CallOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private actor ReplacementTestConnection: MCPConnection {
    nonisolated let config: MCPServerConfig
    private let diesAfterListing: Bool
    private let startDelayNanoseconds: UInt64
    private var alive = false
    private(set) var startCount = 0
    private(set) var shutdownCount = 0

    init(
        config: MCPServerConfig,
        diesAfterListing: Bool,
        startDelayNanoseconds: UInt64
    ) {
        self.config = config
        self.diesAfterListing = diesAfterListing
        self.startDelayNanoseconds = startDelayNanoseconds
    }

    var isAlive: Bool { alive }

    func start() async throws {
        startCount += 1
        if startDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: startDelayNanoseconds)
        }
        alive = true
    }

    func listTools() -> [RemoteToolSpec] {
        if diesAfterListing { alive = false }
        return []
    }

    func callTool(
        name: String,
        arguments: [String: Any]
    ) throws -> [String: Any] {
        [:]
    }

    func shutdown() {
        shutdownCount += 1
        alive = false
    }
}

private final class ReplacementConnectionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let firstDiesAfterListing: Bool
    private let startDelayNanoseconds: UInt64
    private var connections: [ReplacementTestConnection] = []

    init(
        firstDiesAfterListing: Bool = true,
        startDelayNanoseconds: UInt64 = 0
    ) {
        self.firstDiesAfterListing = firstDiesAfterListing
        self.startDelayNanoseconds = startDelayNanoseconds
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    func make(config: MCPServerConfig) -> any MCPConnection {
        lock.lock()
        let connection = ReplacementTestConnection(
            config: config,
            diesAfterListing:
                firstDiesAfterListing && connections.isEmpty,
            startDelayNanoseconds: startDelayNanoseconds)
        connections.append(connection)
        lock.unlock()
        return connection
    }

    func connection(at index: Int) -> ReplacementTestConnection? {
        lock.lock()
        defer { lock.unlock() }
        guard connections.indices.contains(index) else { return nil }
        return connections[index]
    }
}
