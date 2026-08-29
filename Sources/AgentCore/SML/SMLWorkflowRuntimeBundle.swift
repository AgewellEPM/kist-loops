import Foundation

public struct SMLWorkflowModelToolDescriptor: Sendable, Codable, Equatable {
    public let name: String
    public let description: String
    public let parameters: [ToolParameter]

    public init(name: String, description: String, parameters: [ToolParameter]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    public init(_ tool: ToolSpec) {
        self.init(
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters
        )
    }
}

public struct SMLWorkflowREPLDescriptor: Sendable, Codable, Equatable {
    public let allowedActions: [SMLWorkflowControlAction]
    public let grammar: String
    public let helpText: String

    public init(
        allowedActions: [SMLWorkflowControlAction],
        grammar: String,
        helpText: String
    ) {
        self.allowedActions = allowedActions
        self.grammar = grammar
        self.helpText = helpText
    }
}

public struct SMLWorkflowModelDescriptor: Sendable, Codable, Equatable {
    public let requiresNativeTools: Bool
    public let allowedActions: [SMLWorkflowControlAction]
    public let tool: SMLWorkflowModelToolDescriptor
    public let maximumAdvisoryBytes: Int
    public let maximumCommandRounds: Int

    public init(
        requiresNativeTools: Bool,
        allowedActions: [SMLWorkflowControlAction],
        tool: SMLWorkflowModelToolDescriptor,
        maximumAdvisoryBytes: Int,
        maximumCommandRounds: Int
    ) {
        self.requiresNativeTools = requiresNativeTools
        self.allowedActions = allowedActions
        self.tool = tool
        self.maximumAdvisoryBytes = maximumAdvisoryBytes
        self.maximumCommandRounds = maximumCommandRounds
    }
}

/// Stable, codable description of every generated interface for one admitted workflow.
///
/// This value is intentionally authority-neutral. It contains no actor lease, credentials, replay
/// state, runtime handle, provider registry, or executable closure. Hosts can persist or serve it as
/// a descriptor, then route live mutations back through the generated compilers and admission gate.
public struct SMLWorkflowRuntimeDescriptor: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let workflowID: String
    public let workflowVersion: String
    public let workflowName: String
    public let role: String
    public let sourceKind: SMLWorkflowSourceKind
    public let sourceReference: String
    public let sourceDigest: String?
    public let inputs: [SMLWorkflowFieldDescriptor]
    public let outputs: [SMLWorkflowFieldDescriptor]
    public let commands: [SMLWorkflowCommandDescriptor]
    public let schemaSummary: String
    public let graphSummary: String
    public let repl: SMLWorkflowREPLDescriptor
    public let api: SMLWorkflowAPICatalog
    public let model: SMLWorkflowModelDescriptor
    public let onyx: SMLOnyxDriverManifest

    public init(
        schemaVersion: Int = SMLWorkflowRuntimeDescriptor.currentSchemaVersion,
        workflowID: String,
        workflowVersion: String,
        workflowName: String,
        role: String,
        sourceKind: SMLWorkflowSourceKind,
        sourceReference: String,
        sourceDigest: String?,
        inputs: [SMLWorkflowFieldDescriptor],
        outputs: [SMLWorkflowFieldDescriptor],
        commands: [SMLWorkflowCommandDescriptor],
        schemaSummary: String,
        graphSummary: String,
        repl: SMLWorkflowREPLDescriptor,
        api: SMLWorkflowAPICatalog,
        model: SMLWorkflowModelDescriptor,
        onyx: SMLOnyxDriverManifest
    ) {
        self.schemaVersion = schemaVersion
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.workflowName = workflowName
        self.role = role
        self.sourceKind = sourceKind
        self.sourceReference = sourceReference
        self.sourceDigest = sourceDigest
        self.inputs = inputs
        self.outputs = outputs
        self.commands = commands
        self.schemaSummary = schemaSummary
        self.graphSummary = graphSummary
        self.repl = repl
        self.api = api
        self.model = model
        self.onyx = onyx
    }
}

/// One admitted workflow compiled into all generated runtime adapters.
///
/// The bundle owns no authority. Its live helpers only bind the already-scoped compilers to a host
/// gateway and an authority resolver supplied by the transport/runtime layer.
public struct SMLWorkflowRuntimeBundle: Sendable {
    public let surface: SMLWorkflowSurface
    public let actor: String
    public let replCompiler: SMLWorkflowREPLCompiler
    public let apiCompiler: SMLWorkflowAPICompiler
    public let onyxDriver: SMLOnyxDriverManifest
    public let descriptor: SMLWorkflowRuntimeDescriptor
    private let admittedWorkflow: SMLAdmittedWorkflow?

    public init(
        surface: SMLWorkflowSurface,
        actor: String,
        replCompiler: SMLWorkflowREPLCompiler,
        apiCompiler: SMLWorkflowAPICompiler,
        onyxDriver: SMLOnyxDriverManifest,
        descriptor: SMLWorkflowRuntimeDescriptor,
        admittedWorkflow: SMLAdmittedWorkflow? = nil
    ) {
        self.surface = surface
        self.actor = actor
        self.replCompiler = replCompiler
        self.apiCompiler = apiCompiler
        self.onyxDriver = onyxDriver
        self.descriptor = descriptor
        self.admittedWorkflow = admittedWorkflow
    }

    public static func compile(
        admitted: SMLAdmittedWorkflow,
        role: String,
        actor: String,
        replActions: Set<SMLWorkflowControlAction>? = nil,
        modelActions: Set<SMLWorkflowControlAction> = SMLWorkflowSurface.modelDefaultActions,
        apiBasePath: String = "/v1",
        modelMaximumCommandRounds: Int = 4,
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() }
    ) throws -> SMLWorkflowRuntimeBundle {
        let surface = try SMLWorkflowSurface.compile(admitted: admitted, role: role)
        let replCompiler = SMLWorkflowREPLCompiler(
            surface: surface,
            actor: actor,
            allowedActions: replActions,
            commandID: commandID,
            taskID: taskID
        )
        let apiCompiler = try SMLWorkflowAPICompiler(
            surface: surface,
            actor: actor,
            basePath: apiBasePath,
            commandID: commandID
        )
        let onyxDriver = SMLOnyxDriverCompiler.compile(
            surface: surface,
            modelActions: modelActions,
            apiBasePath: apiBasePath
        )
        let descriptor = SMLWorkflowRuntimeDescriptor(
            workflowID: surface.workflowID,
            workflowVersion: surface.workflowVersion,
            workflowName: surface.workflowName,
            role: surface.role,
            sourceKind: surface.sourceKind,
            sourceReference: surface.workflow.source.reference,
            sourceDigest: surface.workflow.source.digest,
            inputs: surface.inputs,
            outputs: surface.outputs,
            commands: surface.commands,
            schemaSummary: surface.schemaSummary,
            graphSummary: surface.graphSummary,
            repl: SMLWorkflowREPLDescriptor(
                allowedActions: replCompiler.allowedActions.stableOrder,
                grammar: surface.grammar(allowedActions: replCompiler.allowedActions),
                helpText: replCompiler.helpText
            ),
            api: apiCompiler.catalog,
            model: SMLWorkflowModelDescriptor(
                requiresNativeTools: true,
                allowedActions: modelActions.stableOrder,
                tool: SMLWorkflowModelToolDescriptor(
                    surface.modelCommandTool(allowedActions: modelActions)
                ),
                maximumAdvisoryBytes: SMLWorkflowModelAdapter.maximumAdvisoryBytes,
                maximumCommandRounds: min(max(1, modelMaximumCommandRounds), 8)
            ),
            onyx: onyxDriver
        )
        return SMLWorkflowRuntimeBundle(
            surface: surface,
            actor: actor,
            replCompiler: replCompiler,
            apiCompiler: apiCompiler,
            onyxDriver: onyxDriver,
            descriptor: descriptor,
            admittedWorkflow: admitted
        )
    }

    public func install(into runtime: SMLRuntime) async throws -> SMLWorkflowProjection {
        guard let admittedWorkflow else {
            throw SMLWorkflowRuntimeRegistryError.workflowAdmissionUnavailable(surface.workflowID)
        }
        return try await runtime.installWorkflow(admittedWorkflow, role: surface.role)
    }

    public func makeREPLSession(
        gateway: SMLCommandGateway,
        authorityResolver: @escaping SMLWorkflowREPLSession.AuthorityResolver,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) -> SMLWorkflowREPLSession {
        SMLWorkflowREPLSession(
            compiler: replCompiler,
            gateway: gateway,
            authorityResolver: authorityResolver,
            clock: clock
        )
    }

    public func makeAPI(
        gateway: SMLCommandGateway,
        authorityResolver: @escaping SMLWorkflowAPI.AuthorityResolver,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) -> SMLWorkflowAPI {
        SMLWorkflowAPI(
            compiler: apiCompiler,
            gateway: gateway,
            authorityResolver: authorityResolver,
            clock: clock
        )
    }

    public func makeModelAdapter(
        binding: ProviderBinding,
        providers: ProviderRegistry,
        gateway: SMLCommandGateway,
        authorityResolver: @escaping SMLWorkflowModelAdapter.AuthorityResolver,
        settings: ModelSettings = ModelSettings(),
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) -> SMLWorkflowModelAdapter {
        SMLWorkflowModelAdapter(
            surface: surface,
            actor: actor,
            binding: binding,
            providers: providers,
            gateway: gateway,
            allowedActions: Set(descriptor.model.allowedActions),
            authorityResolver: authorityResolver,
            settings: settings,
            clock: clock
        )
    }

    public func makeModelSession(
        binding: ProviderBinding,
        providers: ProviderRegistry,
        gateway: SMLCommandGateway,
        authorityResolver: @escaping SMLWorkflowModelAdapter.AuthorityResolver,
        settings: ModelSettings = ModelSettings(),
        maximumCommandRounds: Int? = nil,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) -> SMLWorkflowModelSession {
        let adapter = makeModelAdapter(
            binding: binding,
            providers: providers,
            gateway: gateway,
            authorityResolver: authorityResolver,
            settings: settings,
            clock: clock
        )
        return SMLWorkflowModelSession(
            adapter: adapter,
            maximumCommandRounds: maximumCommandRounds ?? descriptor.model.maximumCommandRounds
        )
    }
}

public struct SMLWorkflowRuntimeMount: Sendable {
    public let admitted: SMLAdmittedWorkflow
    public let role: String
    public let actor: String
    public let replActions: Set<SMLWorkflowControlAction>?
    public let modelActions: Set<SMLWorkflowControlAction>
    public let apiBasePath: String
    public let modelMaximumCommandRounds: Int

    public init(
        admitted: SMLAdmittedWorkflow,
        role: String,
        actor: String,
        replActions: Set<SMLWorkflowControlAction>? = nil,
        modelActions: Set<SMLWorkflowControlAction> = SMLWorkflowSurface.modelDefaultActions,
        apiBasePath: String = "/v1",
        modelMaximumCommandRounds: Int = 4
    ) {
        self.admitted = admitted
        self.role = role
        self.actor = actor
        self.replActions = replActions
        self.modelActions = modelActions
        self.apiBasePath = apiBasePath
        self.modelMaximumCommandRounds = modelMaximumCommandRounds
    }
}

