import Foundation

public struct SMLWorkflowRuntimeREPLMount: Sendable, Codable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let workflowName: String
    public let role: String
    public let apiBasePath: String
    public let apiWorkflowPath: String
    public let workflowMetadata: SMLWorkflowRuntimeWorkflowMetadataLinks
    public let grammar: String
    public let helpText: String
    public let commands: [SMLWorkflowREPLCommandDescriptor]
    public let examples: [SMLWorkflowREPLExample]
    public let modelToolName: String
    public let modelRouterToolName: String
    public let onyxDriverID: String
    public let commandBindings: [SMLWorkflowRuntimePlanningCommandBinding]

    public init(
        workflowID: String,
        workflowVersion: String,
        workflowName: String,
        role: String,
        apiBasePath: String,
        apiWorkflowPath: String? = nil,
        workflowMetadata: SMLWorkflowRuntimeWorkflowMetadataLinks? = nil,
        grammar: String,
        helpText: String,
        commands: [SMLWorkflowREPLCommandDescriptor] = [],
        examples: [SMLWorkflowREPLExample] = [],
        modelToolName: String,
        modelRouterToolName: String,
        onyxDriverID: String,
        commandBindings: [SMLWorkflowRuntimePlanningCommandBinding] = []
    ) {
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.workflowName = workflowName
        self.role = role
        self.apiBasePath = apiBasePath
        self.apiWorkflowPath = apiWorkflowPath
            ?? SMLWorkflowRuntimeAPIWorkflowPath.defaultWorkflowPath(workflowID: workflowID)
        self.workflowMetadata = workflowMetadata ?? SMLWorkflowRuntimeWorkflowMetadataLinks(
            workflowID: workflowID,
            workflowVersion: workflowVersion,
            apiBasePath: apiBasePath
        )
        self.grammar = grammar
        self.helpText = helpText
        self.commands = commands.sorted {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.verb < $1.verb
        }
        self.examples = examples.sorted {
            if $0.verb != $1.verb { return $0.verb < $1.verb }
            return $0.line < $1.line
        }
        self.modelToolName = modelToolName
        self.modelRouterToolName = modelRouterToolName
        self.onyxDriverID = onyxDriverID
        self.commandBindings = Self.sortedCommandBindings(commandBindings)
    }

    public init(_ descriptor: SMLWorkflowRuntimeDescriptor) {
        self.init(
            workflowID: descriptor.workflowID,
            workflowVersion: descriptor.workflowVersion,
            workflowName: descriptor.workflowName,
            role: descriptor.role,
            apiBasePath: descriptor.api.basePath,
            apiWorkflowPath: descriptor.api.workflowPath,
            workflowMetadata: SMLWorkflowRuntimeWorkflowMetadataLinks(descriptor),
            grammar: descriptor.repl.grammar,
            helpText: descriptor.repl.helpText,
            commands: descriptor.repl.commands,
            examples: descriptor.repl.examples,
            modelToolName: descriptor.model.tool.name,
            modelRouterToolName: SMLWorkflowRuntimeModelAdapter.toolName,
            onyxDriverID: descriptor.onyx.driverID,
            commandBindings: SMLWorkflowRuntimePlanningManifest.commandBindings(for: descriptor)
        )
    }

    enum CodingKeys: String, CodingKey {
        case workflowID
        case workflowVersion
        case workflowName
        case role
        case apiBasePath
        case apiWorkflowPath
        case workflowMetadata
        case grammar
        case helpText
        case commands
        case examples
        case modelToolName
        case modelRouterToolName
        case onyxDriverID
        case commandBindings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            workflowID: try container.decode(String.self, forKey: .workflowID),
            workflowVersion: try container.decode(String.self, forKey: .workflowVersion),
            workflowName: try container.decode(String.self, forKey: .workflowName),
            role: try container.decode(String.self, forKey: .role),
            apiBasePath: try container.decode(String.self, forKey: .apiBasePath),
            apiWorkflowPath: try container.decodeIfPresent(String.self, forKey: .apiWorkflowPath),
            workflowMetadata: try container.decodeIfPresent(
                SMLWorkflowRuntimeWorkflowMetadataLinks.self,
                forKey: .workflowMetadata
            ),
            grammar: try container.decode(String.self, forKey: .grammar),
            helpText: try container.decode(String.self, forKey: .helpText),
            commands: try container.decodeIfPresent(
                [SMLWorkflowREPLCommandDescriptor].self,
                forKey: .commands
            ) ?? [],
            examples: try container.decodeIfPresent(
                [SMLWorkflowREPLExample].self,
                forKey: .examples
            ) ?? [],
            modelToolName: try container.decode(String.self, forKey: .modelToolName),
            modelRouterToolName: try container.decode(String.self, forKey: .modelRouterToolName),
            onyxDriverID: try container.decode(String.self, forKey: .onyxDriverID),
            commandBindings: try container.decodeIfPresent(
                [SMLWorkflowRuntimePlanningCommandBinding].self,
                forKey: .commandBindings
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workflowID, forKey: .workflowID)
        try container.encode(workflowVersion, forKey: .workflowVersion)
        try container.encode(workflowName, forKey: .workflowName)
        try container.encode(role, forKey: .role)
        try container.encode(apiBasePath, forKey: .apiBasePath)
        try container.encode(apiWorkflowPath, forKey: .apiWorkflowPath)
        try container.encode(workflowMetadata, forKey: .workflowMetadata)
        try container.encode(grammar, forKey: .grammar)
        try container.encode(helpText, forKey: .helpText)
        try container.encode(commands, forKey: .commands)
        try container.encode(examples, forKey: .examples)
        try container.encode(modelToolName, forKey: .modelToolName)
        try container.encode(modelRouterToolName, forKey: .modelRouterToolName)
        try container.encode(onyxDriverID, forKey: .onyxDriverID)
        try container.encode(commandBindings, forKey: .commandBindings)
    }

    private static func sortedCommandBindings(
        _ bindings: [SMLWorkflowRuntimePlanningCommandBinding]
    ) -> [SMLWorkflowRuntimePlanningCommandBinding] {
        bindings.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            if $0.action.rawValue != $1.action.rawValue {
                return $0.action.rawValue < $1.action.rawValue
            }
            return $0.replVerb < $1.replVerb
        }
    }
}

