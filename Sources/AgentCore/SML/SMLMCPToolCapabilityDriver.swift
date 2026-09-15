import Crypto
import Foundation

/// Host-owned aliases from stable SML capability names to exact configured MCP server/tool pairs.
///
/// The workflow can request only the alias admitted by `catalog.json`; it never chooses a server or
/// raw remote tool name at execution time. The separate binding also lets an operator replace a
/// transport without rewriting imported workflows while keeping that change behind a private,
/// reviewed host file.
public struct SMLMCPToolBindings: Sendable, Equatable {
    public static let relativePath = ".kist/sml/mcp.json"
    public static let schemaVersion = 1

    public struct Binding: Sendable, Equatable {
        public let capability: String
        public let server: String
        public let tool: String

        public init(capability: String, server: String, tool: String) {
            self.capability = capability
            self.server = server
            self.tool = tool
        }
    }

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case missing(path: String)
        case unreadable(path: String, reason: String)
        case malformed(path: String, reason: String)
        case unsupportedSchemaVersion(Int)

        public var description: String {
            switch self {
            case .missing(let path):
                return "SML MCP bindings are missing: \(path)"
            case .unreadable(let path, let reason):
                return "SML MCP bindings are unsafe or unreadable: \(path) (\(reason))"
            case .malformed(let path, let reason):
                return "SML MCP bindings are malformed: \(path) (\(reason))"
            case .unsupportedSchemaVersion(let version):
                return "unsupported SML MCP binding schema version \(version)"
            }
        }
    }

    public let tools: [String: Binding]
    public let allowProjectConfig: Bool

    public init(tools: [String: Binding], allowProjectConfig: Bool = false) {
        self.tools = tools
        self.allowProjectConfig = allowProjectConfig
    }

    public var serverNames: Set<String> {
        Set(tools.values.map(\.server))
    }

    public func selecting(_ capabilities: Set<String>) -> SMLMCPToolBindings {
        SMLMCPToolBindings(
            tools: tools.filter { capabilities.contains($0.key) },
            allowProjectConfig: allowProjectConfig
        )
    }

    public static func load(projectRoot: String) throws -> SMLMCPToolBindings {
        let url = URL(fileURLWithPath: projectRoot).appendingPathComponent(relativePath)
        let data: Data
        do {
            data = try SMLHostConfigurationFile.read(
                projectRoot: projectRoot,
                relativePath: relativePath
            )
        } catch SMLHostConfigurationFile.ReadError.missing {
            throw LoadError.missing(path: url.path)
        } catch {
            throw LoadError.unreadable(path: url.path, reason: String(describing: error))
        }

        do {
            let root = try SMLHostConfigurationFile.decodeRoot(from: data)
            try SMLHostConfigurationFile.requireOnlyKeys(
                root,
                allowed: ["schema_version", "allow_project_config", "tools"],
                path: "mcp"
            )
            let version = try SMLHostConfigurationFile.requiredInteger(
                root["schema_version"], path: "mcp.schema_version")
            guard version == schemaVersion else {
                throw LoadError.unsupportedSchemaVersion(version)
            }
            let allowProjectConfig = try SMLHostConfigurationFile.optionalBool(
                root["allow_project_config"], path: "mcp.allow_project_config") ?? false
            let rawTools = try SMLHostConfigurationFile.requiredObject(
                root["tools"], path: "mcp.tools")
            guard rawTools.count <= SMLHostConfigurationFile.maximumBindings else {
                throw SMLHostConfigurationFile.SchemaError(
                    reason: "mcp.tools exceeds "
                        + "\(SMLHostConfigurationFile.maximumBindings) entries")
            }

            var tools: [String: Binding] = [:]
            var remoteIdentities = Set<String>()
            for capability in rawTools.keys.sorted() {
                guard SMLValidationSupport.identifierIsValid(
                    capability, maximumLength: 96
                ) else {
                    throw SMLHostConfigurationFile.SchemaError(
                        reason: "mcp.tools key '\(capability)' is not a valid capability identifier")
                }
                let path = "mcp.tools.\(capability)"
                let entry = try SMLHostConfigurationFile.requiredObject(
                    rawTools[capability], path: path)
                try SMLHostConfigurationFile.requireOnlyKeys(
                    entry, allowed: ["server", "tool"], path: path)

                let server = try SMLHostConfigurationFile.requiredString(
                    entry["server"], path: "\(path).server")
                guard SMLValidationSupport.identifierIsValid(
                    server, maximumLength: 96, allowDot: false
                ) else {
                    throw SMLHostConfigurationFile.SchemaError(
                        reason: "\(path).server is not a valid MCP server identifier")
                }
                let tool = try SMLHostConfigurationFile.boundedText(
                    try SMLHostConfigurationFile.requiredString(
                        entry["tool"], path: "\(path).tool"),
                    path: "\(path).tool",
                    maximumBytes: 256
                )
                guard MCPOutputSanitizer.sanitize(tool) == tool else {
                    throw SMLHostConfigurationFile.SchemaError(
                        reason: "\(path).tool contains unsupported format characters")
                }
                let identity = server + "\u{1f}" + tool
                guard remoteIdentities.insert(identity).inserted else {
                    throw SMLHostConfigurationFile.SchemaError(
                        reason: "MCP server/tool '\(server)/\(tool)' is bound more than once")
                }
                tools[capability] = Binding(
                    capability: capability, server: server, tool: tool)
            }
            return SMLMCPToolBindings(
                tools: tools, allowProjectConfig: allowProjectConfig)
        } catch let error as LoadError {
            throw error
        } catch {
            throw LoadError.malformed(path: url.path, reason: String(describing: error))
        }
    }
}

