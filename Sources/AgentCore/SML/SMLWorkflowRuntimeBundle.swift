import Foundation

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
        apiWorkflowPath: String? = nil,
        modelMaximumCommandRounds: Int = 4,
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() }
    ) throws -> SMLWorkflowRuntimeBundle {
        let surface = try SMLWorkflowSurface.compile(admitted: admitted, role: role)
        let apiCompiler = try SMLWorkflowAPICompiler(
            surface: surface,
            actor: actor,
            basePath: apiBasePath,
            workflowPath: apiWorkflowPath,
            commandID: commandID
        )
        let baseOnyxDriver = SMLOnyxDriverCompiler.compile(
            surface: surface,
            modelActions: modelActions,
            apiBasePath: apiBasePath,
            apiWorkflowPath: apiCompiler.catalog.workflowPath
        )
        let modelTool = SMLWorkflowModelToolDescriptor(
            surface.modelCommandTool(allowedActions: modelActions)
        )
        let replAllowedActions = replActions ?? Set(SMLWorkflowControlAction.allCases)
        let replCommands = surface.replCommandDescriptors(allowedActions: replAllowedActions)
        let replExamples = surface.replExamples(allowedActions: replAllowedActions)
        let commandBindings = SMLWorkflowRuntimePlanningManifest.commandBindings(
            workflowID: surface.workflowID,
            workflowVersion: surface.workflowVersion,
            replCommands: replCommands,
            replExamples: replExamples,
            apiEndpoints: apiCompiler.catalog.endpoints,
            modelAllowedActions: modelActions.stableOrder,
            modelToolName: modelTool.name
        )
        let onyxDriver = baseOnyxDriver.withCommandBindings(commandBindings)
        let replCompiler = SMLWorkflowREPLCompiler(
            surface: surface,
            actor: actor,
            allowedActions: replAllowedActions,
            apiCatalog: apiCompiler.catalog,
            modelTool: modelTool,
            modelAllowedActions: modelActions,
            modelMaximumCommandRounds: modelMaximumCommandRounds,
            modelRouterToolName: SMLWorkflowRuntimeModelAdapter.toolName,
            onyxDriver: onyxDriver,
            commandID: commandID,
            taskID: taskID
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
                helpText: replCompiler.helpText,
                commands: replCommands,
                examples: replExamples
            ),
            api: apiCompiler.catalog,
            model: SMLWorkflowModelDescriptor(
                requiresNativeTools: true,
                allowedActions: modelActions.stableOrder,
                tool: modelTool,
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
            apiBasePath: descriptor.api.basePath,
            apiWorkflowPath: descriptor.api.workflowPath,
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

private extension Set where Element == SMLWorkflowControlAction {
    var stableOrder: [SMLWorkflowControlAction] {
        sorted { $0.rawValue < $1.rawValue }
    }
}