public struct SMLWorkflowRuntimeAPIMount: Sendable, Codable, Equatable {
    public let method: SMLWorkflowAPIMethod
    public let pathTemplate: String
    public let operationID: String
    public let handlerKind: SMLWorkflowRuntimeRouteHandlerKind
    public let authority: SMLWorkflowRuntimeRouteAuthority
    public let readOnly: Bool
    public let workflowID: String?
    public let action: SMLWorkflowControlAction?
    public let metadataResource: SMLWorkflowRuntimeMetadataResource?
    public let workflowMetadata: SMLWorkflowRuntimeWorkflowMetadataLinks?
    public let bodyKind: SMLWorkflowAPIRequestBodyKind
    public let bodyFields: [SMLWorkflowFieldDescriptor]
    public let examples: [SMLWorkflowAPIRequestExample]

    public init(
        method: SMLWorkflowAPIMethod,
        pathTemplate: String,
        operationID: String,
        handlerKind: SMLWorkflowRuntimeRouteHandlerKind,
        authority: SMLWorkflowRuntimeRouteAuthority,
        readOnly: Bool,
        workflowID: String? = nil,
        action: SMLWorkflowControlAction? = nil,
        metadataResource: SMLWorkflowRuntimeMetadataResource? = nil,
        workflowMetadata: SMLWorkflowRuntimeWorkflowMetadataLinks? = nil,
        bodyKind: SMLWorkflowAPIRequestBodyKind = .none,
        bodyFields: [SMLWorkflowFieldDescriptor] = [],
        examples: [SMLWorkflowAPIRequestExample] = []
    ) {
        self.method = method
        self.pathTemplate = pathTemplate
        self.operationID = operationID
        self.handlerKind = handlerKind
        self.authority = authority
        self.readOnly = readOnly
        self.workflowID = workflowID
        self.action = action
        self.metadataResource = metadataResource
        self.workflowMetadata = workflowMetadata
        self.bodyKind = bodyKind
        self.bodyFields = bodyFields
        self.examples = examples.sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            if $0.method.rawValue != $1.method.rawValue {
                return $0.method.rawValue < $1.method.rawValue
            }
            return $0.summary < $1.summary
        }
    }

    enum CodingKeys: String, CodingKey {
        case method
        case pathTemplate
        case operationID
        case handlerKind
        case authority
        case readOnly
        case workflowID
        case action
        case metadataResource
        case workflowMetadata
        case bodyKind
        case bodyFields
        case examples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            method: try container.decode(SMLWorkflowAPIMethod.self, forKey: .method),
            pathTemplate: try container.decode(String.self, forKey: .pathTemplate),
            operationID: try container.decode(String.self, forKey: .operationID),
            handlerKind: try container.decode(
                SMLWorkflowRuntimeRouteHandlerKind.self,
                forKey: .handlerKind
            ),
            authority: try container.decode(
                SMLWorkflowRuntimeRouteAuthority.self,
                forKey: .authority
            ),
            readOnly: try container.decode(Bool.self, forKey: .readOnly),
            workflowID: try container.decodeIfPresent(String.self, forKey: .workflowID),
            action: try container.decodeIfPresent(SMLWorkflowControlAction.self, forKey: .action),
            metadataResource: try container.decodeIfPresent(
                SMLWorkflowRuntimeMetadataResource.self,
                forKey: .metadataResource
            ),
            workflowMetadata: try container.decodeIfPresent(
                SMLWorkflowRuntimeWorkflowMetadataLinks.self,
                forKey: .workflowMetadata
            ),
            bodyKind: try container.decodeIfPresent(
                SMLWorkflowAPIRequestBodyKind.self,
                forKey: .bodyKind
            ) ?? .none,
            bodyFields: try container.decodeIfPresent(
                [SMLWorkflowFieldDescriptor].self,
                forKey: .bodyFields
            ) ?? [],
            examples: try container.decodeIfPresent(
                [SMLWorkflowAPIRequestExample].self,
                forKey: .examples
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        try container.encode(pathTemplate, forKey: .pathTemplate)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(handlerKind, forKey: .handlerKind)
        try container.encode(authority, forKey: .authority)
        try container.encode(readOnly, forKey: .readOnly)
        try container.encodeIfPresent(workflowID, forKey: .workflowID)
        try container.encodeIfPresent(action, forKey: .action)
        try container.encodeIfPresent(metadataResource, forKey: .metadataResource)
        try container.encodeIfPresent(workflowMetadata, forKey: .workflowMetadata)
        try container.encode(bodyKind, forKey: .bodyKind)
        try container.encode(bodyFields, forKey: .bodyFields)
        try container.encode(examples, forKey: .examples)
    }
}

