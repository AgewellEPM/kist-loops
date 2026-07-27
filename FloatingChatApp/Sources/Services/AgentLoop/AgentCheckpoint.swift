import Foundation

// MARK: - AgentCheckpoint
//
// A fully-serializable snapshot of an in-flight agent run, so the iterative
// loop can be persisted after every iteration and RESUMED later (even after a
// crash or app restart) at the exact step it left off.
//
// The live runtime models (`ExecutionPlan`, `ExecutableAction`, …) are NOT
// Codable: they carry UUID/Date defaults and `[String: Any]` parameter bags.
// Rather than bolt Codable onto them (which would force custom coding on the
// hot models), we mirror them with the Codable DTOs below and map both ways.
//
// Round-tripping `[String: Any]` is done through the existing `AnyCodableValue`
// (see ExecutionPlan.swift). That type only knew how to go Codable -> Any; the
// `init(any:)` extension here closes the loop (Any -> Codable).

// MARK: - Any -> AnyCodableValue bridge

extension AnyCodableValue {
    /// Build a Codable value from an arbitrary `Any` produced by the runtime.
    /// Numbers arrive as Swift `Int`/`Double`/`Bool` or as bridged `NSNumber`;
    /// `NSNumber`'s `objCType` is used to disambiguate Bool vs Int vs Double so
    /// a `true` is never persisted as `1` (and vice-versa).
    init(any value: Any) {
        switch value {
        case let v as AnyCodableValue:
            self = v
        case is NSNull:
            self = .null
        case let v as String:
            self = .string(v)
        case let v as NSNumber:
            // NSNumber catches bridged Swift Int/Double/Bool too.
            let objCType = String(cString: v.objCType)
            if objCType == "c" || objCType == "B" {
                self = .bool(v.boolValue)
            } else if objCType == "d" || objCType == "f" {
                self = .double(v.doubleValue)
            } else {
                self = .int(v.intValue)
            }
        case let v as Bool:
            self = .bool(v)
        case let v as Int:
            self = .int(v)
        case let v as Double:
            self = .double(v)
        case let v as [Any]:
            self = .array(v.map { AnyCodableValue(any: $0) })
        case let v as [String: Any]:
            self = .dictionary(v.mapValues { AnyCodableValue(any: $0) })
        default:
            // Unknown/opaque types degrade to their textual form rather than
            // crashing serialization. Acceptable for resume fidelity.
            self = .string("\(value)")
        }
    }
}

// MARK: - ExecutionState string codec
//
// `ExecutionState` (AgentOrchestrator.swift) is a plain enum (not Codable /
// RawRepresentable), so we map it to/from a stable string here.

