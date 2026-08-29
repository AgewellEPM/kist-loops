import Foundation

/// Compact, descriptor-only wiring map for host adapters.
///
/// `SMLWorkflowRuntimeHostGuide` is the fuller installation guide. This value is the small,
/// machine-readable map a dashboard, CLI adapter, HTTP router, model host, or Onyx bridge can read
/// to wire REPL/API/model-router/Onyx/planning surfaces without walking the whole runtime export.
/// It carries no actor, lease, credential, provider registry, gateway, replay guard, runtime handle,
/// executable closure, or completion authority.
public struct SMLWorkflowRuntimeWorkflowAttachmentManifest: Sendable, Codable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let workflowName: String
    public let role: String
    public let sourceKind: SMLWorkflowSourceKind
    public let sourceReference: String
    public let sourceDigest: String?
    public let apiBasePath: String
    public let channels: [SMLWorkflowRuntimeHostBindingChannel]
    public let replMount: SMLWorkflowRuntimeREPLMount
    public let replExamples: [SMLWorkflowREPLExample]
    public let apiRoutes: [SMLWorkflowRuntimeAPIMount]
    public let apiExamples: [SMLWorkflowAPIRequestExample]
    public let modelToolName: String
    public let modelRouterToolName: String
    public let modelToolExamples: [SMLWorkflowRuntimeModelToolCallExample]
    public let modelRouterExamples: [SMLWorkflowRuntimeModelToolCallExample]
    public let onyxDriverID: String
    public let planningWorkflowID: String?
    public let plannerEntrypoint: String?
    public let toolReferences: [String]
    public let decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit]
    public let approvalGates: [SMLWorkflowRuntimePlanningApprovalGate]

    public init(
        workflowID: String,
        workflowVersion: String,
        workflowName: String,
        role: String,
        sourceKind: SMLWorkflowSourceKind,
        sourceReference: String,
        sourceDigest: String?,
        apiBasePath: String,
        replMount: SMLWorkflowRuntimeREPLMount,
        apiRoutes: [SMLWorkflowRuntimeAPIMount],
        modelToolName: String,
        modelRouterToolName: String,
        onyxDriverID: String,
        planningWorkflowID: String?,
        plannerEntrypoint: String?,
        toolReferences: [String],
        decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit],
        approvalGates: [SMLWorkflowRuntimePlanningApprovalGate],
        hostBindings: [SMLWorkflowRuntimeHostBinding]
    ) {
        let sortedAPIRoutes = apiRoutes.sorted {
            if $0.pathTemplate != $1.pathTemplate { return $0.pathTemplate < $1.pathTemplate }
            if $0.method.rawValue != $1.method.rawValue {
                return $0.method.rawValue < $1.method.rawValue
            }
            return $0.operationID < $1.operationID
        }
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.workflowName = workflowName
        self.role = role
        self.sourceKind = sourceKind
        self.sourceReference = sourceReference
        self.sourceDigest = sourceDigest
        self.apiBasePath = apiBasePath
        self.channels = Array(Set(hostBindings.map(\.channel))).sorted {
            $0.rawValue < $1.rawValue
        }
        self.replMount = replMount
        replExamples = replMount.examples
        self.apiRoutes = sortedAPIRoutes
        apiExamples = sortedAPIRoutes.flatMap(\.examples).sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            if $0.method.rawValue != $1.method.rawValue {
                return $0.method.rawValue < $1.method.rawValue
            }
            return $0.summary < $1.summary
        }
        self.modelToolName = modelToolName
        self.modelRouterToolName = modelRouterToolName
        modelToolExamples = Self.modelExamples(for: .modelTool, in: hostBindings)
        modelRouterExamples = Self.modelExamples(for: .modelRouter, in: hostBindings)
        self.onyxDriverID = onyxDriverID
        self.planningWorkflowID = planningWorkflowID
        self.plannerEntrypoint = plannerEntrypoint
        self.toolReferences = Array(Set(toolReferences)).sorted()
        self.decomposableUnits = decomposableUnits.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.instructionID < $1.instructionID
        }
        self.approvalGates = approvalGates.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.instructionID < $1.instructionID
        }
    }

    private static func modelExamples(
        for channel: SMLWorkflowRuntimeHostBindingChannel,
        in hostBindings: [SMLWorkflowRuntimeHostBinding]
    ) -> [SMLWorkflowRuntimeModelToolCallExample] {
        hostBindings
            .filter { $0.channel == channel }
            .flatMap(\.modelToolExamples)
            .sorted {
                if ($0.workflowID ?? "") != ($1.workflowID ?? "") {
                    return ($0.workflowID ?? "") < ($1.workflowID ?? "")
                }
                if $0.line != $1.line { return $0.line < $1.line }
                if $0.toolName != $1.toolName { return $0.toolName < $1.toolName }
                return $0.summary < $1.summary
            }
    }
}

