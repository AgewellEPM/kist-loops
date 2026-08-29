import Foundation

/// Compact, descriptor-only wiring map for host adapters.
///
/// `SMLWorkflowRuntimeHostGuide` is the fuller installation guide. This value is the small,
/// machine-readable map a dashboard, CLI adapter, HTTP router, model host, or Onyx bridge can read
/// to wire REPL/API/model-router/Onyx/planning surfaces without walking the whole runtime export.
/// It carries no actor, lease, credential, provider registry, gateway, replay guard, runtime handle,
/// executable closure, or completion authority.
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
    public let toolReferences: [String]
    public let decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit]
    public let approvalGates: [SMLWorkflowRuntimePlanningApprovalGate]
    public let hostBindings: [SMLWorkflowRuntimeHostBinding]

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
        toolReferences: [String],
        decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit],
        approvalGates: [SMLWorkflowRuntimePlanningApprovalGate],
        hostBindings: [SMLWorkflowRuntimeHostBinding]
    ) {
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.workflowName = workflowName
        self.role = role
        self.sourceKind = sourceKind
        self.sourceReference = sourceReference
        self.sourceDigest = sourceDigest
        self.apiBasePath = apiBasePath
        self.replMount = replMount
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
        self.toolReferences = Array(Set(toolReferences)).sorted()
        self.decomposableUnits = decomposableUnits.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.instructionID < $1.instructionID
        }
        self.approvalGates = approvalGates.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.instructionID < $1.instructionID
        }
        self.hostBindings = hostBindings.sorted {
            if $0.channel.rawValue != $1.channel.rawValue {
                return $0.channel.rawValue < $1.channel.rawValue
            }
            return $0.reference < $1.reference
        }
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
            toolReferences: hostGuide?.toolReferences ?? [],
            decomposableUnits: hostGuide?.decomposableUnits ?? [],
            approvalGates: hostGuide?.approvalGates ?? [],
            hostBindings: hostGuide?.hostBindings ?? []
        )
    }
}

public struct SMLWorkflowRuntimeHostWiring: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

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
}

public extension SMLWorkflowRuntimeCatalog {
    var hostWiring: SMLWorkflowRuntimeHostWiring {
        SMLWorkflowRuntimeHostWiring(catalog: self)
    }
}
