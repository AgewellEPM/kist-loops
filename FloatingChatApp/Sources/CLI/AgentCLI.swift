import Foundation

/// Command-line interface for testing the agentic system
/// Run with: swift run AgentCLI /path/to/project
@MainActor
final class AgentCLI {
    private let engine: AgentLoopEngine
    private var isRunning = true
    private let projectPath: String

    init(projectPath: String) {
        self.projectPath = projectPath
        self.engine = AgentLoopEngine.shared

        // Setup with default Claude agent
        engine.setup(
            projectPath: projectPath,
            agents: [AgentLoopEngine.createClaudeAgent()]
        )
    }

    // MARK: - Main Loop

    func run() async {
        printBanner()
        printHelp()

        while isRunning {
            print("\n\u{001B}[36m>\u{001B}[0m ", terminator: "")
            fflush(stdout)

            guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !input.isEmpty else {
                continue
            }

            await handleInput(input)
        }
    }

    // MARK: - Input Handling

    private func handleInput(_ input: String) async {
        // Check for commands
        if input.hasPrefix("/") || input.hasPrefix(":") {
            handleCommand(String(input.dropFirst()))
            return
        }

        // Handle built-in commands without prefix
        switch input.lowercased() {
        case "quit", "exit", "q":
            print("Goodbye!")
            isRunning = false
            return

        case "help", "?":
            printHelp()
            return

        case "clear":
            engine.reset()
            print("\u{001B}[32mConversation cleared.\u{001B}[0m")
            return

        case "tools":
            printTools()
            return

        case "history":
            printHistory()
            return

        case "status":
            printStatus()
            return

        case "agents":
            printAgents()
            return

        default:
            break
        }

        // Process as message to agent
        await processMessage(input)
    }

    private func handleCommand(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1)
        let cmd = String(parts.first ?? "").lowercased()
        let arg = parts.count > 1 ? String(parts[1]) : nil