public enum SMLMCPToolDriverError: Error, Equatable, CustomStringConvertible {
    case invalidBinding(capability: String, reason: String)
    case unresolvedBinding(capability: String, server: String, tool: String)
    case ambiguousBinding(capability: String, server: String, tool: String)

    public var description: String {
        switch self {
        case .invalidBinding(let capability, let reason):
            return "SML MCP capability '\(capability)' has an invalid host binding: \(reason)"
        case .unresolvedBinding(let capability, let server, let tool):
            return "SML MCP capability '\(capability)' cannot resolve configured tool "
                + "'\(server)/\(tool)'"
        case .ambiguousBinding(let capability, let server, let tool):
            return "SML MCP capability '\(capability)' resolves more than once to "
                + "'\(server)/\(tool)'"
        }
    }
}

/// An admitted MCP tool is executed through `ToolRegistry`, preserving ToolGate authorization,
/// argument validation, audit logging, dispatch correlation, and normalized failures. The alias wrapper is
/// deliberately the only tool in this registry: a remote server cannot make a newly advertised
/// sibling capability reachable without a fresh host binding and catalog admission.
public struct SMLMCPToolCapabilityDriver: SMLInstructionDriver {
    public let id = "kist-mcp-driver"

    private let bindings: [String: SMLMCPToolBindings.Binding]
    private let registry: ToolRegistry
    private let context: ToolContext
    private let clock: @Sendable () -> Double

