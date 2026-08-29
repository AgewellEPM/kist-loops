import Foundation

/// The transport-agnostic surface the MCP client manager depends on. Both the stdio subprocess transport
/// (`MCPServerConnection`) and the Streamable-HTTP transport (`MCPHTTPConnection`) conform, so the manager
/// can hold either behind one type and the rest of the system is unaware of the wire.
protocol MCPConnection: AnyObject, Sendable {
    var config: MCPServerConfig { get async }
    /// Whether the connection is usable (stdio: process alive; http: always true — each request stands alone).
    var isAlive: Bool { get async }
    /// Connect + handshake (`initialize` → `notifications/initialized`). Throws on failure, leaving no
    /// half-open resource.
    func start() async throws
    /// The server's advertised tools (`tools/list`).
    func listTools() async throws -> [RemoteToolSpec]
    /// Invoke a tool (`tools/call`), returning the raw JSON-RPC `result` object.
    func callTool(name: String, arguments: [String: Any], correlationID: String?) async throws -> [String: Any]
    /// Tear down (idempotent). Best-effort; never throws.
    func shutdown() async
}