public struct SMLWorkflowRuntimeCandidateMount: Sendable {
    public let workflow: SMLWorkflow
    public let admissionCatalog: SMLExecutionAdmissionCatalog
    public let role: String
    public let actor: String
    public let replActions: Set<SMLWorkflowControlAction>?
    public let modelActions: Set<SMLWorkflowControlAction>
    public let apiBasePath: String
    public let modelMaximumCommandRounds: Int

    public init(
        workflow: SMLWorkflow,
        admissionCatalog: SMLExecutionAdmissionCatalog,
        role: String,
        actor: String,
        replActions: Set<SMLWorkflowControlAction>? = nil,
        modelActions: Set<SMLWorkflowControlAction> = SMLWorkflowSurface.modelDefaultActions,
        apiBasePath: String = "/v1",
        modelMaximumCommandRounds: Int = 4
    ) {
        self.workflow = workflow
        self.admissionCatalog = admissionCatalog
        self.role = role
        self.actor = actor
        self.replActions = replActions
        self.modelActions = modelActions
        self.apiBasePath = apiBasePath
        self.modelMaximumCommandRounds = modelMaximumCommandRounds
    }

    public func admit() throws -> SMLWorkflowRuntimeMount {
        SMLWorkflowRuntimeMount(
            admitted: try SMLWorkflowAdmission.admitForExecution(
                SMLWorkflowValidator.requireValidForImport(workflow),
                catalog: admissionCatalog
            ),
            role: role,
            actor: actor,
            replActions: replActions,
            modelActions: modelActions,
            apiBasePath: apiBasePath,
            modelMaximumCommandRounds: modelMaximumCommandRounds
        )
    }
}

public struct SMLWorkflowRuntimeCatalog: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let workflows: [SMLWorkflowRuntimeDescriptor]

    public init(
        schemaVersion: Int = SMLWorkflowRuntimeCatalog.currentSchemaVersion,
        workflows: [SMLWorkflowRuntimeDescriptor]
    ) {
        self.schemaVersion = schemaVersion
        self.workflows = workflows.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.workflowVersion < $1.workflowVersion
        }
    }

    public var workflowIDs: [String] {
        workflows.map(\.workflowID)
    }

    public var apiEndpoints: [SMLWorkflowAPIEndpoint] {
        workflows.flatMap(\.api.endpoints)
    }

    public var onyxDrivers: [SMLOnyxDriverManifest] {
        workflows.map(\.onyx)
    }

    public var apiBasePaths: [String] {
        Array(Set(workflows.map(\.api.basePath))).sorted()
    }

    public var metadataEndpoints: [SMLWorkflowRuntimeMetadataEndpoint] {
        apiBasePaths.flatMap { basePath in
            SMLWorkflowRuntimeMetadataResource.allCases.map { resource in
                SMLWorkflowRuntimeMetadataEndpoint(
                    method: .get,
                    pathTemplate: "\(basePath)/runtime/\(resource.rawValue)",
                    operationID: resource.operationID,
                    resource: resource,
                    summary: resource.summary
                )
            }
        }
    }
}

public struct SMLWorkflowRuntimeModelToolExport: Sendable, Codable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let tool: SMLWorkflowModelToolDescriptor
    public let allowedActions: [SMLWorkflowControlAction]
    public let maximumCommandRounds: Int

    public init(
        workflowID: String,
        workflowVersion: String,
        tool: SMLWorkflowModelToolDescriptor,
        allowedActions: [SMLWorkflowControlAction],
        maximumCommandRounds: Int
    ) {
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.tool = tool
        self.allowedActions = allowedActions
        self.maximumCommandRounds = maximumCommandRounds
    }

    public init(_ descriptor: SMLWorkflowRuntimeDescriptor) {
        self.init(
            workflowID: descriptor.workflowID,
            workflowVersion: descriptor.workflowVersion,
            tool: descriptor.model.tool,
            allowedActions: descriptor.model.allowedActions,
            maximumCommandRounds: descriptor.model.maximumCommandRounds
        )
    }
}

public struct SMLWorkflowRuntimeModelRouterDescriptor: Sendable, Codable, Equatable {
    public let requiresNativeTools: Bool
    public let tool: SMLWorkflowModelToolDescriptor
    public let workflowIDs: [String]
    public let maximumAdvisoryBytes: Int
    public let maximumCommandRounds: Int

    public init(
        requiresNativeTools: Bool = true,
        tool: SMLWorkflowModelToolDescriptor,
        workflowIDs: [String],
        maximumAdvisoryBytes: Int,
        maximumCommandRounds: Int
    ) {
        self.requiresNativeTools = requiresNativeTools
        self.tool = tool
        self.workflowIDs = workflowIDs.sorted()
        self.maximumAdvisoryBytes = max(0, maximumAdvisoryBytes)
        self.maximumCommandRounds = min(max(1, maximumCommandRounds), 8)
    }
}

public enum SMLWorkflowRuntimeMetadataResource: String, Sendable, Codable, Equatable, CaseIterable {
    case catalog
    case mount
    case export
    case openAPI = "openapi"
    case planning
    case agentGuide = "agent-guide"
    case hostGuide = "host-guide"
    case modelRouter = "model-router"
    case onyxDrivers = "onyx-drivers"

    public var operationID: String {
        "get_sml_runtime_" + rawValue.replacingOccurrences(of: "-", with: "_")
    }

    public var summary: String {
        switch self {
        case .catalog:
            return "List the mounted SML workflow runtime catalog"
        case .mount:
            return "Return the host mount contract for this SML workflow runtime"
        case .export:
            return "Return the complete authority-neutral SML workflow runtime export"
        case .openAPI:
            return "Return the generated OpenAPI document for this SML workflow runtime"
        case .planning:
            return "Return the aggregate planner manifest for mounted SML workflows"
        case .agentGuide:
            return "Return the canonical model and agent operating guide for mounted SML workflows"
        case .hostGuide:
            return "Return the canonical host wiring guide for mounting SML workflow runtimes"
        case .modelRouter:
            return "Return the native model-router tool descriptor for mounted SML workflows"
        case .onyxDrivers:
            return "Return provider-neutral Onyx driver manifests for mounted SML workflows"
        }
    }
}

public struct SMLWorkflowRuntimeMetadataEndpoint: Sendable, Codable, Equatable {
    public let method: SMLWorkflowAPIMethod
    public let pathTemplate: String
    public let operationID: String
    public let resource: SMLWorkflowRuntimeMetadataResource
    public let summary: String

    public init(
        method: SMLWorkflowAPIMethod,
        pathTemplate: String,
        operationID: String,
        resource: SMLWorkflowRuntimeMetadataResource,
        summary: String
    ) {
        self.method = method
        self.pathTemplate = pathTemplate
        self.operationID = operationID
        self.resource = resource
        self.summary = summary
    }
}

public enum SMLWorkflowRuntimeAPIRoute: Sendable, Equatable {
    case metadata(SMLWorkflowRuntimeMetadataResource)
    case workflow(workflowID: String)
}

public enum SMLWorkflowRuntimeRouteHandlerKind: String, Sendable, Codable, Equatable {
    case metadata
    case workflow
}

public enum SMLWorkflowRuntimeRouteAuthority: String, Sendable, Codable, Equatable {
    case descriptorOnly = "descriptor_only"
    case hostCommandGateway = "host_command_gateway"
}

public struct SMLWorkflowRuntimeREPLMount: Sendable, Codable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let workflowName: String
    public let role: String
    public let apiBasePath: String
    public let grammar: String
    public let helpText: String
    public let modelToolName: String
    public let modelRouterToolName: String
    public let onyxDriverID: String

    public init(
        workflowID: String,
        workflowVersion: String,
        workflowName: String,
        role: String,
        apiBasePath: String,
        grammar: String,
        helpText: String,
        modelToolName: String,
        modelRouterToolName: String,
        onyxDriverID: String
    ) {
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.workflowName = workflowName
        self.role = role
        self.apiBasePath = apiBasePath
        self.grammar = grammar
        self.helpText = helpText
        self.modelToolName = modelToolName
        self.modelRouterToolName = modelRouterToolName
        self.onyxDriverID = onyxDriverID
    }

    public init(_ descriptor: SMLWorkflowRuntimeDescriptor) {
        self.init(
            workflowID: descriptor.workflowID,
            workflowVersion: descriptor.workflowVersion,
            workflowName: descriptor.workflowName,
            role: descriptor.role,
            apiBasePath: descriptor.api.basePath,
            grammar: descriptor.repl.grammar,
            helpText: descriptor.repl.helpText,
            modelToolName: descriptor.model.tool.name,
            modelRouterToolName: SMLWorkflowRuntimeModelAdapter.toolName,
            onyxDriverID: descriptor.onyx.driverID
        )
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
    public let bodyKind: SMLWorkflowAPIRequestBodyKind
    public let bodyFields: [SMLWorkflowFieldDescriptor]

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
        bodyKind: SMLWorkflowAPIRequestBodyKind = .none,
        bodyFields: [SMLWorkflowFieldDescriptor] = []
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
        self.bodyKind = bodyKind
        self.bodyFields = bodyFields
    }
}

