import Foundation

// MARK: - Execution Plan Models

/// The structured output from LLM - intent, plan steps, and executable actions
struct ExecutionPlan: Identifiable {
    let id = UUID()
    let intent: AgentIntent
    var planSteps: [PlanStep]           // Human-readable steps for UI (var for status updates)
    let actions: [ExecutableAction]      // Machine-executable actions
    var summary: String                  // var for iterative updates
    let estimatedDuration: TimeInterval?
    let createdAt = Date()

    var progress: Double {
        guard !planSteps.isEmpty else { return 1.0 }
        let completed = planSteps.filter { $0.status == .completed }.count
        return Double(completed) / Double(planSteps.count)
    }

    var isComplete: Bool {
        planSteps.allSatisfy { $0.status == .completed || $0.status == .skipped }
    }
}

/// A human-readable step in the plan (maps to one or more actions)
struct PlanStep: Identifiable {
    let id = UUID()
    let index: Int
    let description: String
    let actionIndices: [Int]            // Which actions belong to this step
    var status: StepStatus = .pending

    enum StepStatus: String, Codable {
        case pending = "pending"
        case inProgress = "in_progress"
        case completed = "completed"
        case failed = "failed"
        case skipped = "skipped"

        var icon: String {
            switch self {
            case .pending: return "circle"
            case .inProgress: return "arrow.right.circle.fill"
            case .completed: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            case .skipped: return "minus.circle"
            }
        }
    }
}

/// A machine-executable action
struct ExecutableAction: Identifiable {
    let id = UUID()
    let type: ActionType
    let tool: String?
    let parameters: [String: Any]
    let description: String             // Human-readable description
    let stepIndex: Int                  // Which plan step this belongs to

    enum ActionType: String, Codable {
        case toolCall = "tool_call"
        case createFile = "create_file"
        case editFile = "edit_file"
        case runCommand = "run_command"
        case desktopAction = "desktop_action"
        case wait = "wait"
        case askUser = "ask_user"
        case observe = "observe"     // Check state before acting
        case done = "done"           // Signal task completion

        var icon: String {
            switch self {
            case .toolCall: return "wrench.and.screwdriver"
            case .createFile: return "doc.badge.plus"
            case .editFile: return "pencil"
            case .runCommand: return "terminal"
            case .desktopAction: return "cursorarrow.click"
            case .wait: return "clock"
            case .askUser: return "questionmark.bubble"
            case .observe: return "eye"
            case .done: return "checkmark.seal.fill"
            }
        }

        /// Create from string, with fallback
        static func from(string: String) -> ActionType {
            return ActionType(rawValue: string) ?? .toolCall
        }
    }

    /// Summary for display
    var displaySummary: String {
        switch type {
        case .toolCall:
            return tool ?? "tool"
        case .createFile:
            if let path = parameters["path"] as? String {
                return "Create \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "Create file"
        case .editFile:
            if let path = parameters["path"] as? String {
                return "Edit \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "Edit file"
        case .runCommand:
            if let cmd = parameters["command"] as? String {
                return String(cmd.prefix(30)) + (cmd.count > 30 ? "..." : "")
            }
            return "Run command"
        case .desktopAction:
            return parameters["action"] as? String ?? "Desktop action"
        case .wait:
            let seconds = parameters["seconds"] as? Double ?? 1
            return "Wait \(String(format: "%.1f", seconds))s"
        case .askUser:
            return "Ask user"
        case .observe:
            let check = parameters["check"] as? String ?? "state"
            return "Observe \(check)"
        case .done:
            return "✅ Done"
        }
    }
}

/// Result of executing an action
struct ActionExecutionResult: Identifiable {
    let id = UUID()
    let action: ExecutableAction
    let success: Bool
    let output: String
    let error: String?
    let duration: TimeInterval
    let timestamp = Date()
    let metadata: [String: String]?

    /// Convert to ToolResult for compatibility
    var asToolResult: ToolResult {
        ToolResult(success: success, output: output, error: error, metadata: metadata)
    }
}

/// Overall execution result
enum ExecutionResult {
    case success(String)
    case failed(String)
    case cancelled
    case askingUser(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .success(let msg): return msg
        case .failed(let msg): return msg
        case .cancelled: return "Execution cancelled"
        case .askingUser(let question): return question
        }
    }
}

// MARK: - LLM Response Parsing

/// Raw structure from LLM JSON output
struct StructuredLLMResponse: Codable {
    let intent: String
    let plan: [String]
    let actions: [StructuredAction]
    let thinking: String?
    let message: String?
    let askUser: String?

