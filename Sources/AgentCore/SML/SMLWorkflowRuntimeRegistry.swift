import Foundation

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
        let catalog = SMLWorkflowRuntimeCatalog(workflows: ordered.map(\.descriptor))
        try Self.requireUniqueGeneratedAPIRoutes(catalog.mountContract.apiRoutes)
        self.bundles = ordered
        bundlesByWorkflowID = byID
        self.catalog = catalog
    }

    private static func requireUniqueGeneratedAPIRoutes(
        _ routes: [SMLWorkflowRuntimeAPIMount]
    ) throws {
        var seenRoutes: Set<String> = []
        for route in routes.sorted(by: Self.routeSort) {
            let key = "\(route.method.rawValue)\u{0}\(route.pathTemplate)"
            guard seenRoutes.insert(key).inserted else {
                throw SMLWorkflowRuntimeRegistryError.ambiguousAPIRoute(
                    method: route.method.rawValue,
                    path: route.pathTemplate
                )
            }
        }
    }

    private static func routeSort(
        lhs: SMLWorkflowRuntimeAPIMount,
        rhs: SMLWorkflowRuntimeAPIMount
    ) -> Bool {
        if lhs.pathTemplate != rhs.pathTemplate {
            return lhs.pathTemplate < rhs.pathTemplate
        }
        if lhs.method.rawValue != rhs.method.rawValue {
            return lhs.method.rawValue < rhs.method.rawValue
        }
        return lhs.operationID < rhs.operationID
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
                apiWorkflowPath: mount.apiWorkflowPath,
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
                    apiWorkflowPath: nil,
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
                    apiWorkflowPath: nil,
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

    public var hostWiring: SMLWorkflowRuntimeHostWiring {
        catalog.hostWiring
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
        launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor? = nil,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) -> SMLWorkflowRuntimeAPI {
        SMLWorkflowRuntimeAPI(
            registry: self,
            gateway: gateway,
            authorityResolver: authorityResolver,
            launchDescriptor: launchDescriptor,
            clock: clock
        )
    }

    public func makeApp(
        gateway: SMLCommandGateway,
        authorityResolver: @escaping SMLWorkflowRuntimeAPI.AuthorityResolver,
        launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor? = nil,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) -> SMLWorkflowRuntimeApp {
        SMLWorkflowRuntimeApp(
            registry: self,
            gateway: gateway,
            authorityResolver: authorityResolver,
            launchDescriptor: launchDescriptor,
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