public struct SMLWorkflowRuntimeWorkflowMount: Sendable, Codable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let workflowName: String
    public let role: String
    public let apiBasePath: String
    public let repl: SMLWorkflowRuntimeREPLMount
    public let apiRoutes: [SMLWorkflowRuntimeAPIMount]
    public let modelToolName: String
    public let modelRouterToolName: String
    public let onyxDriverID: String
    public let planningWorkflowID: String?

    public init(
        workflowID: String,
        workflowVersion: String,
        workflowName: String,
        role: String,
        apiBasePath: String,
        repl: SMLWorkflowRuntimeREPLMount,
        apiRoutes: [SMLWorkflowRuntimeAPIMount],
        modelToolName: String,
        modelRouterToolName: String,
        onyxDriverID: String,
        planningWorkflowID: String?
    ) {
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.workflowName = workflowName
        self.role = role
        self.apiBasePath = apiBasePath
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
            repl: repl,
            apiRoutes: apiRoutes,
            modelToolName: repl.modelToolName,
            modelRouterToolName: repl.modelRouterToolName,
            onyxDriverID: repl.onyxDriverID,
            planningWorkflowID: planningWorkflowID
        )
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
    public static let currentSchemaVersion = 2

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
                  onyxDriverIDs.contains(mount.onyxDriverID),
                  planningLinkIsValid,
                  !mount.apiRoutes.isEmpty,
                  mount.apiRoutes.allSatisfy({
                      $0.handlerKind == .workflow && $0.workflowID == mount.workflowID
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
                metadataResource: endpoint.resource
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
                    bodyKind: endpoint.bodyKind,
                    bodyFields: endpoint.bodyFields
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

public struct SMLWorkflowRuntimePlanningWorkflow: Sendable, Codable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let workflowName: String
    public let role: String
    public let sourceKind: SMLWorkflowSourceKind
    public let sourceReference: String
    public let sourceDigest: String?
    public let entrypoint: String
    public let apiBasePath: String
    public let replGrammar: String
    public let modelToolName: String
    public let modelRouterToolName: String
    public let skillTree: [SMLOnyxSkillNode]
    public let tools: [SMLOnyxToolBinding]
    public let plan: SMLOnyxPlan

    public init(
        workflowID: String,
        workflowVersion: String,
        workflowName: String,
        role: String,
        sourceKind: SMLWorkflowSourceKind,
        sourceReference: String,
        sourceDigest: String?,
        entrypoint: String,
        apiBasePath: String,
        replGrammar: String,
        modelToolName: String,
        modelRouterToolName: String,
        skillTree: [SMLOnyxSkillNode],
        tools: [SMLOnyxToolBinding],
        plan: SMLOnyxPlan
    ) {
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.workflowName = workflowName
        self.role = role
        self.sourceKind = sourceKind
        self.sourceReference = sourceReference
        self.sourceDigest = sourceDigest
        self.entrypoint = entrypoint
        self.apiBasePath = apiBasePath
        self.replGrammar = replGrammar
        self.modelToolName = modelToolName
        self.modelRouterToolName = modelRouterToolName
        self.skillTree = skillTree
        self.tools = tools
        self.plan = plan
    }

    public init(_ descriptor: SMLWorkflowRuntimeDescriptor) {
        self.init(
            workflowID: descriptor.workflowID,
            workflowVersion: descriptor.workflowVersion,
            workflowName: descriptor.workflowName,
            role: descriptor.role,
            sourceKind: descriptor.sourceKind,
            sourceReference: descriptor.sourceReference,
            sourceDigest: descriptor.sourceDigest,
            entrypoint: descriptor.onyx.plan.entrypoint,
            apiBasePath: descriptor.api.basePath,
            replGrammar: descriptor.repl.grammar,
            modelToolName: descriptor.model.tool.name,
            modelRouterToolName: SMLWorkflowRuntimeModelAdapter.toolName,
            skillTree: descriptor.onyx.skillTree,
            tools: descriptor.onyx.tools,
            plan: descriptor.onyx.plan
        )
    }
}

public struct SMLWorkflowRuntimePlanningToolIndexEntry: Sendable, Codable, Equatable {
    public let workflowID: String
    public let instructionID: String
    public let operation: SMLInstructionOperation
    public let reference: String
    public let unitKind: SMLOnyxPlanningUnitKind?
    public let statePreconditions: [String]
    public let declaredOutputs: [String]
    public let verifier: String?
    public let sideEffectLevel: SMLSideEffectLevel?

    public init(
        workflowID: String,
        instructionID: String,
        operation: SMLInstructionOperation,
        reference: String,
        unitKind: SMLOnyxPlanningUnitKind?,
        statePreconditions: [String],
        declaredOutputs: [String],
        verifier: String?,
        sideEffectLevel: SMLSideEffectLevel?
    ) {
        self.workflowID = workflowID
        self.instructionID = instructionID
        self.operation = operation
        self.reference = reference
        self.unitKind = unitKind
        self.statePreconditions = statePreconditions.sorted()
        self.declaredOutputs = declaredOutputs.sorted()
        self.verifier = verifier
        self.sideEffectLevel = sideEffectLevel
    }
}

public struct SMLWorkflowRuntimePlanningDecompositionUnit: Sendable, Codable, Equatable {
    public let workflowID: String
    public let instructionID: String
    public let unitKind: SMLOnyxPlanningUnitKind
    public let reference: String?
    public let successors: [String]

    public init(
        workflowID: String,
        instructionID: String,
        unitKind: SMLOnyxPlanningUnitKind,
        reference: String?,
        successors: [String]
    ) {
        self.workflowID = workflowID
        self.instructionID = instructionID
        self.unitKind = unitKind
        self.reference = reference
        self.successors = successors.sorted()
    }
}

public struct SMLWorkflowRuntimePlanningApprovalGate: Sendable, Codable, Equatable {
    public let workflowID: String
    public let instructionID: String
    public let reference: String?
    public let statePreconditions: [String]
    public let successors: [String]

    public init(
        workflowID: String,
        instructionID: String,
        reference: String?,
        statePreconditions: [String],
        successors: [String]
    ) {
        self.workflowID = workflowID
        self.instructionID = instructionID
        self.reference = reference
        self.statePreconditions = statePreconditions.sorted()
        self.successors = successors.sorted()
    }
}

/// Runtime-level planning manifest for a mounted workflow app.
///
/// This aggregates the already-admitted per-workflow Onyx skill trees, tool bindings, and graph
/// plans into one portable value a planner can load before choosing a REPL/API/model command. It is
/// intentionally descriptor-only: no actor, lease, credential, runtime handle, provider registry, or
/// executable closure is present.
public struct SMLWorkflowRuntimePlanningManifest: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let workflowIDs: [String]
    public let workflows: [SMLWorkflowRuntimePlanningWorkflow]
    public let toolIndex: [SMLWorkflowRuntimePlanningToolIndexEntry]
    public let decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit]
    public let approvalGates: [SMLWorkflowRuntimePlanningApprovalGate]

    public init(
        schemaVersion: Int = SMLWorkflowRuntimePlanningManifest.currentSchemaVersion,
        workflows: [SMLWorkflowRuntimePlanningWorkflow]
    ) {
        let sortedWorkflows = workflows.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.workflowVersion < $1.workflowVersion
        }
        self.schemaVersion = schemaVersion
        self.workflowIDs = sortedWorkflows.map(\.workflowID)
        self.workflows = sortedWorkflows
        self.toolIndex = Self.toolIndex(for: sortedWorkflows)
        self.decomposableUnits = Self.decomposableUnits(for: sortedWorkflows)
        self.approvalGates = Self.approvalGates(for: sortedWorkflows)
    }

    public init(
        schemaVersion: Int = SMLWorkflowRuntimePlanningManifest.currentSchemaVersion,
        descriptors: [SMLWorkflowRuntimeDescriptor]
    ) {
        self.init(
            schemaVersion: schemaVersion,
            workflows: descriptors.map(SMLWorkflowRuntimePlanningWorkflow.init)
        )
    }

    private static func toolIndex(
        for workflows: [SMLWorkflowRuntimePlanningWorkflow]
    ) -> [SMLWorkflowRuntimePlanningToolIndexEntry] {
        workflows.flatMap { workflow in
            let planningByInstructionID = Dictionary(
                uniqueKeysWithValues: workflow.skillTree.compactMap { node in
                    node.planning.map { (node.id, $0) }
                }
            )
            return workflow.tools.map { binding in
                let planning = planningByInstructionID[binding.instructionID]
                return SMLWorkflowRuntimePlanningToolIndexEntry(
                    workflowID: workflow.workflowID,
                    instructionID: binding.instructionID,
                    operation: binding.operation,
                    reference: binding.reference,
                    unitKind: planning?.unitKind,
                    statePreconditions: planning?.statePreconditions ?? [],
                    declaredOutputs: planning?.declaredOutputs ?? [],
                    verifier: binding.verifier,
                    sideEffectLevel: binding.sideEffectLevel
                )
            }
        }.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            if $0.instructionID != $1.instructionID { return $0.instructionID < $1.instructionID }
            return $0.reference < $1.reference
        }
    }

    private static func decomposableUnits(
        for workflows: [SMLWorkflowRuntimePlanningWorkflow]
    ) -> [SMLWorkflowRuntimePlanningDecompositionUnit] {
        workflows.flatMap { workflow in
            workflow.skillTree.compactMap { node in
                guard let planning = node.planning, planning.canDecomposeFurther else {
                    return nil
                }
                return SMLWorkflowRuntimePlanningDecompositionUnit(
                    workflowID: workflow.workflowID,
                    instructionID: node.id,
                    unitKind: planning.unitKind,
                    reference: node.reference,
                    successors: node.successors
                )
            }
        }.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.instructionID < $1.instructionID
        }
    }

    private static func approvalGates(
        for workflows: [SMLWorkflowRuntimePlanningWorkflow]
    ) -> [SMLWorkflowRuntimePlanningApprovalGate] {
        workflows.flatMap { workflow in
            workflow.skillTree.compactMap { node in
                guard node.operation == .waitApproval
                    || node.planning?.unitKind == .approvalGate else {
                    return nil
                }
                return SMLWorkflowRuntimePlanningApprovalGate(
                    workflowID: workflow.workflowID,
                    instructionID: node.id,
                    reference: node.reference,
                    statePreconditions: node.planning?.statePreconditions ?? [],
                    successors: node.successors
                )
            }
        }.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.instructionID < $1.instructionID
        }
    }
}

/// Portable, authority-neutral payload a host can serve to API/model/Onyx front ends.
///
/// The OpenAPI document is emitted as closed `SMLValue` JSON rather than `[String: Any]`, so callers
/// can persist, diff, and sign the exact API shape without gaining runtime authority.
public struct SMLWorkflowRuntimeExport: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let catalog: SMLWorkflowRuntimeCatalog
    public let mountContract: SMLWorkflowRuntimeMountContract
    public let openAPI: SMLObject
    public let modelTools: [SMLWorkflowRuntimeModelToolExport]
    public let modelRouter: SMLWorkflowRuntimeModelRouterDescriptor
    public let onyxDrivers: [SMLOnyxDriverManifest]
    public let planning: SMLWorkflowRuntimePlanningManifest
    public let agentGuide: SMLWorkflowRuntimeAgentGuide
    public let hostGuide: SMLWorkflowRuntimeHostGuide

    public init(
        schemaVersion: Int = SMLWorkflowRuntimeExport.currentSchemaVersion,
        catalog: SMLWorkflowRuntimeCatalog,
        mountContract: SMLWorkflowRuntimeMountContract,
        openAPI: SMLObject,
        modelTools: [SMLWorkflowRuntimeModelToolExport],
        modelRouter: SMLWorkflowRuntimeModelRouterDescriptor,
        onyxDrivers: [SMLOnyxDriverManifest],
        planning: SMLWorkflowRuntimePlanningManifest,
        agentGuide: SMLWorkflowRuntimeAgentGuide? = nil,
        hostGuide: SMLWorkflowRuntimeHostGuide? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.catalog = catalog
        self.mountContract = mountContract
        self.openAPI = openAPI
        self.modelTools = modelTools
        self.modelRouter = modelRouter
        self.onyxDrivers = onyxDrivers
        self.planning = planning
        self.agentGuide = agentGuide ?? catalog.agentGuide
        self.hostGuide = hostGuide ?? catalog.hostGuide
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, catalog, mountContract, openAPI, modelTools, modelRouter,
             onyxDrivers, planning, agentGuide, hostGuide
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        catalog = try container.decode(SMLWorkflowRuntimeCatalog.self, forKey: .catalog)
        mountContract = try container.decodeIfPresent(
            SMLWorkflowRuntimeMountContract.self, forKey: .mountContract
        ) ?? catalog.mountContract
        openAPI = try container.decode(SMLObject.self, forKey: .openAPI)
        modelTools = try container.decode(
            [SMLWorkflowRuntimeModelToolExport].self, forKey: .modelTools
        )
        modelRouter = try container.decodeIfPresent(
            SMLWorkflowRuntimeModelRouterDescriptor.self, forKey: .modelRouter
        ) ?? catalog.modelRouter
        onyxDrivers = try container.decode([SMLOnyxDriverManifest].self, forKey: .onyxDrivers)
        planning = try container.decodeIfPresent(
            SMLWorkflowRuntimePlanningManifest.self, forKey: .planning
        ) ?? catalog.planningManifest
        agentGuide = try container.decodeIfPresent(
            SMLWorkflowRuntimeAgentGuide.self, forKey: .agentGuide
        ) ?? catalog.agentGuide
        hostGuide = try container.decodeIfPresent(
            SMLWorkflowRuntimeHostGuide.self, forKey: .hostGuide
        ) ?? catalog.hostGuide
    }
}