enum SMLWorkflowRuntimeAPIWorkflowPath {
    static func defaultWorkflowPath(workflowID: String) -> String {
        SMLWorkflowAPICatalog.defaultWorkflowPath(workflowID: workflowID)
    }

    static func inferredWorkflowPath(
        workflowID: String,
        apiBasePath: String,
        apiRoutes: [SMLWorkflowRuntimeAPIMount]
    ) -> String {
        inferredWorkflowPathIfAvailable(
            workflowID: workflowID,
            apiBasePath: apiBasePath,
            apiRoutes: apiRoutes
        ) ?? defaultWorkflowPath(workflowID: workflowID)
    }

    private static func inferredWorkflowPathIfAvailable(
        workflowID: String,
        apiBasePath: String,
        apiRoutes: [SMLWorkflowRuntimeAPIMount]
    ) -> String? {
        let normalizedBasePath = normalizePath(apiBasePath)
        let candidateRoutes = apiRoutes.sorted {
            let lhsStart = $0.action == .start ? 0 : 1
            let rhsStart = $1.action == .start ? 0 : 1
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            if $0.pathTemplate != $1.pathTemplate { return $0.pathTemplate < $1.pathTemplate }
            return $0.operationID < $1.operationID
        }
        for route in candidateRoutes {
            guard route.handlerKind == .workflow,
                  route.workflowID == nil || route.workflowID == workflowID else {
                continue
            }
            guard let suffix = routeSuffix(
                pathTemplate: route.pathTemplate,
                apiBasePath: normalizedBasePath
            ), let taskRange = suffix.range(of: "/tasks") else {
                continue
            }
            let workflowPath = String(suffix[..<taskRange.lowerBound])
            guard workflowPath.hasPrefix("/"), workflowPath.count > 1 else {
                continue
            }
            return workflowPath
        }
        return nil
    }

