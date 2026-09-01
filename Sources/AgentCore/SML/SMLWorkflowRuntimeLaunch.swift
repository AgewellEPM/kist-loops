import Foundation

public struct SMLWorkflowRuntimeLaunchWorkflow: Sendable, Codable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let workflowName: String
    public let role: String
    public let sourceKind: SMLWorkflowSourceKind
    public let apiBasePath: String
    public let apiWorkflowPath: String
    public let installed: Bool
    public let installedInstructionCount: Int?
    public let replMount: SMLWorkflowRuntimeREPLMount
    public let apiRoutes: [SMLWorkflowRuntimeAPIMount]
    public let modelToolName: String
    public let modelRouterToolName: String
    public let onyxDriverID: String
    public let planningWorkflowID: String?
    public let hostBindingChannels: [SMLWorkflowRuntimeHostBindingChannel]
    public let commandBindings: [SMLWorkflowRuntimePlanningCommandBinding]
    public let skillIndex: [SMLWorkflowRuntimePlanningSkillIndexEntry]
    public let attachment: SMLWorkflowRuntimeWorkflowAttachmentManifest?

    public init(
        workflowID: String,
        workflowVersion: String,
        workflowName: String,
        role: String,
        sourceKind: SMLWorkflowSourceKind,
        apiBasePath: String,
        apiWorkflowPath: String? = nil,
        installed: Bool,
        installedInstructionCount: Int?,
        replMount: SMLWorkflowRuntimeREPLMount,
        apiRoutes: [SMLWorkflowRuntimeAPIMount],
        modelToolName: String,
        modelRouterToolName: String,
        onyxDriverID: String,
        planningWorkflowID: String?,
        hostBindingChannels: [SMLWorkflowRuntimeHostBindingChannel],
        commandBindings: [SMLWorkflowRuntimePlanningCommandBinding] = [],
        skillIndex: [SMLWorkflowRuntimePlanningSkillIndexEntry] = [],
        attachment: SMLWorkflowRuntimeWorkflowAttachmentManifest? = nil
    ) {
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.workflowName = workflowName
        self.role = role
        self.sourceKind = sourceKind
        self.apiBasePath = apiBasePath
        self.apiWorkflowPath = apiWorkflowPath ?? replMount.apiWorkflowPath
        self.installed = installed
        self.installedInstructionCount = installedInstructionCount
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
        self.hostBindingChannels = Array(Set(hostBindingChannels)).sorted {
            $0.rawValue < $1.rawValue
        }
        self.commandBindings = Self.sortedCommandBindings(commandBindings)
        self.skillIndex = Self.sortedSkillIndex(skillIndex)
        self.attachment = attachment
    }

    public init(
        mount: SMLWorkflowRuntimeWorkflowMount,
        descriptor: SMLWorkflowRuntimeDescriptor,
        installedWorkflow: SMLWorkflowProjection?,
        hostBinding: SMLWorkflowRuntimeWorkflowHostGuide?
    ) {
        self.init(
            workflowID: mount.workflowID,
            workflowVersion: mount.workflowVersion,
            workflowName: mount.workflowName,
            role: mount.role,
            sourceKind: descriptor.sourceKind,
            apiBasePath: mount.apiBasePath,
            apiWorkflowPath: mount.apiWorkflowPath,
            installed: installedWorkflow != nil,
            installedInstructionCount: installedWorkflow?.instructionCount,
            replMount: mount.repl,
            apiRoutes: mount.apiRoutes,
            modelToolName: mount.modelToolName,
            modelRouterToolName: mount.modelRouterToolName,
            onyxDriverID: mount.onyxDriverID,
            planningWorkflowID: mount.planningWorkflowID,
            hostBindingChannels: hostBinding?.hostBindings.map(\.channel) ?? [],
            commandBindings: mount.commandBindings,
            skillIndex: hostBinding?.skillIndex ?? [],
            attachment: hostBinding.map { guide in
                SMLWorkflowRuntimeWorkflowAttachmentManifest(
                    workflowID: mount.workflowID,
                    workflowVersion: mount.workflowVersion,
                    workflowName: mount.workflowName,
                    role: mount.role,
                    sourceKind: descriptor.sourceKind,
                    sourceReference: descriptor.sourceReference,
                    sourceDigest: descriptor.sourceDigest,
                    apiBasePath: mount.apiBasePath,
                    replMount: mount.repl,
                    apiRoutes: mount.apiRoutes,
                    modelToolName: mount.modelToolName,
                    model: descriptor.model,
                    modelRouterToolName: mount.modelRouterToolName,
                    onyxDriverID: mount.onyxDriverID,
                    planningWorkflowID: mount.planningWorkflowID,
                    plannerEntrypoint: guide.plannerEntrypoint,
                    skillTree: descriptor.onyx.skillTree,
                    skillIndex: guide.skillIndex,
                    toolBindings: descriptor.onyx.tools,
                    plan: descriptor.onyx.plan,
                    toolReferences: guide.toolReferences,
                    decomposableUnits: guide.decomposableUnits,
                    approvalGates: guide.approvalGates,
                    commandBindings: mount.commandBindings,
                    hostBindings: guide.hostBindings
                )
            }
        )
    }

    enum CodingKeys: String, CodingKey {
        case workflowID
        case workflowVersion
        case workflowName
        case role
        case sourceKind
        case apiBasePath
        case apiWorkflowPath
        case installed
        case installedInstructionCount
        case replMount
        case apiRoutes
        case modelToolName
        case modelRouterToolName
        case onyxDriverID
        case planningWorkflowID
        case hostBindingChannels
        case commandBindings
        case skillIndex
        case attachment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let replMount = try container.decode(SMLWorkflowRuntimeREPLMount.self, forKey: .replMount)
        let apiBasePath = try container.decode(String.self, forKey: .apiBasePath)
        let apiRoutes = try container.decode([SMLWorkflowRuntimeAPIMount].self, forKey: .apiRoutes)
        let workflowID = try container.decode(String.self, forKey: .workflowID)
        self.init(
            workflowID: workflowID,
            workflowVersion: try container.decode(String.self, forKey: .workflowVersion),
            workflowName: try container.decode(String.self, forKey: .workflowName),
            role: try container.decode(String.self, forKey: .role),
            sourceKind: try container.decode(SMLWorkflowSourceKind.self, forKey: .sourceKind),
            apiBasePath: apiBasePath,
            apiWorkflowPath: try container.decodeIfPresent(String.self, forKey: .apiWorkflowPath)
                ?? SMLWorkflowRuntimeAPIWorkflowPath.inferredWorkflowPath(
                    workflowID: workflowID,
                    apiBasePath: apiBasePath,
                    apiRoutes: apiRoutes
                ),
            installed: try container.decode(Bool.self, forKey: .installed),
            installedInstructionCount: try container.decodeIfPresent(
                Int.self,
                forKey: .installedInstructionCount
            ),
            replMount: replMount,
            apiRoutes: apiRoutes,
            modelToolName: try container.decode(String.self, forKey: .modelToolName),
            modelRouterToolName: try container.decode(String.self, forKey: .modelRouterToolName),
            onyxDriverID: try container.decode(String.self, forKey: .onyxDriverID),
            planningWorkflowID: try container.decodeIfPresent(String.self, forKey: .planningWorkflowID),
            hostBindingChannels: try container.decodeIfPresent(
                [SMLWorkflowRuntimeHostBindingChannel].self,
                forKey: .hostBindingChannels
            ) ?? [],
            commandBindings: try container.decodeIfPresent(
                [SMLWorkflowRuntimePlanningCommandBinding].self,
                forKey: .commandBindings
            ) ?? replMount.commandBindings,
            skillIndex: try container.decodeIfPresent(
                [SMLWorkflowRuntimePlanningSkillIndexEntry].self,
                forKey: .skillIndex
            ) ?? [],
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
        try container.encode(apiBasePath, forKey: .apiBasePath)
        try container.encode(apiWorkflowPath, forKey: .apiWorkflowPath)
        try container.encode(installed, forKey: .installed)
        try container.encodeIfPresent(installedInstructionCount, forKey: .installedInstructionCount)
        try container.encode(replMount, forKey: .replMount)
        try container.encode(apiRoutes, forKey: .apiRoutes)
        try container.encode(modelToolName, forKey: .modelToolName)
        try container.encode(modelRouterToolName, forKey: .modelRouterToolName)
        try container.encode(onyxDriverID, forKey: .onyxDriverID)
        try container.encodeIfPresent(planningWorkflowID, forKey: .planningWorkflowID)
        try container.encode(hostBindingChannels, forKey: .hostBindingChannels)
        try container.encode(commandBindings, forKey: .commandBindings)
        try container.encode(skillIndex, forKey: .skillIndex)
        try container.encodeIfPresent(attachment, forKey: .attachment)
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

    private static func sortedSkillIndex(
        _ skillIndex: [SMLWorkflowRuntimePlanningSkillIndexEntry]
    ) -> [SMLWorkflowRuntimePlanningSkillIndexEntry] {
        skillIndex.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            if $0.instructionID != $1.instructionID {
                return $0.instructionID < $1.instructionID
            }
            return $0.operation.rawValue < $1.operation.rawValue
        }
    }
}