public extension SMLWorkflowRuntimeCatalog {
    var modelTools: [SMLWorkflowRuntimeModelToolExport] {
        workflows.map(SMLWorkflowRuntimeModelToolExport.init)
    }

    var modelRouter: SMLWorkflowRuntimeModelRouterDescriptor {
        SMLWorkflowRuntimeModelRouterDescriptor(
            tool: SMLWorkflowModelToolDescriptor(
                SMLWorkflowRuntimeModelAdapter.modelCommandTool(catalog: self)
            ),
            workflowIDs: workflowIDs,
            maximumAdvisoryBytes: SMLWorkflowModelAdapter.maximumAdvisoryBytes,
            maximumCommandRounds: workflows
                .map(\.model.maximumCommandRounds)
                .max() ?? 1
        )
    }

    var planningManifest: SMLWorkflowRuntimePlanningManifest {
        SMLWorkflowRuntimePlanningManifest(descriptors: workflows)
    }

    var mountContract: SMLWorkflowRuntimeMountContract {
        SMLWorkflowRuntimeMountContract(catalog: self)
    }

    func openAPIDocument(
        title: String = "SML Workflow Runtime API",
        version: String = "1.0.0"
    ) -> SMLObject {
        SMLWorkflowRuntimeOpenAPIGenerator.document(
            catalog: self,
            title: title,
            version: version
        )
    }

    func export(
        title: String = "SML Workflow Runtime API",
        version: String = "1.0.0"
    ) -> SMLWorkflowRuntimeExport {
        SMLWorkflowRuntimeExport(
            catalog: self,
            mountContract: mountContract,
            openAPI: openAPIDocument(title: title, version: version),
            modelTools: modelTools,
            modelRouter: modelRouter,
            onyxDrivers: onyxDrivers,
            planning: planningManifest,
            agentGuide: agentGuide,
            hostGuide: hostGuide
        )
    }
}

public enum SMLWorkflowRuntimeRegistryError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyRegistry
    case duplicateWorkflowID(String)
    case unknownWorkflow(String)
    case workflowAdmissionUnavailable(String)
    case invalidAPIPath(String)
    case routeNotFound(method: String, path: String)
    case ambiguousAPIRoute(method: String, path: String)
    case metadataRequestMustBeReadOnly
    case invalidWorkflowMount(String)

    public var description: String {
        switch self {
        case .emptyRegistry:
            return "workflow runtime registry requires at least one mounted workflow"
        case .duplicateWorkflowID(let workflowID):
            return "workflow runtime registry mounted duplicate workflow id: \(workflowID)"
        case .unknownWorkflow(let workflowID):
            return "workflow runtime registry has no workflow: \(workflowID)"
        case .workflowAdmissionUnavailable(let workflowID):
            return "workflow runtime bundle has no admission proof for workflow: \(workflowID)"
        case .invalidAPIPath(let path):
            return "invalid workflow runtime API path: \(path)"
        case .routeNotFound(let method, let path):
            return "workflow runtime API route not found: \(method) \(path)"
        case .ambiguousAPIRoute(let method, let path):
            return "workflow runtime API route is ambiguous: \(method) \(path)"
        case .metadataRequestMustBeReadOnly:
            return "workflow runtime metadata endpoints accept only read-only GET requests without body, scope, or expected state"
        case .invalidWorkflowMount(let workflowID):
            return "workflow runtime mount is internally inconsistent for workflow: \(workflowID)"
        }
    }
}

/// Host-side mount table for admitted workflows.
///
/// This is the piece that lets a daemon expose many imported workflows without bespoke switch
/// statements. The registry remains descriptor/router glue only: it does not mint authority, hold
/// credentials, execute capabilities directly, or bypass the replay/admission gateway.
public struct SMLWorkflowRuntimeRegistry: Sendable {
    public let bundles: [SMLWorkflowRuntimeBundle]
    public let catalog: SMLWorkflowRuntimeCatalog
    private let bundlesByWorkflowID: [String: SMLWorkflowRuntimeBundle]

    public init(bundles: [SMLWorkflowRuntimeBundle]) throws {
        guard !bundles.isEmpty else { throw SMLWorkflowRuntimeRegistryError.emptyRegistry }
        let ordered = bundles.sorted {
            if $0.surface.workflowID != $1.surface.workflowID {
                return $0.surface.workflowID < $1.surface.workflowID
            }
            return $0.surface.workflowVersion < $1.surface.workflowVersion
        }
        var byID: [String: SMLWorkflowRuntimeBundle] = [:]
        for bundle in ordered {
            let workflowID = bundle.surface.workflowID
            if byID[workflowID] != nil {
                throw SMLWorkflowRuntimeRegistryError.duplicateWorkflowID(workflowID)
            }
            byID[workflowID] = bundle
        }
        self.bundles = ordered
        bundlesByWorkflowID = byID
        catalog = SMLWorkflowRuntimeCatalog(workflows: ordered.map(\.descriptor))
    }

    public static func compile(
        mounts: [SMLWorkflowRuntimeMount],
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() }
    ) throws -> SMLWorkflowRuntimeRegistry {
        let bundles = try mounts.map { mount in
            try SMLWorkflowRuntimeBundle.compile(
                admitted: mount.admitted,
                role: mount.role,
                actor: mount.actor,
                replActions: mount.replActions,
                modelActions: mount.modelActions,
                apiBasePath: mount.apiBasePath,
                modelMaximumCommandRounds: mount.modelMaximumCommandRounds,
                commandID: commandID,
                taskID: taskID
            )
        }
        return try SMLWorkflowRuntimeRegistry(bundles: bundles)
    }

    public static func compile(
        candidateMounts: [SMLWorkflowRuntimeCandidateMount],
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() }
    ) throws -> SMLWorkflowRuntimeRegistry {
        try compile(
            mounts: candidateMounts.map { try $0.admit() },
            commandID: commandID,
            taskID: taskID
        )
    }

    public static func compile(
        workflows: [SMLWorkflow],
        admissionCatalog: SMLExecutionAdmissionCatalog,
        role: String,
        actor: String,
        replActions: Set<SMLWorkflowControlAction>? = nil,
        modelActions: Set<SMLWorkflowControlAction> = SMLWorkflowSurface.modelDefaultActions,
        apiBasePath: String = "/v1",
        modelMaximumCommandRounds: Int = 4,
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() }
    ) throws -> SMLWorkflowRuntimeRegistry {
        try compile(
            candidateMounts: workflows.map {
                SMLWorkflowRuntimeCandidateMount(
                    workflow: $0,
                    admissionCatalog: admissionCatalog,
                    role: role,
                    actor: actor,
                    replActions: replActions,
                    modelActions: modelActions,
                    apiBasePath: apiBasePath,
                    modelMaximumCommandRounds: modelMaximumCommandRounds
                )
            },
            commandID: commandID,
            taskID: taskID
        )
    }

    public static func compile(
        admitted workflows: [SMLAdmittedWorkflow],
        role: String,
        actor: String,
        replActions: Set<SMLWorkflowControlAction>? = nil,
        modelActions: Set<SMLWorkflowControlAction> = SMLWorkflowSurface.modelDefaultActions,
        apiBasePath: String = "/v1",
        modelMaximumCommandRounds: Int = 4,
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() }
    ) throws -> SMLWorkflowRuntimeRegistry {
        try compile(
            mounts: workflows.map {
                SMLWorkflowRuntimeMount(
                    admitted: $0,
                    role: role,
                    actor: actor,
                    replActions: replActions,
                    modelActions: modelActions,
                    apiBasePath: apiBasePath,
                    modelMaximumCommandRounds: modelMaximumCommandRounds
                )
            },
            commandID: commandID,
            taskID: taskID
        )
    }

    public var workflowIDs: [String] {
        bundles.map(\.surface.workflowID)
    }

    public var planningManifest: SMLWorkflowRuntimePlanningManifest {
        catalog.planningManifest
    }

    public var mountContract: SMLWorkflowRuntimeMountContract {
        catalog.mountContract
    }

    public var metadataEndpoints: [SMLWorkflowRuntimeMetadataEndpoint] {
        catalog.metadataEndpoints
    }

    public func resolveMount(
        for request: SMLWorkflowAPIRequest
    ) throws -> SMLWorkflowRuntimeResolvedAPIRoute {
        do {
            return try mountContract.resolveAPI(request)
        } catch let error as SMLWorkflowRuntimeMountContractError {
            throw Self.registryError(from: error)
        }
    }

    public func resolveWorkflowMount(
        workflowID: String
    ) throws -> SMLWorkflowRuntimeWorkflowMount {
        do {
            return try mountContract.resolveWorkflow(workflowID: workflowID)
        } catch let error as SMLWorkflowRuntimeMountContractError {
            throw Self.registryError(from: error)
        }
    }

    public func installAll(into runtime: SMLRuntime) async throws -> [SMLWorkflowProjection] {
        var installed: [SMLWorkflowProjection] = []
        installed.reserveCapacity(bundles.count)
        for bundle in bundles {
            installed.append(try await bundle.install(into: runtime))
        }
        return installed
    }

    public func bundle(workflowID: String) throws -> SMLWorkflowRuntimeBundle {
        guard let bundle = bundlesByWorkflowID[workflowID] else {
            throw SMLWorkflowRuntimeRegistryError.unknownWorkflow(workflowID)
        }
        return bundle
    }

    public func descriptor(workflowID: String) throws -> SMLWorkflowRuntimeDescriptor {
        try bundle(workflowID: workflowID).descriptor
    }

    public func onyxDriver(workflowID: String) throws -> SMLOnyxDriverManifest {
        try bundle(workflowID: workflowID).onyxDriver
    }

    public func openAPIDocument(
        title: String = "SML Workflow Runtime API",
        version: String = "1.0.0"
    ) -> SMLObject {
        catalog.openAPIDocument(title: title, version: version)
    }

    public func export(
        title: String = "SML Workflow Runtime API",
        version: String = "1.0.0"
    ) -> SMLWorkflowRuntimeExport {
        catalog.export(title: title, version: version)
    }

    public func compileREPL(
        _ line: String,
        workflowID: String,
        issuedAtEpoch: Double,
        defaultTaskID: String? = nil
    ) throws -> SMLWorkflowREPLCompilation {
        try bundle(workflowID: workflowID).replCompiler.compile(
            line,
            issuedAtEpoch: issuedAtEpoch,
            defaultTaskID: defaultTaskID
        )
    }

    public func compileAPI(
        _ request: SMLWorkflowAPIRequest,
        issuedAtEpoch: Double
    ) throws -> SMLCommandEnvelope {
        let resolved = try resolveMount(for: request)
        guard resolved.route.handlerKind == .workflow,
              let workflowID = resolved.route.workflowID else {
            throw SMLWorkflowRuntimeRegistryError.routeNotFound(
                method: request.method.rawValue,
                path: request.path
            )
        }
        let bundle = try bundle(workflowID: workflowID)
        return try bundle.apiCompiler.compile(request, issuedAtEpoch: issuedAtEpoch)
    }

    public func route(
        for request: SMLWorkflowAPIRequest
    ) throws -> SMLWorkflowRuntimeAPIRoute {
        let resolved = try resolveMount(for: request)
        switch resolved.route.handlerKind {
        case .metadata:
            guard let resource = resolved.route.metadataResource else {
                throw SMLWorkflowRuntimeRegistryError.routeNotFound(
                    method: request.method.rawValue,
                    path: request.path
                )
            }
            return .metadata(resource)
        case .workflow:
            guard let workflowID = resolved.route.workflowID else {
                throw SMLWorkflowRuntimeRegistryError.routeNotFound(
                    method: request.method.rawValue,
                    path: request.path
                )
            }
            return .workflow(workflowID: workflowID)
        }
    }

    public func metadataResource(
        for request: SMLWorkflowAPIRequest
    ) throws -> SMLWorkflowRuntimeMetadataResource {
        let resolved = try resolveMount(for: request)
        guard resolved.route.handlerKind == .metadata,
              let resource = resolved.route.metadataResource else {
            throw SMLWorkflowRuntimeRegistryError.routeNotFound(
                method: request.method.rawValue,
                path: request.path
            )
        }
        return resource
    }

    public func makeREPLSession(
        workflowID: String,
        gateway: SMLCommandGateway,
        authorityResolver: @escaping SMLWorkflowREPLSession.AuthorityResolver,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) throws -> SMLWorkflowREPLSession {
        try bundle(workflowID: workflowID).makeREPLSession(
            gateway: gateway,
            authorityResolver: authorityResolver,
            clock: clock
        )
    }

    public func makeAPI(
        gateway: SMLCommandGateway,
        authorityResolver: @escaping SMLWorkflowRuntimeAPI.AuthorityResolver,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) -> SMLWorkflowRuntimeAPI {
        SMLWorkflowRuntimeAPI(
            registry: self,
            gateway: gateway,
            authorityResolver: authorityResolver,
            clock: clock
        )
    }

    public func makeApp(
        gateway: SMLCommandGateway,
        authorityResolver: @escaping SMLWorkflowRuntimeAPI.AuthorityResolver,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) -> SMLWorkflowRuntimeApp {
        SMLWorkflowRuntimeApp(
            registry: self,
            gateway: gateway,
            authorityResolver: authorityResolver,
            clock: clock
        )
    }

    public func makeModelAdapter(
        workflowID: String,
        binding: ProviderBinding,
        providers: ProviderRegistry,
        gateway: SMLCommandGateway,
        authorityResolver: @escaping SMLWorkflowModelAdapter.AuthorityResolver,
        settings: ModelSettings = ModelSettings(),
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) throws -> SMLWorkflowModelAdapter {
        try bundle(workflowID: workflowID).makeModelAdapter(
            binding: binding,
            providers: providers,
            gateway: gateway,
            authorityResolver: authorityResolver,
            settings: settings,
            clock: clock
        )
    }

    public func makeModelSession(
        workflowID: String,
        binding: ProviderBinding,
        providers: ProviderRegistry,
        gateway: SMLCommandGateway,
        authorityResolver: @escaping SMLWorkflowModelAdapter.AuthorityResolver,
        settings: ModelSettings = ModelSettings(),
        maximumCommandRounds: Int? = nil,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) throws -> SMLWorkflowModelSession {
        try bundle(workflowID: workflowID).makeModelSession(
            binding: binding,
            providers: providers,
            gateway: gateway,
            authorityResolver: authorityResolver,
            settings: settings,
            maximumCommandRounds: maximumCommandRounds,
            clock: clock
        )
    }

    public func makeModelRouter(
        binding: ProviderBinding,
        providers: ProviderRegistry,
        gateway: SMLCommandGateway,
        authorityResolver: @escaping SMLWorkflowRuntimeModelAdapter.AuthorityResolver,
        settings: ModelSettings = ModelSettings(),
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) -> SMLWorkflowRuntimeModelAdapter {
        SMLWorkflowRuntimeModelAdapter(
            registry: self,
            binding: binding,
            providers: providers,
            gateway: gateway,
            authorityResolver: authorityResolver,
            settings: settings,
            clock: clock
        )
    }

    public func makeModelRouterSession(
        binding: ProviderBinding,
        providers: ProviderRegistry,
        gateway: SMLCommandGateway,
        authorityResolver: @escaping SMLWorkflowRuntimeModelAdapter.AuthorityResolver,
        settings: ModelSettings = ModelSettings(),
        maximumCommandRounds: Int? = nil,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) -> SMLWorkflowRuntimeModelSession {
        SMLWorkflowRuntimeModelSession(
            adapter: makeModelRouter(
                binding: binding,
                providers: providers,
                gateway: gateway,
                authorityResolver: authorityResolver,
                settings: settings,
                clock: clock
            ),
            maximumCommandRounds: maximumCommandRounds ?? catalog.modelRouter.maximumCommandRounds
        )
    }

    private static func registryError(
        from error: SMLWorkflowRuntimeMountContractError
    ) -> SMLWorkflowRuntimeRegistryError {
        switch error {
        case .invalidAPIPath(let path):
            return .invalidAPIPath(path)
        case .routeNotFound(let method, let path):
            return .routeNotFound(method: method, path: path)
        case .ambiguousAPIRoute(let method, let path):
            return .ambiguousAPIRoute(method: method, path: path)
        case .metadataRequestMustBeReadOnly:
            return .metadataRequestMustBeReadOnly
        case .workflowNotMounted(let workflowID):
            return .unknownWorkflow(workflowID)
        case .invalidWorkflowMount(let workflowID):
            return .invalidWorkflowMount(workflowID)
        }
    }
}

