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

/// Portable, authority-neutral payload a host can serve to API/model/Onyx front ends.
///
/// The OpenAPI document is emitted as closed `SMLValue` JSON rather than `[String: Any]`, so callers
/// can persist, diff, and sign the exact API shape without gaining runtime authority.
public struct SMLWorkflowRuntimeExport: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let catalog: SMLWorkflowRuntimeCatalog
    public let openAPI: SMLObject
    public let modelTools: [SMLWorkflowRuntimeModelToolExport]
    public let modelRouter: SMLWorkflowRuntimeModelRouterDescriptor
    public let onyxDrivers: [SMLOnyxDriverManifest]

    public init(
        schemaVersion: Int = SMLWorkflowRuntimeExport.currentSchemaVersion,
        catalog: SMLWorkflowRuntimeCatalog,
        openAPI: SMLObject,
        modelTools: [SMLWorkflowRuntimeModelToolExport],
        modelRouter: SMLWorkflowRuntimeModelRouterDescriptor,
        onyxDrivers: [SMLOnyxDriverManifest]
    ) {
        self.schemaVersion = schemaVersion
        self.catalog = catalog
        self.openAPI = openAPI
        self.modelTools = modelTools
        self.modelRouter = modelRouter
        self.onyxDrivers = onyxDrivers
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, catalog, openAPI, modelTools, modelRouter, onyxDrivers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        catalog = try container.decode(SMLWorkflowRuntimeCatalog.self, forKey: .catalog)
        openAPI = try container.decode(SMLObject.self, forKey: .openAPI)
        modelTools = try container.decode(
            [SMLWorkflowRuntimeModelToolExport].self, forKey: .modelTools
        )
        modelRouter = try container.decodeIfPresent(
            SMLWorkflowRuntimeModelRouterDescriptor.self, forKey: .modelRouter
        ) ?? catalog.modelRouter
        onyxDrivers = try container.decode([SMLOnyxDriverManifest].self, forKey: .onyxDrivers)
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
            openAPI: openAPIDocument(title: title, version: version),
            modelTools: modelTools,
            modelRouter: modelRouter,
            onyxDrivers: onyxDrivers
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
        let bundle = try routeBundle(for: request)
        return try bundle.apiCompiler.compile(request, issuedAtEpoch: issuedAtEpoch)
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

    private func routeBundle(
        for request: SMLWorkflowAPIRequest
    ) throws -> SMLWorkflowRuntimeBundle {
        let segments = try pathSegments(request.path)
        let matches = bundles.filter { bundle in
            let baseSegments = bundle.descriptor.api.basePath
                .split(separator: "/")
                .map(String.init)
            guard segments.starts(with: baseSegments) else { return false }
            let tail = Array(segments.dropFirst(baseSegments.count))
            return tail.count >= 2
                && tail[0] == "workflows"
                && tail[1] == bundle.surface.workflowID
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            throw SMLWorkflowRuntimeRegistryError.ambiguousAPIRoute(
                method: request.method.rawValue,
                path: request.path
            )
        }
        throw SMLWorkflowRuntimeRegistryError.routeNotFound(
            method: request.method.rawValue,
            path: request.path
        )
    }

    private func pathSegments(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"),
              !path.contains("?"),
              !path.contains("#"),
              !path.contains("//"),
              !path.contains("%"),
              !path.split(separator: "/").contains("..") else {
            throw SMLWorkflowRuntimeRegistryError.invalidAPIPath(path)
        }
        return path.split(separator: "/").map(String.init)
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

    public func handle(_ request: SMLWorkflowAPIRequest) async throws -> SMLWorkflowAPIResponse {
        let now = clock()
        let command = try registry.compileAPI(request, issuedAtEpoch: now)
        let authority = try await authorityResolver(command)
        let result = try await gateway.submit(command, authority: authority, nowEpoch: now)
        let status = command.op == SMLRuntimeCommandOperation.workflowRun ? 201 : 200
        return SMLWorkflowAPIResponse(statusCode: status, command: command, result: result)
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
        """
        You are operating a mounted SML workflow runtime.
        Your prose is advisory and never proves completion. To request a state transition, call
        \(Self.toolName) exactly once with a mounted workflow_id and one line from that workflow's
        grammar. Never call an unlisted command, never claim a capability step passed, and never
        fabricate a receipt.

        Mounted workflow catalog:
        \(workflowCatalogPrompt)
        """
    }

    private var workflowCatalogPrompt: String {
        registry.catalog.workflows.map { workflow in
            """
            \(workflow.workflowID)@\(workflow.workflowVersion) — \(workflow.workflowName)
            \(workflow.schemaSummary)
            Workflow graph:
            \(workflow.graphSummary)
            Allowed grammar:
            \(workflow.repl.grammar)
            """
        }.joined(separator: "\n\n")
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

    public var catalog: SMLWorkflowRuntimeCatalog { registry.catalog }

    public var workflowIDs: [String] { registry.workflowIDs }

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
        ]

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
                "onyxDriverIDs": .array(catalog.onyxDrivers.map { .string($0.driverID) }),
                "modelToolNames": .array(catalog.modelTools.map { .string($0.tool.name) }),
                "modelRouterToolName": .string(catalog.modelRouter.tool.name),
                "modelRouterTool": .object(modelTool(catalog.modelRouter.tool)),
                "modelRouterMaximumCommandRounds": .number(
                    Decimal(catalog.modelRouter.maximumCommandRounds)
                ),
            ]),
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
