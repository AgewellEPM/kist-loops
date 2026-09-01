import Foundation

public struct SMLWorkflowRuntimePlanningWorkflow: Sendable, Codable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let workflowName: String
    public let role: String
    public let sourceKind: SMLWorkflowSourceKind
    public let sourceReference: String
    public let sourceDigest: String?
    public let entrypoint: String
    public let apiBasePath: String
    public let apiWorkflowPath: String
    public let workflowMetadata: SMLWorkflowRuntimeWorkflowMetadataLinks
    public let replGrammar: String
    public let modelToolName: String
    public let modelRouterToolName: String
    public let skillTree: [SMLOnyxSkillNode]
    public let tools: [SMLOnyxToolBinding]
    public let plan: SMLOnyxPlan

    public init(
        workflowID: String,
        workflowVersion: String,
        workflowName: String,
        role: String,
        sourceKind: SMLWorkflowSourceKind,
        sourceReference: String,
        sourceDigest: String?,
        entrypoint: String,
        apiBasePath: String,
        apiWorkflowPath: String? = nil,
        workflowMetadata: SMLWorkflowRuntimeWorkflowMetadataLinks? = nil,
        replGrammar: String,
        modelToolName: String,
        modelRouterToolName: String,
        skillTree: [SMLOnyxSkillNode],
        tools: [SMLOnyxToolBinding],
        plan: SMLOnyxPlan
    ) {
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.workflowName = workflowName
        self.role = role
        self.sourceKind = sourceKind
        self.sourceReference = sourceReference
        self.sourceDigest = sourceDigest
        self.entrypoint = entrypoint
        self.apiBasePath = apiBasePath
        self.apiWorkflowPath = apiWorkflowPath
            ?? SMLWorkflowRuntimeAPIWorkflowPath.defaultWorkflowPath(workflowID: workflowID)
        self.workflowMetadata = workflowMetadata ?? SMLWorkflowRuntimeWorkflowMetadataLinks(
            workflowID: workflowID,
            workflowVersion: workflowVersion,
            apiBasePath: apiBasePath
        )
        self.replGrammar = replGrammar
        self.modelToolName = modelToolName
        self.modelRouterToolName = modelRouterToolName
        self.skillTree = skillTree
        self.tools = tools
        self.plan = plan
    }

    public init(_ descriptor: SMLWorkflowRuntimeDescriptor) {
        self.init(
            workflowID: descriptor.workflowID,
            workflowVersion: descriptor.workflowVersion,
            workflowName: descriptor.workflowName,
            role: descriptor.role,
            sourceKind: descriptor.sourceKind,
            sourceReference: descriptor.sourceReference,
            sourceDigest: descriptor.sourceDigest,
            entrypoint: descriptor.onyx.plan.entrypoint,
            apiBasePath: descriptor.api.basePath,
            apiWorkflowPath: descriptor.api.workflowPath,
            workflowMetadata: SMLWorkflowRuntimeWorkflowMetadataLinks(descriptor),
            replGrammar: descriptor.repl.grammar,
            modelToolName: descriptor.model.tool.name,
            modelRouterToolName: SMLWorkflowRuntimeModelAdapter.toolName,
            skillTree: descriptor.onyx.skillTree,
            tools: descriptor.onyx.tools,
            plan: descriptor.onyx.plan
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
        case entrypoint
        case apiBasePath
        case apiWorkflowPath
        case workflowMetadata
        case replGrammar
        case modelToolName
        case modelRouterToolName
        case skillTree
        case tools
        case plan
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let workflowID = try container.decode(String.self, forKey: .workflowID)
        self.init(
            workflowID: workflowID,
            workflowVersion: try container.decode(String.self, forKey: .workflowVersion),
            workflowName: try container.decode(String.self, forKey: .workflowName),
            role: try container.decode(String.self, forKey: .role),
            sourceKind: try container.decode(SMLWorkflowSourceKind.self, forKey: .sourceKind),
            sourceReference: try container.decode(String.self, forKey: .sourceReference),
            sourceDigest: try container.decodeIfPresent(String.self, forKey: .sourceDigest),
            entrypoint: try container.decode(String.self, forKey: .entrypoint),
            apiBasePath: try container.decode(String.self, forKey: .apiBasePath),
            apiWorkflowPath: try container.decodeIfPresent(String.self, forKey: .apiWorkflowPath),
            workflowMetadata: try container.decodeIfPresent(
                SMLWorkflowRuntimeWorkflowMetadataLinks.self,
                forKey: .workflowMetadata
            ),
            replGrammar: try container.decode(String.self, forKey: .replGrammar),
            modelToolName: try container.decode(String.self, forKey: .modelToolName),
            modelRouterToolName: try container.decode(String.self, forKey: .modelRouterToolName),
            skillTree: try container.decode([SMLOnyxSkillNode].self, forKey: .skillTree),
            tools: try container.decode([SMLOnyxToolBinding].self, forKey: .tools),
            plan: try container.decode(SMLOnyxPlan.self, forKey: .plan)
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
        try container.encode(entrypoint, forKey: .entrypoint)
        try container.encode(apiBasePath, forKey: .apiBasePath)
        try container.encode(apiWorkflowPath, forKey: .apiWorkflowPath)
        try container.encode(workflowMetadata, forKey: .workflowMetadata)
        try container.encode(replGrammar, forKey: .replGrammar)
        try container.encode(modelToolName, forKey: .modelToolName)
        try container.encode(modelRouterToolName, forKey: .modelRouterToolName)
        try container.encode(skillTree, forKey: .skillTree)
        try container.encode(tools, forKey: .tools)
        try container.encode(plan, forKey: .plan)
    }
}

public struct SMLWorkflowRuntimePlanningSkillIndexEntry: Sendable, Codable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let instructionID: String
    public let kind: SMLOnyxSkillKind
    public let operation: SMLInstructionOperation
    public let reference: String?
    public let prerequisites: [String]
    public let successors: [String]
    public let unitKind: SMLOnyxPlanningUnitKind?
    public let statePreconditions: [String]
    public let expectedState: SMLObject
    public let declaredOutputs: [String]
    public let outputSchema: String?
    public let receiptFields: [String]
    public let canDecomposeFurther: Bool
    public let requiresApproval: Bool
    public let terminal: Bool

    public init(
        workflowID: String,
        workflowVersion: String,
        instructionID: String,
        kind: SMLOnyxSkillKind,
        operation: SMLInstructionOperation,
        reference: String?,
        prerequisites: [String],
        successors: [String],
        unitKind: SMLOnyxPlanningUnitKind?,
        statePreconditions: [String],
        expectedState: SMLObject,
        declaredOutputs: [String],
        outputSchema: String?,
        receiptFields: [String],
        canDecomposeFurther: Bool,
        requiresApproval: Bool,
        terminal: Bool
    ) {
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.instructionID = instructionID
        self.kind = kind
        self.operation = operation
        self.reference = reference
        self.prerequisites = prerequisites.sorted()
        self.successors = successors.sorted()
        self.unitKind = unitKind
        self.statePreconditions = statePreconditions.sorted()
        self.expectedState = expectedState
        self.declaredOutputs = declaredOutputs.sorted()
        self.outputSchema = outputSchema
        self.receiptFields = receiptFields.sorted()
        self.canDecomposeFurther = canDecomposeFurther
        self.requiresApproval = requiresApproval
        self.terminal = terminal
    }

    public init(
        workflow: SMLWorkflowRuntimePlanningWorkflow,
        node: SMLOnyxSkillNode,
        planNode: SMLOnyxPlanNode?
    ) {
        self.init(
            workflowID: workflow.workflowID,
            workflowVersion: workflow.workflowVersion,
            instructionID: node.id,
            kind: node.kind,
            operation: node.operation,
            reference: node.reference,
            prerequisites: node.prerequisites,
            successors: node.successors,
            unitKind: node.planning?.unitKind,
            statePreconditions: node.planning?.statePreconditions ?? [],
            expectedState: node.planning?.expectedState ?? [:],
            declaredOutputs: node.planning?.declaredOutputs ?? [],
            outputSchema: node.planning?.outputSchema,
            receiptFields: node.planning?.receiptFields ?? [],
            canDecomposeFurther: node.planning?.canDecomposeFurther ?? false,
            requiresApproval: planNode?.requiresApproval ?? (node.operation == .waitApproval),
            terminal: planNode?.terminal ?? [
                .complete, .escalate, .emitReceipt,
            ].contains(node.operation)
        )
    }
}

