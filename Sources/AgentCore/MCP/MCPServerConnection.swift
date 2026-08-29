import Foundation

// MARK: - MCP Server Connection (AgentCore)
//
// One live stdio connection to an external MCP server. Owns the subprocess, frames
// JSON-RPC 2.0 over its stdin/stdout (newline-delimited — mirrors our own
// mcp-server framing), correlates responses to requests by id, enforces timeouts.
//
// Concurrency: an `actor`. All mutable protocol state (pending continuations, id
// counter, alive flag, read buffer) is actor-isolated. One serial stdout pump reads
// the pipe and synchronously enqueues observations in `MCPOrderedInbox`; exactly
// one scheduled actor drain consumes that FIFO. Process termination only signals
// the pump, which drains kernel-readable tail bytes before publishing stream end.
//
// Failure model (fail-fast, NO ZOMBIES):
//   - spawn failure        -> throws, no process left behind
//   - handshake failure    -> the half-started process is SHUT DOWN, then rethrows
//   - request timeout      -> that one call throws; connection stays usable
//   - EOF / crash          -> ALL pending calls fail with .serverClosed, alive=false
//   - shutdown()           -> SIGTERM, close pipes, fail pending; idempotent

enum MCPConnectionError: Error, LocalizedError {
    case spawnFailed(String)
    case notInitialized
    case serverClosed
    case timeout(method: String)
    case rpcError(code: Int, message: String)
    case badResponse(String)
    case alreadyShuttingDown
    case cannotRestart

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let m): return "Failed to spawn MCP server: \(m)"
        case .notInitialized: return "MCP server not initialized"
        case .serverClosed: return "MCP server connection closed"
        case .timeout(let method): return "MCP request timed out: \(method)"
        case .rpcError(let code, let message): return "MCP error \(code): \(message)"
        case .badResponse(let m): return "Malformed MCP response: \(m)"
        case .alreadyShuttingDown: return "MCP connection is shutting down"
        case .cannotRestart:
            return "MCP stdio connections are one-shot; create a new connection to restart"
        }
    }
}

/// A tool as advertised by a remote server (`tools/list` entry). Consumed inside the
/// manager actor to build a (Sendable) `RemoteMCPTool`, so it need not be Sendable.
struct RemoteToolSpec {
    let name: String
    let description: String
    let inputSchema: [String: Any]   // JSON Schema object (may be empty)
}

/// Bounded, lock-guarded tail of a server's most recent stderr. The live stream is gated behind
/// `verbose` (a chatty server floods the REPL), but on a spawn/handshake/unexpected-close FAILURE
/// we surface this tail so a fatal server message ("missing API key", a crash trace) isn't a silent
/// dark spot. Written from the non-isolated pipe handler, read from the actor — hence the lock.
final class MCPStderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = ""
    private let cap = 2000

    func append(_ s: String) {
        // Bound the incoming value before concatenating so a hostile stderr write
        // cannot create an attacker-sized temporary allocation in the tail buffer.
        let recent = String(decoding: s.utf8.suffix(cap), as: UTF8.self)
        lock.lock()
        buf = String((buf + recent).suffix(cap))
        lock.unlock()
    }

    func snapshot() -> String { lock.lock(); defer { lock.unlock() }; return buf }
}

private final class MCPRequestCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