public struct SMLWorkflowRuntimeAPI: Sendable {
    public typealias AuthorityResolver = @Sendable (
        _ command: SMLCommandEnvelope
    ) async throws -> SMLCommandAuthority

    public let registry: SMLWorkflowRuntimeRegistry
    private let gateway: SMLCommandGateway
    private let authorityResolver: AuthorityResolver
    private let clock: @Sendable () -> Double

    public init(
        registry: SMLWorkflowRuntimeRegistry,
        gateway: SMLCommandGateway,
        authorityResolver: @escaping AuthorityResolver,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.registry = registry
        self.gateway = gateway
        self.authorityResolver = authorityResolver
        self.clock = clock
    }

    public var catalog: SMLWorkflowRuntimeCatalog {
        registry.catalog
    }

    public var mountContract: SMLWorkflowRuntimeMountContract {
        registry.mountContract
    }

    public var metadataEndpoints: [SMLWorkflowRuntimeMetadataEndpoint] {
        registry.metadataEndpoints
    }

    public func resolveMount(
        for request: SMLWorkflowAPIRequest
    ) throws -> SMLWorkflowRuntimeResolvedAPIRoute {
        try registry.resolveMount(for: request)
    }

    public func resolveWorkflowMount(
        workflowID: String
    ) throws -> SMLWorkflowRuntimeWorkflowMount {
        try registry.resolveWorkflowMount(workflowID: workflowID)
    }

    public func openAPIDocument(
        title: String = "SML Workflow Runtime API",
        version: String = "1.0.0"
    ) -> SMLObject {
        registry.openAPIDocument(title: title, version: version)
    }

    public func export(
        title: String = "SML Workflow Runtime API",
        version: String = "1.0.0"
    ) -> SMLWorkflowRuntimeExport {
        registry.export(title: title, version: version)
    }

    public func handleMetadata(
        _ request: SMLWorkflowAPIRequest
    ) throws -> SMLWorkflowRuntimeMetadataResponse {
        let resource = try registry.metadataResource(for: request)
        return try SMLWorkflowRuntimeMetadataResponse(
            resource: resource,
            path: request.path,
            body: metadataPayload(for: resource)
        )
    }

    public func handleRuntime(
        _ request: SMLWorkflowAPIRequest
    ) async throws -> SMLWorkflowRuntimeAPIResponse {
        let resolved = try registry.resolveMount(for: request)
        switch resolved.route.handlerKind {
        case .metadata:
            guard let resource = resolved.route.metadataResource else {
                throw SMLWorkflowRuntimeRegistryError.routeNotFound(
                    method: request.method.rawValue,
                    path: request.path
                )
            }
            let metadata = try SMLWorkflowRuntimeMetadataResponse(
                resource: resource,
                path: request.path,
                body: metadataPayload(for: resource)
            )
            return SMLWorkflowRuntimeAPIResponse(
                metadata: metadata,
                route: resolved.route,
                pathParameters: resolved.pathParameters
            )
        case .workflow:
            return try SMLWorkflowRuntimeAPIResponse(
                workflow: try await handle(request),
                path: request.path,
                route: resolved.route,
                pathParameters: resolved.pathParameters
            )
        }
    }

    public func handle(_ request: SMLWorkflowAPIRequest) async throws -> SMLWorkflowAPIResponse {
        let now = clock()
        let command = try registry.compileAPI(request, issuedAtEpoch: now)
        let authority = try await authorityResolver(command)
        let result = try await gateway.submit(command, authority: authority, nowEpoch: now)
        let status = command.op == SMLRuntimeCommandOperation.workflowRun ? 201 : 200
        return SMLWorkflowAPIResponse(statusCode: status, command: command, result: result)
    }

    private func metadataPayload(
        for resource: SMLWorkflowRuntimeMetadataResource
    ) throws -> SMLValue {
        switch resource {
        case .catalog:
            return try SMLWorkflowRuntimePayloadCodec.encode(registry.catalog)
        case .mount:
            return try SMLWorkflowRuntimePayloadCodec.encode(registry.mountContract)
        case .export:
            return try SMLWorkflowRuntimePayloadCodec.encode(registry.export())
        case .openAPI:
            return .object(registry.openAPIDocument())
        case .planning:
            return try SMLWorkflowRuntimePayloadCodec.encode(registry.planningManifest)
        case .agentGuide:
            return try SMLWorkflowRuntimePayloadCodec.encode(registry.catalog.agentGuide)
        case .hostGuide:
            return try SMLWorkflowRuntimePayloadCodec.encode(registry.catalog.hostGuide)
        case .modelRouter:
            return try SMLWorkflowRuntimePayloadCodec.encode(registry.catalog.modelRouter)
        case .onyxDrivers:
            return try SMLWorkflowRuntimePayloadCodec.encode(registry.catalog.onyxDrivers)
        }
    }
}

public struct SMLWorkflowRuntimeMetadataResponse: Sendable, Equatable {
    public let statusCode: Int
    public let resource: SMLWorkflowRuntimeMetadataResource
    public let path: String
    public let body: SMLValue

    public init(
        statusCode: Int = 200,
        resource: SMLWorkflowRuntimeMetadataResource,
        path: String,
        body: SMLValue
    ) {
        self.statusCode = statusCode
        self.resource = resource
        self.path = path
        self.body = body
    }
}

public enum SMLWorkflowRuntimeAPIResponseKind: String, Sendable, Codable, Equatable {
    case metadata
    case workflow
}

