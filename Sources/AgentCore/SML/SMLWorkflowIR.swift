import Foundation

public enum SMLWorkflowSourceKind: String, Sendable, Codable, Equatable {
    case native
    case langGraph = "langgraph"
    case jobDescription = "job_description"
    case scribe
    case demonstration
    case standardOperatingProcedure = "sop"
    case perslis
    case existingCode = "existing_code"
}

public struct SMLWorkflowSource: Sendable, Codable, Equatable {
    public let kind: SMLWorkflowSourceKind
    public let reference: String
    public let digest: String?

    public init(kind: SMLWorkflowSourceKind, reference: String, digest: String? = nil) {
        self.kind = kind
        self.reference = reference
        self.digest = digest
    }
}

public struct SMLTrigger: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, Equatable {
        case manual
        case event
        case schedule
    }

    public let kind: Kind
    public let value: String?

    public init(kind: Kind, value: String? = nil) {
        self.kind = kind
        self.value = value
    }
}

public enum SMLStateType: String, Sendable, Codable, Equatable {
    case string
    case number
    case integer
    case boolean
    case object
    case array
}

public struct SMLStateField: Sendable, Codable, Equatable {
    public let name: String
    public let type: SMLStateType
    public let required: Bool
    public let nullable: Bool
    public let description: String?

    public init(name: String, type: SMLStateType, required: Bool = true,
                nullable: Bool = false, description: String? = nil) {
        self.name = name
        self.type = type
        self.required = required
        self.nullable = nullable
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(SMLStateType.self, forKey: .type)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true
        nullable = try container.decodeIfPresent(Bool.self, forKey: .nullable) ?? false
        description = try container.decodeIfPresent(String.self, forKey: .description)
    }

    enum CodingKeys: String, CodingKey {
        case name, type, required, nullable, description
    }
}

public enum SMLConditionOperator: String, Sendable, Codable, Equatable {
    case equals
    case notEquals = "not_equals"
    case lessThan = "less_than"
    case lessThanOrEqual = "less_than_or_equal"
    case greaterThan = "greater_than"
    case greaterThanOrEqual = "greater_than_or_equal"
    case contains
    case exists
    case isNull = "is_null"
}

public struct SMLConditionClause: Sendable, Codable, Equatable {
    public let field: String
    public let op: SMLConditionOperator
    public let value: SMLValue?

    public init(field: String, op: SMLConditionOperator, value: SMLValue? = nil) {
        self.field = field
        self.op = op
        self.value = value
    }
}

public struct SMLCondition: Sendable, Codable, Equatable {
    public enum Combination: String, Sendable, Codable, Equatable {
        case all
        case any
    }

    public let combination: Combination
    public let clauses: [SMLConditionClause]

    public init(combination: Combination = .all, clauses: [SMLConditionClause]) {
        self.combination = combination
        self.clauses = clauses
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        combination = try container.decodeIfPresent(Combination.self, forKey: .combination) ?? .all
        clauses = try container.decode([SMLConditionClause].self, forKey: .clauses)
    }

    enum CodingKeys: String, CodingKey {
        case combination, clauses
    }
}

public struct SMLRetryPolicy: Sendable, Codable, Equatable {
    public let target: String
    public let maximumAttempts: Int
    public let backoffSeconds: Double

    public init(target: String, maximumAttempts: Int, backoffSeconds: Double = 0) {
        self.target = target
        self.maximumAttempts = maximumAttempts
        self.backoffSeconds = backoffSeconds
    }

    enum CodingKeys: String, CodingKey {
        case target
        case maximumAttempts = "maximum_attempts"
        case backoffSeconds = "backoff_seconds"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decode(String.self, forKey: .target)
        maximumAttempts = try container.decode(Int.self, forKey: .maximumAttempts)
        backoffSeconds = try container.decodeIfPresent(Double.self, forKey: .backoffSeconds) ?? 0
    }
}

public enum SMLSideEffectLevel: String, Sendable, Codable, Equatable {
    case readOnly = "read_only"
    case reversibleInternal = "reversible_internal"
    case reversibleExternal = "reversible_external"
    case irreversible
    case unknown
}

