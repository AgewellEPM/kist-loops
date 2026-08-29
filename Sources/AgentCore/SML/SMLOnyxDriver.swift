import Foundation

public enum SMLOnyxSkillKind: String, Sendable, Codable, Equatable {
    case knowledge
    case reasoning
    case action
    case verification
    case control
    case governance
}

public enum SMLOnyxPlanningUnitKind: String, Sendable, Codable, Equatable {
    case atomic
    case control
    case externalCapability = "external_capability"
    case modelReasoning = "model_reasoning"
    case nestedWorkflow = "nested_workflow"
    case pluginContract = "plugin_contract"
    case approvalGate = "approval_gate"
    case boundedRetry = "bounded_retry"
    case terminal
}

public struct SMLOnyxPlanningContract: Sendable, Codable, Equatable {
    public let unitKind: SMLOnyxPlanningUnitKind
    public let statePreconditions: [String]
    public let condition: SMLCondition?
    public let expectedState: SMLObject
    public let declaredOutputs: [String]
    public let outputSchema: String?
    public let receiptFields: [String]
    public let retryPolicy: SMLRetryPolicy?
    public let plugin: SMLPluginContract?
    public let canDecomposeFurther: Bool

    public init(
        unitKind: SMLOnyxPlanningUnitKind,
        statePreconditions: [String],
        condition: SMLCondition?,
        expectedState: SMLObject,
        declaredOutputs: [String],
        outputSchema: String?,
        receiptFields: [String],
        retryPolicy: SMLRetryPolicy?,
        plugin: SMLPluginContract?,
        canDecomposeFurther: Bool
    ) {
        self.unitKind = unitKind
        self.statePreconditions = statePreconditions
        self.condition = condition
        self.expectedState = expectedState
        self.declaredOutputs = declaredOutputs
        self.outputSchema = outputSchema
        self.receiptFields = receiptFields
        self.retryPolicy = retryPolicy
        self.plugin = plugin
        self.canDecomposeFurther = canDecomposeFurther
    }
}

public struct SMLOnyxSkillNode: Sendable, Codable, Equatable {
    public let id: String
    public let kind: SMLOnyxSkillKind
    public let operation: SMLInstructionOperation
    public let reference: String?
    public let prerequisites: [String]
    public let successors: [String]
    public let planning: SMLOnyxPlanningContract?

    public init(
        id: String,
        kind: SMLOnyxSkillKind,
        operation: SMLInstructionOperation,
        reference: String?,
        prerequisites: [String],
        successors: [String],
        planning: SMLOnyxPlanningContract? = nil
    ) {
        self.id = id
        self.kind = kind
        self.operation = operation
        self.reference = reference
        self.prerequisites = prerequisites
        self.successors = successors
        self.planning = planning
    }
}

public struct SMLOnyxToolBinding: Sendable, Codable, Equatable {
    public let instructionID: String
    public let operation: SMLInstructionOperation
    public let reference: String
    public let arguments: SMLObject
    public let scope: SMLObject
    public let expectedState: SMLObject
    public let verifier: String?
    public let sideEffectLevel: SMLSideEffectLevel?

    public init(
        instructionID: String,
        operation: SMLInstructionOperation,
        reference: String,
        arguments: SMLObject,
        scope: SMLObject,
        expectedState: SMLObject,
        verifier: String?,
        sideEffectLevel: SMLSideEffectLevel?
    ) {
        self.instructionID = instructionID
        self.operation = operation
        self.reference = reference
        self.arguments = arguments
        self.scope = scope
        self.expectedState = expectedState
        self.verifier = verifier
        self.sideEffectLevel = sideEffectLevel
    }
}

public struct SMLOnyxPlanNode: Sendable, Codable, Equatable {
    public let id: String
    public let operation: SMLInstructionOperation
    public let normalTarget: String?
    public let passTarget: String?
    public let failureTarget: String?
    public let trueTarget: String?
    public let falseTarget: String?
    public let requiresApproval: Bool
    public let terminal: Bool

    public init(
        id: String,
        operation: SMLInstructionOperation,
        normalTarget: String?,
        passTarget: String?,
        failureTarget: String?,
        trueTarget: String?,
        falseTarget: String?,
        requiresApproval: Bool,
        terminal: Bool
    ) {
        self.id = id
        self.operation = operation
        self.normalTarget = normalTarget
        self.passTarget = passTarget
        self.failureTarget = failureTarget
        self.trueTarget = trueTarget
        self.falseTarget = falseTarget
        self.requiresApproval = requiresApproval
        self.terminal = terminal
    }
}

