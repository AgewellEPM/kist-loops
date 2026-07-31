import Foundation

// MARK: - MCP Server Connection (AgentCore)
//
// One live stdio connection to an external MCP server. Owns the subprocess, frames
// JSON-RPC 2.0 over its stdin/stdout (newline-delimited — mirrors our own
// mcp-server framing), correlates responses to requests by id, enforces timeouts.
//
// Concurrency: an `actor`. All mutable state (pending continuations, id counter,
// alive flag, read buffer) is actor-isolated, so id correlation is race-free without
// manual locks. Stdout is drained on a background readability handler that hops back
// into the actor to deliver lines.
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

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let m): return "Failed to spawn MCP server: \(m)"
        case .notInitialized: return "MCP server not initialized"
        case .serverClosed: return "MCP server connection closed"
        case .timeout(let method): return "MCP request timed out: \(method)"
        case .rpcError(let code, let message): return "MCP error \(code): \(message)"
        case .badResponse(let m): return "Malformed MCP response: \(m)"
        case .alreadyShuttingDown: return "MCP connection is shutting down"
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
    func append(_ s: String) { lock.lock(); buf = String((buf + s).suffix(cap)); lock.unlock() }
    func snapshot() -> String { lock.lock(); defer { lock.unlock() }; return buf }
}