// Combined: main's MCPStderrTail (failure-surface) + kist-modularized's MCPConnection conformance.
actor MCPServerConnection: MCPConnection {
    private enum Lifecycle {
        case idle
        case starting
        case running
        case stopping
        case stopped
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<[String: Any], Error>
        let writerToken: UUID
        var timeoutTask: Task<Void, Never>?
    }

    let config: MCPServerConfig

    private let stderrTail = MCPStderrTail()
    private let stdoutInbox: MCPOrderedInbox
    private let stdoutPump: MCPOrderedPipePump
    private let stderrPump: MCPStderrPipePump
    private var stdioProcess: MCPStdioProcess?
    private var stdinWriter: MCPNonblockingPipeWriter?

    private var nextId = 1
    private var pending: [Int: PendingRequest] = [:]
    private var alive = false
    private var didShutdown = false
    private var lifecycle: Lifecycle = .idle
    /// The protocol version the server negotiated in `initialize` (previously discarded). Recorded so the
    /// version kist actually speaks is the one the server agreed to, not a stale hardcoded guess.
    private var negotiatedVersion = MCPProtocol.offeredVersion
    private var readBuffer = Data()
    private var stdoutGeneration: MCPOrderedPipePump.Generation?
    private var malformedLineCount = 0
    private var malformedWarningEmitted = false

    /// Max single JSON-RPC line accepted before we assume a malicious/runaway server
    /// and drop the connection. 1 MB.
    private let maxLineBytes = 1 * 1024 * 1024
    private let initializeTimeout: UInt64 = 10
    private let callTimeout: UInt64
    private let primaryExitDrainByteLimit: Int
    private let primaryExitDrainTimeoutNanoseconds: UInt64
    private let malformedLineLimit = 8
    private let actorEventBatchLimit = 32
    private let actorLineBatchLimit = 128

    /// The default accepts multiple normal pipe reads while still bounding aggregate
    /// callback-to-actor backlog independently of the per-line bound.
    init(
        config: MCPServerConfig,
        inboxByteLimit: Int = 2 * 1024 * 1024,
        primaryExitDrainByteLimit: Int? = nil,
        primaryExitDrainTimeoutNanoseconds: UInt64 = 5_000_000_000,
        callTimeout: UInt64 = 30
    ) {
        let inbox = MCPOrderedInbox(byteLimit: inboxByteLimit)
        let drainLimit = primaryExitDrainByteLimit ?? inboxByteLimit
        precondition(callTimeout > 0, "MCP call timeout must be positive")
        self.config = config
        self.stdoutInbox = inbox
        self.callTimeout = callTimeout
        self.primaryExitDrainByteLimit = drainLimit
        self.primaryExitDrainTimeoutNanoseconds =
            primaryExitDrainTimeoutNanoseconds
        self.stdoutPump = MCPOrderedPipePump(
            label: "com.kist.mcp.stdout.\(config.name)",
            inbox: inbox,
            primaryExitDrainByteLimit: drainLimit,
            primaryExitDrainTimeoutNanoseconds:
                primaryExitDrainTimeoutNanoseconds
        )
        self.stderrPump = MCPStderrPipePump(
            label: "com.kist.mcp.stderr.\(config.name)",
            tail: stderrTail,
            serverName: config.name)
    }

    // MARK: - Lifecycle

    /// Spawn the process, wire pipes, and complete `initialize` + `notifications/initialized`.
    /// Throws on ANY failure and leaves NO running process behind — if the handshake
    /// fails (e.g. the server spawns but never answers `initialize`), the half-started
    /// process is shut down before the error propagates.
    func start() async throws {
        switch lifecycle {
        case .running:
            return
        case .idle:
            lifecycle = .starting
        case .starting, .stopping:
            throw MCPConnectionError.alreadyShuttingDown
        case .stopped:
            throw MCPConnectionError.cannotRestart
        }

        let launched: MCPSpawnedStdio
        do {
            launched = try MCPSpawnedStdio.spawn(config: config)
        } catch {
            lifecycle = .stopped
            didShutdown = true
            throw MCPConnectionError.spawnFailed(error.localizedDescription)
        }

        let writer: MCPNonblockingPipeWriter
        do {
            writer = try MCPNonblockingPipeWriter(
                descriptor: launched.stdinWriteFD,
                label: "com.kist.mcp.stdin.\(config.name)")
        } catch {
            MCPDescriptor.closeOnce(launched.stdinWriteFD)
            MCPDescriptor.closeOnce(launched.stdoutReadFD)
            MCPDescriptor.closeOnce(launched.stderrReadFD)
            launched.process.startMonitoring(onExit: {})
            launched.process.requestTermination()
            await launched.process.shutdown()
            lifecycle = .stopped
            didShutdown = true
            throw MCPConnectionError.spawnFailed(error.localizedDescription)
        }

        stdinWriter = writer
        stdioProcess = launched.process
        let stdoutPump = self.stdoutPump
        let stderrPump = self.stderrPump
        let generation = stdoutPump.start(
            descriptor: launched.stdoutReadFD
        ) { [weak self] in
            self?.scheduleStdoutDrain()
        }
        stdoutGeneration = generation
        stderrPump.start(descriptor: launched.stderrReadFD)
        launched.process.startMonitoring {
            stdoutPump.primaryProcessDidTerminate(generation: generation)
            stderrPump.requestFinalDrain()
        }
        alive = true

        // Handshake. If it fails, tear the process down before rethrowing — otherwise
        // a server that spawns but never completes `initialize` leaks as a zombie.
        do {
            let result = try await request(
                method: "initialize",
                params: MCPProtocol.initializeParams(),
                timeoutSeconds: initializeTimeout
            )
            // Honor the version the server negotiated back (previously ignored) instead of a stale guess.
            negotiatedVersion = MCPProtocol.negotiatedVersion(from: result)
            guard alive, !didShutdown else {
                throw MCPConnectionError.serverClosed
            }
            lifecycle = .running
            notify(method: "notifications/initialized", params: [:])
        } catch {
            // Joins transport queues and completes the bounded TERM/KILL phase.
            // A retained process owner performs the eventual waitpid if the
            // primary cannot exit inside that finite budget.
            await shutdown()
            // Surface the server's OWN reason (gated out of the live stream) so a handshake failure
            // isn't a silent "connection closed" — a fatal stderr message ("missing API key") is the
            // actual diagnosis. Ungated warn; bounded so a chatty server can't blow out the log.
            let reason = stderrTail.snapshot().trimmingCharacters(in: .whitespacesAndNewlines)
            if !reason.isEmpty {
                MCPLog.warn("server '\(config.name)' failed to initialize; recent stderr: \(String(reason.suffix(500)))")
            }
            throw error
        }
    }

    /// List the tools this server exposes. Call after `start()`.
    func listTools() async throws -> [RemoteToolSpec] {
        let result = try await request(method: "tools/list", params: [:], timeoutSeconds: callTimeout)
        guard let tools = result["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return RemoteToolSpec(
                name: name,
                description: entry["description"] as? String ?? "",
                inputSchema: (entry["inputSchema"] as? [String: Any]) ?? [:]
            )
        }
    }

    /// Invoke a tool. Returns the raw result object (caller sanitizes).
    func callTool(name: String, arguments: [String: Any], correlationID: String? = nil) async throws -> [String: Any] {
        try await request(
            method: "tools/call",
            params: Self.toolCallParams(name: name, arguments: arguments, config: config,
                                        correlationID: correlationID),
            timeoutSeconds: callTimeout
        )
    }

    static func toolCallParams(
        name: String,
        arguments: [String: Any],
        config: MCPServerConfig,
        correlationID: String? = nil
    ) -> [String: Any] {
        var params: [String: Any] = ["name": name, "arguments": arguments]
        let token = config.env["FCA_MCP_AUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorization = token.flatMap { $0.isEmpty ? nil : "Bearer \($0)" }
        if let metadata = MCPProtocol.toolCallMetadata(
            correlationID: correlationID, authorization: authorization) {
            params["_meta"] = metadata
        }
        return params
    }

    var isAlive: Bool { alive }

    /// Synchronous teardown: mark dead, detach handlers, SIGTERM, close stdin, fail
    /// pending. Idempotent. Used by reactive paths (oversized line, start() rollback)
    /// where we can't await. Does NOT guarantee the child is gone — see `shutdown()`.
    private func beginShutdown(scheduleDefinitiveShutdown: Bool = true) {
        guard !didShutdown else { return }
        didShutdown = true
        alive = false
        lifecycle = .stopping
        stdinWriter?.requestStop()
        if let stdoutGeneration {
            stdoutPump.requestStop(generation: stdoutGeneration)
        }
        stdoutInbox.closeAndDiscard()
        stderrPump.requestFinalDrain()
        stdioProcess?.requestTermination()
        failAllPending(with: MCPConnectionError.serverClosed)
        if scheduleDefinitiveShutdown {
            // Reactive failures (EOF, malformed stdout, a partial stdin frame)
            // have no guaranteed external caller. Retain the actor until all pipe
            // queues join and the bounded process-group shutdown phase completes.
            // The process object retains itself if an eventual waitpid is needed.
            Task { await self.shutdown() }
        }
    }

    /// Bounded shutdown: signal the process group with SIGTERM, escalate to SIGKILL,
    /// and join the pipe queues. Normally the primary exits and is reaped before
    /// return. If it remains uninterruptible beyond the finite grace budget, a
    /// retained reaper performs the one eventual waitpid without pinning the caller.
    /// Idempotent. This is what `shutdownAll()` and start()-failure rollback call.
    func shutdown() async {
        let writer = stdinWriter
        let process = stdioProcess
        let generation = stdoutGeneration
        beginShutdown(scheduleDefinitiveShutdown: false)

        await writer?.waitUntilStopped()
        await process?.shutdown()
        if let generation {
            await stdoutPump.waitUntilStopped(generation: generation)
            if stdoutGeneration == generation {
                stdoutGeneration = nil
            }
        }
        stderrPump.requestFinalDrain()
        await stderrPump.waitUntilStopped()
        if stdinWriter === writer { stdinWriter = nil }
        if stdioProcess === process { stdioProcess = nil }
        lifecycle = .stopped
    }

    // MARK: - JSON-RPC core

    private func request(method: String, params: [String: Any], timeoutSeconds: UInt64) async throws -> [String: Any] {
        guard alive, !didShutdown, let writer = stdinWriter else {
            throw MCPConnectionError.serverClosed
        }

        let id = nextId
        nextId += 1

        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard let line = encodeLine(message) else {
            throw MCPConnectionError.badResponse("could not encode request \(method)")
        }

        let writerToken = UUID()
        let cancellation = MCPRequestCancellationState()
        let timeoutNanoseconds = Self.timeoutNanoseconds(seconds: timeoutSeconds)
        let deadline = Self.deadline(after: timeoutNanoseconds)

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[String: Any], Error>) in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    await self?.timeoutPending(
                        id: id,
                        writerToken: writerToken,
                        method: method)
                }
                pending[id] = PendingRequest(
                    continuation: continuation,
                    writerToken: writerToken,
                    timeoutTask: timeoutTask)

                writer.enqueue(
                    token: writerToken,
                    data: line,
                    deadlineNanoseconds: deadline
                ) { [weak self] outcome in
                    Task { [weak self] in
                        await self?.handleWriteOutcome(
                            outcome,
                            id: id,
                            writerToken: writerToken,
                            method: method)
                    }
                }

                // Cancellation can race between Task.checkCancellation() and
                // continuation registration. The lock-backed flag closes that gap;
                // the actor-side removal remains exactly-once.
                if cancellation.isCancelled {
                    cancelPending(id: id, writerToken: writerToken)
                }
            }
        } onCancel: {
            cancellation.cancel()
            writer.cancel(writerToken)
            Task { [weak self] in
                await self?.cancelPending(id: id, writerToken: writerToken)
            }
        }
    }

    private func handleWriteOutcome(
        _ outcome: MCPNonblockingPipeWriter.Outcome,
        id: Int,
        writerToken: UUID,
        method: String
    ) {
        // Cancelling or timing out after write(2) made partial progress leaves an
        // unterminated JSON-RPC frame in the byte stream. Even when the pending
        // continuation already won the race, that transport cannot be reused.
        let lostFraming: Bool
        switch outcome {
        case .cancelled(partialWrite: true),
             .timedOut(partialWrite: true):
            lostFraming = true
        default:
            lostFraming = false
        }

        guard pending[id]?.writerToken == writerToken else {
            if lostFraming { beginShutdown() }
            return
        }
        switch outcome {
        case .success:
            return
        case .cancelled:
            finishPending(
                id: id,
                writerToken: writerToken,
                result: .failure(CancellationError()))
        case .timedOut:
            finishPending(
                id: id,
                writerToken: writerToken,
                result: .failure(MCPConnectionError.timeout(method: method)))
        case .overflow:
            finishPending(
                id: id,
                writerToken: writerToken,
                result: .failure(MCPConnectionError.badResponse(
                    "outbound MCP request exceeded the bounded stdin queue")))
        case .closed:
            finishPending(
                id: id,
                writerToken: writerToken,
                result: .failure(MCPConnectionError.serverClosed))
            beginShutdown()
        }
        if lostFraming { beginShutdown() }
    }

    private func timeoutPending(id: Int, writerToken: UUID, method: String) {
        guard pending[id]?.writerToken == writerToken else { return }
        stdinWriter?.cancel(writerToken)
        finishPending(
            id: id,
            writerToken: writerToken,
            result: .failure(MCPConnectionError.timeout(method: method)))
    }

    private func cancelPending(id: Int, writerToken: UUID) {
        guard pending[id]?.writerToken == writerToken else { return }
        stdinWriter?.cancel(writerToken)
        finishPending(
            id: id,
            writerToken: writerToken,
            result: .failure(CancellationError()))
    }

    private func finishPending(
        id: Int,
        writerToken: UUID,
        result: Result<[String: Any], Error>
    ) {
        guard let request = pending[id], request.writerToken == writerToken else {
            return
        }
        pending[id] = nil
        request.timeoutTask?.cancel()
        stdinWriter?.cancel(writerToken)
        switch result {
        case .success(let value):
            request.continuation.resume(returning: value)
        case .failure(let error):
            request.continuation.resume(throwing: error)
        }
    }

    private func notify(method: String, params: [String: Any]) {
        guard alive, !didShutdown, let writer = stdinWriter else { return }
        let message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        guard let line = encodeLine(message) else { return }
        let token = UUID()
        writer.enqueue(
            token: token,
            data: line,
            deadlineNanoseconds: Self.deadline(after: 5_000_000_000)
        ) { [weak self] outcome in
            guard case .success = outcome else {
                Task { [weak self] in await self?.notificationWriteFailed() }
                return
            }
        }
    }

    private func notificationWriteFailed() {
        guard alive, !didShutdown else { return }
        MCPLog.warn("server '\(config.name)' stdin closed while sending notification")
        beginShutdown()
    }

    // MARK: - Read path

    private nonisolated func scheduleStdoutDrain() {
        Task { [weak self] in await self?.drainStdoutInbox() }
    }

    /// The sole actor entry point for stdout bytes and both close observations.
    /// `MCPOrderedInbox` guarantees there is at most one scheduled drain at a time.
    private func drainStdoutInbox() async {
        var processedEvents = 0
        var remainingLines = actorLineBatchLimit
        while processedEvents < actorEventBatchLimit {
            let processedLines = dispatchBufferedLines(limit: remainingLines)
            remainingLines -= processedLines
            guard !didShutdown else {
                stdoutInbox.closeAndDiscard()
                return
            }

            if remainingLines == 0, hasBufferedCompleteLine {
                if stdoutInbox.continueDrainAfterYield(localWorkPending: true) {
                    scheduleStdoutDrain()
                }
                return
            }

            guard let event = stdoutInbox.next() else { return }
            processedEvents += 1
            switch event {
            case .bytes(let data):
                appendStdout(data)
            case .end(let reason):
                await handleStreamEnd(reason)
                return
            case .overflow(let byteLimit, let eventLimit):
                MCPLog.warn("server '\(config.name)' exceeded ordered stdout inbox bounds (\(byteLimit) bytes or \(eventLimit) callbacks); dropping")
                beginShutdown()
                return
            }
        }
        if stdoutInbox.continueDrainAfterYield(
            localWorkPending: hasBufferedCompleteLine
        ) {
            scheduleStdoutDrain()
        }
    }

    private func appendStdout(_ data: Data) {
        guard !didShutdown else { return }
        readBuffer.append(data)

        // Reject an oversized first line immediately. Complete lines behind it are
        // processed in bounded actor batches below, so aggregate callback size is
        // never mistaken for one line.
        if let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            if readBuffer.distance(
                from: readBuffer.startIndex,
                to: newlineIndex
            ) > maxLineBytes {
                MCPLog.warn("server '\(config.name)' line exceeds \(maxLineBytes) bytes; dropping")
                beginShutdown()
            }
        } else if readBuffer.count > maxLineBytes {
            MCPLog.warn("server '\(config.name)' sent >\(maxLineBytes) bytes with no newline; dropping")
            beginShutdown()
        }
    }

    /// Dispatch at most `limit` complete JSON-RPC lines. A single kernel read can
    /// contain thousands of tiny messages; bounding them separately from callback
    /// events guarantees another actor turn gets a scheduling opportunity.
    @discardableResult
    private func dispatchBufferedLines(limit: Int) -> Int {
        guard !didShutdown, limit > 0 else { return 0 }
        let newline: UInt8 = 0x0A
        var processed = 0
        while processed < limit,
              let idx = readBuffer.firstIndex(of: newline) {
            let lineByteCount = readBuffer.distance(
                from: readBuffer.startIndex,
                to: idx)
            if lineByteCount > maxLineBytes {
                MCPLog.warn("server '\(config.name)' line exceeds \(maxLineBytes) bytes; dropping")
                beginShutdown()
                return processed
            }
            let lineData = readBuffer.subdata(in: readBuffer.startIndex..<idx)
            readBuffer.removeSubrange(readBuffer.startIndex...idx)
            processed += 1
            if lineData.isEmpty { continue }
            dispatch(lineData)
            if didShutdown { return processed }
        }

        if !hasBufferedCompleteLine, readBuffer.count > maxLineBytes {
            MCPLog.warn("server '\(config.name)' sent >\(maxLineBytes) bytes with no newline; dropping")
            beginShutdown()
        }
        return processed
    }

    private var hasBufferedCompleteLine: Bool {
        readBuffer.contains(0x0A)
    }

    private func dispatch(_ lineData: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            malformedLineCount += 1
            if !malformedWarningEmitted {
                malformedWarningEmitted = true
                MCPLog.warn("server '\(config.name)' sent non-JSON stdout; suppressing repeated diagnostics")
            }
            if malformedLineCount >= malformedLineLimit {
                MCPLog.warn("server '\(config.name)' repeatedly violated JSON-RPC stdout framing; dropping")
                beginShutdown()
            }
            return
        }
        // Only correlate responses to an integer id we issued. Server->client
        // requests/notifications are ignored (this minimal client doesn't serve them).
        guard let id = obj["id"] as? Int else { return }
        guard let request = pending[id] else { return }   // late/dup/timed-out

        if let error = obj["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let msg = error["message"] as? String ?? "unknown error"
            finishPending(
                id: id,
                writerToken: request.writerToken,
                result: .failure(MCPConnectionError.rpcError(code: code, message: msg)))
        } else if let result = obj["result"] as? [String: Any] {
            finishPending(
                id: id,
                writerToken: request.writerToken,
                result: .success(result))
        } else {
            finishPending(
                id: id,
                writerToken: request.writerToken,
                result: .failure(MCPConnectionError.badResponse(
                    "response \(id) had neither result nor error")))
        }
    }

    private func handleStreamEnd(_ endReason: MCPOrderedInbox.EndReason) async {
        guard alive, !didShutdown else { return }

        if endReason == .primaryExitDrainLimitExceeded ||
            endReason == .primaryExitDrainDeadlineExceeded {
            readBuffer.removeAll(keepingCapacity: false)
            let bound: String
            if endReason == .primaryExitDrainLimitExceeded {
                bound = "\(primaryExitDrainByteLimit)-byte"
            } else {
                let seconds = Double(primaryExitDrainTimeoutNanoseconds) /
                    1_000_000_000
                bound = "\(String(format: "%.3g", seconds))-second"
            }
            MCPLog.warn("server '\(config.name)' kept writing stdout after its primary process exited; exceeded \(bound) ordered drain bound")
            beginShutdown()
            await stderrPump.waitUntilStopped()
            return
        }
        if endReason == .stdoutReadFailure {
            readBuffer.removeAll(keepingCapacity: false)
            MCPLog.warn("server '\(config.name)' stdout read failed; dropping")
            beginShutdown()
            await stderrPump.waitUntilStopped()
            return
        }

        // A final complete JSON value without a trailing newline is still observed
        // before EOF. Dispatch it now; malformed/oversized tails fail closed without
        // reflecting their bytes into diagnostics.
        if !readBuffer.isEmpty {
            let tail = readBuffer
            readBuffer.removeAll(keepingCapacity: false)
            if tail.count > maxLineBytes {
                MCPLog.warn("server '\(config.name)' final line exceeds \(maxLineBytes) bytes; dropping")
            } else {
                dispatch(tail)
            }
        }

        beginShutdown()
        await stderrPump.waitUntilStopped()

        // Include the server's own last words if it printed any — a mid-session crash otherwise
        // surfaces as a bare "closed" with no cause (the live stderr line is gated behind verbose).
        let reason = stderrTail.snapshot().trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = reason.isEmpty ? "" : "; recent stderr: \(String(reason.suffix(500)))"
        let closeKind = endReason == .stdoutEOF
            ? "stdout EOF"
            : "primary process exited; stdout drained"
        MCPLog.warn("server '\(config.name)' closed (\(closeKind))\(suffix)")
    }

    private func failAllPending(with error: Error) {
        let requests = pending
        pending.removeAll()
        for (_, request) in requests {
            request.timeoutTask?.cancel()
            stdinWriter?.cancel(request.writerToken)
            request.continuation.resume(throwing: error)
        }
    }

    // MARK: - Helpers

    private static func timeoutNanoseconds(seconds: UInt64) -> UInt64 {
        let (value, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        return overflow ? UInt64.max : value
    }

    private static func deadline(after nanoseconds: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = now.addingReportingOverflow(nanoseconds)
        return overflow ? UInt64.max : deadline
    }

    var stderrDescriptorForTesting: Int32 {
        stderrPump.descriptorForTesting
    }

    private func encodeLine(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        data.append(0x0A)
        return data
    }
}