/// Serializable receipt-shaped summary of what a host actually mounted.
///
/// `SMLWorkflowRuntimeExport` describes what can be mounted. This value is produced after launch and
/// cross-checks the declared runtime catalog against the installed workflow projections, so a host
/// can persist or display one bounded artifact for REPL/API/model-router/Onyx/planning attachment.
/// It intentionally carries no actor, lease, credentials, provider registry, gateway, replay guard,
/// runtime handle, or executable closure.
public struct SMLWorkflowRuntimeLaunchDescriptor: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 20

    public let schemaVersion: Int
    public let sourcePackageSchemaVersion: Int?
    public let runtimeExportSchemaVersion: Int
    public let workflowIDs: [String]
    public let installedWorkflowIDs: [String]
    public let missingInstalledWorkflowIDs: [String]
    public let unexpectedInstalledWorkflowIDs: [String]
    public let launchComplete: Bool
    public let apiBasePaths: [String]
    public let metadataEndpoints: [SMLWorkflowRuntimeMetadataEndpoint]
    public let hostWiring: SMLWorkflowRuntimeHostWiring
    public let workflows: [SMLWorkflowRuntimeLaunchWorkflow]
    public let modelRouter: SMLWorkflowRuntimeModelRouterDescriptor
    public let onyxDriverIDs: [String]
    public let planningWorkflowIDs: [String]
    public let requiredHostServices: [String]
    public let launchSteps: [SMLWorkflowRuntimeHostLaunchStep]
    public let sourceSummaries: [SMLWorkflowRuntimeSourceSummary]

    public init(
        schemaVersion: Int = SMLWorkflowRuntimeLaunchDescriptor.currentSchemaVersion,
        sourcePackageSchemaVersion: Int?,
        runtimeExportSchemaVersion: Int,
        workflowIDs: [String],
        installedWorkflowIDs: [String],
        missingInstalledWorkflowIDs: [String],
        unexpectedInstalledWorkflowIDs: [String],
        launchComplete: Bool,
        apiBasePaths: [String],
        metadataEndpoints: [SMLWorkflowRuntimeMetadataEndpoint],
        hostWiring: SMLWorkflowRuntimeHostWiring,
        workflows: [SMLWorkflowRuntimeLaunchWorkflow],
        modelRouter: SMLWorkflowRuntimeModelRouterDescriptor,
        onyxDriverIDs: [String],
        planningWorkflowIDs: [String],
        requiredHostServices: [String],
        launchSteps: [SMLWorkflowRuntimeHostLaunchStep],
        sourceSummaries: [SMLWorkflowRuntimeSourceSummary]
    ) {
        self.schemaVersion = schemaVersion
        self.sourcePackageSchemaVersion = sourcePackageSchemaVersion
        self.runtimeExportSchemaVersion = runtimeExportSchemaVersion
        self.workflowIDs = workflowIDs.sorted()
        self.installedWorkflowIDs = installedWorkflowIDs.sorted()
        self.missingInstalledWorkflowIDs = missingInstalledWorkflowIDs.sorted()
        self.unexpectedInstalledWorkflowIDs = unexpectedInstalledWorkflowIDs.sorted()
        self.launchComplete = launchComplete
        self.apiBasePaths = apiBasePaths.sorted()
        self.metadataEndpoints = metadataEndpoints.sorted {
            if $0.pathTemplate != $1.pathTemplate { return $0.pathTemplate < $1.pathTemplate }
            return $0.operationID < $1.operationID
        }
        self.hostWiring = hostWiring
        self.workflows = workflows.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.workflowVersion < $1.workflowVersion
        }
        self.modelRouter = modelRouter
        self.onyxDriverIDs = onyxDriverIDs.sorted()
        self.planningWorkflowIDs = planningWorkflowIDs.sorted()
        self.requiredHostServices = requiredHostServices.sorted()
        self.launchSteps = launchSteps
        self.sourceSummaries = sourceSummaries.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.workflowVersion < $1.workflowVersion
        }
    }

    public init(
        registry: SMLWorkflowRuntimeRegistry,
        installedWorkflows: [SMLWorkflowProjection],
        sourcePackage: SMLWorkflowRuntimeSourcePackage? = nil
    ) {
        let catalog = registry.catalog
        let mountContract = catalog.mountContract
        let hostGuide = catalog.hostGuide
        let descriptorsByWorkflowID = Dictionary(
            uniqueKeysWithValues: catalog.workflows.map { ($0.workflowID, $0) }
        )
        let installed = installedWorkflows.sorted {
            if $0.id != $1.id { return $0.id < $1.id }
            return $0.version < $1.version
        }
        var installedByWorkflowID: [String: SMLWorkflowProjection] = [:]
        for projection in installed {
            installedByWorkflowID[projection.id] = projection
        }
        let hostBindingsByWorkflowID = Dictionary(
            uniqueKeysWithValues: hostGuide.workflowBindings.map { ($0.workflowID, $0) }
        )
        let declaredWorkflowIDs = catalog.workflowIDs
        let declaredSet = Set(declaredWorkflowIDs)
        let installedWorkflowIDs = installed.map(\.id)
        let installedSet = Set(installedWorkflowIDs)
        let missingInstalled = declaredWorkflowIDs.filter { !installedSet.contains($0) }
        let unexpectedInstalled = installedWorkflowIDs.filter { !declaredSet.contains($0) }
        self.init(
            sourcePackageSchemaVersion: sourcePackage?.schemaVersion,
            runtimeExportSchemaVersion: SMLWorkflowRuntimeExport.currentSchemaVersion,
            workflowIDs: declaredWorkflowIDs,
            installedWorkflowIDs: installedWorkflowIDs,
            missingInstalledWorkflowIDs: missingInstalled,
            unexpectedInstalledWorkflowIDs: unexpectedInstalled,
            launchComplete: missingInstalled.isEmpty && unexpectedInstalled.isEmpty,
            apiBasePaths: mountContract.apiBasePaths,
            metadataEndpoints: catalog.metadataEndpoints,
            hostWiring: catalog.hostWiring,
            workflows: mountContract.workflowMounts.compactMap { mount in
                guard let descriptor = descriptorsByWorkflowID[mount.workflowID] else {
                    return nil
                }
                return SMLWorkflowRuntimeLaunchWorkflow(
                    mount: mount,
                    descriptor: descriptor,
                    installedWorkflow: installedByWorkflowID[mount.workflowID],
                    hostBinding: hostBindingsByWorkflowID[mount.workflowID]
                )
            },
            modelRouter: catalog.modelRouter,
            onyxDriverIDs: mountContract.onyxDriverIDs,
            planningWorkflowIDs: mountContract.planningWorkflowIDs,
            requiredHostServices: hostGuide.requiredHostServices,
            launchSteps: hostGuide.launchSteps,
            sourceSummaries: Self.sourceSummaries(
                from: sourcePackage,
                mountContract: mountContract
            )
        )
    }

    private static func sourceSummaries(
        from sourcePackage: SMLWorkflowRuntimeSourcePackage?,
        mountContract: SMLWorkflowRuntimeMountContract
    ) -> [SMLWorkflowRuntimeSourceSummary] {
        guard let sourcePackage else { return [] }
        let mountsByWorkflowID = Dictionary(
            uniqueKeysWithValues: mountContract.workflowMounts.map { ($0.workflowID, $0) }
        )
        return sourcePackage.normalizedWorkflows.map { workflow in
            let mount = mountsByWorkflowID[workflow.id]
            return SMLWorkflowRuntimeSourceSummary(
                workflowID: workflow.id,
                workflowVersion: workflow.version,
                workflowName: workflow.name,
                sourceKind: workflow.source.kind,
                sourceReference: workflow.source.reference,
                sourceDigest: workflow.source.digest,
                apiBasePath: mount?.apiBasePath ?? "",
                apiWorkflowPath: mount?.apiWorkflowPath,
                apiRoutePaths: mount?.apiRoutes.map(\.pathTemplate) ?? [],
                workflowMetadata: mount?.workflowMetadata,
                replGrammar: mount?.repl.grammar ?? "",
                modelToolName: mount?.modelToolName ?? "",
                modelRouterToolName: mount?.modelRouterToolName
                    ?? SMLWorkflowRuntimeModelAdapter.toolName,
                onyxDriverID: mount?.onyxDriverID ?? "",
                planningWorkflowID: mount?.planningWorkflowID
            )
        }
    }
}