        switch cmd {
        case "tool":
            if let toolName = arg {
                Task { await testTool(toolName) }
            } else {
                print("Usage: /tool <name>")
                print("Available tools:")
                printTools()
            }

        case "agent":
            if let agentType = arg {
                addAgent(agentType)
            } else {
                print("Usage: /agent <type>")
                print("Types: claude, deepseek, gpt, ollama")
            }

        case "project":
            if let path = arg {
                engine.setup(projectPath: path, agents: engine.currentSession?.agents ?? [])
                print("\u{001B}[32mProject path set to: \(path)\u{001B}[0m")
            } else {
                print("Current project: \(projectPath)")
            }

        case "model":
            if let modelId = arg {
                print("Model selection would set: \(modelId)")
            } else {
                printModels()
            }

        case "export":
            exportHistory(to: arg ?? "conversation.json")

        case "load":
            if let path = arg {
                loadHistory(from: path)
            } else {
                print("Usage: /load <path>")
            }

        default:
            print("\u{001B}[33mUnknown command: /\(cmd)\u{001B}[0m")
            print("Type 'help' for available commands.")
        }
    }

    // MARK: - Message Processing

    private func processMessage(_ message: String) async {
        print("\n\u{001B}[90m--- Processing ---\u{001B}[0m")

        // Setup observation of state changes
        var lastThought = ""

        // Create a task to print updates while processing
        let updateTask = Task {
            while !Task.isCancelled {
                // Check for new thinking
                for (agentId, state) in await engine.agentStates {
                    if state.isActive && !state.currentThought.isEmpty && state.currentThought != lastThought {
                        lastThought = state.currentThought
                        print("\u{001B}[35m[\(agentId)] Thinking:\u{001B}[0m \(lastThought.prefix(100))...")
                    }
                }

                // Check for pending user input
                if let pending = await engine.pendingUserInput {
                    print("\n\u{001B}[36m[\(pending.agentId)] asks: \(pending.question)\u{001B}[0m")
                    print("> ", terminator: "")
                    fflush(stdout)
                    if let response = readLine() {
                        await MainActor.run {
                            engine.submitUserInput(response)
                        }
                    }
                }

                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }

        // Process the message
        await engine.processMessage(message)

        // Cancel the update task
        updateTask.cancel()

        // Print results
        printResults()
    }

    private func printResults() {
        print("\n\u{001B}[90m--- Results ---\u{001B}[0m")

        // Show recent messages
        let recentMessages = Array(engine.conversationHistory.suffix(10))

        for msg in recentMessages {
            switch msg {
            case .thinking(let agentId, let content, _, _):
                print("\u{001B}[35m[\(agentId)] Thought:\u{001B}[0m \(content.prefix(200))...")

            case .toolUse(let agentId, let name, let args, _, _):
                let argsStr = args.map { "\($0.key)=\($0.value.prefix(30))" }.joined(separator: ", ")
                print("\u{001B}[33m[\(agentId)] Tool:\u{001B}[0m \(name)(\(argsStr))")

            case .toolResult(_, let name, let result, _, _):
                let status = result.success ? "\u{001B}[32mOK\u{001B}[0m" : "\u{001B}[31mFAIL\u{001B}[0m"
                print("  -> \(name): \(status)")
                if !result.output.isEmpty {
                    let output = result.output.prefix(200)
                    print("     \(output)\(result.output.count > 200 ? "..." : "")")
                }
                if let error = result.error {
                    print("     \u{001B}[31mError: \(error)\u{001B}[0m")
                }

            case .assistant(let agentId, let content, _, _):
                print("\n\u{001B}[32m[\(agentId)] Response:\u{001B}[0m")
                print(content)

            case .error(_, let message, _, _):
                print("\u{001B}[31m[ERROR] \(message)\u{001B}[0m")

            case .agentHandoff(let from, let to, let context, _, _):
                print("\u{001B}[34m[HANDOFF] \(from) -> \(to): \(context.prefix(50))...\u{001B}[0m")

            default:
                break
            }
        }
    }

    // MARK: - Tool Testing

    private func testTool(_ toolName: String) async {
        print("Testing tool: \(toolName)")
        print("Enter arguments as JSON (or empty for defaults):")
        print("> ", terminator: "")
        fflush(stdout)

        guard let argsInput = readLine() else { return }

        var arguments: [String: Any] = [:]
        if !argsInput.isEmpty {
            if let data = argsInput.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                arguments = json
            } else {
                print("\u{001B}[31mInvalid JSON. Using empty arguments.\u{001B}[0m")
            }
        }

        do {
            let result = try await ToolRegistry.shared.execute(
                toolName: toolName,
                arguments: arguments,
                projectPath: projectPath
            )
            print("\n\u{001B}[32mTool Result:\u{001B}[0m")
            print("Success: \(result.success)")
            print("Output: \(result.output)")
            if let error = result.error {
                print("Error: \(error)")
            }
            if let metadata = result.metadata {
                print("Metadata: \(metadata)")
            }
        } catch {
            print("\u{001B}[31mTool execution failed: \(error)\u{001B}[0m")
        }
    }

    // MARK: - Agent Management

    private func addAgent(_ type: String) {
        let agent: AgentConfig
        switch type.lowercased() {
        case "claude":
            agent = AgentLoopEngine.createClaudeAgent()
        case "deepseek":
            agent = AgentLoopEngine.createDeepSeekAgent()
        case "gpt":
            agent = AgentLoopEngine.createGPTAgent()
        case "ollama", "local":
            agent = AgentLoopEngine.createLocalAgent()
        default:
            print("\u{001B}[31mUnknown agent type: \(type)\u{001B}[0m")
            print("Available: claude, deepseek, gpt, ollama")
            return
        }

        engine.addAgent(agent)
        print("\u{001B}[32mAdded \(type) agent: \(agent.id)\u{001B}[0m")
    }

    // MARK: - Export/Import

    private func exportHistory(to filename: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(engine.conversationHistory)
            try data.write(to: URL(fileURLWithPath: filename))
            print("\u{001B}[32mExported conversation to: \(filename)\u{001B}[0m")
        } catch {
            print("\u{001B}[31mFailed to export: \(error)\u{001B}[0m")
        }
    }

    private func loadHistory(from filename: String) {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: filename))
            let messages = try JSONDecoder().decode([AgentMessage].self, from: data)
            // Note: This would require exposing a way to set conversationHistory
            print("\u{001B}[32mLoaded \(messages.count) messages from: \(filename)\u{001B}[0m")
        } catch {
            print("\u{001B}[31mFailed to load: \(error)\u{001B}[0m")
        }
    }

    // MARK: - Display Helpers

    private func printBanner() {
        print("""

        \u{001B}[36m╔════════════════════════════════════════════════════════════╗
        ║          FloatingChatApp Agent CLI Tester                  ║
        ║                                                            ║
        ║   Type a message to interact with the agent                ║
        ║   Type 'help' for commands                                 ║
        ╚════════════════════════════════════════════════════════════╝\u{001B}[0m

        Project: \(projectPath)
        """)
    }

    private func printHelp() {
        print("""

        \u{001B}[33mCommands:\u{001B}[0m
          help      - Show this help
          tools     - List available tools
          history   - Show conversation history
          status    - Show engine status
          agents    - List active agents
          clear     - Clear conversation
          quit/exit - Exit

        \u{001B}[33mSlash Commands:\u{001B}[0m
          /tool <name>     - Test a specific tool interactively
          /agent <type>    - Add agent (claude/deepseek/gpt/ollama)
          /project <path>  - Set project path
          /model           - Show available models
          /export [file]   - Export conversation to JSON
          /load <file>     - Load conversation from JSON

        \u{001B}[33mExamples:\u{001B}[0m
          > List all Swift files in the project
          > Read the main AppDelegate file
          > Find all TODO comments in the codebase
          > Run the tests and tell me about any failures
        """)
    }

    private func printTools() {
        print("\n\u{001B}[33mAvailable Tools:\u{001B}[0m")
        for tool in ToolRegistry.shared.allTools() {
            print("  \u{001B}[36m\(tool.name)\u{001B}[0m - \(tool.description)")
            for param in tool.parameters {
                let req = param.required ? "*" : ""
                print("      \(param.name)\(req): \(param.type) - \(param.description)")
            }
        }
    }

    private func printHistory() {
        print("\n\u{001B}[33mConversation History (\(engine.conversationHistory.count) messages):\u{001B}[0m")
        for (i, msg) in engine.conversationHistory.enumerated() {
            let preview: String
            switch msg {
            case .user(let content, _, _):
                preview = "USER: \(content.prefix(60))"
            case .assistant(let agentId, let content, _, _):
                preview = "[\(agentId)] \(content.prefix(50))"
            case .thinking(let agentId, _, _, _):
                preview = "[\(agentId)] <thinking...>"
            case .toolUse(let agentId, let name, _, _, _):
                preview = "[\(agentId)] TOOL: \(name)"
            case .toolResult(_, let name, let result, _, _):
                preview = "  RESULT: \(name) -> \(result.success ? "OK" : "FAIL")"
            case .error(_, let message, _, _):
                preview = "ERROR: \(message.prefix(50))"
            case .agentHandoff(let from, let to, _, _, _):
                preview = "HANDOFF: \(from) -> \(to)"
            }
            print("  \(i): \(preview)")
        }
    }

    private func printStatus() {
        print("\n\u{001B}[33mEngine Status:\u{001B}[0m")
        print("  Running: \(engine.isRunning)")
        print("  Project: \(engine.currentSession?.projectPath ?? "not set")")
        print("  Agents: \(engine.agentStates.count)")
        for (id, state) in engine.agentStates {
            let statusStr: String
            switch state.status {
            case .idle: statusStr = "idle"
            case .thinking: statusStr = "thinking"
            case .usingTool(let tool): statusStr = "using \(tool)"
            case .waitingForUser: statusStr = "waiting for user"
            case .waitingForAgent(let agent): statusStr = "waiting for \(agent)"
            case .error(let msg): statusStr = "error: \(msg)"
            }
            print("    - \(id): \(statusStr)")
        }
        print("  Messages: \(engine.conversationHistory.count)")

        // Token stats
        let tokenManager = TokenManager.shared
        let usage = tokenManager.getSessionUsage()
        print("  Token Usage:")
        print("    Input: \(usage.inputTokens)")
        print("    Output: \(usage.outputTokens)")
        print("    Total: \(usage.totalTokens)")
        print("    API Calls: \(usage.totalCalls)")
    }

    private func printAgents() {
        print("\n\u{001B}[33mActive Agents:\u{001B}[0m")
        for agent in engine.currentSession?.agents ?? [] {
            let state = engine.agentStates[agent.id]
            let activeStr = state?.isActive == true ? " [ACTIVE]" : ""
            print("  \u{001B}[36m\(agent.name)\u{001B}[0m (\(agent.id))")
            print("    Provider: \(agent.provider)")
            print("    Model: \(agent.model)")
            print("    Role: \(agent.role.rawValue)\(activeStr)")
        }
    }

    private func printModels() {
        print("\n\u{001B}[33mAvailable Models by Provider:\u{001B}[0m")
        for provider in ProviderManager.shared.availableProviders {
            print("  \u{001B}[36m\(provider.name)\u{001B}[0m:")
            for model in provider.availableModels {
                print("    - \(model.displayName ?? model.name) [\(model.id)]")
            }
        }
    }
}

// MARK: - Entry Point

/// Run the CLI
/// Usage: swift run AgentCLI /path/to/project
func runAgentCLI() async {
    let args = CommandLine.arguments

    let projectPath: String
    if args.count > 1 {
        projectPath = args[1]
    } else {
        projectPath = FileManager.default.currentDirectoryPath
    }

    // Verify project path exists
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else {
        print("\u{001B}[31mError: Project path does not exist or is not a directory: \(projectPath)\u{001B}[0m")
        print("Usage: AgentCLI /path/to/project")
        return
    }

    let cli = await AgentCLI(projectPath: projectPath)
    await cli.run()
}