enum ExecutionStateCodec {
    static func string(_ state: ExecutionState) -> String {
        switch state {
        case .idle: return "idle"
        case .analyzing: return "analyzing"
        case .planning: return "planning"
        case .executing: return "executing"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    static func state(_ raw: String) -> ExecutionState {
        switch raw {
        case "analyzing": return .analyzing
        case "planning": return .planning
        case "executing": return .executing
        case "completed": return .completed
        case "failed": return .failed
        case "cancelled": return .cancelled
        default: return .idle
        }
    }
}

// MARK: - Codable mirrors of the live models

struct CheckpointIntent: Codable {
    let type: String
    let description: String
    let confidence: Double
    let rawMessage: String

    init(_ intent: AgentIntent) {
        self.type = intent.type.rawValue
        self.description = intent.description
        self.confidence = intent.confidence
        self.rawMessage = intent.rawMessage
    }

    var live: AgentIntent {
        AgentIntent(
            type: AgentIntent.IntentType(rawValue: type) ?? .coding,
            description: description,
            confidence: confidence,
            rawMessage: rawMessage
        )
    }
}

struct CheckpointAction: Codable {
    let type: String
    let tool: String?
    let parameters: [String: AnyCodableValue]
    let description: String
    let stepIndex: Int

    init(_ action: ExecutableAction) {
        self.type = action.type.rawValue
        self.tool = action.tool
        self.parameters = action.parameters.mapValues { AnyCodableValue(any: $0) }
        self.description = action.description
        self.stepIndex = action.stepIndex
    }

    var live: ExecutableAction {
        ExecutableAction(
            type: ExecutableAction.ActionType.from(string: type),
            tool: tool,
            parameters: parameters.mapValues { $0.value },
            description: description,
            stepIndex: stepIndex
        )
    }
}

struct CheckpointPlanStep: Codable {
    let index: Int
    let description: String
    let actionIndices: [Int]
    let status: PlanStep.StepStatus

    init(_ step: PlanStep) {
        self.index = step.index
        self.description = step.description
        self.actionIndices = step.actionIndices
        self.status = step.status
    }

    var live: PlanStep {
        var step = PlanStep(index: index, description: description, actionIndices: actionIndices)
        step.status = status
        return step
    }
}

struct CheckpointPlan: Codable {
    let intent: CheckpointIntent
    let planSteps: [CheckpointPlanStep]
    let actions: [CheckpointAction]
    let summary: String
    let estimatedDuration: TimeInterval?

    init(_ plan: ExecutionPlan) {
        self.intent = CheckpointIntent(plan.intent)
        self.planSteps = plan.planSteps.map(CheckpointPlanStep.init)
        self.actions = plan.actions.map(CheckpointAction.init)
        self.summary = plan.summary
        self.estimatedDuration = plan.estimatedDuration
    }

    var live: ExecutionPlan {
        ExecutionPlan(
            intent: intent.live,
            planSteps: planSteps.map(\.live),
            actions: actions.map(\.live),
            summary: summary,
            estimatedDuration: estimatedDuration
        )
    }
}

struct CheckpointActionResult: Codable {
    let action: CheckpointAction
    let success: Bool
    let output: String
    let error: String?
    let duration: TimeInterval
    let metadata: [String: String]?

    init(_ result: ActionExecutionResult) {
        self.action = CheckpointAction(result.action)
        self.success = result.success
        self.output = result.output
        self.error = result.error
        self.duration = result.duration
        self.metadata = result.metadata
    }

    var live: ActionExecutionResult {
        ActionExecutionResult(
            action: action.live,
            success: success,
            output: output,
            error: error,
            duration: duration,
            metadata: metadata
        )
    }
}

/// One turn of the iterative loop's working context.
struct ConversationTurn: Codable {
    enum Role: String, Codable { case user, assistant, system }
    let role: Role
    let content: String

    init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    /// Build from the runtime's `(role: String, content: String)` tuples.
    init(rawRole: String, content: String) {
        self.role = Role(rawValue: rawRole) ?? .system
        self.content = content
    }
}

// MARK: - AgentCheckpoint (top-level serializable run state)

struct AgentCheckpoint: Codable, Identifiable {
    enum Mode: String, Codable { case iterative, batch, oneShot }
    enum Status: String, Codable { case running, paused, completed, failed, cancelled }

    let id: String
    var title: String
    let projectPath: String
    let userMessage: String
    var mode: Mode
    var status: Status

    /// The loop's working context (what we feed back to the LLM each turn).
    var conversation: [ConversationTurn]
    /// The plan preview, if one was generated before the loop.
    var plan: CheckpointPlan?
    /// Results of every primary action executed so far.
    var actionResults: [CheckpointActionResult]

    /// The exact execution cursor — this is what shallow conversation-only
    /// restores were missing.
    var currentActionIndex: Int
    var iterationCount: Int
    var maxIterations: Int
    var retryAttempt: Int
    /// How many live re-plans this run has performed. Optional for backward
    /// compatibility with checkpoints written before re-plan existed.
    var replanCount: Int?
    /// Consecutive failed actions — drives the live re-plan trigger. Persisted
    /// so a crash mid-streak doesn't reset the streak on resume (Codex HIGH-2).
    var consecutiveFailures: Int?
    /// The action that is ABOUT to execute (or was executing when we stopped).
    /// Bracketing the side effect lets resume detect an interrupted action and
    /// verify state instead of blindly replaying it (Codex HIGH-1).
    var pendingAction: CheckpointAction?
    var executionState: String   // via ExecutionStateCodec
    var lastError: String?

    let createdAt: Date
    var updatedAt: Date

    /// Fresh checkpoint for a new iterative run.
    init(iterativeFor userMessage: String, projectPath: String, maxIterations: Int, id: String = UUID().uuidString) {
        self.id = id
        self.title = String(userMessage.prefix(60))
        self.projectPath = projectPath
        self.userMessage = userMessage
        self.mode = .iterative
        self.status = .running
        self.conversation = [ConversationTurn(role: .user, content: userMessage)]
        self.plan = nil
        self.actionResults = []
        self.currentActionIndex = 0
        self.iterationCount = 0
        self.maxIterations = maxIterations
        self.retryAttempt = 0
        self.replanCount = 0
        self.consecutiveFailures = 0
        self.pendingAction = nil
        self.executionState = "analyzing"
        self.lastError = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var isResumable: Bool {
        status == .running || status == .paused || status == .failed
    }
}
