import Foundation

public struct SMLWorkflowRuntimeAPI: Sendable {
    public typealias AuthorityResolver = @Sendable (
        _ command: SMLCommandEnvelope
    ) async throws -> SMLCommandAuthority

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

    public var catalog: SMLWorkflowRuntimeCatalog {
        registry.catalog
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
        let resolved = try registry.resolveMount(for: request)
        guard resolved.route.handlerKind == .metadata,
              let resource = resolved.route.metadataResource else {
            throw SMLWorkflowRuntimeRegistryError.routeNotFound(
                method: request.method.rawValue,
                path: request.path
            )
        }
        return try SMLWorkflowRuntimeMetadataResponse(
            resource: resource,
            path: request.path,
            body: metadataPayload(
                for: resource,
                pathParameters: resolved.pathParameters
            )
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
                body: metadataPayload(
                    for: resource,
                    pathParameters: resolved.pathParameters
                )
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

    /// The operator queue exposes the same tasks as the generated watch command.
    public func pendingView(from snapshot: SMLRuntimeSnapshot) async -> SMLRuntimePendingView {
        var visible = snapshot
        visible.tasks = [:]
        let now = clock()
        for task in snapshot.tasks.values {
            do {
                let bundle = try registry.bundle(workflowID: task.workflowID)
                let command = try SMLWorkflowCommandCompiler(surface: bundle.surface, actor: bundle.actor)
                    .compile(action: .watch, task: task.taskID, issuedAtEpoch: now)
                guard command.role == task.role else { continue }
                let authority = try await authorityResolver(command)
                try SMLCommandAdmission.preflight(command, authority: authority, nowEpoch: now)
                visible.tasks[task.taskID] = task
            } catch {
                continue
            }
        }
        return SMLRuntimePendingView.build(from: visible)
    }

    private func metadataPayload(
        for resource: SMLWorkflowRuntimeMetadataResource,
        pathParameters: [String: String] = [:]
    ) throws -> SMLValue {
        switch resource {
        case .catalog:
            return try SMLWorkflowRuntimePayloadCodec.encode(registry.catalog)
        case .mount:
            return try SMLWorkflowRuntimePayloadCodec.encode(registry.mountContract)
        case .launch:
            return try SMLWorkflowRuntimePayloadCodec.encode(
                launchDescriptor ?? SMLWorkflowRuntimeLaunchDescriptor(
                    registry: registry,
                    installedWorkflows: []
                )
            )
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
        case .hostWiring:
            return try SMLWorkflowRuntimePayloadCodec.encode(registry.catalog.hostWiring)
        case .attachments:
            return try SMLWorkflowRuntimePayloadCodec.encode(registry.catalog.hostWiring.attachmentManifests)
        case .workflowAttachment:
            let attachment = try workflowAttachment(
                from: pathParameters,
                resource: resource
            )
            return try SMLWorkflowRuntimePayloadCodec.encode(attachment)
        case .workflowREPLMount:
            let attachment = try workflowAttachment(
                from: pathParameters,
                resource: resource
            )
            return try SMLWorkflowRuntimePayloadCodec.encode(attachment.replMount)
        case .workflowAPIMount:
            let attachment = try workflowAttachment(
                from: pathParameters,
                resource: resource
            )
            return try SMLWorkflowRuntimePayloadCodec.encode(attachment.apiRoutes)
        case .workflowModelTool:
            let workflowID = try workflowID(from: pathParameters, resource: resource)
            return try SMLWorkflowRuntimePayloadCodec.encode(
                SMLWorkflowRuntimeModelToolExport(
                    registry.descriptor(workflowID: workflowID)
                )
            )
        case .workflowOnyxDriver:
            let workflowID = try workflowID(from: pathParameters, resource: resource)
            guard let driver = registry.catalog.onyxDrivers.first(where: {
                $0.workflowID == workflowID
            }) else {
                throw SMLWorkflowRuntimeRegistryError.unknownWorkflow(workflowID)
            }
            return try SMLWorkflowRuntimePayloadCodec.encode(driver)
        case .workflowSkillTree:
            let attachment = try workflowAttachment(
                from: pathParameters,
                resource: resource
            )
            return try SMLWorkflowRuntimePayloadCodec.encode(attachment.skillTree)
        case .workflowToolBindings:
            let attachment = try workflowAttachment(
                from: pathParameters,
                resource: resource
            )
            return try SMLWorkflowRuntimePayloadCodec.encode(attachment.toolBindings)
        case .workflowPlanning:
            let workflowID = try workflowID(from: pathParameters, resource: resource)
            let planning = registry.planningManifest
            guard let workflow = planning.workflows.first(where: {
                $0.workflowID == workflowID
            }) else {
                throw SMLWorkflowRuntimeRegistryError.unknownWorkflow(workflowID)
            }
            let bundle = SMLWorkflowRuntimePlanningWorkflowBundle(
                workflow: workflow,
                skillIndex: planning.skillIndex.filter { $0.workflowID == workflowID },
                toolIndex: planning.toolIndex.filter { $0.workflowID == workflowID },
                decomposableUnits: planning.decomposableUnits.filter {
                    $0.workflowID == workflowID
                },
                approvalGates: planning.approvalGates.filter { $0.workflowID == workflowID },
                commandBindings: planning.commandBindings.filter {
                    $0.workflowID == workflowID
                }
            )
            return try SMLWorkflowRuntimePayloadCodec.encode(bundle)
        case .modelRouter:
            return try SMLWorkflowRuntimePayloadCodec.encode(registry.catalog.modelRouter)
        case .onyxDrivers:
            return try SMLWorkflowRuntimePayloadCodec.encode(registry.catalog.onyxDrivers)
        }
    }

    private func workflowAttachment(
        from pathParameters: [String: String],
        resource: SMLWorkflowRuntimeMetadataResource
    ) throws -> SMLWorkflowRuntimeWorkflowAttachmentManifest {
        let workflowID = try workflowID(from: pathParameters, resource: resource)
        guard let attachment = registry.catalog.hostWiring.attachmentManifests.first(where: {
            $0.workflowID == workflowID
        }) else {
            throw SMLWorkflowRuntimeRegistryError.unknownWorkflow(workflowID)
        }
        return attachment
    }

    private func workflowID(
        from pathParameters: [String: String],
        resource: SMLWorkflowRuntimeMetadataResource
    ) throws -> String {
        guard let workflowID = pathParameters["workflow_id"] else {
            throw SMLWorkflowRuntimeRegistryError.routeNotFound(
                method: "GET",
                path: registry.catalog.apiBasePaths.first.map {
                    "\($0)/runtime/\(resource.pathSuffix)"
                } ?? resource.pathSuffix
            )
        }
        return workflowID
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

private enum SMLWorkflowRuntimePayloadCodec {
    static func encode<T: Encodable>(_ value: T) throws -> SMLValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(SMLValue.self, from: data)
    }
}
