import Foundation

// MARK: - Agent Tool Protocol

/// Protocol for all agent tools - like Claude Code's tool system
protocol AgentTool {
    var name: String { get }
    var description: String { get }
    var parameters: [ToolParameter] { get }

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult
}

// MARK: - Tool Registry

/// Registry of all available tools
final class ToolRegistry {
    static let shared = ToolRegistry()

    private var tools: [String: AgentTool] = [:]

    private init() {
        registerDefaultTools()
    }

    private func registerDefaultTools() {
        // File Operations
        register(ReadFileTool())
        register(WriteFileTool())
        register(EditFileTool())
        register(ListFilesTool())
        register(SearchCodeTool())
        register(GlobFilesTool())
        register(GetProjectStructureTool())

        // Build & Development
        register(RunBuildTool())
        register(RunCommandTool())
        register(GitTool())
        register(CreateXcodeAppTool())
        register(SetProjectPathTool())
        register(FindProjectsTool())
        register(RunTestsTool())
        register(InstallDependenciesTool())

        // Search & Web
        register(WebSearchTool())
        register(SystemSearchTool())

        // Media
        register(PlaywrightCaptureTool())
        register(ExtractVideoFramesTool())
        register(TranscribeMediaTool())

        // Desktop Control Tools (NEW)
        register(ClipboardTool())
        register(AppleScriptTool())
        register(SystemControlTool())
        register(WindowManagementTool())
        register(InputControlTool())
        register(GitHubTool())
    }

    func register(_ tool: AgentTool) {
        tools[tool.name] = tool
    }

    func getTool(_ name: String) -> AgentTool? {
        tools[name]
    }

    func allTools() -> [AgentTool] {
        Array(tools.values)
    }

    func toolDescriptions() -> String {
        tools.values.map { tool in
            let params = tool.parameters.map { p in
                "\(p.name): \(p.type)\(p.required ? "" : "?")"
            }.joined(separator: ", ")
            return "- \(tool.name)(\(params)): \(tool.description)"
        }.joined(separator: "\n")
    }

    func toolsAsJSON() -> [[String: Any]] {
        tools.values.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": [
                        "type": "object",
                        "properties": Dictionary(uniqueKeysWithValues: tool.parameters.map { param in
                            (param.name, [
                                "type": param.type,
                                "description": param.description
                            ])
                        }),
                        "required": tool.parameters.filter { $0.required }.map { $0.name }
                    ]
                ]
            ]
        }
    }
}

// MARK: - Tool Execution Helper

extension ToolRegistry {
    func execute(toolName: String, arguments: [String: Any], projectPath: String) async -> ToolResult {
        guard let tool = getTool(toolName) else {
            return ToolResult(
                success: false,
                output: "",
                error: "Unknown tool: \(toolName)"
            )
        }

        do {
            return try await tool.execute(arguments: arguments, projectPath: projectPath)
        } catch {
            return ToolResult(
                success: false,
                output: "",
                error: error.localizedDescription
            )
        }
    }

    /// Execute a tool with runtime hooks (auto-build, retry)
    @MainActor
    func executeWithRuntime(
        toolName: String,
        arguments: [String: Any],
        projectPath: String
    ) async throws -> ToolResult {
        guard let tool = getTool(toolName) else {
            return ToolResult(
                success: false,
                output: "",
                error: "Unknown tool: \(toolName)"
            )
        }

        return try await AgentRuntimeService.shared.executeWithRuntime(
            tool: tool,
            arguments: arguments,
            projectPath: projectPath
        )
    }
}