public struct SMLWorkflowRuntimeAPIResponse: Sendable, Equatable {
    public let statusCode: Int
    public let kind: SMLWorkflowRuntimeAPIResponseKind
    public let path: String
    public let body: SMLValue
    public let route: SMLWorkflowRuntimeAPIMount?
    public let pathParameters: [String: String]
    public let metadataResource: SMLWorkflowRuntimeMetadataResource?
    public let command: SMLCommandEnvelope?
    public let result: SMLCommandResult?

    public init(
        statusCode: Int,
        kind: SMLWorkflowRuntimeAPIResponseKind,
        path: String,
        body: SMLValue,
        route: SMLWorkflowRuntimeAPIMount? = nil,
        pathParameters: [String: String] = [:],
        metadataResource: SMLWorkflowRuntimeMetadataResource? = nil,
        command: SMLCommandEnvelope? = nil,
        result: SMLCommandResult? = nil
    ) {
        self.statusCode = statusCode
        self.kind = kind
        self.path = path
        self.body = body
        self.route = route
        self.pathParameters = pathParameters
        self.metadataResource = metadataResource
        self.command = command
        self.result = result
    }

    public init(
        metadata response: SMLWorkflowRuntimeMetadataResponse,
        route: SMLWorkflowRuntimeAPIMount? = nil,
        pathParameters: [String: String] = [:]
    ) {
        self.init(
            statusCode: response.statusCode,
            kind: .metadata,
            path: response.path,
            body: response.body,
            route: route,
            pathParameters: pathParameters,
            metadataResource: response.resource
        )
    }

    public init(
        workflow response: SMLWorkflowAPIResponse,
        path: String,
        route: SMLWorkflowRuntimeAPIMount? = nil,
        pathParameters: [String: String] = [:]
    ) throws {
        self.init(
            statusCode: response.statusCode,
            kind: .workflow,
            path: path,
            body: try SMLWorkflowRuntimePayloadCodec.encode(response.result),
            route: route,
            pathParameters: pathParameters,
            command: response.command,
            result: response.result
        )
    }
}

public struct SMLWorkflowRuntimeLaunch: Sendable {
    public let registry: SMLWorkflowRuntimeRegistry
    public let app: SMLWorkflowRuntimeApp
    public let installedWorkflows: [SMLWorkflowProjection]

    public init(
        registry: SMLWorkflowRuntimeRegistry,
        app: SMLWorkflowRuntimeApp,
        installedWorkflows: [SMLWorkflowProjection]
    ) {
        self.registry = registry
        self.app = app
        self.installedWorkflows = installedWorkflows
    }

    public var mountContract: SMLWorkflowRuntimeMountContract {
        registry.mountContract
    }

    public func export(
        title: String = "SML Workflow Runtime API",
        version: String = "1.0.0"
    ) -> SMLWorkflowRuntimeExport {
        registry.export(title: title, version: version)
    }
}

private enum SMLWorkflowRuntimePayloadCodec {
    static func encode<T: Encodable>(_ value: T) throws -> SMLValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(SMLValue.self, from: data)
    }
}

/// One model loop over many mounted workflows.
///
/// The model chooses a `workflow_id` and one line from that workflow's generated REPL grammar. The
/// adapter still compiles through `SMLWorkflowRuntimeRegistry`, so workflow selection cannot bypass
/// per-workflow allowed actions, command validation, host authority, replay admission, or runtime
/// state checks.
public struct SMLWorkflowRuntimeModelAdapter: Sendable {
    public typealias AuthorityResolver = @Sendable (
        _ command: SMLCommandEnvelope
    ) async throws -> SMLCommandAuthority

    public static let toolName = "propose_sml_runtime_command"

    public let registry: SMLWorkflowRuntimeRegistry
    public let binding: ProviderBinding
    private let providers: ProviderRegistry
    private let gateway: SMLCommandGateway
    private let authorityResolver: AuthorityResolver
    private let clock: @Sendable () -> Double
    private let baseSettings: ModelSettings

    public init(
        registry: SMLWorkflowRuntimeRegistry,
        binding: ProviderBinding,
        providers: ProviderRegistry,
        gateway: SMLCommandGateway,
        authorityResolver: @escaping AuthorityResolver,
        settings: ModelSettings = ModelSettings(),
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.registry = registry
        self.binding = binding
        self.providers = providers
        self.gateway = gateway
        self.authorityResolver = authorityResolver
        self.clock = clock
        baseSettings = settings
    }

    public static func modelCommandTool(catalog: SMLWorkflowRuntimeCatalog) -> ToolSpec {
        ToolSpec(
            name: toolName,
            description: "Propose exactly one command for one mounted SML workflow. "
                + "The host validates the selected workflow, command grammar, authority, and replay. "
                + "Mounted workflows: \(catalog.workflowIDs.joined(separator: ", ")).",
            parameters: [
                ToolParameter(
                    name: "workflow_id",
                    type: "string",
                    description: "Exact workflow id from the mounted SML runtime catalog."
                ),
                ToolParameter(
                    name: "line",
                    type: "string",
                    description: "One exact command line from that workflow's allowed REPL grammar."
                ),
            ]
        )
    }

    public var modelCommandTool: ToolSpec {
        Self.modelCommandTool(catalog: registry.catalog)
    }

    public func step(
        messages: [ChatMessage],
        defaultTaskIDs: [String: String] = [:],
        requestBudget: ProviderRequestBudget
    ) async throws -> SMLWorkflowModelStep {
        let capabilities = providers.capabilities(
            providerId: binding.providerId, model: binding.model
        )
        guard capabilities.nativeTools else {
            throw SMLWorkflowModelError.nativeToolsRequired(
                provider: binding.providerId, model: binding.model
            )
        }

        var settings = baseSettings
        settings.geminiBuiltins = false
        settings.toolChoice = .any
        settings.jsonOutput = false
        settings.jsonSchema = nil
        settings.systemPrompt = [settings.systemPrompt, systemPrompt]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let stream = try await providers.streamTools(
            providerId: binding.providerId,
            model: binding.model,
            messages: messages,
            settings: settings,
            tools: [modelCommandTool],
            allowFallback: false,
            allowModelResolution: false,
            routePolicy: .exact,
            requestBudget: requestBudget
        )

        var advisory = ""
        var calls: [ToolCallRef] = []
        var unsafeFinishReason: String?
        var sawTerminalFinish = false
        for try await event in stream {
            switch event {
            case .delta(let text):
                if sawTerminalFinish { unsafeFinishReason = "events_after_finish" }
                advisory += text
                if advisory.utf8.count > SMLWorkflowModelAdapter.maximumAdvisoryBytes {
                    throw SMLWorkflowModelError.responseTooLarge
                }
            case .toolCall(let id, let name, let argumentsJSON):
                if sawTerminalFinish { unsafeFinishReason = "events_after_finish" }
                calls.append(ToolCallRef(id: id, name: name, argumentsJSON: argumentsJSON))
                if calls.count > 1 {
                    throw SMLWorkflowModelError.multipleToolCalls(calls.count)
                }
            case .finish(let reason):
                if sawTerminalFinish {
                    unsafeFinishReason = "multiple_finish_events"
                }
                sawTerminalFinish = true
                if !Self.finishReasonIsSafe(reason) {
                    unsafeFinishReason = reason ?? "unknown_finish"
                }
            case .reasoning, .effortResolution, .reasoningHandle, .usage:
                break
            }
        }

        if let unsafeFinishReason {
            throw SMLWorkflowModelError.unsafeFinishReason(unsafeFinishReason)
        }

        guard let call = calls.first else {
            return SMLWorkflowModelStep(
                disposition: .advisoryOnly,
                advisoryText: advisory,
                transcriptMessages: [ChatMessage(role: .assistant, content: advisory)]
            )
        }
        guard sawTerminalFinish else {
            throw SMLWorkflowModelError.unsafeFinishReason("missing_finish")
        }
        guard call.name == Self.toolName else {
            throw SMLWorkflowModelError.unexpectedTool(call.name)
        }
        let proposal = try decodeArguments(call.argumentsJSON)
        let now = clock()
        let command: SMLCommandEnvelope
        switch try registry.compileREPL(
            proposal.line,
            workflowID: proposal.workflowID,
            issuedAtEpoch: now,
            defaultTaskID: defaultTaskIDs[proposal.workflowID]
        ) {
        case .command(let compiled): command = compiled
        case .local, .exit: throw SMLWorkflowModelError.nonCommandProposal
        }
        let authority = try await authorityResolver(command)
        let result = try await gateway.submit(command, authority: authority, nowEpoch: now)
        let assistant = ChatMessage(
            role: .assistant,
            content: advisory,
            toolCalls: [call]
        )
        let toolResult = ChatMessage.toolResult(
            callId: call.id,
            content: SMLREPLRenderer.render(result)
        )
        return SMLWorkflowModelStep(
            disposition: .commandExecuted,
            advisoryText: advisory,
            toolCallID: call.id,
            command: command,
            result: result,
            transcriptMessages: [assistant, toolResult]
        )
    }

    private var systemPrompt: String {
        registry.catalog.agentGuide.systemPrompt
    }

    private func decodeArguments(_ json: String) throws -> (workflowID: String, line: String) {
        guard let data = json.data(using: .utf8) else {
            throw SMLWorkflowModelError.malformedToolArguments("arguments are not UTF-8")
        }
        do {
            let object = try SMLWireCodec.decodeOpenObject(
                from: data,
                limits: .init(maximumBytes: 64 * 1_024, maximumDepth: 8, maximumNodes: 1_024)
            )
            if let unknown = object.keys
                .filter({ !["workflow_id", "line"].contains($0) })
                .sorted()
                .first {
                throw SMLWorkflowModelError.malformedToolArguments("unknown key \(unknown)")
            }
            guard case .string(let workflowID)? = object["workflow_id"],
                  !workflowID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SMLWorkflowModelError.malformedToolArguments("missing workflow_id")
            }
            guard case .string(let line)? = object["line"],
                  !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SMLWorkflowModelError.missingCommandLine
            }
            return (workflowID, line)
        } catch let error as SMLWorkflowModelError {
            throw error
        } catch {
            throw SMLWorkflowModelError.malformedToolArguments(String(describing: error))
        }
    }

    private static func finishReasonIsSafe(_ reason: String?) -> Bool {
        guard let reason else { return true }
        let normalized = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        return ["stop", "tool_calls", "end_turn", "complete", "completed"]
            .contains(normalized)
    }
}

public struct SMLWorkflowRuntimeModelTurn: Sendable, Equatable {
    public let advisoryText: String
    public let steps: [SMLWorkflowModelStep]
    public let taskIDsByWorkflowID: [String: String]

    public init(
        advisoryText: String,
        steps: [SMLWorkflowModelStep],
        taskIDsByWorkflowID: [String: String]
    ) {
        self.advisoryText = advisoryText
        self.steps = steps
        self.taskIDsByWorkflowID = taskIDsByWorkflowID
    }
}