public struct SMLWorkflowRuntimePlanningToolIndexEntry: Sendable, Codable, Equatable {
    public let workflowID: String
    public let instructionID: String
    public let operation: SMLInstructionOperation
    public let reference: String
    public let unitKind: SMLOnyxPlanningUnitKind?
    public let statePreconditions: [String]
    public let declaredOutputs: [String]
    public let verifier: String?
    public let sideEffectLevel: SMLSideEffectLevel?

    public init(
        workflowID: String,
        instructionID: String,
        operation: SMLInstructionOperation,
        reference: String,
        unitKind: SMLOnyxPlanningUnitKind?,
        statePreconditions: [String],
        declaredOutputs: [String],
        verifier: String?,
        sideEffectLevel: SMLSideEffectLevel?
    ) {
        self.workflowID = workflowID
        self.instructionID = instructionID
        self.operation = operation
        self.reference = reference
        self.unitKind = unitKind
        self.statePreconditions = statePreconditions.sorted()
        self.declaredOutputs = declaredOutputs.sorted()
        self.verifier = verifier
        self.sideEffectLevel = sideEffectLevel
    }
}

public struct SMLWorkflowRuntimePlanningDecompositionUnit: Sendable, Codable, Equatable {
    public let workflowID: String
    public let instructionID: String
    public let unitKind: SMLOnyxPlanningUnitKind
    public let reference: String?
    public let successors: [String]

