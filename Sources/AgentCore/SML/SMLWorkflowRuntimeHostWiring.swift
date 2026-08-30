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
    public let apiWorkflowPath: String
    public let runtimeAttachmentsPath: String
    public let runtimeWorkflowAttachmentPath: String
    public let runtimeWorkflowREPLMountPath: String
    public let runtimeWorkflowAPIMountPath: String
    public let runtimeWorkflowModelToolPath: String
    public let runtimeWorkflowOnyxDriverPath: String
    public let runtimeWorkflowSkillTreePath: String
    public let runtimeWorkflowToolBindingsPath: String
    public let runtimeWorkflowPlanningPath: String
    public let channels: [SMLWorkflowRuntimeHostBindingChannel]
    public let replMount: SMLWorkflowRuntimeREPLMount
    public let replExamples: [SMLWorkflowREPLExample]
    public let apiRoutes: [SMLWorkflowRuntimeAPIMount]
    public let apiExamples: [SMLWorkflowAPIRequestExample]
    public let modelToolName: String
    public let model: SMLWorkflowModelDescriptor?
    public let modelRouterToolName: String
    public let modelToolExamples: [SMLWorkflowRuntimeModelToolCallExample]
    public let modelRouterExamples: [SMLWorkflowRuntimeModelToolCallExample]
    public let onyxDriverID: String
    public let planningWorkflowID: String?
    public let plannerEntrypoint: String?
    public let skillTree: [SMLOnyxSkillNode]
    public let skillIndex: [SMLWorkflowRuntimePlanningSkillIndexEntry]
    public let toolBindings: [SMLOnyxToolBinding]
    public let plan: SMLOnyxPlan?
    public let toolReferences: [String]
    public let decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit]
    public let approvalGates: [SMLWorkflowRuntimePlanningApprovalGate]
    public let commandBindings: [SMLWorkflowRuntimePlanningCommandBinding]

    public init(
        workflowID: String,
        workflowVersion: String,
        workflowName: String,
        role: String,
        sourceKind: SMLWorkflowSourceKind,
        sourceReference: String,
        sourceDigest: String?,
        apiBasePath: String,
        apiWorkflowPath: String? = nil,
        runtimeAttachmentsPath: String? = nil,
        runtimeWorkflowAttachmentPath: String? = nil,
        runtimeWorkflowREPLMountPath: String? = nil,
        runtimeWorkflowAPIMountPath: String? = nil,
        runtimeWorkflowModelToolPath: String? = nil,
        runtimeWorkflowOnyxDriverPath: String? = nil,
        runtimeWorkflowSkillTreePath: String? = nil,
        runtimeWorkflowToolBindingsPath: String? = nil,
        runtimeWorkflowPlanningPath: String? = nil,
        replMount: SMLWorkflowRuntimeREPLMount,
        apiRoutes: [SMLWorkflowRuntimeAPIMount],
        modelToolName: String,
        model: SMLWorkflowModelDescriptor? = nil,
        modelRouterToolName: String,
        onyxDriverID: String,
        planningWorkflowID: String?,
        plannerEntrypoint: String?,
        skillTree: [SMLOnyxSkillNode] = [],
        skillIndex: [SMLWorkflowRuntimePlanningSkillIndexEntry] = [],
        toolBindings: [SMLOnyxToolBinding] = [],
        plan: SMLOnyxPlan? = nil,
        toolReferences: [String],
        decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit],
        approvalGates: [SMLWorkflowRuntimePlanningApprovalGate],
        commandBindings: [SMLWorkflowRuntimePlanningCommandBinding] = [],
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
        self.apiWorkflowPath = apiWorkflowPath ?? replMount.apiWorkflowPath
        self.runtimeAttachmentsPath = runtimeAttachmentsPath
            ?? Self.runtimeResourcePath(apiBasePath: apiBasePath, resourcePath: "attachments")
        self.runtimeWorkflowAttachmentPath = runtimeWorkflowAttachmentPath
            ?? Self.runtimeWorkflowPath(
                apiBasePath: apiBasePath,
                resourcePath: "attachments",
                workflowID: workflowID
            )
        self.runtimeWorkflowREPLMountPath = runtimeWorkflowREPLMountPath
            ?? Self.runtimeWorkflowPath(
                apiBasePath: apiBasePath,
                resourcePath: "repl-mounts",
                workflowID: workflowID
            )
        self.runtimeWorkflowAPIMountPath = runtimeWorkflowAPIMountPath
            ?? Self.runtimeWorkflowPath(
                apiBasePath: apiBasePath,
                resourcePath: "api-mounts",
                workflowID: workflowID
            )
        self.runtimeWorkflowModelToolPath = runtimeWorkflowModelToolPath
            ?? Self.runtimeWorkflowPath(
                apiBasePath: apiBasePath,
                resourcePath: "model-tools",
                workflowID: workflowID
            )
        self.runtimeWorkflowOnyxDriverPath = runtimeWorkflowOnyxDriverPath
            ?? Self.runtimeWorkflowPath(
                apiBasePath: apiBasePath,
                resourcePath: "onyx-drivers",
                workflowID: workflowID
            )
        self.runtimeWorkflowSkillTreePath = runtimeWorkflowSkillTreePath
            ?? Self.runtimeWorkflowPath(
                apiBasePath: apiBasePath,
                resourcePath: "skill-trees",
                workflowID: workflowID
            )
        self.runtimeWorkflowToolBindingsPath = runtimeWorkflowToolBindingsPath
            ?? Self.runtimeWorkflowPath(
                apiBasePath: apiBasePath,
                resourcePath: "tool-bindings",
                workflowID: workflowID
            )
        self.runtimeWorkflowPlanningPath = runtimeWorkflowPlanningPath
            ?? Self.runtimeWorkflowPath(
                apiBasePath: apiBasePath,
                resourcePath: "planning",
                workflowID: workflowID
            )
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
        self.model = model
        self.modelRouterToolName = modelRouterToolName
        modelToolExamples = Self.modelExamples(for: .modelTool, in: hostBindings)
        modelRouterExamples = Self.modelExamples(for: .modelRouter, in: hostBindings)
        self.onyxDriverID = onyxDriverID
        self.planningWorkflowID = planningWorkflowID
        self.plannerEntrypoint = plannerEntrypoint
        self.skillTree = skillTree
        self.skillIndex = Self.sortedSkillIndex(skillIndex)
        self.toolBindings = toolBindings.sorted {
            if $0.instructionID != $1.instructionID {
                return $0.instructionID < $1.instructionID
            }
            return $0.reference < $1.reference
        }
        self.plan = plan
        self.toolReferences = Array(Set(toolReferences)).sorted()
        self.decomposableUnits = decomposableUnits.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.instructionID < $1.instructionID
        }
        self.approvalGates = approvalGates.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.instructionID < $1.instructionID
        }
        self.commandBindings = Self.sortedCommandBindings(commandBindings)
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
        case apiWorkflowPath
        case runtimeAttachmentsPath
        case runtimeWorkflowAttachmentPath
        case runtimeWorkflowREPLMountPath
        case runtimeWorkflowAPIMountPath
        case runtimeWorkflowModelToolPath
        case runtimeWorkflowOnyxDriverPath
        case runtimeWorkflowSkillTreePath
        case runtimeWorkflowToolBindingsPath
        case runtimeWorkflowPlanningPath
        case channels
        case replMount
        case replExamples
        case apiRoutes
        case apiExamples
        case modelToolName
        case model
        case modelRouterToolName
        case modelToolExamples
        case modelRouterExamples
        case onyxDriverID
        case planningWorkflowID
        case plannerEntrypoint
        case skillTree
        case skillIndex
        case toolBindings
        case plan
        case toolReferences
        case decomposableUnits
        case approvalGates
        case commandBindings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workflowID = try container.decode(String.self, forKey: .workflowID)
        workflowVersion = try container.decode(String.self, forKey: .workflowVersion)
        workflowName = try container.decode(String.self, forKey: .workflowName)
        role = try container.decode(String.self, forKey: .role)
        sourceKind = try container.decode(SMLWorkflowSourceKind.self, forKey: .sourceKind)
        sourceReference = try container.decode(String.self, forKey: .sourceReference)
        sourceDigest = try container.decodeIfPresent(String.self, forKey: .sourceDigest)
        apiBasePath = try container.decode(String.self, forKey: .apiBasePath)
        channels = try container.decode([SMLWorkflowRuntimeHostBindingChannel].self, forKey: .channels).sorted {
            $0.rawValue < $1.rawValue
        }
        replMount = try container.decode(SMLWorkflowRuntimeREPLMount.self, forKey: .replMount)
        replExamples = try container.decode([SMLWorkflowREPLExample].self, forKey: .replExamples)
        apiRoutes = try container.decode([SMLWorkflowRuntimeAPIMount].self, forKey: .apiRoutes).sorted {
            if $0.pathTemplate != $1.pathTemplate { return $0.pathTemplate < $1.pathTemplate }
            if $0.method.rawValue != $1.method.rawValue {
                return $0.method.rawValue < $1.method.rawValue
            }
            return $0.operationID < $1.operationID
        }
        apiWorkflowPath = try container.decodeIfPresent(String.self, forKey: .apiWorkflowPath)
            ?? SMLWorkflowRuntimeAPIWorkflowPath.inferredWorkflowPath(
                workflowID: workflowID,
                apiBasePath: apiBasePath,
                apiRoutes: apiRoutes
            )
        runtimeAttachmentsPath = try container.decodeIfPresent(
            String.self,
            forKey: .runtimeAttachmentsPath
        ) ?? Self.runtimeResourcePath(apiBasePath: apiBasePath, resourcePath: "attachments")
        runtimeWorkflowAttachmentPath = try container.decodeIfPresent(
            String.self,
            forKey: .runtimeWorkflowAttachmentPath
        ) ?? Self.runtimeWorkflowPath(
            apiBasePath: apiBasePath,
            resourcePath: "attachments",
            workflowID: workflowID
        )
        runtimeWorkflowREPLMountPath = try container.decodeIfPresent(
            String.self,
            forKey: .runtimeWorkflowREPLMountPath
        ) ?? Self.runtimeWorkflowPath(
            apiBasePath: apiBasePath,
            resourcePath: "repl-mounts",
            workflowID: workflowID
        )
        runtimeWorkflowAPIMountPath = try container.decodeIfPresent(
            String.self,
            forKey: .runtimeWorkflowAPIMountPath
        ) ?? Self.runtimeWorkflowPath(
            apiBasePath: apiBasePath,
            resourcePath: "api-mounts",
            workflowID: workflowID
        )
        runtimeWorkflowModelToolPath = try container.decodeIfPresent(
            String.self,
            forKey: .runtimeWorkflowModelToolPath
        ) ?? Self.runtimeWorkflowPath(
            apiBasePath: apiBasePath,
            resourcePath: "model-tools",
            workflowID: workflowID
        )
        runtimeWorkflowOnyxDriverPath = try container.decodeIfPresent(
            String.self,
            forKey: .runtimeWorkflowOnyxDriverPath
        ) ?? Self.runtimeWorkflowPath(
            apiBasePath: apiBasePath,
            resourcePath: "onyx-drivers",
            workflowID: workflowID
        )
        runtimeWorkflowSkillTreePath = try container.decodeIfPresent(
            String.self,
            forKey: .runtimeWorkflowSkillTreePath
        ) ?? Self.runtimeWorkflowPath(
            apiBasePath: apiBasePath,
            resourcePath: "skill-trees",
            workflowID: workflowID
        )
        runtimeWorkflowToolBindingsPath = try container.decodeIfPresent(
            String.self,
            forKey: .runtimeWorkflowToolBindingsPath
        ) ?? Self.runtimeWorkflowPath(
            apiBasePath: apiBasePath,
            resourcePath: "tool-bindings",
            workflowID: workflowID
        )
        runtimeWorkflowPlanningPath = try container.decodeIfPresent(
            String.self,
            forKey: .runtimeWorkflowPlanningPath
        ) ?? Self.runtimeWorkflowPath(
            apiBasePath: apiBasePath,
            resourcePath: "planning",
            workflowID: workflowID
        )
        apiExamples = try container.decode([SMLWorkflowAPIRequestExample].self, forKey: .apiExamples).sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            if $0.method.rawValue != $1.method.rawValue {
                return $0.method.rawValue < $1.method.rawValue
            }
            return $0.summary < $1.summary
        }
        modelToolName = try container.decode(String.self, forKey: .modelToolName)
        model = try container.decodeIfPresent(SMLWorkflowModelDescriptor.self, forKey: .model)
        modelRouterToolName = try container.decode(String.self, forKey: .modelRouterToolName)
        modelToolExamples = try container.decode(
            [SMLWorkflowRuntimeModelToolCallExample].self,
            forKey: .modelToolExamples
        )
        modelRouterExamples = try container.decode(
            [SMLWorkflowRuntimeModelToolCallExample].self,
            forKey: .modelRouterExamples
        )
        onyxDriverID = try container.decode(String.self, forKey: .onyxDriverID)
        planningWorkflowID = try container.decodeIfPresent(String.self, forKey: .planningWorkflowID)
        plannerEntrypoint = try container.decodeIfPresent(String.self, forKey: .plannerEntrypoint)
        skillTree = try container.decodeIfPresent([SMLOnyxSkillNode].self, forKey: .skillTree) ?? []
        skillIndex = Self.sortedSkillIndex(
            try container.decodeIfPresent(
                [SMLWorkflowRuntimePlanningSkillIndexEntry].self,
                forKey: .skillIndex
            ) ?? []
        )
        toolBindings = try container.decodeIfPresent([SMLOnyxToolBinding].self, forKey: .toolBindings) ?? []
        plan = try container.decodeIfPresent(SMLOnyxPlan.self, forKey: .plan)
        toolReferences = try container.decode([String].self, forKey: .toolReferences)
        decomposableUnits = try container.decode(
            [SMLWorkflowRuntimePlanningDecompositionUnit].self,
            forKey: .decomposableUnits
        )
        approvalGates = try container.decode(
            [SMLWorkflowRuntimePlanningApprovalGate].self,
            forKey: .approvalGates
        )
        commandBindings = Self.sortedCommandBindings(
            try container.decodeIfPresent(
                [SMLWorkflowRuntimePlanningCommandBinding].self,
                forKey: .commandBindings
            ) ?? []
        )
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

    private static func runtimeResourcePath(apiBasePath: String, resourcePath: String) -> String {
        "\(apiBasePath)/runtime/\(resourcePath)"
    }

    private static func runtimeWorkflowPath(
        apiBasePath: String,
        resourcePath: String,
        workflowID: String
    ) -> String {
        "\(runtimeResourcePath(apiBasePath: apiBasePath, resourcePath: resourcePath))/\(workflowID)"
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
    public let apiWorkflowPath: String
    public let replMount: SMLWorkflowRuntimeREPLMount
    public let apiRoutes: [SMLWorkflowRuntimeAPIMount]
    public let modelToolName: String
    public let model: SMLWorkflowModelDescriptor?
    public let modelRouterToolName: String
    public let onyxDriverID: String
    public let planningWorkflowID: String?
    public let plannerEntrypoint: String?
    public let toolReferences: [String]
    public let skillIndex: [SMLWorkflowRuntimePlanningSkillIndexEntry]
    public let decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit]
    public let approvalGates: [SMLWorkflowRuntimePlanningApprovalGate]
    public let commandBindings: [SMLWorkflowRuntimePlanningCommandBinding]
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
        apiWorkflowPath: String? = nil,
        replMount: SMLWorkflowRuntimeREPLMount,
        apiRoutes: [SMLWorkflowRuntimeAPIMount],
        modelToolName: String,
        model: SMLWorkflowModelDescriptor? = nil,
        modelRouterToolName: String,
        onyxDriverID: String,
        planningWorkflowID: String?,
        plannerEntrypoint: String? = nil,
        skillTree: [SMLOnyxSkillNode] = [],
        toolBindings: [SMLOnyxToolBinding] = [],
        plan: SMLOnyxPlan? = nil,
        toolReferences: [String],
        skillIndex: [SMLWorkflowRuntimePlanningSkillIndexEntry] = [],
        decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit],
        approvalGates: [SMLWorkflowRuntimePlanningApprovalGate],
        commandBindings: [SMLWorkflowRuntimePlanningCommandBinding] = [],
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
        let sortedSkillIndex = Self.sortedSkillIndex(skillIndex)
        let sortedDecomposableUnits = decomposableUnits.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.instructionID < $1.instructionID
        }
        let sortedApprovalGates = approvalGates.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.instructionID < $1.instructionID
        }
        let sortedCommandBindings = Self.sortedCommandBindings(commandBindings)
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
        self.apiWorkflowPath = apiWorkflowPath ?? replMount.apiWorkflowPath
        self.replMount = replMount
        self.apiRoutes = sortedAPIRoutes
        self.modelToolName = modelToolName
        self.model = model
        self.modelRouterToolName = modelRouterToolName
        self.onyxDriverID = onyxDriverID
        self.planningWorkflowID = planningWorkflowID
        self.plannerEntrypoint = plannerEntrypoint
        self.toolReferences = sortedToolReferences
        self.skillIndex = sortedSkillIndex
        self.decomposableUnits = sortedDecomposableUnits
        self.approvalGates = sortedApprovalGates
        self.commandBindings = sortedCommandBindings
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
            apiWorkflowPath: self.apiWorkflowPath,
            replMount: replMount,
            apiRoutes: sortedAPIRoutes,
            modelToolName: modelToolName,
            model: model,
            modelRouterToolName: modelRouterToolName,
            onyxDriverID: onyxDriverID,
            planningWorkflowID: planningWorkflowID,
            plannerEntrypoint: plannerEntrypoint,
            skillTree: skillTree,
            skillIndex: sortedSkillIndex,
            toolBindings: toolBindings,
            plan: plan,
            toolReferences: sortedToolReferences,
            decomposableUnits: sortedDecomposableUnits,
            approvalGates: sortedApprovalGates,
            commandBindings: sortedCommandBindings,
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
            apiWorkflowPath: mount.apiWorkflowPath,
            replMount: mount.repl,
            apiRoutes: mount.apiRoutes,
            modelToolName: mount.modelToolName,
            model: descriptor.model,
            modelRouterToolName: mount.modelRouterToolName,
            onyxDriverID: mount.onyxDriverID,
            planningWorkflowID: mount.planningWorkflowID,
            plannerEntrypoint: hostGuide?.plannerEntrypoint,
            skillTree: descriptor.onyx.skillTree,
            toolBindings: descriptor.onyx.tools,
            plan: descriptor.onyx.plan,
            toolReferences: hostGuide?.toolReferences ?? [],
            skillIndex: hostGuide?.skillIndex ?? [],
            decomposableUnits: hostGuide?.decomposableUnits ?? [],
            approvalGates: hostGuide?.approvalGates ?? [],
            commandBindings: SMLWorkflowRuntimePlanningManifest.commandBindings(for: descriptor),
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
        case apiWorkflowPath
        case replMount
        case apiRoutes
        case modelToolName
        case model
        case modelRouterToolName
        case onyxDriverID
        case planningWorkflowID
        case plannerEntrypoint
        case toolReferences
        case skillIndex
        case decomposableUnits
        case approvalGates
        case commandBindings
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
        let model = try container.decodeIfPresent(SMLWorkflowModelDescriptor.self, forKey: .model)
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
        let skillIndex = try container.decodeIfPresent(
            [SMLWorkflowRuntimePlanningSkillIndexEntry].self,
            forKey: .skillIndex
        ) ?? []
        let decomposableUnits = try container.decode(
            [SMLWorkflowRuntimePlanningDecompositionUnit].self,
            forKey: .decomposableUnits
        )
        let approvalGates = try container.decode(
            [SMLWorkflowRuntimePlanningApprovalGate].self,
            forKey: .approvalGates
        )
        let commandBindings = try container.decodeIfPresent(
            [SMLWorkflowRuntimePlanningCommandBinding].self,
            forKey: .commandBindings
        ) ?? []
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
            apiWorkflowPath: try container.decodeIfPresent(String.self, forKey: .apiWorkflowPath)
                ?? SMLWorkflowRuntimeAPIWorkflowPath.inferredWorkflowPath(
                    workflowID: workflowID,
                    apiBasePath: apiBasePath,
                    apiRoutes: apiRoutes
                ),
            replMount: replMount,
            apiRoutes: apiRoutes,
            modelToolName: modelToolName,
            model: model,
            modelRouterToolName: modelRouterToolName,
            onyxDriverID: onyxDriverID,
            planningWorkflowID: planningWorkflowID,
            plannerEntrypoint: plannerEntrypoint,
            toolReferences: toolReferences,
            skillIndex: skillIndex,
            decomposableUnits: decomposableUnits,
            approvalGates: approvalGates,
            commandBindings: commandBindings,
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
        try container.encode(apiWorkflowPath, forKey: .apiWorkflowPath)
        try container.encode(replMount, forKey: .replMount)
        try container.encode(apiRoutes, forKey: .apiRoutes)
        try container.encode(modelToolName, forKey: .modelToolName)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(modelRouterToolName, forKey: .modelRouterToolName)
        try container.encode(onyxDriverID, forKey: .onyxDriverID)
        try container.encodeIfPresent(planningWorkflowID, forKey: .planningWorkflowID)
        try container.encodeIfPresent(plannerEntrypoint, forKey: .plannerEntrypoint)
        try container.encode(toolReferences, forKey: .toolReferences)
        try container.encode(skillIndex, forKey: .skillIndex)
        try container.encode(decomposableUnits, forKey: .decomposableUnits)
        try container.encode(approvalGates, forKey: .approvalGates)
        try container.encode(commandBindings, forKey: .commandBindings)
        try container.encode(hostBindings, forKey: .hostBindings)
        try container.encode(attachment, forKey: .attachment)
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
}

public struct SMLWorkflowRuntimeHostWiring: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 16

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