// Combined: main's MCPStderrTail (failure-surface) + kist-modularized's MCPConnection conformance.
actor MCPServerConnection: MCPConnection {
    let config: MCPServerConfig

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stderrTail = MCPStderrTail()

    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var alive = false
    private var didShutdown = false
    private var readBuffer = Data()

    /// Max single JSON-RPC line accepted before we assume a malicious/runaway server
    /// and drop the connection. 1 MB.
    private let maxLineBytes = 1 * 1024 * 1024
    private let initializeTimeout: UInt64 = 10
    private let callTimeout: UInt64 = 30
    /// A misbehaving server (e.g. one printing a startup banner to stdout) emits many non-JSON lines;
    /// warn ONCE so it can't flood startup. Reset is unnecessary — one notice per connection is enough.
    private var warnedNonJSON = false

    init(config: MCPServerConfig) {
        self.config = config
    }

    // MARK: - Lifecycle

    /// Spawn the process, wire pipes, and complete `initialize` + `notifications/initialized`.
    /// Throws on ANY failure and leaves NO running process behind — if the handshake
    /// fails (e.g. the server spawns but never answers `initialize`), the half-started
    /// process is shut down before the error propagates.
    func start() async throws {
        guard !alive, !didShutdown else { return }

        process.executableURL = URL(fileURLWithPath: config.command)
        process.arguments = config.args
        process.environment = MCPClientConfig.resolvedEnvironment(for: config)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let serverName = config.name
        let tail = stderrTail
        // Drain stderr so the server can't block on a full pipe. The live line is gated behind verbose
        // (no flood), but we always keep the recent tail so a FAILURE can surface the server's own reason.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            tail.append(s)
            MCPLog.serverStderr(server: serverName, text: s)
        }
        // stdout: accumulate, split on newlines, deliver each JSON-RPC line.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                Task { await self.handleEOF() }   // EOF: server closed stdout
            } else {
                Task { await self.ingest(data) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.handleEOF() }
        }

        do {
            try process.run()
        } catch {
            cleanupHandlers()
            throw MCPConnectionError.spawnFailed(error.localizedDescription)
        }
        alive = true

        // Handshake. If it fails, tear the process down before rethrowing — otherwise
        // a server that spawns but never completes `initialize` leaks as a zombie.
        do {
            _ = try await request(
                method: "initialize",
                params: [
                    "protocolVersion": "2024-11-05",
                    "capabilities": [:] as [String: Any],
                    "clientInfo": ["name": "AgentCore", "version": "0.1.0"],
                ],
                timeoutSeconds: initializeTimeout
            )
            notify(method: "notifications/initialized", params: [:])
        } catch {
            // Surface the server's OWN reason (gated out of the live stream) so a handshake failure
            // isn't a silent "connection closed" — a fatal stderr message ("missing API key") is the
            // actual diagnosis. Ungated warn; bounded so a chatty server can't blow out the log.
            let reason = stderrTail.snapshot().trimmingCharacters(in: .whitespacesAndNewlines)
            if !reason.isEmpty {
                MCPLog.warn("server '\(config.name)' failed to initialize; recent stderr: \(String(reason.suffix(500)))")
            }
            await shutdown()   // definitive: no zombie left from a failed handshake
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
    func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        try await request(method: "tools/call", params: ["name": name, "arguments": arguments], timeoutSeconds: callTimeout)
    }

    var isAlive: Bool { alive }

    /// Synchronous teardown: mark dead, detach handlers, SIGTERM, close stdin, fail
    /// pending. Idempotent. Used by reactive paths (oversized line, start() rollback)
    /// where we can't await. Does NOT guarantee the child is gone — see `shutdown()`.
    private func beginShutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        alive = false
        cleanupHandlers()
        if process.isRunning { process.terminate() }   // SIGTERM
        try? stdinPipe.fileHandleForWriting.close()
        failAllPending(with: MCPConnectionError.serverClosed)
    }

    /// DEFINITIVE shutdown — guarantees no surviving child. SIGTERM, then escalate to
    /// SIGKILL if the server ignores it, and await actual exit before returning.
    /// Idempotent. This is what `shutdownAll()` and start()-failure rollback call.
    func shutdown() async {
        let wasRunning = process.isRunning
        beginShutdown()                      // SIGTERM (idempotent)
        guard wasRunning else { return }

        // Give it a brief grace period to exit on SIGTERM, polling.
        for _ in 0..<20 where process.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)   // 100ms × 20 = 2s
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        // Await real exit off the cooperative pool so we never return with a live child.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                self.process.waitUntilExit()
                cont.resume()
            }
        }
    }

    // MARK: - JSON-RPC core

    private func request(method: String, params: [String: Any], timeoutSeconds: UInt64) async throws -> [String: Any] {
        guard alive, !didShutdown else { throw MCPConnectionError.serverClosed }

        let id = nextId
        nextId += 1

        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard let line = encodeLine(message) else {
            throw MCPConnectionError.badResponse("could not encode request \(method)")
        }

        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
                    Task { await self.storePending(id: id, cont: cont, line: line) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                await self.failPending(id: id, with: MCPConnectionError.timeout(method: method))
                throw MCPConnectionError.timeout(method: method)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Register the continuation under `id` AND write the request line in one
    /// actor-isolated step, so a response can never arrive before we've recorded it.
    private func storePending(id: Int, cont: CheckedContinuation<[String: Any], Error>, line: Data) {
        guard alive, !didShutdown else {
            cont.resume(throwing: MCPConnectionError.serverClosed)
            return
        }
        pending[id] = cont
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: line)
        } catch {
            pending[id] = nil
            cont.resume(throwing: MCPConnectionError.serverClosed)
        }
    }

    private func failPending(id: Int, with error: Error) {
        if let cont = pending.removeValue(forKey: id) { cont.resume(throwing: error) }
    }

    private func notify(method: String, params: [String: Any]) {
        guard alive, !didShutdown else { return }
        let message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let line = encodeLine(message) { try? stdinPipe.fileHandleForWriting.write(contentsOf: line) }
    }

    // MARK: - Read path

    private func ingest(_ data: Data) {
        guard !didShutdown else { return }
        readBuffer.append(data)

        // Guard against an unbounded line (no newline ever) from a hostile server.
        if readBuffer.count > maxLineBytes, !readBuffer.contains(0x0A) {
            MCPLog.warn("server '\(config.name)' sent >\(maxLineBytes) bytes with no newline; dropping")
            beginShutdown()
            return
        }

        let newline: UInt8 = 0x0A
        while let idx = readBuffer.firstIndex(of: newline) {
            let lineData = readBuffer.subdata(in: readBuffer.startIndex..<idx)
            readBuffer.removeSubrange(readBuffer.startIndex...idx)
            if lineData.isEmpty { continue }
            if lineData.count > maxLineBytes {
                MCPLog.warn("server '\(config.name)' line exceeds \(maxLineBytes) bytes; dropping")
                beginShutdown()
                return
            }
            dispatch(lineData)
        }
    }

    private func dispatch(_ lineData: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            if !warnedNonJSON {
                warnedNonJSON = true
                MCPLog.warn("server '\(config.name)' sent non-JSON on stdout (likely a startup banner); ignoring these lines")
            }
            return
        }
        // Only correlate responses to an integer id we issued. Server->client
        // requests/notifications are ignored (this minimal client doesn't serve them).
        guard let id = obj["id"] as? Int else { return }
        guard let cont = pending.removeValue(forKey: id) else { return }   // late/dup/timed-out

        if let error = obj["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let msg = error["message"] as? String ?? "unknown error"
            cont.resume(throwing: MCPConnectionError.rpcError(code: code, message: msg))
        } else if let result = obj["result"] as? [String: Any] {
            cont.resume(returning: result)
        } else {
            cont.resume(throwing: MCPConnectionError.badResponse("response \(id) had neither result nor error"))
        }
    }

    private func handleEOF() {
        guard alive, !didShutdown else { return }
        alive = false
        cleanupHandlers()
        failAllPending(with: MCPConnectionError.serverClosed)
        // Include the server's own last words if it printed any — a mid-session crash otherwise
        // surfaces as a bare "closed" with no cause (the live stderr line is gated behind verbose).
        let reason = stderrTail.snapshot().trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = reason.isEmpty ? "" : "; recent stderr: \(String(reason.suffix(500)))"
        MCPLog.warn("server '\(config.name)' closed (EOF/terminated)\(suffix)")
    }

    private func failAllPending(with error: Error) {
        let conts = pending
        pending.removeAll()
        for (_, cont) in conts { cont.resume(throwing: error) }
    }

    // MARK: - Helpers

    /// Detach readability handlers so they stop firing into a dead actor.
    private nonisolated func cleanupHandlers() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    private func encodeLine(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        data.append(0x0A)
        return data
    }
}