    public init(
        bindings: SMLMCPToolBindings,
        discoveredTools: [RemoteMCPTool],
        context: ToolContext,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) throws {
        var aliases: [any AgentTool] = []
        var remoteIdentities = Set<String>()
        for capability in bindings.tools.keys.sorted() {
            guard let binding = bindings.tools[capability] else { continue }
            guard capability == binding.capability,
                  SMLValidationSupport.identifierIsValid(capability, maximumLength: 96),
                  SMLValidationSupport.identifierIsValid(
                    binding.server, maximumLength: 96, allowDot: false),
                  binding.tool.utf8.count <= 256,
                  !binding.tool.isEmpty,
                  binding.tool == binding.tool.trimmingCharacters(in: .whitespacesAndNewlines),
                  !binding.tool.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                  }),
                  MCPOutputSanitizer.sanitize(binding.tool) == binding.tool else {
                throw SMLMCPToolDriverError.invalidBinding(
                    capability: capability,
                    reason: "alias, server, or remote tool identity violates the bounded schema"
                )
            }
            guard remoteIdentities.insert(binding.server + "\u{1f}" + binding.tool).inserted else {
                throw SMLMCPToolDriverError.invalidBinding(
                    capability: capability,
                    reason: "the same remote server/tool is already bound to another alias"
                )
            }
            let matches = discoveredTools.filter {
                $0.matches(server: binding.server, tool: binding.tool)
            }
            guard !matches.isEmpty else {
                throw SMLMCPToolDriverError.unresolvedBinding(
                    capability: capability, server: binding.server, tool: binding.tool)
            }
            guard matches.count == 1 else {
                throw SMLMCPToolDriverError.ambiguousBinding(
                    capability: capability, server: binding.server, tool: binding.tool)
            }
            aliases.append(SMLMCPAliasTool(
                capability: capability, remote: matches[0]))
        }
        self.bindings = bindings.tools
        registry = ToolRegistry(capabilityScoped: aliases)
        self.context = context
        self.clock = clock
    }

    public func supports(_ request: SMLCapabilityRequest) -> Bool {
        request.operation == .callTool && bindings[request.reference] != nil
    }

    public func execute(
        _ invocation: SMLCapabilityInvocation
    ) async throws -> SMLCapabilityOutcome {
        let request = invocation.request
        guard let binding = bindings[request.reference] else {
            throw SMLCapabilityDriverConfigurationError.unknownTool(
                capability: request.reference)
        }
        let outputField = try SMLCapabilityDriverSupport.outputField(of: request)
        var arguments = request.arguments
        arguments.removeValue(forKey: SMLCapabilityDriverSupport.outputFieldArgument)
        let result = await registry.execute(
            name: request.reference,
            arguments: SMLCapabilityDriverSupport.foundationArguments(arguments),
            context: context.withCorrelationID(invocation.dispatchID)
        )

        var statePatch: SMLObject = [:]
        if result.success, let outputField {
            statePatch[outputField] = .string(result.output)
        }
        let attachmentEvidence = result.attachments.map(Self.attachmentEvidence)
        let evidencePayload: SMLObject = [
            "capability": .string(request.reference),
            "server": .string(binding.server),
            "tool": .string(binding.tool),
            "success": .bool(result.success),
            "output": .string(result.output),
            "error": result.error.map { .string($0) } ?? .null,
            "metadata": .object(result.metadata.mapValues(SMLValue.string)),
            "attachments": .array(attachmentEvidence.map(SMLValue.object)),
        ]
        return SMLCapabilityDriverSupport.outcome(
            for: invocation,
            driverID: id,
            status: result.success ? .passed : .failed,
            statePatch: statePatch,
            evidencePayload: evidencePayload,
            receiptID: "mcp.\(request.reference).\(result.success ? "passed" : "failed")",
            observedAtEpoch: clock()
        )
    }

    private static func attachmentEvidence(_ attachment: MediaAttachment) -> SMLObject {
        let payloadDigest: String
        let byteCount: Int
        switch attachment.payload {
        case .inline(let data):
            payloadDigest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }.joined()
            byteCount = data.count
        case .fileURI(let uri):
            payloadDigest = SHA256.hash(data: Data(uri.utf8))
                .map { String(format: "%02x", $0) }.joined()
            byteCount = uri.utf8.count
        }
        return [
            "kind": .string(attachment.kind.rawValue),
            "mime_type": .string(attachment.mimeType),
            "payload_digest": .string(payloadDigest),
            "payload_bytes": .number(Decimal(byteCount)),
        ]
    }
}

private struct SMLMCPAliasTool: AgentTool {
    let name: String
    let description: String
    let parameters: [ToolParameter]
    private let remote: RemoteMCPTool

    init(capability: String, remote: RemoteMCPTool) {
        name = capability
        description = remote.description
        parameters = remote.parameters
        self.remote = remote
    }

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        try await remote.execute(arguments: arguments, context: context)
    }
}