/// An imported claim about arbitrary framework or application code.
///
/// Trust and execution isolation are deliberately absent: a wire payload cannot attest itself.
/// The daemon may execute this candidate only after matching it to a host-owned attestation.
public struct SMLPluginContract: Sendable, Codable, Equatable {
    public let id: String
    public let reads: [String]
    public let writes: [String]
    public let sideEffectLevel: SMLSideEffectLevel
    public let preconditions: [String]
    public let postconditions: [String]
    public let rollback: String?
    public let verifier: String?

    public init(
        id: String,
        reads: [String] = [],
        writes: [String] = [],
        sideEffectLevel: SMLSideEffectLevel = .unknown,
        preconditions: [String] = [],
        postconditions: [String] = [],
        rollback: String? = nil,
        verifier: String? = nil
    ) {
        self.id = id
        self.reads = reads
        self.writes = writes
        self.sideEffectLevel = sideEffectLevel
        self.preconditions = preconditions
        self.postconditions = postconditions
        self.rollback = rollback
        self.verifier = verifier
    }

    enum CodingKeys: String, CodingKey {
        case id, reads, writes
        case sideEffectLevel = "side_effect_level"
        case preconditions, postconditions, rollback, verifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        reads = try container.decodeIfPresent([String].self, forKey: .reads) ?? []
        writes = try container.decodeIfPresent([String].self, forKey: .writes) ?? []
        sideEffectLevel = try container.decodeIfPresent(
            SMLSideEffectLevel.self, forKey: .sideEffectLevel
        ) ?? .unknown
        preconditions = try container.decodeIfPresent([String].self, forKey: .preconditions) ?? []
        postconditions = try container.decodeIfPresent([String].self, forKey: .postconditions) ?? []
        rollback = try container.decodeIfPresent(String.self, forKey: .rollback)
        verifier = try container.decodeIfPresent(String.self, forKey: .verifier)
    }
}

/// The closed instruction set understood by the SML runtime.
public enum SMLInstructionOperation: String, Sendable, Codable, Equatable, CaseIterable {
    case observe = "OBSERVE"
    case retrieve = "RETRIEVE"
    case callTool = "CALL_TOOL"
    case callModel = "CALL_MODEL"
    case invokeVCard = "INVOKE_VCARD"
    case runPlugin = "RUN_PLUGIN"
    case runWorkflow = "RUN_WORKFLOW"
    case branch = "BRANCH"
    case assert = "ASSERT"
    case verify = "VERIFY"
    case checkpoint = "CHECKPOINT"
    case waitApproval = "WAIT_APPROVAL"
    case retry = "RETRY"
    case rollback = "ROLLBACK"
    case escalate = "ESCALATE"
    case commit = "COMMIT"
    case emitReceipt = "EMIT_RECEIPT"
    case complete = "COMPLETE"
}

/// One instruction in the common SML intermediate representation.
///
/// Optional fields are operation-specific and are rejected when required data is absent. Keeping
/// transitions explicit makes the compiled graph inspectable without executing imported code.
public struct SMLInstruction: Sendable, Codable, Equatable {
    public let id: String
    public let op: SMLInstructionOperation
    public let source: String?
    public let purpose: String?
    public let capability: String?
    public let workflow: String?
    public let verifier: String?
    public let outputSchema: String?
    public let reason: String?
    public let owner: String?
    public let arguments: SMLObject
    public let scope: SMLObject
    public let expectedState: SMLObject
    public let condition: SMLCondition?
    public let plugin: SMLPluginContract?
    public let retryPolicy: SMLRetryPolicy?
    public let receiptFields: [String]
    public let next: String?
    public let onPass: String?
    public let onFailure: String?
    public let trueTarget: String?
    public let falseTarget: String?