public struct SMLWorkflowRuntimeHostWorkflowWiring: Sendable, Codable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let workflowName: String
    public let role: String
    public let sourceKind: SMLWorkflowSourceKind
    public let sourceReference: String
    public let sourceDigest: String?
    public let apiBasePath: String
    public let replMount: SMLWorkflowRuntimeREPLMount
    public let apiRoutes: [SMLWorkflowRuntimeAPIMount]
    public let modelToolName: String
    public let modelRouterToolName: String
    public let onyxDriverID: String
    public let planningWorkflowID: String?
    public let plannerEntrypoint: String?
    public let toolReferences: [String]
    public let decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit]
    public let approvalGates: [SMLWorkflowRuntimePlanningApprovalGate]
    public let hostBindings: [SMLWorkflowRuntimeHostBinding]
    public let attachment: SMLWorkflowRuntimeWorkflowAttachmentManifest

    public init(
        workflowID: String,
        workflowVersion: String,
        workflowName: String,
        role: String,
        sourceKind: SMLWorkflowSourceKind,
        sourceReference: String,
        sourceDigest: String?,
        apiBasePath: String,
        replMount: SMLWorkflowRuntimeREPLMount,
        apiRoutes: [SMLWorkflowRuntimeAPIMount],
        modelToolName: String,
        modelRouterToolName: String,
        onyxDriverID: String,
        planningWorkflowID: String?,
        plannerEntrypoint: String? = nil,
        toolReferences: [String],
        decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit],
        approvalGates: [SMLWorkflowRuntimePlanningApprovalGate],
        hostBindings: [SMLWorkflowRuntimeHostBinding],
        attachment: SMLWorkflowRuntimeWorkflowAttachmentManifest? = nil
    ) {
        let sortedAPIRoutes = apiRoutes.sorted {
            if $0.pathTemplate != $1.pathTemplate { return $0.pathTemplate < $1.pathTemplate }
            if $0.method.rawValue != $1.method.rawValue {
                return $0.method.rawValue < $1.method.rawValue
            }
            return $0.operationID < $1.operationID
        }
        let sortedToolReferences = Array(Set(toolReferences)).sorted()
        let sortedDecomposableUnits = decomposableUnits.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.instructionID < $1.instructionID
        }
        let sortedApprovalGates = approvalGates.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.instructionID < $1.instructionID
        }
        let sortedHostBindings = hostBindings.sorted {
            if $0.channel.rawValue != $1.channel.rawValue {
                return $0.channel.rawValue < $1.channel.rawValue
            }
            return $0.reference < $1.reference
        }
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.workflowName = workflowName
        self.role = role
        self.sourceKind = sourceKind
        self.sourceReference = sourceReference
        self.sourceDigest = sourceDigest
        self.apiBasePath = apiBasePath
        self.replMount = replMount
        self.apiRoutes = sortedAPIRoutes
        self.modelToolName = modelToolName
        self.modelRouterToolName = modelRouterToolName
        self.onyxDriverID = onyxDriverID
        self.planningWorkflowID = planningWorkflowID
        self.plannerEntrypoint = plannerEntrypoint
        self.toolReferences = sortedToolReferences
        self.decomposableUnits = sortedDecomposableUnits
        self.approvalGates = sortedApprovalGates
        self.hostBindings = sortedHostBindings
        self.attachment = attachment ?? SMLWorkflowRuntimeWorkflowAttachmentManifest(
            workflowID: workflowID,
            workflowVersion: workflowVersion,
            workflowName: workflowName,
            role: role,
            sourceKind: sourceKind,
            sourceReference: sourceReference,
            sourceDigest: sourceDigest,
            apiBasePath: apiBasePath,
            replMount: replMount,
            apiRoutes: sortedAPIRoutes,
            modelToolName: modelToolName,
            modelRouterToolName: modelRouterToolName,
            onyxDriverID: onyxDriverID,
            planningWorkflowID: planningWorkflowID,
            plannerEntrypoint: plannerEntrypoint,
            toolReferences: sortedToolReferences,
            decomposableUnits: sortedDecomposableUnits,
            approvalGates: sortedApprovalGates,
            hostBindings: sortedHostBindings
        )
    }

    public init(
        descriptor: SMLWorkflowRuntimeDescriptor,
        mount: SMLWorkflowRuntimeWorkflowMount,
        hostGuide: SMLWorkflowRuntimeWorkflowHostGuide?
    ) {
        self.init(
            workflowID: descriptor.workflowID,
            workflowVersion: descriptor.workflowVersion,
            workflowName: descriptor.workflowName,
            role: mount.role,
            sourceKind: descriptor.sourceKind,
            sourceReference: descriptor.sourceReference,
            sourceDigest: descriptor.sourceDigest,
            apiBasePath: mount.apiBasePath,
            replMount: mount.repl,
            apiRoutes: mount.apiRoutes,
            modelToolName: mount.modelToolName,
            modelRouterToolName: mount.modelRouterToolName,
            onyxDriverID: mount.onyxDriverID,
            planningWorkflowID: mount.planningWorkflowID,
            plannerEntrypoint: hostGuide?.plannerEntrypoint,
            toolReferences: hostGuide?.toolReferences ?? [],
            decomposableUnits: hostGuide?.decomposableUnits ?? [],
            approvalGates: hostGuide?.approvalGates ?? [],
            hostBindings: hostGuide?.hostBindings ?? []
        )
    }

    enum CodingKeys: String, CodingKey {
        case workflowID
        case workflowVersion
        case workflowName
        case role
        case sourceKind
        case sourceReference
        case sourceDigest
        case apiBasePath
        case replMount
        case apiRoutes
        case modelToolName
        case modelRouterToolName
        case onyxDriverID
        case planningWorkflowID
        case plannerEntrypoint
        case toolReferences
        case decomposableUnits
        case approvalGates
        case hostBindings
        case attachment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let workflowID = try container.decode(String.self, forKey: .workflowID)
        let workflowVersion = try container.decode(String.self, forKey: .workflowVersion)
        let workflowName = try container.decode(String.self, forKey: .workflowName)
        let role = try container.decode(String.self, forKey: .role)
        let sourceKind = try container.decode(SMLWorkflowSourceKind.self, forKey: .sourceKind)
        let sourceReference = try container.decode(String.self, forKey: .sourceReference)
        let sourceDigest = try container.decodeIfPresent(String.self, forKey: .sourceDigest)
        let apiBasePath = try container.decode(String.self, forKey: .apiBasePath)
        let replMount = try container.decode(SMLWorkflowRuntimeREPLMount.self, forKey: .replMount)
        let apiRoutes = try container.decode([SMLWorkflowRuntimeAPIMount].self, forKey: .apiRoutes)
        let modelToolName = try container.decode(String.self, forKey: .modelToolName)
        let modelRouterToolName = try container.decode(String.self, forKey: .modelRouterToolName)
        let onyxDriverID = try container.decode(String.self, forKey: .onyxDriverID)
        let planningWorkflowID = try container.decodeIfPresent(
            String.self,
            forKey: .planningWorkflowID
        )
        let plannerEntrypoint = try container.decodeIfPresent(
            String.self,
            forKey: .plannerEntrypoint
        )
        let toolReferences = try container.decode([String].self, forKey: .toolReferences)
        let decomposableUnits = try container.decode(
            [SMLWorkflowRuntimePlanningDecompositionUnit].self,
            forKey: .decomposableUnits
        )
        let approvalGates = try container.decode(
            [SMLWorkflowRuntimePlanningApprovalGate].self,
            forKey: .approvalGates
        )
        let hostBindings = try container.decode(
            [SMLWorkflowRuntimeHostBinding].self,
            forKey: .hostBindings
        )
        self.init(
            workflowID: workflowID,
            workflowVersion: workflowVersion,
            workflowName: workflowName,
            role: role,
            sourceKind: sourceKind,
            sourceReference: sourceReference,
            sourceDigest: sourceDigest,
            apiBasePath: apiBasePath,
            replMount: replMount,
            apiRoutes: apiRoutes,
            modelToolName: modelToolName,
            modelRouterToolName: modelRouterToolName,
            onyxDriverID: onyxDriverID,
            planningWorkflowID: planningWorkflowID,
            plannerEntrypoint: plannerEntrypoint,
            toolReferences: toolReferences,
            decomposableUnits: decomposableUnits,
            approvalGates: approvalGates,
            hostBindings: hostBindings,
            attachment: try container.decodeIfPresent(
                SMLWorkflowRuntimeWorkflowAttachmentManifest.self,
                forKey: .attachment
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workflowID, forKey: .workflowID)
        try container.encode(workflowVersion, forKey: .workflowVersion)
        try container.encode(workflowName, forKey: .workflowName)
        try container.encode(role, forKey: .role)
        try container.encode(sourceKind, forKey: .sourceKind)
        try container.encode(sourceReference, forKey: .sourceReference)
        try container.encodeIfPresent(sourceDigest, forKey: .sourceDigest)
        try container.encode(apiBasePath, forKey: .apiBasePath)
        try container.encode(replMount, forKey: .replMount)
        try container.encode(apiRoutes, forKey: .apiRoutes)
        try container.encode(modelToolName, forKey: .modelToolName)
        try container.encode(modelRouterToolName, forKey: .modelRouterToolName)
        try container.encode(onyxDriverID, forKey: .onyxDriverID)
        try container.encodeIfPresent(planningWorkflowID, forKey: .planningWorkflowID)
        try container.encodeIfPresent(plannerEntrypoint, forKey: .plannerEntrypoint)
        try container.encode(toolReferences, forKey: .toolReferences)
        try container.encode(decomposableUnits, forKey: .decomposableUnits)
        try container.encode(approvalGates, forKey: .approvalGates)
        try container.encode(hostBindings, forKey: .hostBindings)
        try container.encode(attachment, forKey: .attachment)
    }
}

