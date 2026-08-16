import Foundation

// MARK: - MCP Client Manager (AgentCore)
//
// Owns external MCP server connections. Unlike the GUI app's forced singleton, this
// is INJECTABLE — Kist, mcp-server, and the GUI each construct their own. It:
//   1. loads + validates configured servers (MCPClientConfig)
//   2. spawns one MCPServerConnection each, completing the handshake
//   3. discovers their tools (tools/list), wrapping each as a RemoteMCPTool
//   4. routes tool calls to the right connection
//   5. tears everything down (`shutdownAll`) — NO ZOMBIES
//
// An `actor`, so the connection cache + discovery are race-free across the agent
// loop's concurrent tool calls.
public actor MCPClientManager {
    typealias ConnectionFactory =
        @Sendable (MCPServerConfig) -> any MCPConnection
    typealias RetrySleep = @Sendable (UInt64) async throws -> Void

    private static let defaultReconnectDelaysNanoseconds: [UInt64] = [
        1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000, 16_000_000_000,
    ]

    /// Separator between server and tool in the namespaced id (`server__tool`), matching
    /// Claude Code's `mcp__server__tool` convention so collisions are impossible.
    public static let namespaceSeparator = "__"

    private var connections: [String: any MCPConnection] = [:]
    /// Last validated recipe for replacing a dead one-shot transport.
    private var knownConfigs: [String: MCPServerConfig] = [:]
    private struct StartupLease {
        let id: UUID
        let task: Task<any MCPConnection, Error>
    }
    /// One shared startup per server name. An unstructured task is intentional:
    /// cancellation of one discovery waiter must not cancel startup underneath all
    /// other waiters or strand the subprocess it already created.
    private var startupLeases: [String: StartupLease] = [:]
    private var shuttingDown = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    /// Invalidates discovery operations that were suspended across a completed
    /// shutdown, so they cannot restart a server after teardown returns.
    private var lifecycleGeneration: UInt64 = 0
    /// Refresh-aware OAuth bearer source for HTTP servers that were authorized via `kist mcp auth`.
    private let oauthStore = OAuthTokenStore()
    private let configuredServersOverride: [MCPServerConfig]?
    private let connectionFactoryOverride: ConnectionFactory?
    private let reconnectDelaysNanoseconds: [UInt64]
    private let retrySleep: RetrySleep

    public init() {
        configuredServersOverride = nil
        connectionFactoryOverride = nil
        reconnectDelaysNanoseconds = Self.defaultReconnectDelaysNanoseconds
        retrySleep = { delay in try await Task.sleep(nanoseconds: delay) }
    }

    /// Deterministic dependency seam for lifecycle tests. Production discovery
    /// always uses validated on-disk configuration and the concrete transports.
    init(
        serversForTesting: [MCPServerConfig],
        connectionFactory: @escaping ConnectionFactory,
        reconnectDelaysNanoseconds: [UInt64] = [0],
        retrySleep: @escaping RetrySleep = { _ in }
    ) {
        configuredServersOverride = serversForTesting
        connectionFactoryOverride = connectionFactory
        self.reconnectDelaysNanoseconds = reconnectDelaysNanoseconds
        self.retrySleep = retrySleep
    }

    // MARK: - Discovery

    /// Connect to every configured server and return AgentTool wrappers for their
    /// tools. Best-effort: a server that fails to start or list is logged and skipped,
    /// never aborting discovery of the others. Idempotent — won't double-spawn.
    ///
    /// - Parameter allowProjectConfig: load `<projectRoot>/.mcp.json` too. Off by
    ///   default (untrusted-workspace RCE guard); enable ONLY for a trusted workspace.
    public func discoverAndWrapTools(projectRoot: String, allowProjectConfig: Bool = false) async -> [RemoteMCPTool] {
        let servers: [MCPServerConfig]
        let issues: [MCPConfigIssue]
        if let configuredServersOverride {
            servers = configuredServersOverride
            issues = []
        } else {
            (servers, issues) = MCPClientConfig.load(
                projectRoot: projectRoot,
                allowProjectConfig: allowProjectConfig)
        }
        for issue in issues { MCPLog.warn("config: server '\(issue.server)': \(issue.reason)") }
        if servers.isEmpty { return [] }   // common case: stay quiet

        var wrappers: [RemoteMCPTool] = []
        for cfg in servers {
            knownConfigs[cfg.name] = cfg
            let connection: any MCPConnection
            do {
                connection = try await resolveConnection(for: cfg)
            } catch {
                MCPLog.error("server '\(cfg.name)' failed to start: \(error.localizedDescription)")
                continue
            }

            do {
                let specs = try await connection.listTools()
                for spec in specs {
                    wrappers.append(RemoteMCPTool(serverName: cfg.name, spec: spec, manager: self))
                }
                MCPLog.info("server '\(cfg.name)': discovered \(specs.count) tool(s)")
            } catch {
                MCPLog.error("server '\(cfg.name)' tools/list failed: \(error.localizedDescription)")
            }
        }
        return wrappers
    }

    /// Return the current usable connection or join/create the one startup lease
    /// for this server. Re-check state after every await because this actor is
    /// reentrant while transports start, report liveness, and shut down.
    private func resolveConnection(
        for config: MCPServerConfig
    ) async throws -> any MCPConnection {
        let generation = lifecycleGeneration
        while true {
            guard !shuttingDown, generation == lifecycleGeneration else {
                throw MCPConnectionError.serverClosed
            }
            if let existing = connections[config.name] {
                let existingConfig = await existing.config
                let alive = await existing.isAlive
                guard !shuttingDown, generation == lifecycleGeneration else {
                    throw MCPConnectionError.serverClosed
                }
                guard connections[config.name] === existing else {
                    continue
                }
                if alive, existingConfig == config {
                    return existing
                }

                // Dead entries are terminal one-shot transports. An alive entry
                // with changed same-name configuration is stale too; never keep
                // routing a newly configured server to old command/auth details.
                connections[config.name] = nil
                await existing.shutdown()
                continue
            }

            if let lease = startupLeases[config.name] {
                do {
                    let started = try await lease.task.value
                    guard !shuttingDown, generation == lifecycleGeneration else {
                        throw MCPConnectionError.serverClosed
                    }
                    if startupLeases[config.name]?.id == lease.id {
                        startupLeases[config.name] = nil
                        connections[config.name] = started
                    }

                    // If configuration changed while this same-name startup was in
                    // flight, every concurrent waiter still joins that one child.
                    // A subsequent refresh observes the cached mismatch above and
                    // replaces it; competing configs never oscillate startups.
                    if connections[config.name] === started {
                        return started
                    }
                    continue
                } catch {
                    if startupLeases[config.name]?.id == lease.id {
                        startupLeases[config.name] = nil
                    }
                    throw error
                }
            }

            let connection = makeConnection(for: config)
            let leaseID = UUID()
            let task = Task { () throws -> any MCPConnection in
                do {
                    try await connection.start()
                    return connection
                } catch {
                    // Concrete start paths already roll back, but the manager owns
                    // the generic contract and defensively joins custom transports.
                    await connection.shutdown()
                    throw error
                }
            }
            startupLeases[config.name] = StartupLease(
                id: leaseID,
                task: task)
            // Join through the common branch, which owns cache publication and
            // lease removal for every waiter.
        }
    }

    private func makeConnection(
        for config: MCPServerConfig
    ) -> any MCPConnection {
        if let connectionFactoryOverride {
            return connectionFactoryOverride(config)
        }
        let store = oauthStore
        let name = config.name
        return config.isHTTP
            ? MCPHTTPConnection(
                config: config,
                bearerProvider: { await store.bearer(for: name) })
            : MCPServerConnection(config: config)
    }

    /// Replace a dead one-shot transport with at most five production attempts,
    /// delayed 1, 2, 4, 8, and 16 seconds. Concurrent callers share the existing
    /// per-server startup lease.
    private func reconnect(to config: MCPServerConfig) async throws -> any MCPConnection {
        let generation = lifecycleGeneration
        let delays = reconnectDelaysNanoseconds.isEmpty ? [UInt64(0)] : reconnectDelaysNanoseconds
        var lastError: Error = MCPConnectionError.serverClosed
        for (index, delay) in delays.enumerated() {
            guard !shuttingDown, generation == lifecycleGeneration else {
                throw MCPConnectionError.serverClosed
            }
            do {
                if delay > 0 { try await retrySleep(delay) }
                guard !shuttingDown, generation == lifecycleGeneration else {
                    throw MCPConnectionError.serverClosed
                }
                return try await resolveConnection(for: config)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if index + 1 < delays.count {
                    MCPLog.warn("server '\(config.name)' reconnect attempt \(index + 1)/\(delays.count) failed")
                }
            }
        }
        throw lastError
    }

    // MARK: - Tool calls

    /// Route a tool call to its server. `arguments` come straight from the model; the
    /// result is sanitized before return.
    public func call(server: String, tool: String, arguments: [String: Any]) async -> ToolResult {
        guard let config = knownConfigs[server] else {
            return .failure("MCP server '\(server)' is not connected")
        }
        let connection: any MCPConnection
        if let cached = connections[server], await cached.isAlive {
            connection = cached
        } else {
            do {
                connection = try await reconnect(to: config)
            } catch {
                return .failure("MCP server '\(server)' reconnect failed after \(reconnectDelaysNanoseconds.count) attempt(s): \(MCPOutputSanitizer.sanitize(error.localizedDescription))")
            }
        }
        do {
            let raw = try await connection.callTool(name: tool, arguments: arguments)
            let (text, isError) = MCPOutputSanitizer.extract(from: raw)
            return ToolResult(
                success: !isError,
                output: text,
                error: isError ? text : nil,
                // The raw remote tool name is UNTRUSTED and this metadata is rendered into the model-facing
                // observation footer — sanitize it (Codex #4).
                metadata: ["mcp_server": server, "mcp_tool": MCPOutputSanitizer.sanitize(tool)]
            )
        } catch {
            // Never replay an ambiguous failed call: it may have executed remotely.
            // Clearing a dead cache makes the next invocation reconnect safely.
            if !(await connection.isAlive), connections[server] === connection {
                connections[server] = nil
            }
            // The error text can carry server-controlled content (rpc message / bad-response body) — it's
            // sanitized at the throw sites, but sanitize the whole surfaced string too (defense-in-depth,
            // DeepSeek M1) before it reaches the model as a failure.
            return .failure("MCP call \(server)/\(tool) failed: \(MCPOutputSanitizer.sanitize(error.localizedDescription))")
        }
    }

    // MARK: - Shutdown

    /// Terminate all connections. MUST be called at process exit to avoid leaving
    /// spawned MCP server processes running. Idempotent.
    public func shutdownAll() async {
        if shuttingDown {
            await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
            return
        }
        shuttingDown = true
        lifecycleGeneration &+= 1
        // Finish any startup already in flight so it cannot publish a live orphan
        // after the connection cache has been drained.
        let leases = startupLeases
        startupLeases.removeAll()
        for (_, lease) in leases {
            do {
                let connection = try await lease.task.value
                await connection.shutdown()
            } catch {
                // The startup task performs its own defensive shutdown on failure.
            }
        }
        for (name, conn) in connections {
            await conn.shutdown()
            MCPLog.info("server '\(name)' shut down")
        }
        connections.removeAll()
        shuttingDown = false
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
