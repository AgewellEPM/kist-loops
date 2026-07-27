import Foundation

// MARK: - Agent Message Types

/// Messages in the agent conversation - supports multiple agent types
/// FIXED: Each case now includes stored id and timestamp instead of computed id
enum AgentMessage: Identifiable, Equatable, Codable {
    case user(_ content: String, id: String = UUID().uuidString, timestamp: Date = Date())
    case assistant(agentId: String, content: String, id: String = UUID().uuidString, timestamp: Date = Date())
    case thinking(agentId: String, content: String, id: String = UUID().uuidString, timestamp: Date = Date())
    case toolUse(agentId: String, name: String, arguments: [String: String], id: String = UUID().uuidString, timestamp: Date = Date())
    case toolResult(agentId: String, name: String, result: ToolResult, id: String = UUID().uuidString, timestamp: Date = Date())
    case error(agentId: String, message: String, id: String = UUID().uuidString, timestamp: Date = Date())
    case agentHandoff(from: String, to: String, context: String, id: String = UUID().uuidString, timestamp: Date = Date())

    // FIXED: Now returns the STORED id from each case, not a new UUID
    var id: String {
        switch self {
        case .user(_, let id, _): return id
        case .assistant(_, _, let id, _): return id
        case .thinking(_, _, let id, _): return id
        case .toolUse(_, _, _, let id, _): return id
        case .toolResult(_, _, _, let id, _): return id
        case .error(_, _, let id, _): return id
        case .agentHandoff(_, _, _, let id, _): return id
        }
    }

    var timestamp: Date {
        switch self {
        case .user(_, _, let ts): return ts
        case .assistant(_, _, _, let ts): return ts
        case .thinking(_, _, _, let ts): return ts
        case .toolUse(_, _, _, _, let ts): return ts
        case .toolResult(_, _, _, _, let ts): return ts
        case .error(_, _, _, let ts): return ts
        case .agentHandoff(_, _, _, _, let ts): return ts
        }
    }

    // FIXED: Now properly compares using stored id
    static func == (lhs: AgentMessage, rhs: AgentMessage) -> Bool {
        lhs.id == rhs.id
    }

    var agentId: String {
        switch self {
        case .user: return "user"
        case .assistant(let id, _, _, _): return id
        case .thinking(let id, _, _, _): return id
        case .toolUse(let id, _, _, _, _): return id
        case .toolResult(let id, _, _, _, _): return id
        case .error(let id, _, _, _): return id
        case .agentHandoff(let from, _, _, _, _): return from
        }
    }

    var content: String {
        switch self {
        case .user(let content, _, _): return content
        case .assistant(_, let content, _, _): return content
        case .thinking(_, let content, _, _): return content
        case .toolUse(_, let name, let args, _, _):
            let argsStr = args.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            return "\(name)(\(argsStr))"
        case .toolResult(_, let name, let result, _, _):
            return "\(name): \(result.success ? "OK" : "FAIL") - \(result.output.prefix(100))"
        case .error(_, let message, _, _): return message
        case .agentHandoff(let from, let to, let context, _, _):
            return "Handoff from \(from) to \(to): \(context)"
        }
    }
}

// MARK: - Tool Types

/// Result from executing a tool
struct ToolResult: Equatable, Codable {
    let success: Bool
    let output: String
    let error: String?
    let metadata: [String: String]?

    init(success: Bool, output: String, error: String? = nil, metadata: [String: String]? = nil) {
        self.success = success
        self.output = output
        self.error = error
        self.metadata = metadata
    }
}

/// A tool call parsed from LLM response (renamed to avoid conflict with AgentModels.ToolCall)
struct AgentToolCall: Equatable {
    let name: String
    let arguments: [String: Any]

    static func == (lhs: AgentToolCall, rhs: AgentToolCall) -> Bool {
        lhs.name == rhs.name
    }
}

/// Parameter definition for a tool
struct ToolParameter: Codable {
    let name: String
    let type: String
    let description: String
    let required: Bool

    init(name: String, type: String, description: String, required: Bool = true) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
    }
}

// MARK: - Agent Configuration

/// Configuration for an agent instance
struct AgentConfig: Identifiable, Codable {
    let id: String
    let name: String
    let provider: String  // "claude", "deepseek", "gpt", "ollama"
    let model: String
    let role: AgentRole
    let color: String  // Hex color for UI
    let systemPrompt: String?

    enum AgentRole: String, Codable {
        case lead       // Primary agent that orchestrates
        case coder      // Specialized in writing code
        case reviewer   // Reviews code for issues
        case researcher // Searches and reads files
        case builder    // Runs builds and tests
    }
}

/// Pending user input when agent asks a question
/// FIXED: continuation is now sync - async is handled internally via withCheckedContinuation
struct PendingUserInput: Identifiable {
    let id = UUID()
    let agentId: String
    let question: String
    let options: [String]?
    let continuation: (String) -> Void  // FIXED: Sync closure, not async
}

// MARK: - Multi-Agent Session

/// A session with multiple agents working together
struct MultiAgentSession: Identifiable, Codable {
    let id: String
    var agents: [AgentConfig]
    var conversationHistory: [AgentMessage]
    var activeAgentId: String
    var projectPath: String
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, agents: [AgentConfig], projectPath: String) {
        self.id = id
        self.agents = agents
        self.conversationHistory = []
        self.activeAgentId = agents.first?.id ?? ""
        self.projectPath = projectPath
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Agent Status

/// Current status of an agent
enum AgentStatus: Equatable {
    case idle
    case thinking
    case usingTool(String)
    case waitingForUser
    case waitingForAgent(String)
    case error(String)
}

/// Real-time state of an agent
struct AgentState: Identifiable {
    let id: String
    var status: AgentStatus
    var currentThought: String
    var lastToolUsed: String?
    var isActive: Bool

    init(id: String) {
        self.id = id
        self.status = .idle
        self.currentThought = ""
        self.lastToolUsed = nil
        self.isActive = false
    }
}