public actor SMLWorkflowRuntimeModelSession {
    private let adapter: SMLWorkflowRuntimeModelAdapter
    private let maximumCommandRounds: Int
    private var messages: [ChatMessage]
    private var taskIDsByWorkflowID: [String: String]

    public init(
        adapter: SMLWorkflowRuntimeModelAdapter,
        maximumCommandRounds: Int = 4,
        messages: [ChatMessage] = [],
        taskIDsByWorkflowID: [String: String] = [:]
    ) {
        self.adapter = adapter
        self.maximumCommandRounds = min(max(1, maximumCommandRounds), 8)
        self.messages = Array(messages.suffix(128))
        self.taskIDsByWorkflowID = taskIDsByWorkflowID
    }

    public func submit(
        _ userText: String,
        requestBudget: ProviderRequestBudget
    ) async throws -> SMLWorkflowRuntimeModelTurn {
        messages.append(ChatMessage(role: .user, content: userText))
        var steps: [SMLWorkflowModelStep] = []
        for _ in 0..<maximumCommandRounds {
            let step = try await adapter.step(
                messages: messages,
                defaultTaskIDs: taskIDsByWorkflowID,
                requestBudget: requestBudget
            )
            messages.append(contentsOf: step.transcriptMessages)
            messages = Array(messages.suffix(128))
            steps.append(step)
            if let command = step.command,
               command.op == SMLRuntimeCommandOperation.workflowRun,
               case .string(let workflowID)? = command.arguments["workflow_id"] {
                taskIDsByWorkflowID[workflowID] = command.task
            }
            if step.disposition == .advisoryOnly {
                return SMLWorkflowRuntimeModelTurn(
                    advisoryText: step.advisoryText,
                    steps: steps,
                    taskIDsByWorkflowID: taskIDsByWorkflowID
                )
            }
            if step.result?.task?.status == .waitingCapability {
                return SMLWorkflowRuntimeModelTurn(
                    advisoryText: step.advisoryText,
                    steps: steps,
                    taskIDsByWorkflowID: taskIDsByWorkflowID
                )
            }
        }
        throw SMLWorkflowModelError.commandRoundLimitExceeded(maximumCommandRounds)
    }

    public func transcript() -> [ChatMessage] { messages }

    public func taskIDs() -> [String: String] { taskIDsByWorkflowID }
}

/// Host-loadable facade for one mounted SML workflow runtime.
///
/// This is the ergonomic boundary for turning admitted workflows into a custom workflow app: the
/// same registry/catalog feeds REPL sessions, API handling, model routing, and Onyx manifests while
/// every mutation still crosses the supplied host authority resolver and command gateway.
public struct SMLWorkflowRuntimeApp: Sendable {
    public typealias AuthorityResolver = SMLWorkflowRuntimeAPI.AuthorityResolver

    public let registry: SMLWorkflowRuntimeRegistry
    private let gateway: SMLCommandGateway
    private let authorityResolver: AuthorityResolver
    private let clock: @Sendable () -> Double

    public init(
        registry: SMLWorkflowRuntimeRegistry,
        gateway: SMLCommandGateway,
        authorityResolver: @escaping AuthorityResolver,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.registry = registry
        self.gateway = gateway
        self.authorityResolver = authorityResolver
        self.clock = clock
    }

    public static func launch(
        mounts: [SMLWorkflowRuntimeMount],
        runtime: SMLRuntime,
        replayGuard: any SMLCommandReplayGuard,
        authorityResolver: @escaping AuthorityResolver,
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() },
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) async throws -> SMLWorkflowRuntimeLaunch {
        let registry = try SMLWorkflowRuntimeRegistry.compile(
            mounts: mounts,
            commandID: commandID,
            taskID: taskID
        )
        let installed = try await registry.installAll(into: runtime)
        let app = registry.makeApp(
            gateway: SMLCommandGateway(runtime: runtime, replayGuard: replayGuard),
            authorityResolver: authorityResolver,
            clock: clock
        )
        return SMLWorkflowRuntimeLaunch(
            registry: registry,
            app: app,
            installedWorkflows: installed
        )
    }

    public static func launch(
        candidateMounts: [SMLWorkflowRuntimeCandidateMount],
        runtime: SMLRuntime,
        replayGuard: any SMLCommandReplayGuard,
        authorityResolver: @escaping AuthorityResolver,
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() },
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) async throws -> SMLWorkflowRuntimeLaunch {
        try await launch(
            mounts: candidateMounts.map { try $0.admit() },
            runtime: runtime,
            replayGuard: replayGuard,
            authorityResolver: authorityResolver,
            commandID: commandID,
            taskID: taskID,
            clock: clock
        )
    }

    public static func launch(
        workflows: [SMLWorkflow],
        admissionCatalog: SMLExecutionAdmissionCatalog,
        runtime: SMLRuntime,
        replayGuard: any SMLCommandReplayGuard,
        role: String,
        actor: String,
        replActions: Set<SMLWorkflowControlAction>? = nil,
        modelActions: Set<SMLWorkflowControlAction> = SMLWorkflowSurface.modelDefaultActions,
        apiBasePath: String = "/v1",
        modelMaximumCommandRounds: Int = 4,
        authorityResolver: @escaping AuthorityResolver,
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() },
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) async throws -> SMLWorkflowRuntimeLaunch {
        try await launch(
            candidateMounts: workflows.map {
                SMLWorkflowRuntimeCandidateMount(
                    workflow: $0,
                    admissionCatalog: admissionCatalog,
                    role: role,
                    actor: actor,
                    replActions: replActions,
                    modelActions: modelActions,
                    apiBasePath: apiBasePath,
                    modelMaximumCommandRounds: modelMaximumCommandRounds
                )
            },
            runtime: runtime,
            replayGuard: replayGuard,
            authorityResolver: authorityResolver,
            commandID: commandID,
            taskID: taskID,
            clock: clock
        )
    }

    public var catalog: SMLWorkflowRuntimeCatalog { registry.catalog }

    public var workflowIDs: [String] { registry.workflowIDs }

    public var planningManifest: SMLWorkflowRuntimePlanningManifest {
        registry.planningManifest
    }

    public var mountContract: SMLWorkflowRuntimeMountContract {
        registry.mountContract
    }

    public var metadataEndpoints: [SMLWorkflowRuntimeMetadataEndpoint] {
        registry.metadataEndpoints
    }

    public func resolveMount(
        for request: SMLWorkflowAPIRequest
    ) throws -> SMLWorkflowRuntimeResolvedAPIRoute {
        try registry.resolveMount(for: request)
    }

    public func resolveWorkflowMount(
        workflowID: String
    ) throws -> SMLWorkflowRuntimeWorkflowMount {
        try registry.resolveWorkflowMount(workflowID: workflowID)
    }

    public var runtimeAPI: SMLWorkflowRuntimeAPI {
        registry.makeAPI(
            gateway: gateway,
            authorityResolver: authorityResolver,
            clock: clock
        )
    }

    public func descriptor(workflowID: String) throws -> SMLWorkflowRuntimeDescriptor {
        try registry.descriptor(workflowID: workflowID)
    }

    public func onyxDriver(workflowID: String) throws -> SMLOnyxDriverManifest {
        try registry.onyxDriver(workflowID: workflowID)
    }

    public func openAPIDocument(
        title: String = "SML Workflow Runtime API",
        version: String = "1.0.0"
    ) -> SMLObject {
        registry.openAPIDocument(title: title, version: version)
    }

    public func export(
        title: String = "SML Workflow Runtime API",
        version: String = "1.0.0"
    ) -> SMLWorkflowRuntimeExport {
        registry.export(title: title, version: version)
    }

    public func handleAPI(_ request: SMLWorkflowAPIRequest) async throws -> SMLWorkflowAPIResponse {
        try await runtimeAPI.handle(request)
    }

    public func handleMetadata(
        _ request: SMLWorkflowAPIRequest
    ) throws -> SMLWorkflowRuntimeMetadataResponse {
        try runtimeAPI.handleMetadata(request)
    }

    public func handleRuntimeAPI(
        _ request: SMLWorkflowAPIRequest
    ) async throws -> SMLWorkflowRuntimeAPIResponse {
        try await runtimeAPI.handleRuntime(request)
    }

    public func replSession(workflowID: String) throws -> SMLWorkflowREPLSession {
        try registry.makeREPLSession(
            workflowID: workflowID,
            gateway: gateway,
            authorityResolver: authorityResolver,
            clock: clock
        )
    }

    public func modelAdapter(
        workflowID: String,
        binding: ProviderBinding,
        providers: ProviderRegistry,
        settings: ModelSettings = ModelSettings()
    ) throws -> SMLWorkflowModelAdapter {
        try registry.makeModelAdapter(
            workflowID: workflowID,
            binding: binding,
            providers: providers,
            gateway: gateway,
            authorityResolver: authorityResolver,
            settings: settings,
            clock: clock
        )
    }

    public func modelSession(
        workflowID: String,
        binding: ProviderBinding,
        providers: ProviderRegistry,
        settings: ModelSettings = ModelSettings(),
        maximumCommandRounds: Int? = nil
    ) throws -> SMLWorkflowModelSession {
        try registry.makeModelSession(
            workflowID: workflowID,
            binding: binding,
            providers: providers,
            gateway: gateway,
            authorityResolver: authorityResolver,
            settings: settings,
            maximumCommandRounds: maximumCommandRounds,
            clock: clock
        )
    }

    public func modelRouter(
        binding: ProviderBinding,
        providers: ProviderRegistry,
        settings: ModelSettings = ModelSettings()
    ) -> SMLWorkflowRuntimeModelAdapter {
        registry.makeModelRouter(
            binding: binding,
            providers: providers,
            gateway: gateway,
            authorityResolver: authorityResolver,
            settings: settings,
            clock: clock
        )
    }

    public func modelRouterSession(
        binding: ProviderBinding,
        providers: ProviderRegistry,
        settings: ModelSettings = ModelSettings(),
        maximumCommandRounds: Int? = nil
    ) -> SMLWorkflowRuntimeModelSession {
        registry.makeModelRouterSession(
            binding: binding,
            providers: providers,
            gateway: gateway,
            authorityResolver: authorityResolver,
            settings: settings,
            maximumCommandRounds: maximumCommandRounds,
            clock: clock
        )
    }
}