public struct SMLOnyxPlan: Sendable, Codable, Equatable {
    public let entrypoint: String
    public let nodes: [SMLOnyxPlanNode]

    public init(entrypoint: String, nodes: [SMLOnyxPlanNode]) {
        self.entrypoint = entrypoint
        self.nodes = nodes
    }
}

/// Provider-neutral payload an Onyx implementation can load as its workflow driver. It contains no
/// credentials, authority tokens, closures, or execution handles: all commands still return through
/// the generated SML surface and host admission gateway.
public struct SMLOnyxDriverManifest: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let driverID: String
    public let providerFamily: String
    public let workflowID: String
    public let workflowVersion: String
    public let role: String
    public let replGrammar: String
    public let modelToolName: String
    public let modelActions: [SMLWorkflowControlAction]
    public let api: SMLWorkflowAPICatalog
    public let skillTree: [SMLOnyxSkillNode]
    public let tools: [SMLOnyxToolBinding]
    public let plan: SMLOnyxPlan
    public let commandBindings: [SMLWorkflowRuntimePlanningCommandBinding]

    public init(
        schemaVersion: Int = SMLOnyxDriverManifest.currentSchemaVersion,
        driverID: String,
        providerFamily: String = "onyx",
        workflowID: String,
        workflowVersion: String,
        role: String,
        replGrammar: String,
        modelToolName: String,
        modelActions: [SMLWorkflowControlAction],
        api: SMLWorkflowAPICatalog,
        skillTree: [SMLOnyxSkillNode],
        tools: [SMLOnyxToolBinding],
        plan: SMLOnyxPlan,
        commandBindings: [SMLWorkflowRuntimePlanningCommandBinding] = []
    ) {
        self.schemaVersion = schemaVersion
        self.driverID = driverID
        self.providerFamily = providerFamily
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.role = role
        self.replGrammar = replGrammar
        self.modelToolName = modelToolName
        self.modelActions = modelActions
        self.api = api
        self.skillTree = skillTree
        self.tools = tools
        self.plan = plan
        self.commandBindings = Self.sortedCommandBindings(commandBindings)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case driverID
        case providerFamily
        case workflowID
        case workflowVersion
        case role
        case replGrammar
        case modelToolName
        case modelActions
        case api
        case skillTree
        case tools
        case plan
        case commandBindings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            driverID: try container.decode(String.self, forKey: .driverID),
            providerFamily: try container.decode(String.self, forKey: .providerFamily),
            workflowID: try container.decode(String.self, forKey: .workflowID),
            workflowVersion: try container.decode(String.self, forKey: .workflowVersion),
            role: try container.decode(String.self, forKey: .role),
            replGrammar: try container.decode(String.self, forKey: .replGrammar),
            modelToolName: try container.decode(String.self, forKey: .modelToolName),
            modelActions: try container.decode(
                [SMLWorkflowControlAction].self,
                forKey: .modelActions
            ),
            api: try container.decode(SMLWorkflowAPICatalog.self, forKey: .api),
            skillTree: try container.decode([SMLOnyxSkillNode].self, forKey: .skillTree),
            tools: try container.decode([SMLOnyxToolBinding].self, forKey: .tools),
            plan: try container.decode(SMLOnyxPlan.self, forKey: .plan),
            commandBindings: try container.decodeIfPresent(
                [SMLWorkflowRuntimePlanningCommandBinding].self,
                forKey: .commandBindings
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(driverID, forKey: .driverID)
        try container.encode(providerFamily, forKey: .providerFamily)
        try container.encode(workflowID, forKey: .workflowID)
        try container.encode(workflowVersion, forKey: .workflowVersion)
        try container.encode(role, forKey: .role)
        try container.encode(replGrammar, forKey: .replGrammar)
        try container.encode(modelToolName, forKey: .modelToolName)
        try container.encode(modelActions, forKey: .modelActions)
        try container.encode(api, forKey: .api)
        try container.encode(skillTree, forKey: .skillTree)
        try container.encode(tools, forKey: .tools)
        try container.encode(plan, forKey: .plan)
        try container.encode(commandBindings, forKey: .commandBindings)
    }

    public func withCommandBindings(
        _ commandBindings: [SMLWorkflowRuntimePlanningCommandBinding]
    ) -> SMLOnyxDriverManifest {
        SMLOnyxDriverManifest(
            schemaVersion: SMLOnyxDriverManifest.currentSchemaVersion,
            driverID: driverID,
            providerFamily: providerFamily,
            workflowID: workflowID,
            workflowVersion: workflowVersion,
            role: role,
            replGrammar: replGrammar,
            modelToolName: modelToolName,
            modelActions: modelActions,
            api: api,
            skillTree: skillTree,
            tools: tools,
            plan: plan,
            commandBindings: commandBindings
        )
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

public enum SMLOnyxDriverCompiler {
    public static func compile(
        surface: SMLWorkflowSurface,
        modelActions: Set<SMLWorkflowControlAction> = SMLWorkflowSurface.modelDefaultActions,
        apiBasePath: String = "/v1"
    ) -> SMLOnyxDriverManifest {
        let workflow = surface.workflow
        let successorsByID = Dictionary(uniqueKeysWithValues: workflow.instructions.map {
            ($0.id, successors(of: $0))
        })
        var predecessors: [String: [String]] = [:]
        for (source, targets) in successorsByID {
            for target in targets { predecessors[target, default: []].append(source) }
        }
        let skillTree = workflow.instructions.map { instruction in
            SMLOnyxSkillNode(
                id: instruction.id,
                kind: skillKind(instruction.op),
                operation: instruction.op,
                reference: reference(of: instruction),
                prerequisites: (predecessors[instruction.id] ?? []).sorted(),
                successors: (successorsByID[instruction.id] ?? []).sorted(),
                planning: planningContract(instruction)
            )
        }
        let tools = workflow.instructions.compactMap(toolBinding).sorted {
            $0.instructionID < $1.instructionID
        }
        let api = SMLWorkflowAPICatalog(surface: surface, basePath: apiBasePath)
        let modelToolName = "propose_sml_command"
        let planNodes = workflow.instructions.map { instruction in
            SMLOnyxPlanNode(
                id: instruction.id,
                operation: instruction.op,
                normalTarget: instruction.next,
                passTarget: instruction.onPass,
                failureTarget: instruction.onFailure,
                trueTarget: instruction.trueTarget,
                falseTarget: instruction.falseTarget,
                requiresApproval: instruction.op == .waitApproval,
                terminal: [.complete, .escalate, .emitReceipt].contains(instruction.op)
            )
        }
        let actions = modelActions.sorted { $0.rawValue < $1.rawValue }
        let commandBindings = SMLWorkflowRuntimePlanningManifest.commandBindings(
            workflowID: workflow.id,
            workflowVersion: workflow.version,
            replCommands: surface.replCommandDescriptors(),
            replExamples: surface.replExamples(),
            apiEndpoints: api.endpoints,
            modelAllowedActions: actions,
            modelToolName: modelToolName
        )
        return SMLOnyxDriverManifest(
            driverID: driverID(for: surface),
            workflowID: workflow.id,
            workflowVersion: workflow.version,
            role: surface.role,
            replGrammar: surface.grammar(allowedActions: modelActions),
            modelToolName: modelToolName,
            modelActions: actions,
            api: api,
            skillTree: skillTree,
            tools: tools,
            plan: SMLOnyxPlan(entrypoint: workflow.entrypoint, nodes: planNodes),
            commandBindings: commandBindings
        )
    }

    /// Versions may contain SemVer build punctuation and are intentionally not length-bounded by
    /// the imported IR. Keep the public identifier readable but bind the exact workflow revision and
    /// role through a fixed-size digest so every emitted driver ID remains a valid SML identifier.
    private static func driverID(for surface: SMLWorkflowSurface) -> String {
        let workflow = surface.workflow
        let identity = [
            "sml-onyx-driver-v1", workflow.id, workflow.version, surface.role,
        ].joined(separator: "\u{0}")
        let digest = MythosCrypto.sha256(Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "onyx.\(String(workflow.id.prefix(48))).\(digest)"
    }

    private static func skillKind(_ operation: SMLInstructionOperation) -> SMLOnyxSkillKind {
        switch operation {
        case .observe, .retrieve: return .knowledge
        case .callModel: return .reasoning
        case .callTool, .invokeVCard, .runPlugin, .runWorkflow: return .action
        case .assert, .verify: return .verification
        case .branch, .retry: return .control
        case .checkpoint, .waitApproval, .rollback, .escalate, .commit,
             .emitReceipt, .complete: return .governance
        }
    }

    private static func planningContract(
        _ instruction: SMLInstruction
    ) -> SMLOnyxPlanningContract {
        let conditionFields = instruction.condition?.clauses.map(\.field) ?? []
        let statePreconditions = Array(Set(
            conditionFields + Array(instruction.expectedState.keys)
        )).sorted()
        var declaredOutputs = Set<String>()
        declaredOutputs.formUnion(instruction.receiptFields)
        if let plugin = instruction.plugin {
            declaredOutputs.formUnion(plugin.writes)
        }
        return SMLOnyxPlanningContract(
            unitKind: planningUnitKind(instruction.op),
            statePreconditions: statePreconditions,
            condition: instruction.condition,
            expectedState: instruction.expectedState,
            declaredOutputs: Array(declaredOutputs).sorted(),
            outputSchema: instruction.outputSchema,
            receiptFields: instruction.receiptFields,
            retryPolicy: instruction.retryPolicy,
            plugin: instruction.plugin,
            canDecomposeFurther: canDecomposeFurther(instruction.op)
        )
    }

    private static func planningUnitKind(
        _ operation: SMLInstructionOperation
    ) -> SMLOnyxPlanningUnitKind {
        switch operation {
        case .observe, .retrieve, .callTool, .invokeVCard, .verify, .commit:
            return .externalCapability
        case .callModel:
            return .modelReasoning
        case .runPlugin:
            return .pluginContract
        case .runWorkflow:
            return .nestedWorkflow
        case .branch, .assert, .checkpoint:
            return .control
        case .waitApproval:
            return .approvalGate
        case .retry:
            return .boundedRetry
        case .rollback, .escalate, .emitReceipt, .complete:
            return .terminal
        }
    }

    private static func canDecomposeFurther(_ operation: SMLInstructionOperation) -> Bool {
        switch operation {
        case .runPlugin, .runWorkflow:
            return true
        case .observe, .retrieve, .callTool, .callModel, .invokeVCard, .branch,
             .assert, .verify, .checkpoint, .waitApproval, .retry, .rollback,
             .escalate, .commit, .emitReceipt, .complete:
            return false
        }
    }

    private static func reference(of instruction: SMLInstruction) -> String? {
        switch instruction.op {
        case .observe, .retrieve: return instruction.source
        case .callTool, .invokeVCard: return instruction.capability
        case .callModel: return instruction.purpose
        case .runPlugin: return instruction.plugin?.id
        case .runWorkflow: return instruction.workflow
        case .verify, .commit: return instruction.verifier
        case .waitApproval, .escalate: return instruction.owner
        case .rollback: return instruction.reason
        case .branch, .assert, .checkpoint, .retry, .emitReceipt, .complete: return nil
        }
    }

    private static func toolBinding(_ instruction: SMLInstruction) -> SMLOnyxToolBinding? {
        let external: Bool
        switch instruction.op {
        case .observe, .retrieve, .callTool, .callModel, .invokeVCard,
             .runPlugin, .runWorkflow, .verify, .commit:
            external = true
        case .branch, .assert, .checkpoint, .waitApproval, .retry, .rollback,
             .escalate, .emitReceipt, .complete:
            external = false
        }
        guard external, let reference = reference(of: instruction) else { return nil }
        return SMLOnyxToolBinding(
            instructionID: instruction.id,
            operation: instruction.op,
            reference: reference,
            arguments: instruction.arguments,
            scope: instruction.scope,
            expectedState: instruction.expectedState,
            verifier: instruction.verifier ?? instruction.plugin?.verifier,
            sideEffectLevel: instruction.plugin?.sideEffectLevel
        )
    }

    private static func successors(of instruction: SMLInstruction) -> [String] {
        let values: [String?]
        switch instruction.op {
        case .branch: values = [instruction.trueTarget, instruction.falseTarget]
        case .assert, .verify: values = [instruction.onPass, instruction.onFailure]
        case .waitApproval: values = [instruction.next, instruction.onFailure]
        case .retry: values = [instruction.retryPolicy?.target, instruction.onFailure]
        case .escalate, .emitReceipt, .complete: values = []
        default: values = [instruction.next]
        }
        return Array(Set(values.compactMap { $0 })).sorted()
    }
}
