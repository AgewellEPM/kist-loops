import Foundation

public enum SMLOnyxSkillKind: String, Sendable, Codable, Equatable {
    case knowledge
    case reasoning
    case action
    case verification
    case control
    case governance
}

public struct SMLOnyxSkillNode: Sendable, Codable, Equatable {
    public let id: String
    public let kind: SMLOnyxSkillKind
    public let operation: SMLInstructionOperation
    public let reference: String?
    public let prerequisites: [String]
    public let successors: [String]

    public init(
        id: String,
        kind: SMLOnyxSkillKind,
        operation: SMLInstructionOperation,
        reference: String?,
        prerequisites: [String],
        successors: [String]
    ) {
        self.id = id
        self.kind = kind
        self.operation = operation
        self.reference = reference
        self.prerequisites = prerequisites
        self.successors = successors
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
    public static let currentSchemaVersion = 1

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
        plan: SMLOnyxPlan
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
                successors: (successorsByID[instruction.id] ?? []).sorted()
            )
        }
        let tools = workflow.instructions.compactMap(toolBinding).sorted {
            $0.instructionID < $1.instructionID
        }
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
        return SMLOnyxDriverManifest(
            driverID: driverID(for: surface),
            workflowID: workflow.id,
            workflowVersion: workflow.version,
            role: surface.role,
            replGrammar: surface.grammar(allowedActions: modelActions),
            modelToolName: "propose_sml_command",
            modelActions: actions,
            api: SMLWorkflowAPICatalog(surface: surface, basePath: apiBasePath),
            skillTree: skillTree,
            tools: tools,
            plan: SMLOnyxPlan(entrypoint: workflow.entrypoint, nodes: planNodes)
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