    private static func normalizePath(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    private static func routeSuffix(pathTemplate: String, apiBasePath: String) -> String? {
        if apiBasePath == "/" {
            return pathTemplate.hasPrefix("/") ? pathTemplate : nil
        }
        guard pathTemplate.hasPrefix(apiBasePath) else { return nil }
        let suffix = String(pathTemplate.dropFirst(apiBasePath.count))
        guard suffix.hasPrefix("/") else { return nil }
        return suffix
    }
}

public struct SMLWorkflowRuntimeWorkflowMount: Sendable, Codable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let workflowName: String
    public let role: String
    public let apiBasePath: String
    public let apiWorkflowPath: String
    public let workflowMetadata: SMLWorkflowRuntimeWorkflowMetadataLinks
    public let repl: SMLWorkflowRuntimeREPLMount
    public let apiRoutes: [SMLWorkflowRuntimeAPIMount]
    public let modelToolName: String
    public let modelRouterToolName: String
    public let onyxDriverID: String
    public let planningWorkflowID: String?
    public let commandBindings: [SMLWorkflowRuntimePlanningCommandBinding]

    public init(
        workflowID: String,
        workflowVersion: String,
        workflowName: String,
        role: String,
        apiBasePath: String,
        apiWorkflowPath: String? = nil,
        workflowMetadata: SMLWorkflowRuntimeWorkflowMetadataLinks? = nil,
        repl: SMLWorkflowRuntimeREPLMount,
        apiRoutes: [SMLWorkflowRuntimeAPIMount],
        modelToolName: String,
        modelRouterToolName: String,
        onyxDriverID: String,
        planningWorkflowID: String?,
        commandBindings: [SMLWorkflowRuntimePlanningCommandBinding] = []
    ) {
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.workflowName = workflowName
        self.role = role
        self.apiBasePath = apiBasePath
        self.apiWorkflowPath = apiWorkflowPath ?? repl.apiWorkflowPath
        self.workflowMetadata = workflowMetadata ?? repl.workflowMetadata
        self.repl = repl
        self.apiRoutes = apiRoutes.sorted {
            if $0.pathTemplate != $1.pathTemplate { return $0.pathTemplate < $1.pathTemplate }
            if $0.method.rawValue != $1.method.rawValue {
                return $0.method.rawValue < $1.method.rawValue
            }
            return $0.operationID < $1.operationID
        }
        self.modelToolName = modelToolName
        self.modelRouterToolName = modelRouterToolName
        self.onyxDriverID = onyxDriverID
        self.planningWorkflowID = planningWorkflowID
        self.commandBindings = Self.sortedCommandBindings(commandBindings)
    }

    public init(
        repl: SMLWorkflowRuntimeREPLMount,
        apiRoutes: [SMLWorkflowRuntimeAPIMount],
        planningWorkflowID: String?
    ) {
        self.init(
            workflowID: repl.workflowID,
            workflowVersion: repl.workflowVersion,
            workflowName: repl.workflowName,
            role: repl.role,
            apiBasePath: repl.apiBasePath,
            apiWorkflowPath: repl.apiWorkflowPath,
            repl: repl,
            apiRoutes: apiRoutes,
            modelToolName: repl.modelToolName,
            modelRouterToolName: repl.modelRouterToolName,
            onyxDriverID: repl.onyxDriverID,
            planningWorkflowID: planningWorkflowID,
            commandBindings: repl.commandBindings
        )
    }