    public init(
        workflowID: String,
        instructionID: String,
        unitKind: SMLOnyxPlanningUnitKind,
        reference: String?,
        successors: [String]
    ) {
        self.workflowID = workflowID
        self.instructionID = instructionID
        self.unitKind = unitKind
        self.reference = reference
        self.successors = successors.sorted()
    }
}

public struct SMLWorkflowRuntimePlanningApprovalGate: Sendable, Codable, Equatable {
    public let workflowID: String
    public let instructionID: String
    public let reference: String?
    public let statePreconditions: [String]
    public let successors: [String]

    public init(
        workflowID: String,
        instructionID: String,
        reference: String?,
        statePreconditions: [String],
        successors: [String]
    ) {
        self.workflowID = workflowID
        self.instructionID = instructionID
        self.reference = reference
        self.statePreconditions = statePreconditions.sorted()
        self.successors = successors.sorted()
    }
}

public struct SMLWorkflowRuntimePlanningCommandBinding: Sendable, Codable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let action: SMLWorkflowControlAction
    public let replVerb: String
    public let replAliases: [String]
    public let replLineTemplate: String
    public let replJSONBodyKind: SMLWorkflowREPLJSONBodyKind
    public let replJSONFields: [SMLWorkflowFieldDescriptor]
    public let apiMethod: SMLWorkflowAPIMethod
    public let apiPathTemplate: String
    public let apiOperationID: String
    public let apiBodyKind: SMLWorkflowAPIRequestBodyKind
    public let apiBodyFields: [SMLWorkflowFieldDescriptor]
    public let readOnly: Bool
    public let requiresTask: Bool
    public let changesTaskState: Bool
    public let modelEligible: Bool
    public let modelToolName: String
    public let modelRouterToolName: String
    public let modelRouterArgumentsTemplate: SMLObject
    public let exampleReplLine: String?
    public let exampleAPIPath: String?
    public let exampleAPIBody: SMLObject?
    public let exampleModelRouterArguments: SMLObject?

    public init(
        workflowID: String,
        workflowVersion: String,
        action: SMLWorkflowControlAction,
        replVerb: String,
        replAliases: [String],
        replLineTemplate: String,
        replJSONBodyKind: SMLWorkflowREPLJSONBodyKind,
        replJSONFields: [SMLWorkflowFieldDescriptor],
        apiMethod: SMLWorkflowAPIMethod,
        apiPathTemplate: String,
        apiOperationID: String,
        apiBodyKind: SMLWorkflowAPIRequestBodyKind,
        apiBodyFields: [SMLWorkflowFieldDescriptor],
        readOnly: Bool,
        requiresTask: Bool,
        changesTaskState: Bool,
        modelEligible: Bool,
        modelToolName: String,
        modelRouterToolName: String,
        modelRouterArgumentsTemplate: SMLObject,
        exampleReplLine: String?,
        exampleAPIPath: String?,
        exampleAPIBody: SMLObject?,
        exampleModelRouterArguments: SMLObject?
    ) {
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.action = action
        self.replVerb = replVerb
        self.replAliases = Array(Set(replAliases)).sorted()
        self.replLineTemplate = replLineTemplate
        self.replJSONBodyKind = replJSONBodyKind
        self.replJSONFields = replJSONFields.sorted {
            if $0.required != $1.required { return $0.required && !$1.required }
            return $0.name < $1.name
        }
        self.apiMethod = apiMethod
        self.apiPathTemplate = apiPathTemplate
        self.apiOperationID = apiOperationID
        self.apiBodyKind = apiBodyKind
        self.apiBodyFields = apiBodyFields.sorted {
            if $0.required != $1.required { return $0.required && !$1.required }
            return $0.name < $1.name
        }
        self.readOnly = readOnly
        self.requiresTask = requiresTask
        self.changesTaskState = changesTaskState
        self.modelEligible = modelEligible
        self.modelToolName = modelToolName
        self.modelRouterToolName = modelRouterToolName
        self.modelRouterArgumentsTemplate = modelRouterArgumentsTemplate
        self.exampleReplLine = exampleReplLine
        self.exampleAPIPath = exampleAPIPath
        self.exampleAPIBody = exampleAPIBody
        self.exampleModelRouterArguments = exampleModelRouterArguments
    }
}

