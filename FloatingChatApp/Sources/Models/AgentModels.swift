import Foundation

// MARK: - Agent Stage Output

enum AgentStageOutput: Equatable {
    case understanding(analysis: String)
    case requirements(spec: String)
    case codeGeneration(chunk: String)
    case fileWritten(path: String)
    case buildStarted
    case buildOutput(line: String)
    case buildComplete(success: Bool)
    case error(message: String)
    case complete(summary: String)
}

// MARK: - Conversation Analysis

struct ConversationAnalysis: Codable {
    let userIntent: String
    let projectContext: String
    let clarifications: [String]
    let isReadyForDevelopment: Bool
    let complexity: Complexity

    enum Complexity: String, Codable {
        case simple
        case medium
        case complex
    }
}

// MARK: - Code Requirements

struct CodeRequirements: Codable {
    let summary: String
    let filesToCreate: [FileSpec]
    let filesToModify: [FileModification]
    let dependencies: [String]
    let testCases: [String]
}

struct FileSpec: Codable, Identifiable {
    var id: String { path }
    let path: String
    let purpose: String
    var content: String
}

struct FileModification: Codable, Identifiable {
    var id: String { path }
    let path: String
    let changes: [CodeChange]
}

struct CodeChange: Codable, Identifiable {
    let id: UUID
    let location: String
    let action: ChangeAction
    let oldCode: String?
    let newCode: String

    init(id: UUID = UUID(), location: String, action: ChangeAction, oldCode: String? = nil, newCode: String) {
        self.id = id
        self.location = location
        self.action = action
        self.oldCode = oldCode
        self.newCode = newCode
    }
}

enum ChangeAction: String, Codable {
    case add
    case modify
    case delete
}

// MARK: - Generated File

struct GeneratedFile: Codable, Identifiable {
    var id: String { path }
    let path: String
    let content: String
    let isNew: Bool
}

// MARK: - Build Result

struct AgentBuildResult: Codable {
    let success: Bool
    let output: String
    let errors: [AgentBuildError]
    let warnings: [String]
    let duration: TimeInterval
}

struct AgentBuildError: Codable, Identifiable {
    let id: UUID
    let file: String
    let line: Int
    let column: Int?
    let message: String
    let suggestion: String?

    init(id: UUID = UUID(), file: String, line: Int, column: Int? = nil, message: String, suggestion: String? = nil) {
        self.id = id
        self.file = file
        self.line = line
        self.column = column
        self.message = message
        self.suggestion = suggestion
    }
}

// MARK: - Tool Definitions for Function Calling

struct ToolDefinition: Codable {
    let name: String
    let description: String
    let parameters: ToolParameters

    struct ToolParameters: Codable {
        let type: String
        let properties: [String: ParameterProperty]
        let required: [String]
    }

    struct ParameterProperty: Codable {
        let type: String
        let description: String
    }
}

struct ToolCall: Codable {
    let id: String
    let name: String
    let arguments: String  // JSON string
}

struct ToolCallResult: Codable {
    let toolCalls: [ToolCall]
    let content: String?
}

// MARK: - Agent Settings

struct AgentSettings: Codable {
    var conversationModel: String = "claude"  // claude, gpt
    var codeModel: String = "deepseek-v4-pro"
    var projectPath: String = ""
    var scheme: String = ""
    var autoFixErrors: Bool = true
    var maxFixAttempts: Int = 3
    var selectedTeamId: String = "solo"  // Default to solo agent
    var iterationLimit: Int = 50         // Safety cap for iterative loop (full build-outs)
    var requirePlanApproval: Bool = true // Require user approval before executing plan
    var oneShotMode: Bool = false        // Full iterative execution by default
    var planPreviewBeforeIterative: Bool = true // Show plan, then run iterative
    var runTestsAfterWrite: Bool = true  // Automatically run tests after file writes
    var autoInstallDependencies: Bool = true // Try to resolve/install dependencies on build failures

    /// Returns the project path if set, otherwise defaults to home directory
    /// This ensures tools always have a valid path to work with
    var effectiveProjectPath: String {
        if projectPath.isEmpty {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return projectPath
    }

    /// Get the currently selected team configuration
    var selectedTeam: AgentTeam {
        AgentTeam.allPresets.first { $0.id == selectedTeamId } ?? .soloAgent
    }

    static let `default` = AgentSettings()
}

// MARK: - Agent Team Configuration

/// A team of agents that work together
struct AgentTeam: Identifiable, Codable {
    let id: String
    let name: String
    let description: String
    let iconName: String
    let agents: [AgentTeamMember]
    let orchestrationMode: OrchestrationMode

