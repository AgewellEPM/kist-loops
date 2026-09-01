import Foundation

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
    public let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor?
    private let clock: @Sendable () -> Double

    public init(
        registry: SMLWorkflowRuntimeRegistry,
        gateway: SMLCommandGateway,
        authorityResolver: @escaping AuthorityResolver,
        launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor? = nil,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.registry = registry
        self.gateway = gateway
        self.authorityResolver = authorityResolver
        self.launchDescriptor = launchDescriptor
        self.clock = clock
    }

    public static func launch(
        registry: SMLWorkflowRuntimeRegistry,
        runtime: SMLRuntime,
        replayGuard: any SMLCommandReplayGuard,
        authorityResolver: @escaping AuthorityResolver,
        sourcePackage: SMLWorkflowRuntimeSourcePackage? = nil,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) async throws -> SMLWorkflowRuntimeLaunch {
        if let sourcePackage {
            try requireSourcePackage(sourcePackage, matches: registry)
        }
        let installed = try await registry.installAll(into: runtime)
        let launchDescriptor = SMLWorkflowRuntimeLaunchDescriptor(
            registry: registry,
            installedWorkflows: installed,
            sourcePackage: sourcePackage
        )
        let app = registry.makeApp(
            gateway: SMLCommandGateway(runtime: runtime, replayGuard: replayGuard),
            authorityResolver: authorityResolver,
            launchDescriptor: launchDescriptor,
            clock: clock
        )
        return SMLWorkflowRuntimeLaunch(
            registry: registry,
            app: app,
            installedWorkflows: installed,
            sourcePackage: sourcePackage
        )
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
        try await launch(
            registry: try SMLWorkflowRuntimeRegistry.compile(
                mounts: mounts,
                commandID: commandID,
                taskID: taskID
            ),
            runtime: runtime,
            replayGuard: replayGuard,
            authorityResolver: authorityResolver,
            clock: clock
        )
    }

    private static func requireSourcePackage(
        _ sourcePackage: SMLWorkflowRuntimeSourcePackage,
        matches registry: SMLWorkflowRuntimeRegistry
    ) throws {
        guard sourcePackage.workflowIDs == registry.workflowIDs else {
            throw SMLWorkflowRuntimeSourcePackageError.runtimeExportMismatch(
                field: "launch.registry.workflowIDs",
                expected: sourcePackage.workflowIDs,
                actual: registry.workflowIDs
            )
        }
        let sourceByWorkflowID = Dictionary(
            uniqueKeysWithValues: sourcePackage.normalizedWorkflows.map { ($0.id, $0) }
        )
        for descriptor in registry.catalog.workflows {
            guard let workflow = sourceByWorkflowID[descriptor.workflowID] else {
                throw SMLWorkflowRuntimeSourcePackageError.runtimeExportMismatch(
                    field: "launch.registry.workflowIDs",
                    expected: sourcePackage.workflowIDs,
                    actual: registry.workflowIDs
                )
            }
            try require(
                descriptor.workflowVersion,
                equals: workflow.version,
                workflowID: workflow.id,
                field: "launch.registry.workflowVersion"
            )
            try require(
                descriptor.workflowName,
                equals: workflow.name,
                workflowID: workflow.id,
                field: "launch.registry.workflowName"
            )
            try require(
                descriptor.sourceKind.rawValue,
                equals: workflow.source.kind.rawValue,
                workflowID: workflow.id,
                field: "launch.registry.sourceKind"
            )
            try require(
                descriptor.sourceReference,
                equals: workflow.source.reference,
                workflowID: workflow.id,
                field: "launch.registry.sourceReference"
            )
            try require(
                descriptor.sourceDigest ?? "",
                equals: workflow.source.digest ?? "",
                workflowID: workflow.id,
                field: "launch.registry.sourceDigest"
            )
        }
    }

    private static func require(
        _ actual: String,
        equals expected: String,
        workflowID: String,
        field: String
    ) throws {
        guard actual == expected else {
            throw SMLWorkflowRuntimeSourcePackageError.runtimeWorkflowMismatch(
                workflowID: workflowID,
                field: field,
                expected: expected,
                actual: actual
            )
        }
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

    public var hostWiring: SMLWorkflowRuntimeHostWiring {
        registry.hostWiring
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
            launchDescriptor: launchDescriptor,
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

