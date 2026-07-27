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
    /// Separator between server and tool in the namespaced id (`server__tool`), matching
    /// Claude Code's `mcp__server__tool` convention so collisions are impossible.
    public static let namespaceSeparator = "__"

    private var connections: [String: any MCPConnection] = [:]
    /// Refresh-aware OAuth bearer source for HTTP servers that were authorized via `kist mcp auth`.
    private let oauthStore = OAuthTokenStore()

    public init() {}

    // MARK: - Discovery

    /// Connect to every configured server and return AgentTool wrappers for their
    /// tools. Best-effort: a server that fails to start or list is logged and skipped,
    /// never aborting discovery of the others. Idempotent — won't double-spawn.
    ///
    /// - Parameter allowProjectConfig: load `<projectRoot>/.mcp.json` too. Off by
    ///   default (untrusted-workspace RCE guard); enable ONLY for a trusted workspace.
    public func discoverAndWrapTools(projectRoot: String, allowProjectConfig: Bool = false) async -> [RemoteMCPTool] {
        let (servers, issues) = MCPClientConfig.load(projectRoot: projectRoot, allowProjectConfig: allowProjectConfig)
        for issue in issues { MCPLog.warn("config: server '\(issue.server)': \(issue.reason)") }
        if servers.isEmpty { return [] }   // common case: stay quiet

        var wrappers: [RemoteMCPTool] = []
        for cfg in servers {
            let connection: any MCPConnection
            if let existing = connections[cfg.name] {
                connection = existing
            } else {
                // Pick the transport: HTTP (Streamable-HTTP) when the config has a url, else stdio subprocess.
                // For HTTP, supply an OAuth bearer source — if the server was authorized (a token exists),
                // bearer() returns the current access token (refreshing as needed); otherwise nil ⇒ the
                // connection falls back to the static config headers.
                let store = oauthStore
                let name = cfg.name
                let conn: any MCPConnection = cfg.isHTTP
                    ? MCPHTTPConnection(config: cfg, bearerProvider: { await store.bearer(for: name) })
                    : MCPServerConnection(config: cfg)
                do {
                    try await conn.start()
                } catch {
                    // start() already shut the half-started process down on failure.
                    MCPLog.error("server '\(cfg.name)' failed to start: \(error.localizedDescription)")
                    continue
                }
                connections[cfg.name] = conn
                connection = conn
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

    // MARK: - Tool calls

    /// Route a tool call to its server. `arguments` come straight from the model; the
    /// result is sanitized before return.
    public func call(server: String, tool: String, arguments: [String: Any]) async -> ToolResult {
        guard let connection = connections[server] else {
            return .failure("MCP server '\(server)' is not connected")
        }
        guard await connection.isAlive else {
            return .failure("MCP server '\(server)' is not alive (it may have crashed)")
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
        for (name, conn) in connections {
            await conn.shutdown()
            MCPLog.info("server '\(name)' shut down")
        }
        connections.removeAll()
    }
}