    enum OrchestrationMode: String, Codable {
        case sequential    // One agent at a time, passes results to next
        case parallel      // All agents work simultaneously
        case collaborative // Lead agent delegates to specialists
        case debate        // Agents discuss and reach consensus
    }

    /// Role within a team (mirrors AgentConfig.AgentRole but standalone for Codable)
    enum TeamRole: String, Codable {
        case lead
        case coder
        case reviewer
        case researcher
        case builder
    }

    struct AgentTeamMember: Identifiable, Codable {
        let memberId: String
        let provider: String      // "claude", "deepseek", "gpt", "mlx", "ollama", "user_selected"
        let model: String
        let role: TeamRole
        let specialization: String

        var id: String { memberId }

        init(provider: String, model: String, role: TeamRole, specialization: String) {
            self.memberId = "\(provider)-\(role.rawValue)-\(UUID().uuidString.prefix(4))"
            self.provider = provider
            self.model = model
            self.role = role
            self.specialization = specialization
        }
    }
}

/// Preset team configurations
extension AgentTeam {
    static let soloAgent = AgentTeam(
        id: "solo",
        name: "Solo Agent",
        description: "Single AI handles everything",
        iconName: "person.fill",
        agents: [
            AgentTeamMember(provider: "user_selected", model: "auto", role: TeamRole.lead, specialization: "General purpose")
        ],
        orchestrationMode: .sequential
    )

    static let codingDuo = AgentTeam(
        id: "coding-duo",
        name: "Coding Duo",
        description: "Claude plans, DeepSeek codes",
        iconName: "person.2.fill",
        agents: [
            AgentTeamMember(provider: "claude", model: "claude-fable-5", role: TeamRole.lead, specialization: "Planning & Architecture"),
            AgentTeamMember(provider: "deepseek", model: "deepseek-v4-pro", role: TeamRole.coder, specialization: "Code Implementation")
        ],
        orchestrationMode: .collaborative
    )

    static let fullDevTeam = AgentTeam(
        id: "full-team",
        name: "Full Dev Team",
        description: "Architect, Coder, Reviewer, Tester",
        iconName: "person.3.fill",
        agents: [
            AgentTeamMember(provider: "claude", model: "claude-fable-5", role: TeamRole.lead, specialization: "Architecture & Planning"),
            AgentTeamMember(provider: "deepseek", model: "deepseek-v4-pro", role: TeamRole.coder, specialization: "Swift Implementation"),
            AgentTeamMember(provider: "gpt", model: "gpt-5.5", role: TeamRole.reviewer, specialization: "Code Review & Security"),
            AgentTeamMember(provider: "mlx", model: "mlx-community/Qwen2.5-7B-Instruct-4bit", role: TeamRole.builder, specialization: "Build & Test")
        ],
        orchestrationMode: .collaborative
    )

    static let localOnlyTeam = AgentTeam(
        id: "local-team",
        name: "Local Team",
        description: "100% local inference with MLX",
        iconName: "desktopcomputer",
        agents: [
            AgentTeamMember(provider: "mlx", model: "mlx-community/Qwen2.5-7B-Instruct-4bit", role: TeamRole.lead, specialization: "Planning"),
            AgentTeamMember(provider: "mlx", model: "mlx-community/DeepSeek-Coder-V2-Lite-Instruct-4bit", role: TeamRole.coder, specialization: "Coding"),
            AgentTeamMember(provider: "ollama", model: "codellama", role: TeamRole.reviewer, specialization: "Review")
        ],
        orchestrationMode: .collaborative
    )

    static let debateTeam = AgentTeam(
        id: "debate",
        name: "Debate Team",
        description: "Multiple AIs discuss and reach consensus",
        iconName: "bubble.left.and.bubble.right.fill",
        agents: [
            AgentTeamMember(provider: "claude", model: "claude-fable-5", role: TeamRole.lead, specialization: "Moderator"),
            AgentTeamMember(provider: "gpt", model: "gpt-5.5", role: TeamRole.reviewer, specialization: "Devil's Advocate"),
            AgentTeamMember(provider: "deepseek", model: "deepseek-v4-pro", role: TeamRole.coder, specialization: "Technical Expert")
        ],
        orchestrationMode: .debate
    )

    static let allPresets: [AgentTeam] = [
        .soloAgent,
        .codingDuo,
        .fullDevTeam,
        .localOnlyTeam,
        .debateTeam
    ]
}

// MARK: - Agent Settings Manager

@MainActor
final class AgentSettingsManager: ObservableObject {
    static let shared = AgentSettingsManager()

    @Published var settings: AgentSettings {
        didSet { save() }
    }

    private let key = "agent_settings"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let settings = try? JSONDecoder().decode(AgentSettings.self, from: data) {
            self.settings = settings
        } else {
            self.settings = .default
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