    enum CodingKeys: String, CodingKey {
        case intent, plan, actions, thinking, message
        case askUser = "ask_user"
    }
}

struct StructuredAction: Codable {
    let type: String
    let tool: String?
    let parameters: [String: AnyCodableValue]?

    /// Convert to ExecutableAction
    func toExecutableAction(stepIndex: Int, description: String) -> ExecutableAction {
        let actionType = ExecutableAction.ActionType(rawValue: type) ?? .toolCall
        let params: [String: Any] = parameters?.mapValues { $0.value } ?? [:]

        return ExecutableAction(
            type: actionType,
            tool: tool,
            parameters: params,
            description: description,
            stepIndex: stepIndex
        )
    }
}

/// Type-erased Codable value for JSON parsing
enum AnyCodableValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case dictionary([String: AnyCodableValue])
    case null

    var value: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .array(let a): return a.map { $0.value }
        case .dictionary(let d): return d.mapValues { $0.value }
        case .null: return NSNull()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let array = try? container.decode([AnyCodableValue].self) {
            self = .array(array)
        } else if let dict = try? container.decode([String: AnyCodableValue].self) {
            self = .dictionary(dict)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.typeMismatch(
                AnyCodableValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown type")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .dictionary(let d): try container.encode(d)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Iterative Agent Response (The Real Loop)

/// Response from LLM in iterative mode - ONE action at a time
struct IterativeAgentResponse {
    let thinking: String?
    let nextAction: ExecutableAction
    let message: String?
}

/// Raw JSON structure for iterative response
struct IterativeAgentResponseRaw: Codable {
    let thinking: String?
    let nextAction: IterativeActionRaw
    let message: String?

    enum CodingKeys: String, CodingKey {
        case thinking
        case nextAction = "next_action"
        case message
    }
}

/// Raw action from iterative response
struct IterativeActionRaw: Codable {
    let type: String
    let tool: String?
    let parameters: [String: AnyCodableValue]?
    let description: String?
}

// MARK: - Plan Builder

/// Builds ExecutionPlan from parsed LLM response
struct ExecutionPlanBuilder {
    static func build(from response: StructuredLLMResponse) -> ExecutionPlan {
        // Create intent
        let intentType = AgentIntent.IntentType(rawValue: response.intent) ?? .coding
        let intent = AgentIntent(
            type: intentType,
            description: response.message ?? "Processing request",
            confidence: 0.9,
            rawMessage: ""
        )

        // Create plan steps
        var planSteps: [PlanStep] = []
        var actions: [ExecutableAction] = []
        var currentActionIndex = 0

        for (stepIndex, stepDescription) in response.plan.enumerated() {
            // Find actions for this step (simple 1:1 mapping for now)
            let stepActionIndices: [Int]
            if stepIndex < response.actions.count {
                stepActionIndices = [currentActionIndex]
                let structuredAction = response.actions[stepIndex]
                let action = structuredAction.toExecutableAction(
                    stepIndex: stepIndex,
                    description: stepDescription
                )
                actions.append(action)
                currentActionIndex += 1
            } else {
                stepActionIndices = []
            }

            let step = PlanStep(
                index: stepIndex,
                description: stepDescription,
                actionIndices: stepActionIndices
            )
            planSteps.append(step)
        }

        // Add any remaining actions that weren't mapped to steps
        while currentActionIndex < response.actions.count {
            let structuredAction = response.actions[currentActionIndex]
            let action = structuredAction.toExecutableAction(
                stepIndex: planSteps.count - 1,
                description: structuredAction.tool ?? structuredAction.type
            )
            actions.append(action)
            currentActionIndex += 1
        }

        return ExecutionPlan(
            intent: intent,
            planSteps: planSteps,
            actions: actions,
            summary: response.message ?? "Executing plan",
            estimatedDuration: nil
        )
    }
}