private enum SMLWorkflowRuntimeOpenAPIGenerator {
    static func document(
        catalog: SMLWorkflowRuntimeCatalog,
        title: String,
        version: String
    ) -> SMLObject {
        var paths: SMLObject = [:]
        var schemas: SMLObject = [
            "SMLCommandResult": .object([
                "type": .string("object"),
                "additionalProperties": .bool(true),
                "description": .string("Runtime command result envelope returned after host admission."),
            ]),
            "SMLExpectedState": .object([
                "type": .string("object"),
                "additionalProperties": .bool(true),
                "required": .array([.string("task_revision")]),
                "properties": .object([
                    "task_revision": .object([
                        "type": .string("integer"),
                        "minimum": .number(0),
                    ]),
                ]),
            ]),
            "SMLRuntimeMetadata": .object([
                "type": .array([.string("object"), .string("array")]),
                "additionalProperties": .bool(true),
                "description": .string("Authority-neutral runtime descriptor payload."),
            ]),
        ]

        for endpoint in catalog.metadataEndpoints {
            var methods = pathObject(paths[endpoint.pathTemplate])
            methods[endpoint.method.rawValue.lowercased()] = .object(
                metadataOperation(endpoint)
            )
            paths[endpoint.pathTemplate] = .object(methods)
        }

        for workflow in catalog.workflows {
            schemas[inputSchemaName(workflow)] = .object(inputSchema(workflow))
            schemas[startBodySchemaName(workflow)] = .object(startBodySchema(workflow))
            for endpoint in workflow.api.endpoints {
                var methods = pathObject(paths[endpoint.pathTemplate])
                methods[endpoint.method.rawValue.lowercased()] = .object(
                    operation(endpoint, workflow: workflow)
                )
                paths[endpoint.pathTemplate] = .object(methods)
            }
        }

        let agentGuide = catalog.agentGuide
        let hostGuide = catalog.hostGuide
        return [
            "openapi": .string("3.1.0"),
            "info": .object([
                "title": .string(title),
                "version": .string(version),
            ]),
            "paths": .object(paths),
            "components": .object([
                "schemas": .object(schemas),
            ]),
            "x-sml-runtime": .object([
                "schemaVersion": .number(Decimal(catalog.schemaVersion)),
                "workflowIDs": .array(catalog.workflowIDs.map { .string($0) }),
                "mountContractSchemaVersion": .number(
                    Decimal(catalog.mountContract.schemaVersion)
                ),
                "mountAPIRouteCount": .number(Decimal(catalog.mountContract.apiRoutes.count)),
                "mountREPLCount": .number(Decimal(catalog.mountContract.replMounts.count)),
                "onyxDriverIDs": .array(catalog.onyxDrivers.map { .string($0.driverID) }),
                "modelToolNames": .array(catalog.modelTools.map { .string($0.tool.name) }),
                "modelRouterToolName": .string(catalog.modelRouter.tool.name),
                "modelRouterTool": .object(modelTool(catalog.modelRouter.tool)),
                "modelRouterMaximumCommandRounds": .number(
                    Decimal(catalog.modelRouter.maximumCommandRounds)
                ),
                "metadataEndpoints": .array(
                    catalog.metadataEndpoints.map(metadataEndpoint)
                ),
                "agentGuideSchemaVersion": .number(Decimal(agentGuide.schemaVersion)),
                "agentGuideWorkflowCount": .number(
                    Decimal(agentGuide.workflowGuides.count)
                ),
                "agentGuideModelRouterToolName": .string(agentGuide.modelRouterTool.name),
                "hostGuideSchemaVersion": .number(Decimal(hostGuide.schemaVersion)),
                "hostGuideWorkflowCount": .number(
                    Decimal(hostGuide.workflowBindings.count)
                ),
                "hostGuideBindingCount": .number(Decimal(hostGuide.hostBindingCount)),
                "planningManifestSchemaVersion": .number(
                    Decimal(catalog.planningManifest.schemaVersion)
                ),
                "planningWorkflowIDs": .array(
                    catalog.planningManifest.workflowIDs.map { .string($0) }
                ),
                "planningToolIndex": .array(
                    catalog.planningManifest.toolIndex.map(planningTool)
                ),
                "planningDecomposableUnits": .array(
                    catalog.planningManifest.decomposableUnits.map(decomposableUnit)
                ),
                "planningApprovalGates": .array(
                    catalog.planningManifest.approvalGates.map(approvalGate)
                ),
            ]),
        ]
    }

    private static func metadataOperation(
        _ endpoint: SMLWorkflowRuntimeMetadataEndpoint
    ) -> SMLObject {
        [
            "operationId": .string(endpoint.operationID),
            "summary": .string(endpoint.summary),
            "tags": .array([.string("sml-runtime")]),
            "responses": .object([
                "200": .object([
                    "description": .string("Authority-neutral SML runtime metadata."),
                    "content": .object([
                        "application/json": .object([
                            "schema": .object(reference("SMLRuntimeMetadata")),
                        ]),
                    ]),
                ]),
            ]),
            "x-sml-runtime-resource": .string(endpoint.resource.rawValue),
            "x-sml-read-only": .bool(true),
            "x-sml-authority": .string("descriptor-only"),
        ]
    }

    private static func operation(
        _ endpoint: SMLWorkflowAPIEndpoint,
        workflow: SMLWorkflowRuntimeDescriptor
    ) -> SMLObject {
        let statusCode = endpoint.action == .start ? "201" : "200"
        var object: SMLObject = [
            "operationId": .string(operationID(endpoint, workflow: workflow)),
            "summary": .string(endpoint.summary),
            "tags": .array([.string(workflow.workflowID)]),
            "responses": .object([
                statusCode: .object([
                    "description": .string("Admitted SML runtime result."),
                    "content": .object([
                        "application/json": .object([
                            "schema": .object(reference("SMLCommandResult")),
                        ]),
                    ]),
                ]),
            ]),
            "x-sml-action": .string(endpoint.action.rawValue),
            "x-sml-workflow-id": .string(workflow.workflowID),
            "x-sml-workflow-version": .string(workflow.workflowVersion),
            "x-sml-role": .string(workflow.role),
            "x-sml-model-tool": .string(workflow.model.tool.name),
            "x-sml-model-router-tool": .string(SMLWorkflowRuntimeModelAdapter.toolName),
            "x-sml-onyx-driver-id": .string(workflow.onyx.driverID),
        ]

        if endpoint.pathTemplate.contains("{task_id}") {
            object["parameters"] = .array([
                .object([
                    "name": .string("task_id"),
                    "in": .string("path"),
                    "required": .bool(true),
                    "schema": .object([
                        "type": .string("string"),
                    ]),
                ]),
            ])
        }

        switch endpoint.bodyKind {
        case .none:
            break
        case .startTask:
            object["requestBody"] = .object([
                "required": .bool(true),
                "content": .object([
                    "application/json": .object([
                        "schema": .object(reference(startBodySchemaName(workflow))),
                    ]),
                ]),
            ])
        case .expectedState:
            object["requestBody"] = .object([
                "required": .bool(true),
                "content": .object([
                    "application/json": .object([
                        "schema": .object(reference("SMLExpectedState")),
                    ]),
                ]),
            ])
        }
        return object
    }

    private static func startBodySchema(_ workflow: SMLWorkflowRuntimeDescriptor) -> SMLObject {
        var required: [SMLValue] = [.string("task_id")]
        if workflow.inputs.contains(where: \.required) {
            required.append(.string("input"))
        }
        return [
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array(required),
            "properties": .object([
                "task_id": .object([
                    "type": .string("string"),
                ]),
                "input": .object(reference(inputSchemaName(workflow))),
            ]),
        ]
    }

    private static func inputSchema(_ workflow: SMLWorkflowRuntimeDescriptor) -> SMLObject {
        var properties: SMLObject = [:]
        for field in workflow.inputs {
            properties[field.name] = .object(schema(for: field))
        }
        return [
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array(workflow.inputs.filter(\.required).map { .string($0.name) }),
            "properties": .object(properties),
        ]
    }

    private static func schema(for field: SMLWorkflowFieldDescriptor) -> SMLObject {
        var schema: SMLObject = [
            "type": .array(schemaTypes(for: field)),
        ]
        if let description = field.description {
            schema["description"] = .string(description)
        }
        return schema
    }

    private static func schemaTypes(for field: SMLWorkflowFieldDescriptor) -> [SMLValue] {
        var values: [SMLValue]
        switch field.type {
        case .string:
            values = [.string("string")]
        case .number:
            values = [.string("number")]
        case .integer:
            values = [.string("integer")]
        case .boolean:
            values = [.string("boolean")]
        case .object:
            values = [.string("object")]
        case .array:
            values = [.string("array")]
        }
        if field.nullable {
            values.append(.string("null"))
        }
        return values
    }

    private static func pathObject(_ value: SMLValue?) -> SMLObject {
        guard case .object(let object)? = value else { return [:] }
        return object
    }

    private static func modelTool(_ descriptor: SMLWorkflowModelToolDescriptor) -> SMLObject {
        [
            "name": .string(descriptor.name),
            "description": .string(descriptor.description),
            "parameters": .array(descriptor.parameters.map { parameter in
                .object([
                    "name": .string(parameter.name),
                    "type": .string(parameter.type),
                    "description": .string(parameter.description),
                    "required": .bool(parameter.required),
                ])
            }),
        ]
    }

    private static func metadataEndpoint(
        _ endpoint: SMLWorkflowRuntimeMetadataEndpoint
    ) -> SMLValue {
        .object([
            "method": .string(endpoint.method.rawValue),
            "pathTemplate": .string(endpoint.pathTemplate),
            "operationID": .string(endpoint.operationID),
            "resource": .string(endpoint.resource.rawValue),
            "summary": .string(endpoint.summary),
        ])
    }

    private static func planningTool(
        _ entry: SMLWorkflowRuntimePlanningToolIndexEntry
    ) -> SMLValue {
        var object: SMLObject = [
            "workflowID": .string(entry.workflowID),
            "instructionID": .string(entry.instructionID),
            "operation": .string(entry.operation.rawValue),
            "reference": .string(entry.reference),
            "statePreconditions": .array(entry.statePreconditions.map { .string($0) }),
            "declaredOutputs": .array(entry.declaredOutputs.map { .string($0) }),
        ]
        if let unitKind = entry.unitKind {
            object["unitKind"] = .string(unitKind.rawValue)
        }
        if let verifier = entry.verifier {
            object["verifier"] = .string(verifier)
        }
        if let sideEffectLevel = entry.sideEffectLevel {
            object["sideEffectLevel"] = .string(sideEffectLevel.rawValue)
        }
        return .object(object)
    }

    private static func decomposableUnit(
        _ unit: SMLWorkflowRuntimePlanningDecompositionUnit
    ) -> SMLValue {
        var object: SMLObject = [
            "workflowID": .string(unit.workflowID),
            "instructionID": .string(unit.instructionID),
            "unitKind": .string(unit.unitKind.rawValue),
            "successors": .array(unit.successors.map { .string($0) }),
        ]
        if let reference = unit.reference {
            object["reference"] = .string(reference)
        }
        return .object(object)
    }

    private static func approvalGate(
        _ gate: SMLWorkflowRuntimePlanningApprovalGate
    ) -> SMLValue {
        var object: SMLObject = [
            "workflowID": .string(gate.workflowID),
            "instructionID": .string(gate.instructionID),
            "statePreconditions": .array(gate.statePreconditions.map { .string($0) }),
            "successors": .array(gate.successors.map { .string($0) }),
        ]
        if let reference = gate.reference {
            object["reference"] = .string(reference)
        }
        return .object(object)
    }

    private static func reference(_ name: String) -> SMLObject {
        ["$ref": .string("#/components/schemas/\(name)")]
    }

    private static func inputSchemaName(_ workflow: SMLWorkflowRuntimeDescriptor) -> String {
        "WorkflowInput_\(componentSuffix(workflow))"
    }

    private static func startBodySchemaName(_ workflow: SMLWorkflowRuntimeDescriptor) -> String {
        "WorkflowStart_\(componentSuffix(workflow))"
    }

    private static func operationID(
        _ endpoint: SMLWorkflowAPIEndpoint,
        workflow: SMLWorkflowRuntimeDescriptor
    ) -> String {
        "\(endpoint.operationID)_\(componentSuffix(workflow))"
    }

    private static func componentSuffix(_ workflow: SMLWorkflowRuntimeDescriptor) -> String {
        workflow.workflowID
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

private extension Set where Element == SMLWorkflowControlAction {
    var stableOrder: [SMLWorkflowControlAction] {
        sorted { $0.rawValue < $1.rawValue }
    }
}