    public init(
        id: String,
        op: SMLInstructionOperation,
        source: String? = nil,
        purpose: String? = nil,
        capability: String? = nil,
        workflow: String? = nil,
        verifier: String? = nil,
        outputSchema: String? = nil,
        reason: String? = nil,
        owner: String? = nil,
        arguments: SMLObject = [:],
        scope: SMLObject = [:],
        expectedState: SMLObject = [:],
        condition: SMLCondition? = nil,
        plugin: SMLPluginContract? = nil,
        retryPolicy: SMLRetryPolicy? = nil,
        receiptFields: [String] = [],
        next: String? = nil,
        onPass: String? = nil,
        onFailure: String? = nil,
        trueTarget: String? = nil,
        falseTarget: String? = nil
    ) {
        self.id = id
        self.op = op
        self.source = source
        self.purpose = purpose
        self.capability = capability
        self.workflow = workflow
        self.verifier = verifier
        self.outputSchema = outputSchema
        self.reason = reason
        self.owner = owner
        self.arguments = arguments
        self.scope = scope
        self.expectedState = expectedState
        self.condition = condition
        self.plugin = plugin
        self.retryPolicy = retryPolicy
        self.receiptFields = receiptFields
        self.next = next
        self.onPass = onPass
        self.onFailure = onFailure
        self.trueTarget = trueTarget
        self.falseTarget = falseTarget
    }

    enum CodingKeys: String, CodingKey {
        case id, op, source, purpose, capability, workflow, verifier
        case outputSchema = "output_schema"
        case reason, owner, arguments, scope
        case expectedState = "expected_state"
        case condition, plugin
        case retryPolicy = "retry_policy"
        case receiptFields = "receipt_fields"
        case next
        case onPass = "on_pass"
        case onFailure = "on_failure"
        case trueTarget = "true"
        case falseTarget = "false"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        op = try container.decode(SMLInstructionOperation.self, forKey: .op)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        purpose = try container.decodeIfPresent(String.self, forKey: .purpose)
        capability = try container.decodeIfPresent(String.self, forKey: .capability)
        workflow = try container.decodeIfPresent(String.self, forKey: .workflow)
        verifier = try container.decodeIfPresent(String.self, forKey: .verifier)
        outputSchema = try container.decodeIfPresent(String.self, forKey: .outputSchema)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        arguments = try container.decodeIfPresent(SMLObject.self, forKey: .arguments) ?? [:]
        scope = try container.decodeIfPresent(SMLObject.self, forKey: .scope) ?? [:]
        expectedState = try container.decodeIfPresent(SMLObject.self, forKey: .expectedState) ?? [:]
        condition = try container.decodeIfPresent(SMLCondition.self, forKey: .condition)
        plugin = try container.decodeIfPresent(SMLPluginContract.self, forKey: .plugin)
        retryPolicy = try container.decodeIfPresent(SMLRetryPolicy.self, forKey: .retryPolicy)
        receiptFields = try container.decodeIfPresent([String].self, forKey: .receiptFields) ?? []
        next = try container.decodeIfPresent(String.self, forKey: .next)
        onPass = try container.decodeIfPresent(String.self, forKey: .onPass)
        onFailure = try container.decodeIfPresent(String.self, forKey: .onFailure)
        trueTarget = try container.decodeIfPresent(String.self, forKey: .trueTarget)
        falseTarget = try container.decodeIfPresent(String.self, forKey: .falseTarget)
    }
}

public struct SMLWorkflow: Sendable, Codable, Equatable {
    public static let currentIRVersion = 1

    public let irVersion: Int
    public let id: String
    public let version: String
    public let name: String
    public let source: SMLWorkflowSource
    public let trigger: SMLTrigger
    public let stateSchema: [SMLStateField]
    public let entrypoint: String
    public let instructions: [SMLInstruction]

    public init(
        irVersion: Int = SMLWorkflow.currentIRVersion,
        id: String,
        version: String,
        name: String,
        source: SMLWorkflowSource,
        trigger: SMLTrigger,
        stateSchema: [SMLStateField],
        entrypoint: String,
        instructions: [SMLInstruction]
    ) {
        self.irVersion = irVersion
        self.id = id
        self.version = version
        self.name = name
        self.source = source
        self.trigger = trigger
        self.stateSchema = stateSchema
        self.entrypoint = entrypoint
        self.instructions = instructions
    }

    enum CodingKeys: String, CodingKey {
        case irVersion = "ir_version"
        case id, version, name, source, trigger
        case stateSchema = "state_schema"
        case entrypoint, instructions
    }
}