    enum CodingKeys: String, CodingKey {
        case workflowID
        case workflowVersion
        case workflowName
        case role
        case apiBasePath
        case apiWorkflowPath
        case workflowMetadata
        case repl
        case apiRoutes
        case modelToolName
        case modelRouterToolName
        case onyxDriverID
        case planningWorkflowID
        case commandBindings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let repl = try container.decode(SMLWorkflowRuntimeREPLMount.self, forKey: .repl)
        let apiBasePath = try container.decode(String.self, forKey: .apiBasePath)
        let apiRoutes = try container.decode([SMLWorkflowRuntimeAPIMount].self, forKey: .apiRoutes)
        let workflowID = try container.decode(String.self, forKey: .workflowID)
        self.init(
            workflowID: workflowID,
            workflowVersion: try container.decode(String.self, forKey: .workflowVersion),
            workflowName: try container.decode(String.self, forKey: .workflowName),
            role: try container.decode(String.self, forKey: .role),
            apiBasePath: apiBasePath,
            apiWorkflowPath: try container.decodeIfPresent(String.self, forKey: .apiWorkflowPath)
                ?? SMLWorkflowRuntimeAPIWorkflowPath.inferredWorkflowPath(
                    workflowID: workflowID,
                    apiBasePath: apiBasePath,
                    apiRoutes: apiRoutes
                ),
            workflowMetadata: try container.decodeIfPresent(
                SMLWorkflowRuntimeWorkflowMetadataLinks.self,
                forKey: .workflowMetadata
            ),
            repl: repl,
            apiRoutes: apiRoutes,
            modelToolName: try container.decode(String.self, forKey: .modelToolName),
            modelRouterToolName: try container.decode(String.self, forKey: .modelRouterToolName),
            onyxDriverID: try container.decode(String.self, forKey: .onyxDriverID),
            planningWorkflowID: try container.decodeIfPresent(
                String.self,
                forKey: .planningWorkflowID
            ),
            commandBindings: try container.decodeIfPresent(
                [SMLWorkflowRuntimePlanningCommandBinding].self,
                forKey: .commandBindings
            ) ?? repl.commandBindings
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workflowID, forKey: .workflowID)
        try container.encode(workflowVersion, forKey: .workflowVersion)
        try container.encode(workflowName, forKey: .workflowName)
        try container.encode(role, forKey: .role)
        try container.encode(apiBasePath, forKey: .apiBasePath)
        try container.encode(apiWorkflowPath, forKey: .apiWorkflowPath)
        try container.encode(workflowMetadata, forKey: .workflowMetadata)
        try container.encode(repl, forKey: .repl)
        try container.encode(apiRoutes, forKey: .apiRoutes)
        try container.encode(modelToolName, forKey: .modelToolName)
        try container.encode(modelRouterToolName, forKey: .modelRouterToolName)
        try container.encode(onyxDriverID, forKey: .onyxDriverID)
        try container.encodeIfPresent(planningWorkflowID, forKey: .planningWorkflowID)
        try container.encode(commandBindings, forKey: .commandBindings)
    }

    private static func sortedCommandBindings(
        _ bindings: [SMLWorkflowRuntimePlanningCommandBinding]
    ) -> [SMLWorkflowRuntimePlanningCommandBinding] {
        bindings.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            if $0.action.rawValue != $1.action.rawValue {
                return $0.action.rawValue < $1.action.rawValue
            }
            return $0.replVerb < $1.replVerb
        }
    }
}

public enum SMLWorkflowRuntimeMountContractError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidAPIPath(String)
    case routeNotFound(method: String, path: String)
    case ambiguousAPIRoute(method: String, path: String)
    case metadataRequestMustBeReadOnly
    case workflowNotMounted(String)
    case invalidWorkflowMount(String)

    public var description: String {
        switch self {
        case .invalidAPIPath(let path):
            return "invalid workflow runtime mount API path: \(path)"
        case .routeNotFound(let method, let path):
            return "workflow runtime mount route not found: \(method) \(path)"
        case .ambiguousAPIRoute(let method, let path):
            return "workflow runtime mount route is ambiguous: \(method) \(path)"
        case .metadataRequestMustBeReadOnly:
            return "workflow runtime mount metadata endpoints accept only read-only GET requests without body, scope, or expected state"
        case .workflowNotMounted(let workflowID):
            return "workflow runtime mount has no workflow: \(workflowID)"
        case .invalidWorkflowMount(let workflowID):
            return "workflow runtime mount is internally inconsistent for workflow: \(workflowID)"
        }
    }
}

public struct SMLWorkflowRuntimeResolvedAPIRoute: Sendable, Codable, Equatable {
    public let route: SMLWorkflowRuntimeAPIMount
    public let pathParameters: [String: String]

    public init(
        route: SMLWorkflowRuntimeAPIMount,
        pathParameters: [String: String] = [:]
    ) {
        self.route = route
        self.pathParameters = pathParameters
    }
}