public struct SMLWorkflowRuntimeHostWiring: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 7

    public let schemaVersion: Int
    public let apiBasePaths: [String]
    public let metadataEndpoints: [SMLWorkflowRuntimeMetadataEndpoint]
    public let requiredHostServices: [String]
    public let launchSteps: [SMLWorkflowRuntimeHostLaunchStep]
    public let modelRouter: SMLWorkflowRuntimeModelRouterDescriptor
    public let onyxDriverIDs: [String]
    public let planningWorkflowIDs: [String]
    public let workflows: [SMLWorkflowRuntimeHostWorkflowWiring]

    public init(
        schemaVersion: Int = SMLWorkflowRuntimeHostWiring.currentSchemaVersion,
        apiBasePaths: [String],
        metadataEndpoints: [SMLWorkflowRuntimeMetadataEndpoint],
        requiredHostServices: [String],
        launchSteps: [SMLWorkflowRuntimeHostLaunchStep],
        modelRouter: SMLWorkflowRuntimeModelRouterDescriptor,
        onyxDriverIDs: [String],
        planningWorkflowIDs: [String],
        workflows: [SMLWorkflowRuntimeHostWorkflowWiring]
    ) {
        self.schemaVersion = schemaVersion
        self.apiBasePaths = Array(Set(apiBasePaths)).sorted()
        self.metadataEndpoints = metadataEndpoints.sorted {
            if $0.pathTemplate != $1.pathTemplate { return $0.pathTemplate < $1.pathTemplate }
            return $0.operationID < $1.operationID
        }
        self.requiredHostServices = Array(Set(requiredHostServices)).sorted()
        self.launchSteps = launchSteps
        self.modelRouter = modelRouter
        self.onyxDriverIDs = Array(Set(onyxDriverIDs)).sorted()
        self.planningWorkflowIDs = Array(Set(planningWorkflowIDs)).sorted()
        self.workflows = workflows.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.workflowVersion < $1.workflowVersion
        }
    }

    public init(catalog: SMLWorkflowRuntimeCatalog) {
        let mountContract = catalog.mountContract
        let hostGuide = catalog.hostGuide
        let descriptorsByWorkflowID = Dictionary(
            uniqueKeysWithValues: catalog.workflows.map { ($0.workflowID, $0) }
        )
        let hostGuidesByWorkflowID = Dictionary(
            uniqueKeysWithValues: hostGuide.workflowBindings.map { ($0.workflowID, $0) }
        )
        self.init(
            apiBasePaths: mountContract.apiBasePaths,
            metadataEndpoints: catalog.metadataEndpoints,
            requiredHostServices: hostGuide.requiredHostServices,
            launchSteps: hostGuide.launchSteps,
            modelRouter: catalog.modelRouter,
            onyxDriverIDs: mountContract.onyxDriverIDs,
            planningWorkflowIDs: mountContract.planningWorkflowIDs,
            workflows: mountContract.workflowMounts.compactMap { mount in
                guard let descriptor = descriptorsByWorkflowID[mount.workflowID] else {
                    return nil
                }
                return SMLWorkflowRuntimeHostWorkflowWiring(
                    descriptor: descriptor,
                    mount: mount,
                    hostGuide: hostGuidesByWorkflowID[mount.workflowID]
                )
            }
        )
    }

    public var hostBindingCount: Int {
        workflows.reduce(0) { $0 + $1.hostBindings.count }
    }

    public var attachmentManifests: [SMLWorkflowRuntimeWorkflowAttachmentManifest] {
        workflows.map(\.attachment)
    }
}

public extension SMLWorkflowRuntimeCatalog {
    var hostWiring: SMLWorkflowRuntimeHostWiring {
        SMLWorkflowRuntimeHostWiring(catalog: self)
    }
}
