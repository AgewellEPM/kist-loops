import Foundation

/// A reference to an MCP server exposed as a connector. Execution bridges to kist's
/// existing MCP client (kist already speaks MCP) — this type is the registry entry
/// that makes an MCP server discoverable alongside REST connectors. The universal
/// layer is "MCP + REST", not a reinvented protocol.
public struct MCPConnectorRef: Codable, Sendable, Equatable {
    public let name: String
    public let server: String        // command or URL of the MCP server
    public let tools: [String]       // known tool names (advisory)
    public init(name: String, server: String, tools: [String] = []) {
        self.name = name
        self.server = server
        self.tools = tools
    }
}

/// The universal connector hub: register REST connectors and MCP servers, look them
/// up by name, list everything the AI can drive.
public struct ConnectorRegistry: Sendable {
    public private(set) var rest: [String: RESTConnector]
    public private(set) var mcp: [String: MCPConnectorRef]

    public init(rest: [String: RESTConnector] = [:], mcp: [String: MCPConnectorRef] = [:]) {
        self.rest = rest
        self.mcp = mcp
    }

    public mutating func register(_ connector: RESTConnector) { rest[connector.name] = connector }
    public mutating func registerMCP(_ ref: MCPConnectorRef) { mcp[ref.name] = ref }

    public func connector(_ name: String) -> RESTConnector? { rest[name] }
    public var names: [String] { (Set(rest.keys).union(mcp.keys)).sorted() }

    /// Auto-load every `*.json` REST manifest from `dir` (and `*.mcp.json` MCP refs).
    /// This is the "drop a manifest → it auto-connects" path.
    public static func load(fromDir dir: URL,
                            env: [String: String] = ProcessInfo.processInfo.environment) -> ConnectorRegistry {
        var reg = ConnectorRegistry()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return reg }
        for f in files.sorted() {
            let url = dir.appendingPathComponent(f)
            if f.hasSuffix(".mcp.json") {
                if let data = try? Data(contentsOf: url),
                   let ref = try? JSONDecoder().decode(MCPConnectorRef.self, from: data) {
                    reg.registerMCP(ref)
                }
            } else if f.hasSuffix(".json") {
                if let m = ConnectorManifest.load(url) {
                    reg.register(RESTConnector(manifest: m, env: env))
                }
            }
        }
        return reg
    }
}