/// Compact host contract for mounting a workflow runtime as a custom REPL/API surface.
///
/// This is intentionally only routing and adapter metadata. It tells a host which paths and REPLs
/// to expose and which handler to call, but it carries no actor identity, authority lease,
/// credential, runtime handle, provider registry, or executable closure.
public struct SMLWorkflowRuntimeMountContract: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 14

    public let schemaVersion: Int
    public let workflowIDs: [String]
    public let apiBasePaths: [String]
    public let replMounts: [SMLWorkflowRuntimeREPLMount]
    public let apiRoutes: [SMLWorkflowRuntimeAPIMount]
    public let workflowMounts: [SMLWorkflowRuntimeWorkflowMount]
    public let modelRouter: SMLWorkflowRuntimeModelRouterDescriptor
    public let onyxDriverIDs: [String]
    public let planningWorkflowIDs: [String]

    public init(
        schemaVersion: Int = SMLWorkflowRuntimeMountContract.currentSchemaVersion,
        workflowIDs: [String],
        apiBasePaths: [String],
        replMounts: [SMLWorkflowRuntimeREPLMount],
        apiRoutes: [SMLWorkflowRuntimeAPIMount],
        workflowMounts: [SMLWorkflowRuntimeWorkflowMount]? = nil,
        modelRouter: SMLWorkflowRuntimeModelRouterDescriptor,
        onyxDriverIDs: [String],
        planningWorkflowIDs: [String]
    ) {
        let orderedReplMounts = replMounts.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.workflowVersion < $1.workflowVersion
        }
        let orderedAPIRoutes = apiRoutes.sorted {
            if $0.pathTemplate != $1.pathTemplate { return $0.pathTemplate < $1.pathTemplate }
            if $0.method.rawValue != $1.method.rawValue {
                return $0.method.rawValue < $1.method.rawValue
            }
            return $0.operationID < $1.operationID
        }
        let orderedPlanningWorkflowIDs = planningWorkflowIDs.sorted()
        self.schemaVersion = schemaVersion
        self.workflowIDs = workflowIDs.sorted()
        self.apiBasePaths = apiBasePaths.sorted()
        self.replMounts = orderedReplMounts
        self.apiRoutes = orderedAPIRoutes
        self.workflowMounts = (
            workflowMounts ?? Self.workflowMountRows(
                replMounts: orderedReplMounts,
                apiRoutes: orderedAPIRoutes,
                planningWorkflowIDs: Set(orderedPlanningWorkflowIDs)
            )
        ).sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.workflowVersion < $1.workflowVersion
        }
        self.modelRouter = modelRouter
        self.onyxDriverIDs = onyxDriverIDs.sorted()
        self.planningWorkflowIDs = orderedPlanningWorkflowIDs
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, workflowIDs, apiBasePaths, replMounts, apiRoutes, workflowMounts,
             modelRouter, onyxDriverIDs, planningWorkflowIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let workflowIDs = try container.decode([String].self, forKey: .workflowIDs)
        let apiBasePaths = try container.decode([String].self, forKey: .apiBasePaths)
        let replMounts = try container.decode([SMLWorkflowRuntimeREPLMount].self, forKey: .replMounts)
        let apiRoutes = try container.decode([SMLWorkflowRuntimeAPIMount].self, forKey: .apiRoutes)
        let workflowMounts = try container.decodeIfPresent(
            [SMLWorkflowRuntimeWorkflowMount].self,
            forKey: .workflowMounts
        )
        let modelRouter = try container.decode(
            SMLWorkflowRuntimeModelRouterDescriptor.self,
            forKey: .modelRouter
        )
        let onyxDriverIDs = try container.decode([String].self, forKey: .onyxDriverIDs)
        let planningWorkflowIDs = try container.decode(
            [String].self,
            forKey: .planningWorkflowIDs
        )
        self.init(
            schemaVersion: schemaVersion,
            workflowIDs: workflowIDs,
            apiBasePaths: apiBasePaths,
            replMounts: replMounts,
            apiRoutes: apiRoutes,
            workflowMounts: workflowMounts,
            modelRouter: modelRouter,
            onyxDriverIDs: onyxDriverIDs,
            planningWorkflowIDs: planningWorkflowIDs
        )
    }

    public func resolveAPI(
        _ request: SMLWorkflowAPIRequest
    ) throws -> SMLWorkflowRuntimeResolvedAPIRoute {
        let pathSegments = try Self.pathSegments(request.path)
        let pathMatches = apiRoutes.compactMap { route -> SMLWorkflowRuntimeResolvedAPIRoute? in
            guard let parameters = Self.match(route: route, pathSegments: pathSegments) else {
                return nil
            }
            return SMLWorkflowRuntimeResolvedAPIRoute(
                route: route,
                pathParameters: parameters
            )
        }
        let metadataPathMatches = pathMatches.filter { $0.route.handlerKind == .metadata }
        if !metadataPathMatches.isEmpty {
            if metadataPathMatches.count > 1 {
                throw SMLWorkflowRuntimeMountContractError.ambiguousAPIRoute(
                    method: request.method.rawValue,
                    path: request.path
                )
            }
            guard let route = metadataPathMatches.first?.route,
                  request.method == route.method,
                  request.body.isEmpty,
                  request.scope.isEmpty,
                  request.expectedState.isEmpty else {
                throw SMLWorkflowRuntimeMountContractError.metadataRequestMustBeReadOnly
            }
        }
        return try Self.resolveAPI(
            method: request.method,
            path: request.path,
            pathSegments: pathSegments,
            routes: apiRoutes
        )
    }

    public func resolveAPI(
        method: SMLWorkflowAPIMethod,
        path: String
    ) throws -> SMLWorkflowRuntimeResolvedAPIRoute {
        try Self.resolveAPI(
            method: method,
            path: path,
            pathSegments: Self.pathSegments(path),
            routes: apiRoutes
        )
    }

    public func resolveWorkflow(
        workflowID: String
    ) throws -> SMLWorkflowRuntimeWorkflowMount {
        let matches = workflowMounts.filter { $0.workflowID == workflowID }
        if matches.count == 1 {
            let mount = matches[0]
            let planningLinkIsValid = mount.planningWorkflowID.map {
                planningWorkflowIDs.contains($0)
            } ?? true
            guard workflowIDs.contains(mount.workflowID),
                  modelRouter.workflowIDs.contains(mount.workflowID),
                  replMounts.contains(mount.repl),
                  mount.commandBindings == mount.repl.commandBindings,
                  mount.commandBindings.allSatisfy({ $0.workflowID == mount.workflowID }),
                  onyxDriverIDs.contains(mount.onyxDriverID),
                  planningLinkIsValid,
                  !mount.apiRoutes.isEmpty,
                  mount.apiRoutes.allSatisfy({
                      $0.handlerKind == .workflow
                          && $0.workflowID == mount.workflowID
                          && ($0.workflowMetadata == nil
                              || $0.workflowMetadata?.workflowID == mount.workflowID)
                  }) else {
                throw SMLWorkflowRuntimeMountContractError.invalidWorkflowMount(workflowID)
            }
            return mount
        }
        if matches.count > 1 || workflowIDs.contains(workflowID) {
            throw SMLWorkflowRuntimeMountContractError.invalidWorkflowMount(workflowID)
        }
        throw SMLWorkflowRuntimeMountContractError.workflowNotMounted(workflowID)
    }

    public init(catalog: SMLWorkflowRuntimeCatalog) {
        self.init(
            workflowIDs: catalog.workflowIDs,
            apiBasePaths: catalog.apiBasePaths,
            replMounts: catalog.workflows.map(SMLWorkflowRuntimeREPLMount.init),
            apiRoutes: Self.apiRoutes(for: catalog),
            modelRouter: catalog.modelRouter,
            onyxDriverIDs: catalog.onyxDrivers.map(\.driverID),
            planningWorkflowIDs: catalog.planningManifest.workflowIDs
        )
    }

    private static func apiRoutes(
        for catalog: SMLWorkflowRuntimeCatalog
    ) -> [SMLWorkflowRuntimeAPIMount] {
        let metadataRoutes = catalog.metadataEndpoints.map { endpoint in
            SMLWorkflowRuntimeAPIMount(
                method: endpoint.method,
                pathTemplate: endpoint.pathTemplate,
                operationID: endpoint.operationID,
                handlerKind: .metadata,
                authority: .descriptorOnly,
                readOnly: true,
                metadataResource: endpoint.resource,
                examples: [
                    SMLWorkflowAPIRequestExample(
                        method: endpoint.method,
                        path: endpoint.pathTemplate,
                        summary: endpoint.summary
                    ),
                ]
            )
        }
        let workflowRoutes = catalog.workflows.flatMap { workflow in
            workflow.api.endpoints.map { endpoint in
                let readOnly = !(workflow.commands.first {
                    $0.action == endpoint.action
                }?.changesTaskState ?? true)
                return SMLWorkflowRuntimeAPIMount(
                    method: endpoint.method,
                    pathTemplate: endpoint.pathTemplate,
                    operationID: operationID(endpoint, workflow: workflow),
                    handlerKind: .workflow,
                    authority: .hostCommandGateway,
                    readOnly: readOnly,
                    workflowID: workflow.workflowID,
                    action: endpoint.action,
                    workflowMetadata: SMLWorkflowRuntimeWorkflowMetadataLinks(workflow),
                    bodyKind: endpoint.bodyKind,
                    bodyFields: endpoint.bodyFields,
                    examples: endpoint.examples
                )
            }
        }
        return metadataRoutes + workflowRoutes
    }

    private static func workflowMountRows(
        replMounts: [SMLWorkflowRuntimeREPLMount],
        apiRoutes: [SMLWorkflowRuntimeAPIMount],
        planningWorkflowIDs: Set<String>
    ) -> [SMLWorkflowRuntimeWorkflowMount] {
        replMounts.map { repl in
            SMLWorkflowRuntimeWorkflowMount(
                repl: repl,
                apiRoutes: apiRoutes.filter {
                    $0.handlerKind == .workflow && $0.workflowID == repl.workflowID
                },
                planningWorkflowID: planningWorkflowIDs.contains(repl.workflowID)
                    ? repl.workflowID
                    : nil
            )
        }
    }

    private static func resolveAPI(
        method: SMLWorkflowAPIMethod,
        path: String,
        pathSegments: [String],
        routes: [SMLWorkflowRuntimeAPIMount]
    ) throws -> SMLWorkflowRuntimeResolvedAPIRoute {
        let matches = routes.compactMap { route -> SMLWorkflowRuntimeResolvedAPIRoute? in
            guard route.method == method,
                  let parameters = match(route: route, pathSegments: pathSegments) else {
                return nil
            }
            return SMLWorkflowRuntimeResolvedAPIRoute(
                route: route,
                pathParameters: parameters
            )
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            throw SMLWorkflowRuntimeMountContractError.ambiguousAPIRoute(
                method: method.rawValue,
                path: path
            )
        }
        throw SMLWorkflowRuntimeMountContractError.routeNotFound(
            method: method.rawValue,
            path: path
        )
    }

    private static func match(
        route: SMLWorkflowRuntimeAPIMount,
        pathSegments: [String]
    ) -> [String: String]? {
        guard let templateSegments = try? Self.pathSegments(route.pathTemplate),
              templateSegments.count == pathSegments.count else {
            return nil
        }
        var parameters: [String: String] = [:]
        for (template, actual) in zip(templateSegments, pathSegments) {
            if let name = placeholderName(template) {
                guard parameters[name] == nil else { return nil }
                parameters[name] = actual
                continue
            }
            guard template == actual else { return nil }
        }
        return parameters
    }

    private static func placeholderName(_ segment: String) -> String? {
        guard segment.hasPrefix("{"), segment.hasSuffix("}") else { return nil }
        let name = String(segment.dropFirst().dropLast())
        return name.isEmpty ? nil : name
    }

    private static func pathSegments(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"),
              !path.contains("?"),
              !path.contains("#"),
              !path.contains("//"),
              !path.contains("%"),
              !path.split(separator: "/").contains("..") else {
            throw SMLWorkflowRuntimeMountContractError.invalidAPIPath(path)
        }
        return path.split(separator: "/").map(String.init)
    }

    private static func operationID(
        _ endpoint: SMLWorkflowAPIEndpoint,
        workflow: SMLWorkflowRuntimeDescriptor
    ) -> String {
        "\(endpoint.operationID)_\(componentSuffix(workflow.workflowID))"
    }

    private static func componentSuffix(_ workflowID: String) -> String {
        workflowID
            .split(separator: ".")
            .map { segment in
                segment
                    .split(separator: "-")
                    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    .joined()
            }
            .joined()
    }
}