public struct SMLWorkflowRuntimePlanningWorkflowBundle: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let workflowID: String
    public let workflowVersion: String
    public let workflowName: String
    public let role: String
    public let apiBasePath: String
    public let apiWorkflowPath: String
    public let workflowMetadata: SMLWorkflowRuntimeWorkflowMetadataLinks
    public let workflow: SMLWorkflowRuntimePlanningWorkflow
    public let skillIndex: [SMLWorkflowRuntimePlanningSkillIndexEntry]
    public let toolIndex: [SMLWorkflowRuntimePlanningToolIndexEntry]
    public let toolBindings: [SMLOnyxToolBinding]
    public let decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit]
    public let approvalGates: [SMLWorkflowRuntimePlanningApprovalGate]
    public let commandBindings: [SMLWorkflowRuntimePlanningCommandBinding]

    public init(
        schemaVersion: Int = SMLWorkflowRuntimePlanningWorkflowBundle.currentSchemaVersion,
        workflow: SMLWorkflowRuntimePlanningWorkflow,
        skillIndex: [SMLWorkflowRuntimePlanningSkillIndexEntry],
        toolIndex: [SMLWorkflowRuntimePlanningToolIndexEntry],
        decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit],
        approvalGates: [SMLWorkflowRuntimePlanningApprovalGate],
        commandBindings: [SMLWorkflowRuntimePlanningCommandBinding]
    ) {
        self.schemaVersion = schemaVersion
        self.workflowID = workflow.workflowID
        self.workflowVersion = workflow.workflowVersion
        self.workflowName = workflow.workflowName
        self.role = workflow.role
        self.apiBasePath = workflow.apiBasePath
        self.apiWorkflowPath = workflow.apiWorkflowPath
        self.workflowMetadata = workflow.workflowMetadata
        self.workflow = workflow
        self.skillIndex = skillIndex.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            if $0.instructionID != $1.instructionID {
                return $0.instructionID < $1.instructionID
            }
            return $0.operation.rawValue < $1.operation.rawValue
        }
        self.toolIndex = toolIndex.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            if $0.instructionID != $1.instructionID {
                return $0.instructionID < $1.instructionID
            }
            return $0.reference < $1.reference
        }
        self.toolBindings = workflow.tools.sorted {
            if $0.instructionID != $1.instructionID {
                return $0.instructionID < $1.instructionID
            }
            return $0.reference < $1.reference
        }
        self.decomposableUnits = decomposableUnits.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.instructionID < $1.instructionID
        }
        self.approvalGates = approvalGates.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.instructionID < $1.instructionID
        }
        self.commandBindings = commandBindings.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            if $0.action.rawValue != $1.action.rawValue {
                return $0.action.rawValue < $1.action.rawValue
            }
            return $0.replVerb < $1.replVerb
        }
    }
}