public struct SMLWorkflowRuntimeLaunch: Sendable {
    public let registry: SMLWorkflowRuntimeRegistry
    public let app: SMLWorkflowRuntimeApp
    public let installedWorkflows: [SMLWorkflowProjection]
    public let sourcePackage: SMLWorkflowRuntimeSourcePackage?

    public init(
        registry: SMLWorkflowRuntimeRegistry,
        app: SMLWorkflowRuntimeApp,
        installedWorkflows: [SMLWorkflowProjection],
        sourcePackage: SMLWorkflowRuntimeSourcePackage? = nil
    ) {
        self.registry = registry
        self.app = app
        self.installedWorkflows = installedWorkflows
        self.sourcePackage = sourcePackage
    }

    public var mountContract: SMLWorkflowRuntimeMountContract {
        registry.mountContract
    }

    public var hostWiring: SMLWorkflowRuntimeHostWiring {
        registry.hostWiring
    }

    public var launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor {
        SMLWorkflowRuntimeLaunchDescriptor(
            registry: registry,
            installedWorkflows: installedWorkflows,
            sourcePackage: sourcePackage
        )
    }

    public func export(
        title: String = "SML Workflow Runtime API",
        version: String = "1.0.0"
    ) -> SMLWorkflowRuntimeExport {
        registry.export(title: title, version: version)
    }
}

