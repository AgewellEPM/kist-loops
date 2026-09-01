import Foundation

public struct SMLWorkflowRuntimeMount: Sendable {
    public let admitted: SMLAdmittedWorkflow
    public let role: String
    public let actor: String
    public let replActions: Set<SMLWorkflowControlAction>?
    public let modelActions: Set<SMLWorkflowControlAction>
    public let apiBasePath: String
    public let apiWorkflowPath: String?
    public let modelMaximumCommandRounds: Int

    public init(
        admitted: SMLAdmittedWorkflow,
        role: String,
        actor: String,
        replActions: Set<SMLWorkflowControlAction>? = nil,
        modelActions: Set<SMLWorkflowControlAction> = SMLWorkflowSurface.modelDefaultActions,
        apiBasePath: String = "/v1",
        apiWorkflowPath: String? = nil,
        modelMaximumCommandRounds: Int = 4
    ) {
        self.admitted = admitted
        self.role = role
        self.actor = actor
        self.replActions = replActions
        self.modelActions = modelActions
        self.apiBasePath = apiBasePath
        self.apiWorkflowPath = apiWorkflowPath
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
    public let apiWorkflowPath: String?
    public let modelMaximumCommandRounds: Int

    public init(
        workflow: SMLWorkflow,
        admissionCatalog: SMLExecutionAdmissionCatalog,
        role: String,
        actor: String,
        replActions: Set<SMLWorkflowControlAction>? = nil,
        modelActions: Set<SMLWorkflowControlAction> = SMLWorkflowSurface.modelDefaultActions,
        apiBasePath: String = "/v1",
        apiWorkflowPath: String? = nil,
        modelMaximumCommandRounds: Int = 4
    ) {
        self.workflow = workflow
        self.admissionCatalog = admissionCatalog
        self.role = role
        self.actor = actor
        self.replActions = replActions
        self.modelActions = modelActions
        self.apiBasePath = apiBasePath
        self.apiWorkflowPath = apiWorkflowPath
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
            apiWorkflowPath: apiWorkflowPath,
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
        workflows.map { descriptor in
            let commandBindings = SMLWorkflowRuntimePlanningManifest.commandBindings(for: descriptor)
            guard descriptor.onyx.schemaVersion < SMLOnyxDriverManifest.currentSchemaVersion
                    || descriptor.onyx.commandBindings != commandBindings else {
                return descriptor.onyx
            }
            return descriptor.onyx.withCommandBindings(commandBindings)
        }
    }

    public var apiBasePaths: [String] {
        Array(Set(workflows.map(\.api.basePath))).sorted()
    }

    public var metadataEndpoints: [SMLWorkflowRuntimeMetadataEndpoint] {
        apiBasePaths.flatMap { basePath in
            SMLWorkflowRuntimeMetadataResource.allCases.map { resource in
                SMLWorkflowRuntimeMetadataEndpoint(
                    method: .get,
                    pathTemplate: "\(basePath)/runtime/\(resource.pathSuffix)",
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
    public let workflowMetadata: SMLWorkflowRuntimeWorkflowMetadataLinks

    public init(
        workflowID: String,
        workflowVersion: String,
        tool: SMLWorkflowModelToolDescriptor,
        allowedActions: [SMLWorkflowControlAction],
        maximumCommandRounds: Int,
        workflowMetadata: SMLWorkflowRuntimeWorkflowMetadataLinks? = nil
    ) {
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.tool = tool
        self.allowedActions = allowedActions
        self.maximumCommandRounds = maximumCommandRounds
        self.workflowMetadata = workflowMetadata ?? SMLWorkflowRuntimeWorkflowMetadataLinks(
            workflowID: workflowID,
            workflowVersion: workflowVersion,
            apiBasePath: "/v1"
        )
    }

    public init(_ descriptor: SMLWorkflowRuntimeDescriptor) {
        self.init(
            workflowID: descriptor.workflowID,
            workflowVersion: descriptor.workflowVersion,
            tool: descriptor.model.tool,
            allowedActions: descriptor.model.allowedActions,
            maximumCommandRounds: descriptor.model.maximumCommandRounds,
            workflowMetadata: SMLWorkflowRuntimeWorkflowMetadataLinks(descriptor)
        )
    }

    enum CodingKeys: String, CodingKey {
        case workflowID
        case workflowVersion
        case tool
        case allowedActions
        case maximumCommandRounds
        case workflowMetadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let workflowID = try container.decode(String.self, forKey: .workflowID)
        let workflowVersion = try container.decode(String.self, forKey: .workflowVersion)
        self.init(
            workflowID: workflowID,
            workflowVersion: workflowVersion,
            tool: try container.decode(SMLWorkflowModelToolDescriptor.self, forKey: .tool),
            allowedActions: try container.decode(
                [SMLWorkflowControlAction].self,
                forKey: .allowedActions
            ),
            maximumCommandRounds: try container.decode(Int.self, forKey: .maximumCommandRounds),
            workflowMetadata: try container.decodeIfPresent(
                SMLWorkflowRuntimeWorkflowMetadataLinks.self,
                forKey: .workflowMetadata
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workflowID, forKey: .workflowID)
        try container.encode(workflowVersion, forKey: .workflowVersion)
        try container.encode(tool, forKey: .tool)
        try container.encode(allowedActions, forKey: .allowedActions)
        try container.encode(maximumCommandRounds, forKey: .maximumCommandRounds)
        try container.encode(workflowMetadata, forKey: .workflowMetadata)
    }
}

public struct SMLWorkflowRuntimeWorkflowMetadataLinks: Sendable, Codable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let attachmentPath: String
    public let replMountPath: String
    public let apiMountPath: String
    public let modelToolPath: String
    public let onyxDriverPath: String
    public let skillTreePath: String
    public let toolBindingsPath: String
    public let planningBundlePath: String

    public init(
        workflowID: String,
        workflowVersion: String,
        apiBasePath: String,
        attachmentPath: String? = nil,
        replMountPath: String? = nil,
        apiMountPath: String? = nil,
        modelToolPath: String? = nil,
        onyxDriverPath: String? = nil,
        skillTreePath: String? = nil,
        toolBindingsPath: String? = nil,
        planningBundlePath: String? = nil
    ) {
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.attachmentPath = attachmentPath ?? Self.runtimeWorkflowPath(
            apiBasePath: apiBasePath,
            resourcePath: "attachments",
            workflowID: workflowID
        )
        self.replMountPath = replMountPath ?? Self.runtimeWorkflowPath(
            apiBasePath: apiBasePath,
            resourcePath: "repl-mounts",
            workflowID: workflowID
        )
        self.apiMountPath = apiMountPath ?? Self.runtimeWorkflowPath(
            apiBasePath: apiBasePath,
            resourcePath: "api-mounts",
            workflowID: workflowID
        )
        self.modelToolPath = modelToolPath ?? Self.runtimeWorkflowPath(
            apiBasePath: apiBasePath,
            resourcePath: "model-tools",
            workflowID: workflowID
        )
        self.onyxDriverPath = onyxDriverPath ?? Self.runtimeWorkflowPath(
            apiBasePath: apiBasePath,
            resourcePath: "onyx-drivers",
            workflowID: workflowID
        )
        self.skillTreePath = skillTreePath ?? Self.runtimeWorkflowPath(
            apiBasePath: apiBasePath,
            resourcePath: "skill-trees",
            workflowID: workflowID
        )
        self.toolBindingsPath = toolBindingsPath ?? Self.runtimeWorkflowPath(
            apiBasePath: apiBasePath,
            resourcePath: "tool-bindings",
            workflowID: workflowID
        )
        self.planningBundlePath = planningBundlePath ?? Self.runtimeWorkflowPath(
            apiBasePath: apiBasePath,
            resourcePath: "planning",
            workflowID: workflowID
        )
    }

    public init(_ descriptor: SMLWorkflowRuntimeDescriptor) {
        self.init(
            workflowID: descriptor.workflowID,
            workflowVersion: descriptor.workflowVersion,
            apiBasePath: descriptor.api.basePath
        )
    }

    private enum CodingKeys: String, CodingKey {
        case workflowID
        case workflowVersion
        case attachmentPath
        case replMountPath
        case apiMountPath
        case modelToolPath
        case onyxDriverPath
        case skillTreePath
        case toolBindingsPath
        case planningBundlePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let workflowID = try container.decode(String.self, forKey: .workflowID)
        let workflowVersion = try container.decode(String.self, forKey: .workflowVersion)
        let attachmentPath = try container.decode(String.self, forKey: .attachmentPath)
        let apiBasePath = Self.apiBasePath(fromRuntimeWorkflowPath: attachmentPath)
        self.init(
            workflowID: workflowID,
            workflowVersion: workflowVersion,
            apiBasePath: apiBasePath,
            attachmentPath: attachmentPath,
            replMountPath: try container.decodeIfPresent(String.self, forKey: .replMountPath),
            apiMountPath: try container.decodeIfPresent(String.self, forKey: .apiMountPath),
            modelToolPath: try container.decodeIfPresent(String.self, forKey: .modelToolPath),
            onyxDriverPath: try container.decodeIfPresent(String.self, forKey: .onyxDriverPath),
            skillTreePath: try container.decodeIfPresent(String.self, forKey: .skillTreePath),
            toolBindingsPath: try container.decodeIfPresent(String.self, forKey: .toolBindingsPath),
            planningBundlePath: try container.decodeIfPresent(String.self, forKey: .planningBundlePath)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workflowID, forKey: .workflowID)
        try container.encode(workflowVersion, forKey: .workflowVersion)
        try container.encode(attachmentPath, forKey: .attachmentPath)
        try container.encode(replMountPath, forKey: .replMountPath)
        try container.encode(apiMountPath, forKey: .apiMountPath)
        try container.encode(modelToolPath, forKey: .modelToolPath)
        try container.encode(onyxDriverPath, forKey: .onyxDriverPath)
        try container.encode(skillTreePath, forKey: .skillTreePath)
        try container.encode(toolBindingsPath, forKey: .toolBindingsPath)
        try container.encode(planningBundlePath, forKey: .planningBundlePath)
    }

    private static func apiBasePath(fromRuntimeWorkflowPath path: String) -> String {
        guard let range = path.range(of: "/runtime/") else { return "/v1" }
        return String(path[..<range.lowerBound])
    }

    private static func runtimeWorkflowPath(
        apiBasePath: String,
        resourcePath: String,
        workflowID: String
    ) -> String {
        "\(apiBasePath)/runtime/\(resourcePath)/\(workflowID)"
    }
}

public struct SMLWorkflowRuntimeModelRouterDescriptor: Sendable, Codable, Equatable {
    public let requiresNativeTools: Bool
    public let tool: SMLWorkflowModelToolDescriptor
    public let workflowIDs: [String]
    public let workflowMetadata: [SMLWorkflowRuntimeWorkflowMetadataLinks]
    public let maximumAdvisoryBytes: Int
    public let maximumCommandRounds: Int
    public let examples: [SMLWorkflowRuntimeModelToolCallExample]

    public init(
        requiresNativeTools: Bool = true,
        tool: SMLWorkflowModelToolDescriptor,
        workflowIDs: [String],
        workflowMetadata: [SMLWorkflowRuntimeWorkflowMetadataLinks] = [],
        maximumAdvisoryBytes: Int,
        maximumCommandRounds: Int,
        examples: [SMLWorkflowRuntimeModelToolCallExample] = []
    ) {
        self.requiresNativeTools = requiresNativeTools
        self.tool = tool
        self.workflowIDs = workflowIDs.sorted()
        self.workflowMetadata = workflowMetadata.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.workflowVersion < $1.workflowVersion
        }
        self.maximumAdvisoryBytes = max(0, maximumAdvisoryBytes)
        self.maximumCommandRounds = min(max(1, maximumCommandRounds), 8)
        self.examples = examples.sorted {
            if ($0.workflowID ?? "") != ($1.workflowID ?? "") {
                return ($0.workflowID ?? "") < ($1.workflowID ?? "")
            }
            if $0.line != $1.line { return $0.line < $1.line }
            if $0.toolName != $1.toolName { return $0.toolName < $1.toolName }
            return $0.summary < $1.summary
        }
    }

    enum CodingKeys: String, CodingKey {
        case requiresNativeTools
        case tool
        case workflowIDs
        case workflowMetadata
        case maximumAdvisoryBytes
        case maximumCommandRounds
        case examples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            requiresNativeTools: try container.decode(Bool.self, forKey: .requiresNativeTools),
            tool: try container.decode(SMLWorkflowModelToolDescriptor.self, forKey: .tool),
            workflowIDs: try container.decode([String].self, forKey: .workflowIDs),
            workflowMetadata: try container.decodeIfPresent(
                [SMLWorkflowRuntimeWorkflowMetadataLinks].self,
                forKey: .workflowMetadata
            ) ?? [],
            maximumAdvisoryBytes: try container.decode(Int.self, forKey: .maximumAdvisoryBytes),
            maximumCommandRounds: try container.decode(Int.self, forKey: .maximumCommandRounds),
            examples: try container.decodeIfPresent(
                [SMLWorkflowRuntimeModelToolCallExample].self,
                forKey: .examples
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requiresNativeTools, forKey: .requiresNativeTools)
        try container.encode(tool, forKey: .tool)
        try container.encode(workflowIDs, forKey: .workflowIDs)
        try container.encode(workflowMetadata, forKey: .workflowMetadata)
        try container.encode(maximumAdvisoryBytes, forKey: .maximumAdvisoryBytes)
        try container.encode(maximumCommandRounds, forKey: .maximumCommandRounds)
        try container.encode(examples, forKey: .examples)
    }
}

/// Portable, authority-neutral payload a host can serve to API/model/Onyx front ends.
///
/// The OpenAPI document is emitted as closed `SMLValue` JSON rather than `[String: Any]`, so callers
/// can persist, diff, and sign the exact API shape without gaining runtime authority.
public struct SMLWorkflowRuntimeExport: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 27

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
    public let hostWiring: SMLWorkflowRuntimeHostWiring

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
        hostGuide: SMLWorkflowRuntimeHostGuide? = nil,
        hostWiring: SMLWorkflowRuntimeHostWiring? = nil
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
        self.hostWiring = hostWiring ?? catalog.hostWiring
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, catalog, mountContract, openAPI, modelTools, modelRouter,
             onyxDrivers, planning, agentGuide, hostGuide, hostWiring
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        schemaVersion = decodedSchemaVersion
        catalog = try container.decode(SMLWorkflowRuntimeCatalog.self, forKey: .catalog)
        let decodedMountContract = try container.decodeIfPresent(
            SMLWorkflowRuntimeMountContract.self, forKey: .mountContract
        )
        mountContract = decodedMountContract.flatMap {
            $0.schemaVersion < SMLWorkflowRuntimeMountContract.currentSchemaVersion ? nil : $0
        } ?? catalog.mountContract
        let decodedOpenAPI = try container.decode(SMLObject.self, forKey: .openAPI)
        openAPI = decodedSchemaVersion < SMLWorkflowRuntimeExport.currentSchemaVersion
            ? Self.regeneratedOpenAPI(from: decodedOpenAPI, catalog: catalog)
            : decodedOpenAPI
        let decodedModelTools = try container.decode(
            [SMLWorkflowRuntimeModelToolExport].self, forKey: .modelTools
        )
        modelTools = decodedSchemaVersion < SMLWorkflowRuntimeExport.currentSchemaVersion
            ? catalog.modelTools
            : decodedModelTools
        let decodedModelRouter = try container.decodeIfPresent(
            SMLWorkflowRuntimeModelRouterDescriptor.self, forKey: .modelRouter
        )
        modelRouter = decodedSchemaVersion < SMLWorkflowRuntimeExport.currentSchemaVersion
            ? catalog.modelRouter
            : decodedModelRouter ?? catalog.modelRouter
        let decodedOnyxDrivers = try container.decode(
            [SMLOnyxDriverManifest].self,
            forKey: .onyxDrivers
        )
        onyxDrivers = decodedSchemaVersion < SMLWorkflowRuntimeExport.currentSchemaVersion
            ? catalog.onyxDrivers
            : decodedOnyxDrivers
        let decodedPlanning = try container.decodeIfPresent(
            SMLWorkflowRuntimePlanningManifest.self, forKey: .planning
        )
        planning = decodedPlanning.flatMap {
            $0.schemaVersion < SMLWorkflowRuntimePlanningManifest.currentSchemaVersion ? nil : $0
        } ?? catalog.planningManifest
        let decodedAgentGuide = try container.decodeIfPresent(
            SMLWorkflowRuntimeAgentGuide.self, forKey: .agentGuide
        )
        agentGuide = decodedAgentGuide.flatMap {
            $0.schemaVersion < SMLWorkflowRuntimeAgentGuide.currentSchemaVersion ? nil : $0
        } ?? catalog.agentGuide
        let decodedHostGuide = try container.decodeIfPresent(
            SMLWorkflowRuntimeHostGuide.self, forKey: .hostGuide
        )
        hostGuide = decodedHostGuide.flatMap {
            $0.schemaVersion < SMLWorkflowRuntimeHostGuide.currentSchemaVersion ? nil : $0
        } ?? catalog.hostGuide
        let decodedHostWiring = try container.decodeIfPresent(
            SMLWorkflowRuntimeHostWiring.self, forKey: .hostWiring
        )
        hostWiring = decodedHostWiring.flatMap {
            $0.schemaVersion < SMLWorkflowRuntimeHostWiring.currentSchemaVersion ? nil : $0
        } ?? catalog.hostWiring
    }

    private static func regeneratedOpenAPI(
        from decodedOpenAPI: SMLObject,
        catalog: SMLWorkflowRuntimeCatalog
    ) -> SMLObject {
        let info = object(decodedOpenAPI["info"])
        return catalog.openAPIDocument(
            title: string(info["title"]) ?? "SML Workflow Runtime API",
            version: string(info["version"]) ?? "1.0.0"
        )
    }

    private static func object(_ value: SMLValue?) -> SMLObject {
        guard case .object(let object) = value else { return [:] }
        return object
    }

    private static func string(_ value: SMLValue?) -> String? {
        guard case .string(let string) = value else { return nil }
        return string
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
            workflowMetadata: workflows.map(SMLWorkflowRuntimeWorkflowMetadataLinks.init),
            maximumAdvisoryBytes: SMLWorkflowModelAdapter.maximumAdvisoryBytes,
            maximumCommandRounds: workflows
                .map(\.model.maximumCommandRounds)
                .max() ?? 1,
            examples: modelRouterExamples
        )
    }

    private var modelRouterExamples: [SMLWorkflowRuntimeModelToolCallExample] {
        workflows.flatMap { descriptor in
            let allowedActions = Set(descriptor.model.allowedActions)
            let modelVerbs = Set(descriptor.repl.commands.compactMap { command -> String? in
                guard command.kind == .runtime,
                      let action = command.action,
                      allowedActions.contains(action) else { return nil }
                return command.verb
            })
            return descriptor.repl.examples
                .filter { modelVerbs.contains($0.verb) }
                .map {
                    SMLWorkflowRuntimeModelToolCallExample(
                        toolName: SMLWorkflowRuntimeModelAdapter.toolName,
                        workflowID: descriptor.workflowID,
                        line: $0.line,
                        summary: $0.summary
                    )
                }
        }
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
            hostGuide: hostGuide,
            hostWiring: hostWiring
        )
    }
}