/// Runtime-level planning manifest for a mounted workflow app.
///
/// This aggregates the already-admitted per-workflow Onyx skill trees, tool bindings, and graph
/// plans into one portable value a planner can load before choosing a REPL/API/model command. It is
/// intentionally descriptor-only: no actor, lease, credential, runtime handle, provider registry, or
/// executable closure is present.
public struct SMLWorkflowRuntimePlanningManifest: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 5

    public let schemaVersion: Int
    public let workflowIDs: [String]
    public let workflows: [SMLWorkflowRuntimePlanningWorkflow]
    public let skillIndex: [SMLWorkflowRuntimePlanningSkillIndexEntry]
    public let toolIndex: [SMLWorkflowRuntimePlanningToolIndexEntry]
    public let decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit]
    public let approvalGates: [SMLWorkflowRuntimePlanningApprovalGate]
    public let commandBindings: [SMLWorkflowRuntimePlanningCommandBinding]

    public init(
        schemaVersion: Int = SMLWorkflowRuntimePlanningManifest.currentSchemaVersion,
        workflows: [SMLWorkflowRuntimePlanningWorkflow],
        commandBindings: [SMLWorkflowRuntimePlanningCommandBinding] = []
    ) {
        let sortedWorkflows = workflows.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.workflowVersion < $1.workflowVersion
        }
        self.schemaVersion = schemaVersion
        self.workflowIDs = sortedWorkflows.map(\.workflowID)
        self.workflows = sortedWorkflows
        self.skillIndex = Self.skillIndex(for: sortedWorkflows)
        self.toolIndex = Self.toolIndex(for: sortedWorkflows)
        self.decomposableUnits = Self.decomposableUnits(for: sortedWorkflows)
        self.approvalGates = Self.approvalGates(for: sortedWorkflows)
        self.commandBindings = commandBindings.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            if $0.action.rawValue != $1.action.rawValue {
                return $0.action.rawValue < $1.action.rawValue
            }
            return $0.replVerb < $1.replVerb
        }
    }

    public init(
        schemaVersion: Int = SMLWorkflowRuntimePlanningManifest.currentSchemaVersion,
        descriptors: [SMLWorkflowRuntimeDescriptor]
    ) {
        self.init(
            schemaVersion: schemaVersion,
            workflows: descriptors.map(SMLWorkflowRuntimePlanningWorkflow.init),
            commandBindings: descriptors.flatMap { Self.commandBindings(for: $0) }
        )
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case workflowIDs
        case workflows
        case skillIndex
        case toolIndex
        case decomposableUnits
        case approvalGates
        case commandBindings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            workflows: try container.decode(
                [SMLWorkflowRuntimePlanningWorkflow].self,
                forKey: .workflows
            ),
            commandBindings: try container.decodeIfPresent(
                [SMLWorkflowRuntimePlanningCommandBinding].self,
                forKey: .commandBindings
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(workflowIDs, forKey: .workflowIDs)
        try container.encode(workflows, forKey: .workflows)
        try container.encode(skillIndex, forKey: .skillIndex)
        try container.encode(toolIndex, forKey: .toolIndex)
        try container.encode(decomposableUnits, forKey: .decomposableUnits)
        try container.encode(approvalGates, forKey: .approvalGates)
        try container.encode(commandBindings, forKey: .commandBindings)
    }

    public static func commandBindings(
        workflowID: String,
        workflowVersion: String,
        replCommands: [SMLWorkflowREPLCommandDescriptor],
        replExamples: [SMLWorkflowREPLExample],
        apiEndpoints: [SMLWorkflowAPIEndpoint],
        modelAllowedActions: [SMLWorkflowControlAction],
        modelToolName: String
    ) -> [SMLWorkflowRuntimePlanningCommandBinding] {
        let endpointsByAction = Dictionary(
            uniqueKeysWithValues: apiEndpoints.map { ($0.action, $0) }
        )
        let examplesByVerb = Dictionary(
            grouping: replExamples,
            by: \.verb
        ).mapValues { examples in examples.sorted { $0.line < $1.line } }
        let modelAllowedActions = Set(modelAllowedActions)
        return replCommands.compactMap { command in
            guard command.kind == .runtime,
                  let action = command.action,
                  let endpoint = endpointsByAction[action] else {
                return nil
            }
            let modelEligible = modelAllowedActions.contains(action)
            let replExample = examplesByVerb[command.verb]?.first
            let apiExample = endpoint.examples.first
            let exampleModelArguments: SMLObject?
            if modelEligible, let line = replExample?.line {
                exampleModelArguments = [
                    "workflow_id": .string(workflowID),
                    "line": .string(line),
                ]
            } else {
                exampleModelArguments = nil
            }
            return SMLWorkflowRuntimePlanningCommandBinding(
                workflowID: workflowID,
                workflowVersion: workflowVersion,
                action: action,
                replVerb: command.verb,
                replAliases: command.aliases,
                replLineTemplate: command.usage,
                replJSONBodyKind: command.jsonBodyKind,
                replJSONFields: command.jsonFields,
                apiMethod: endpoint.method,
                apiPathTemplate: endpoint.pathTemplate,
                apiOperationID: runtimeOperationID(
                    endpoint,
                    workflowID: workflowID
                ),
                apiBodyKind: endpoint.bodyKind,
                apiBodyFields: endpoint.bodyFields,
                readOnly: !command.changesTaskState,
                requiresTask: command.requiresTask,
                changesTaskState: command.changesTaskState,
                modelEligible: modelEligible,
                modelToolName: modelToolName,
                modelRouterToolName: SMLWorkflowRuntimeModelAdapter.toolName,
                modelRouterArgumentsTemplate: [
                    "workflow_id": .string(workflowID),
                    "line": .string(command.usage),
                ],
                exampleReplLine: replExample?.line,
                exampleAPIPath: apiExample?.path,
                exampleAPIBody: apiExample?.body,
                exampleModelRouterArguments: exampleModelArguments
            )
        }.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            if $0.action.rawValue != $1.action.rawValue {
                return $0.action.rawValue < $1.action.rawValue
            }
            return $0.replVerb < $1.replVerb
        }
    }

    public static func commandBindings(
        for descriptor: SMLWorkflowRuntimeDescriptor
    ) -> [SMLWorkflowRuntimePlanningCommandBinding] {
        commandBindings(
            workflowID: descriptor.workflowID,
            workflowVersion: descriptor.workflowVersion,
            replCommands: descriptor.repl.commands,
            replExamples: descriptor.repl.examples,
            apiEndpoints: descriptor.api.endpoints,
            modelAllowedActions: descriptor.model.allowedActions,
            modelToolName: descriptor.model.tool.name
        )
    }

    private static func skillIndex(
        for workflows: [SMLWorkflowRuntimePlanningWorkflow]
    ) -> [SMLWorkflowRuntimePlanningSkillIndexEntry] {
        workflows.flatMap { workflow in
            var planNodesByID: [String: SMLOnyxPlanNode] = [:]
            for planNode in workflow.plan.nodes {
                planNodesByID[planNode.id] = planNode
            }
            return workflow.skillTree.map { node in
                SMLWorkflowRuntimePlanningSkillIndexEntry(
                    workflow: workflow,
                    node: node,
                    planNode: planNodesByID[node.id]
                )
            }
        }.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            if $0.instructionID != $1.instructionID {
                return $0.instructionID < $1.instructionID
            }
            return $0.operation.rawValue < $1.operation.rawValue
        }
    }

    private static func toolIndex(
        for workflows: [SMLWorkflowRuntimePlanningWorkflow]
    ) -> [SMLWorkflowRuntimePlanningToolIndexEntry] {
        workflows.flatMap { workflow in
            let planningByInstructionID = Dictionary(
                uniqueKeysWithValues: workflow.skillTree.compactMap { node in
                    node.planning.map { (node.id, $0) }
                }
            )
            return workflow.tools.map { binding in
                let planning = planningByInstructionID[binding.instructionID]
                return SMLWorkflowRuntimePlanningToolIndexEntry(
                    workflowID: workflow.workflowID,
                    instructionID: binding.instructionID,
                    operation: binding.operation,
                    reference: binding.reference,
                    unitKind: planning?.unitKind,
                    statePreconditions: planning?.statePreconditions ?? [],
                    declaredOutputs: planning?.declaredOutputs ?? [],
                    verifier: binding.verifier,
                    sideEffectLevel: binding.sideEffectLevel
                )
            }
        }.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            if $0.instructionID != $1.instructionID { return $0.instructionID < $1.instructionID }
            return $0.reference < $1.reference
        }
    }

    private static func decomposableUnits(
        for workflows: [SMLWorkflowRuntimePlanningWorkflow]
    ) -> [SMLWorkflowRuntimePlanningDecompositionUnit] {
        workflows.flatMap { workflow in
            workflow.skillTree.compactMap { node in
                guard let planning = node.planning, planning.canDecomposeFurther else {
                    return nil
                }
                return SMLWorkflowRuntimePlanningDecompositionUnit(
                    workflowID: workflow.workflowID,
                    instructionID: node.id,
                    unitKind: planning.unitKind,
                    reference: node.reference,
                    successors: node.successors
                )
            }
        }.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.instructionID < $1.instructionID
        }
    }

    private static func approvalGates(
        for workflows: [SMLWorkflowRuntimePlanningWorkflow]
    ) -> [SMLWorkflowRuntimePlanningApprovalGate] {
        workflows.flatMap { workflow in
            workflow.skillTree.compactMap { node in
                guard node.operation == .waitApproval
                    || node.planning?.unitKind == .approvalGate else {
                    return nil
                }
                return SMLWorkflowRuntimePlanningApprovalGate(
                    workflowID: workflow.workflowID,
                    instructionID: node.id,
                    reference: node.reference,
                    statePreconditions: node.planning?.statePreconditions ?? [],
                    successors: node.successors
                )
            }
        }.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.instructionID < $1.instructionID
        }
    }

    private static func runtimeOperationID(
        _ endpoint: SMLWorkflowAPIEndpoint,
        workflowID: String
    ) -> String {
        "\(endpoint.operationID)_\(componentSuffix(workflowID))"
    }

    private static func componentSuffix(_ workflowID: String) -> String {
        workflowID
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

