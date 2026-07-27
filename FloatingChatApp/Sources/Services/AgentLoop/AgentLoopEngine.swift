import Foundation
import Combine

/// The main agentic reasoning loop - like Claude Code's core
/// Supports multiple agents (Claude, DeepSeek, GPT) working together
@MainActor
final class AgentLoopEngine: ObservableObject {
    static let shared = AgentLoopEngine()

    // MARK: - Published State

    @Published var isRunning = false
    @Published var conversationHistory: [AgentMessage] = []
    @Published var agentStates: [String: AgentState] = [:]
    @Published var pendingUserInput: PendingUserInput?
    @Published var currentSession: MultiAgentSession?

    // MARK: - Configuration

    var agents: [AgentConfig] = []
    var projectPath: String = ""
    private let toolRegistry = ToolRegistry.shared
    /// Max debate rounds (instance property so resume can target synthesis).
    var debateMaxRounds: Int = 3

    /// Recursion depth for nested sub-teams (0 = top level). Children run on
    /// SEPARATE engine instances so their conversation/single-flight state never
    /// collides with the parent.
    let depth: Int
    /// Hard cap on sub-team nesting (depth 0 spawns up to this many levels).
    var maxTeamDepth: Int = 3
    /// The most recent agent FINAL response (captured before any ChangeLog
    /// summary is appended), so sub-team result extraction returns the real
    /// answer, not the changelog (Codex HIGH).
    var lastSynthesizedResult: String?

    /// Per-engine bus for directed agent↔agent messaging (peer-to-peer over
    /// turns). One per instance, so sub-teams get isolated buses.
    let messageBus = AgentMessageBus()

    // Track current running tasks for cancellation
    private var runningTasks: [String: Task<Void, Never>] = [:]

    // Pending retry prompt from auto-build failures
    private var pendingRetryPrompt: String?

    // MARK: - Orchestration resume + re-plan state
    var orchestrationStore: OrchestrationCheckpointStore = .shared  // var for test injection
    var activeOrchestration: OrchestrationCheckpoint?
    var persistOrchestrationCheckpoints: Bool = true
    var orchestrationCancelRequested: Bool = false
    /// Single-flight guard, independent of the `isRunning` UI flag and of
    /// stop()/cancel() — cleared only when the owning public method returns, so
    /// a cooperatively-cancelled loop still blocks a new run until it actually
    /// exits (mirrors UnifiedAgentRuntime.isProcessing).
    var isProcessing: Bool = false
    /// Live re-plans allowed per single agent loop (shared by all modes).
    var perAgentReplanBudget: Int = 2
    /// Consecutive tool failures that trigger a live re-plan.
    var replanFailureThreshold: Int = 2

    /// `init()` stays effectively private for the shared top-level engine;
    /// children are created via `init(depth:)` from the sub-team spawner.
    init(depth: Int = 0) {
        self.depth = depth
    }

    // MARK: - Setup

    /// Initialize with project path and agents
    func setup(projectPath: String, agents: [AgentConfig]) {
        self.projectPath = projectPath
        self.agents = agents

        // Initialize agent states
        for agent in agents {
            agentStates[agent.id] = AgentState(id: agent.id)
        }

        // Create session
        currentSession = MultiAgentSession(agents: agents, projectPath: projectPath)
    }

    /// Add a new agent to the session
    func addAgent(_ config: AgentConfig) {
        agents.append(config)
        agentStates[config.id] = AgentState(id: config.id)
        currentSession?.agents.append(config)
    }

    // MARK: - Main Entry Point

    /// Process a user message - starts the agentic loop
    func processMessage(_ userMessage: String) async {
        guard !isProcessing else {
            conversationHistory.append(.error(agentId: "system", message: "A run is already in progress."))
            return
        }
        guard !projectPath.isEmpty else {
            conversationHistory.append(.error(agentId: "system", message: "No project path configured"))
            return
        }
        isProcessing = true
        defer { isProcessing = false }

        isRunning = true
        conversationHistory.append(.user(userMessage))

        // Determine which agent(s) should handle this
        let leadAgent = agents.first { $0.role == .lead } ?? agents.first

        guard let agent = leadAgent else {
            conversationHistory.append(.error(agentId: "system", message: "No agents configured"))
            isRunning = false
            return
        }

        // Start the agent loop
        await runAgentLoop(agent: agent, initialMessage: userMessage)

        isRunning = false
    }

    /// Run the agentic loop for a specific agent
    func runAgentLoop(agent: AgentConfig, initialMessage: String) async {
        agentStates[agent.id]?.isActive = true
        agentStates[agent.id]?.status = .thinking

        var continueLoop = true
        var iterationCount = 0
        let maxIterations = 50  // Safety limit

        // Live re-plan bookkeeping for this agent loop (benefits every
        // orchestration mode, since they all funnel through here).
        var consecutiveToolFailures = 0
        var replansUsed = 0

        while continueLoop && iterationCount < maxIterations {
            iterationCount += 1

            // Honor cancellation requested via stop()/cancelOrchestration().
            if orchestrationCancelRequested {
                agentStates[agent.id]?.status = .idle
                agentStates[agent.id]?.isActive = false
                return
            }

            // Drain this agent's message-bus inbox so directed messages from
            // other agents become visible context for this turn.
            for message in messageBus.drain(for: agent.id) {
                conversationHistory.append(.user("📨 Message from \(message.from): \(message.content)"))
            }

            // Build messages for the LLM
            let messages = buildMessages(for: agent)

            // Call the LLM
            let response = await callLLM(agent: agent, messages: messages)

            // Stop acting on a response that arrived after cancellation. (The
            // in-flight network await itself completes — cancellation is
            // cooperative at await boundaries; `runningTasks` is legacy/unused.)
            if orchestrationCancelRequested {
                agentStates[agent.id]?.status = .idle
                agentStates[agent.id]?.isActive = false
                return
            }

            // Parse the response
            let parsed = parseResponse(response)

            // Handle thinking
            if let thinking = parsed.thinking {
                agentStates[agent.id]?.currentThought = thinking
                conversationHistory.append(.thinking(agentId: agent.id, content: thinking))
            }

            // Handle tool calls
            if let toolCall = parsed.toolCall {
                // Precedence: tool_use wins. Make any dropped co-emitted action
                // explicit instead of silent (Codex).
                var dropped: [String] = []
                if parsed.spawnTeam != nil { dropped.append("<spawn_team>") }
                if parsed.send != nil { dropped.append("<send>") }
                if !dropped.isEmpty {
                    conversationHistory.append(.user("Note: emit ONE action per turn. \(dropped.joined(separator: " and ")) in that response was ignored because a tool_use was also present — re-issue it on its own turn if still needed."))
                }
                agentStates[agent.id]?.status = .usingTool(toolCall.name)
                conversationHistory.append(.toolUse(
                    agentId: agent.id,
                    name: toolCall.name,
                    arguments: toolCall.arguments.mapValues { String(describing: $0) }
                ))

                // Bracket the side effect for crash-safe resume: record the
                // tool we are about to run, then checkpoint. (No-op when not in
                // a team orchestration, i.e. activeOrchestration == nil.)
                activeOrchestration?.pendingTool = toolCall.name
                activeOrchestration?.conversationHistory = conversationHistory
                persistOrchestration()

                // Execute the tool
                let result = await executeTool(toolCall)
                conversationHistory.append(.toolResult(agentId: agent.id, name: toolCall.name, result: result))

                // Tool completed: persist the result so resume sees it as done
                // and won't re-run it, then clear the bracket.
                activeOrchestration?.pendingTool = nil
                activeOrchestration?.conversationHistory = conversationHistory
                persistOrchestration()

                // Track failures for live re-plan (env failures excluded).
                if result.success {
                    consecutiveToolFailures = 0
                } else if !isEnvironmentalFailure(result) {
                    consecutiveToolFailures += 1
                }

                // Check for auto-retry prompt from AgentRuntimeService
                // If a build failed after file changes, inject the retry instructions
                if let retryPrompt = pendingRetryPrompt {
                    pendingRetryPrompt = nil
                    conversationHistory.append(.user(retryPrompt))
                    agentStates[agent.id]?.status = .thinking
                }

                // Live re-plan: if actions keep failing, get a revised strategy
                // instead of looping the same broken approach (all modes).
                if consecutiveToolFailures >= replanFailureThreshold && replansUsed < perAgentReplanBudget {
                    replansUsed += 1  // consume budget for the attempt (success or not)
                    if let revised = await requestAgentReplan(agent: agent, goal: initialMessage) {
                        conversationHistory.append(.user(ReplanEngine.steeringMessage(for: revised)))
                        consecutiveToolFailures = 0
                    }
                }

                // Continue loop to process result
                continue
            }

            // Handle agent handoff
            if let handoff = parsed.handoff {
                if let targetAgent = agents.first(where: { $0.id == handoff.targetAgentId }) {
                    conversationHistory.append(.agentHandoff(
                        from: agent.id,
                        to: targetAgent.id,
                        context: handoff.context
                    ))

                    // Run the target agent
                    await runAgentLoop(agent: targetAgent, initialMessage: handoff.context)
                }
                continue
            }

            // Handle sub-team spawn (recursive orchestration)
            if let spawn = parsed.spawnTeam {
                if parsed.send != nil {
                    conversationHistory.append(.user("Note: a <send> in that response was ignored because a <spawn_team> was also present — re-issue it on its own turn."))
                }
                let result = await spawnSubTeam(spawn, parentAgent: agent)
                conversationHistory.append(.user("Sub-team (\(spawn.teamId)) result:\n\(result)"))
                continue
            }

            // Handle directed agent-to-agent message (message bus)
            if let send = parsed.send {
                messageBus.send(from: agent.id, to: send.to, content: send.content)
                conversationHistory.append(.agentHandoff(from: agent.id, to: send.to, context: "✉️ \(send.content)"))
                continue
            }

            // Handle ask user
            if let question = parsed.askUser {
                agentStates[agent.id]?.status = .waitingForUser

                // Wait for user response
                let userResponse = await waitForUserInput(question: question, agentId: agent.id)
                conversationHistory.append(.user(userResponse))
                continue
            }

            // If we get here, this is the final response
            if let finalResponse = parsed.finalResponse {
                conversationHistory.append(.assistant(agentId: agent.id, content: finalResponse))
                // Capture BEFORE the changelog summary is appended below.
                lastSynthesizedResult = finalResponse
            }

            continueLoop = false
        }

        // Append a synthesized summary of changes/build for better visibility
        let summary = await ChangeLogStore.shared.summaryMarkdown
        if !summary.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            conversationHistory.append(.assistant(agentId: agent.id, content: summary))
        }

        agentStates[agent.id]?.isActive = false
        agentStates[agent.id]?.status = .idle
        agentStates[agent.id]?.currentThought = ""
    }

    // MARK: - LLM Interaction

    private let tokenManager = TokenManager.shared

    private func buildMessages(for agent: AgentConfig) -> [ChatMessage] {
        var messages: [ChatMessage] = []

        // System prompt
        let systemPrompt = buildSystemPrompt(for: agent)
        messages.append(ChatMessage(role: .system, content: systemPrompt))

        // Get context limit for the model
        let contextLimit = TokenManager.ContextLimits.limit(for: agent.model)
        let systemTokens = tokenManager.estimateTokens(systemPrompt)

        // Truncate conversation history if needed to fit context
        let truncatedHistory = tokenManager.truncateHistory(
            conversationHistory,
            maxTokens: contextLimit - systemTokens,
            reserveForResponse: 4096
        )

        // Convert conversation history to chat messages
        // FIXED: Updated pattern matching for new AgentMessage signatures with id and timestamp
        for message in truncatedHistory {
            switch message {
            case .user(let content, _, _):
                messages.append(ChatMessage(role: .user, content: content))

            case .assistant(_, let content, _, _):
                messages.append(ChatMessage(role: .assistant, content: content))

            case .thinking(let agentId, let content, _, _) where agentId == agent.id:
                // Include own thinking as assistant message
                messages.append(ChatMessage(role: .assistant, content: "<thinking>\(content)</thinking>"))

            case .toolUse(let agentId, let name, let args, _, _) where agentId == agent.id:
                let argsJson = try? JSONSerialization.data(withJSONObject: args, options: [])
                let argsString = argsJson.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                messages.append(ChatMessage(role: .assistant, content: "<tool_use>\n{\"tool\": \"\(name)\", \"arguments\": \(argsString)}\n</tool_use>"))

            case .toolResult(let agentId, let name, let result, _, _) where agentId == agent.id:
                let resultContent = result.success ? result.output : "Error: \(result.error ?? "Unknown error")"
                messages.append(ChatMessage(role: .user, content: "<tool_result name=\"\(name)\">\n\(resultContent)\n</tool_result>"))

            case .agentHandoff(_, let to, let context, _, _) where to == agent.id:
                messages.append(ChatMessage(role: .user, content: "Handoff from another agent: \(context)"))

            default:
                break
            }
        }

        return messages
    }

    private func buildSystemPrompt(for agent: AgentConfig) -> String {
        let toolDescriptions = toolRegistry.toolDescriptions()

        // Pull active context (apps/files) to ground the agent
        let contextSummary = ConversationManager.shared.getContextSummary()

        var prompt = """
        You are \(agent.name), an expert coding assistant working on a macOS/iOS Swift project.
        Your role: \(agent.role.rawValue)

        PROJECT PATH: \(projectPath)

        USER CONTEXT:
        \(contextSummary.isEmpty ? "(none)" : contextSummary)

        BEHAVIOR:
        - Think step by step before acting
        - Read relevant files before making changes
        - Make targeted, minimal edits
        - Build and verify your changes work
        - Ask the user if anything is unclear
        - Show your reasoning process

        AVAILABLE TOOLS:
        \(toolDescriptions)

        OUTPUT FORMAT:
        When thinking, wrap your thoughts in:
        <thinking>
        Your step-by-step reasoning here...
        </thinking>

        When you want to use a tool, output EXACTLY:
        <tool_use>
        {"tool": "tool_name", "arguments": {"arg1": "value1", "arg2": "value2"}}
        </tool_use>

        When you need to ask the user a question:
        <ask_user>
        Your question here?
        </ask_user>

        When handing off to another agent:
        <handoff agent="agent_id">
        Context and instructions for the other agent
        </handoff>

        When a sub-problem needs a whole TEAM (e.g. a debate or a multi-role
        effort), spawn a sub-team — it runs its own orchestration and returns a
        synthesized result:
        <spawn_team team="debate">
        The focused task for the sub-team to work on
        </spawn_team>
        Valid team ids: solo, coding-duo, full-team, local-team, debate.

        To send a direct message to another agent (they'll see it on their next
        turn and can reply the same way):
        <send to="agent_id">
        Your message to that agent
        </send>

        After completing a task, provide a clear summary of what you did.

        IMPORTANT:
        - Always use tools to read files before editing them
        - Make small, incremental changes
        - Build after making changes to verify they work
        - If a build fails, analyze the errors and fix them
        """

        if let customPrompt = agent.systemPrompt {
            prompt += "\n\nADDITIONAL INSTRUCTIONS:\n\(customPrompt)"
        }

        return prompt
    }

    private func callLLM(agent: AgentConfig, messages: [ChatMessage]) async -> String {
        let provider = getProvider(for: agent)

        var settings = ModelSettings()
        settings.temperature = 0.3
        settings.topP = 0.9
        settings.maxTokens = 8192
        settings.systemPrompt = ""  // Already included in messages

        do {
            var response = ""
            let stream = try await provider.sendMessage(
                messages: messages,
                settings: settings,
                stream: true
            )

            for try await chunk in stream {
                response += chunk
                // Update current thought with partial response
                if let thinkingMatch = response.range(of: "<thinking>") {
                    let afterThinking = response[thinkingMatch.upperBound...]
                    if let endThinking = afterThinking.range(of: "</thinking>") {
                        agentStates[agent.id]?.currentThought = String(afterThinking[..<endThinking.lowerBound])
                    } else {
                        agentStates[agent.id]?.currentThought = String(afterThinking)
                    }
                }
            }

            return response
        } catch {
            return "<error>Failed to call LLM: \(error.localizedDescription)</error>"
        }
    }

    func getProvider(for agent: AgentConfig) -> any AIProvider {
        // First check if we should use the user's selected provider from ProviderManager
        let userSelectedProvider = ProviderManager.shared.currentProvider

        // If agent.provider matches the user's selection type, use it
        // This respects the user's model selection in the UI
        // The agent's configured model (if concrete) overrides the provider's
        // global default WITHOUT persisting — so each agent on a team can run a
        // different model on the same provider, with no global thrash/races.
        let override = applicableModelOverride(agent.model)

        switch agent.provider {
        case "user_selected", "auto":
            // Defer entirely to the user's UI selection (provider + model).
            return userSelectedProvider
        case "deepseek":
            let p = DeepSeekProvider(); p.modelOverride = override; return p
        case "gpt", "openai":
            let p = OpenAIProvider(); p.modelOverride = override; return p
        case "gemini", "google":
            let p = GeminiProvider(); p.modelOverride = override; return p
        case "grok", "xai":
            let p = GrokProvider(); p.modelOverride = override; return p
        case "moonshot", "kimi":
            let p = MoonshotProvider(); p.modelOverride = override; return p
        case "zhipu", "glm":
            let p = ZhipuProvider(); p.modelOverride = override; return p
        case "mimo", "xiaomi":
            let p = MiMoProvider(); p.modelOverride = override; return p
        case "ollama":
            let p = OllamaProvider(); p.modelOverride = override; return p
        case "mlx":
            let p = MLXProvider(); p.modelOverride = override; return p
        case "claude", "anthropic":
            let p = AnthropicProvider(); p.modelOverride = override; return p
        default:
            return userSelectedProvider
        }
    }

    /// A concrete per-agent model, or nil for "use the provider default".
    private func applicableModelOverride(_ model: String) -> String? {
        guard !model.isEmpty, model != "auto", model != "default" else { return nil }
        return model
    }

    // MARK: - Response Parsing

    private struct ParsedResponse {
        var thinking: String?
        var toolCall: AgentToolCall?
        var handoff: AgentHandoff?
        var spawnTeam: SpawnTeamRequest?
        var send: BusSendRequest?
        var askUser: String?
        var finalResponse: String?
    }

    private struct AgentHandoff {
        let targetAgentId: String
        let context: String
    }

    /// An agent's request to spawn a SUB-TEAM that runs its own orchestration.
    struct SpawnTeamRequest: Equatable {
        let teamId: String
        let task: String
    }

    /// An agent's directed message to another agent (message bus).
    struct BusSendRequest: Equatable {
        let to: String
        let content: String
    }

    /// Parse `<send to="agent-id">message</send>`. Static + pure for tests.
    static func parseSend(_ response: String) -> BusSendRequest? {
        let pattern = #"<send\s+to="([^"]+)"[^>]*>([\s\S]*?)</send>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
              let toRange = Range(match.range(at: 1), in: response),
              let contentRange = Range(match.range(at: 2), in: response) else {
            return nil
        }
        return BusSendRequest(
            to: String(response[toRange]),
            content: String(response[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Parse `<spawn_team team="...">task</spawn_team>`. Static + pure for tests.
    static func parseSpawnTeam(_ response: String) -> SpawnTeamRequest? {
        let pattern = #"<spawn_team\s+team="([^"]+)">([\s\S]*?)</spawn_team>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
              let teamRange = Range(match.range(at: 1), in: response),
              let taskRange = Range(match.range(at: 2), in: response) else {
            return nil
        }
        return SpawnTeamRequest(
            teamId: String(response[teamRange]),
            task: String(response[taskRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func parseResponse(_ response: String) -> ParsedResponse {
        var parsed = ParsedResponse()

        // Check for error response first
        if let errorRange = response.range(of: "<error>"),
           let endError = response.range(of: "</error>") {
            let errorMsg = String(response[errorRange.upperBound..<endError.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            parsed.finalResponse = "⚠️ Error: \(errorMsg)"
            return parsed
        }

        // Extract thinking
        if let thinkingRange = response.range(of: "<thinking>"),
           let endThinking = response.range(of: "</thinking>") {
            parsed.thinking = String(response[thinkingRange.upperBound..<endThinking.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Extract tool use
        if let toolRange = response.range(of: "<tool_use>"),
           let endTool = response.range(of: "</tool_use>") {
            let toolJson = String(response[toolRange.upperBound..<endTool.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let data = toolJson.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let toolName = json["tool"] as? String,
               let args = json["arguments"] as? [String: Any] {
                parsed.toolCall = AgentToolCall(name: toolName, arguments: args)
            }
        }

        // Extract ask user
        if let askRange = response.range(of: "<ask_user>"),
           let endAsk = response.range(of: "</ask_user>") {
            parsed.askUser = String(response[askRange.upperBound..<endAsk.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Extract handoff
        let handoffPattern = #"<handoff agent="([^"]+)">([\s\S]*?)</handoff>"#
        if let regex = try? NSRegularExpression(pattern: handoffPattern),
           let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)) {
            if let agentRange = Range(match.range(at: 1), in: response),
               let contextRange = Range(match.range(at: 2), in: response) {
                parsed.handoff = AgentHandoff(
                    targetAgentId: String(response[agentRange]),
                    context: String(response[contextRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }

        // Spawn sub-team
        parsed.spawnTeam = Self.parseSpawnTeam(response)

        // Directed agent-to-agent message
        parsed.send = Self.parseSend(response)

        // If no special tags, treat as final response
        if parsed.toolCall == nil && parsed.handoff == nil && parsed.spawnTeam == nil && parsed.send == nil && parsed.askUser == nil {
            // Remove thinking tags and get clean response
            var finalText = response
            if let thinkingRange = response.range(of: "<thinking>"),
               let endThinking = response.range(of: "</thinking>") {
                finalText = String(response[..<thinkingRange.lowerBound]) +
                           String(response[endThinking.upperBound...])
            }
            finalText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalText.isEmpty {
                parsed.finalResponse = finalText
            }
        }

        return parsed
    }

    // MARK: - Tool Execution

    private func executeTool(_ toolCall: AgentToolCall) async -> ToolResult {
        do {
            // Use runtime service for auto-build and retry hooks
            let result = try await toolRegistry.executeWithRuntime(
                toolName: toolCall.name,
                arguments: toolCall.arguments,
                projectPath: projectPath
            )

            // After tool execution, check if there are pending build errors that need retry
            // This is injected into the conversation as if the agent received an error
            if AgentRuntimeService.shared.hasPendingErrors,
               let retryPrompt = AgentRuntimeService.shared.getRetryPrompt() {
                // Store the retry prompt to be processed in the next loop iteration
                pendingRetryPrompt = retryPrompt
            }

            return result
        } catch {
            return ToolResult(
                success: false,
                output: "",
                error: "Tool execution failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - User Interaction

    private func waitForUserInput(question: String, agentId: String) async -> String {
        return await withCheckedContinuation { continuation in
            pendingUserInput = PendingUserInput(
                agentId: agentId,
                question: question,
                options: nil,
                continuation: { response in
                    continuation.resume(returning: response)
                }
            )
        }
    }

    /// Called when user provides input
    /// FIXED: continuation is now sync (async is handled internally via withCheckedContinuation)
    func submitUserInput(_ input: String) {
        guard let pending = pendingUserInput else { return }
        pendingUserInput = nil
        pending.continuation(input)  // Sync call - no await needed
    }

    // MARK: - Control

    func stop() {
        orchestrationCancelRequested = true
        for (_, task) in runningTasks {
            task.cancel()
        }
        runningTasks.removeAll()
        isRunning = false

        // Unblock any loop suspended on user input, or cancellation would
        // leave it permanently parked (Codex HIGH). In-flight LLM/tool awaits
        // are not force-killed; cancellation is honored at loop boundaries.
        if let pending = pendingUserInput {
            pendingUserInput = nil
            pending.continuation("[cancelled]")
        }

        for agentId in agentStates.keys {
            agentStates[agentId]?.isActive = false
            agentStates[agentId]?.status = .idle
        }

        // Mark the active orchestration cancelled on disk so it isn't offered
        // as resumable.
        if activeOrchestration != nil {
            activeOrchestration!.status = .cancelled
            persistOrchestration()
        }
    }

    func reset() {
        stop()
        conversationHistory = []
        pendingUserInput = nil
        activeOrchestration = nil
        orchestrationCancelRequested = false
        messageBus.clear()

        for agentId in agentStates.keys {
            agentStates[agentId] = AgentState(id: agentId)
        }
    }

    // MARK: - Multiple Agents in Parallel

    /// Run multiple agents simultaneously on different tasks. Public entry →
    /// single-flight guarded. (Internal orchestration uses `fanOut` directly.)
    func runAgentsInParallel(tasks: [(agent: AgentConfig, task: String)]) async {
        guard !isProcessing else {
            conversationHistory.append(.error(agentId: "system", message: "A run is already in progress."))
            return
        }
        isProcessing = true
        defer { isProcessing = false }

        isRunning = true
        await fanOut(tasks: tasks)
        isRunning = false
    }

    /// The actual concurrent fan-out. NOT single-flight guarded — callers that
    /// already hold the guard (orchestration modes) use this directly.
    private func fanOut(tasks: [(agent: AgentConfig, task: String)]) async {
        await withTaskGroup(of: Void.self) { group in
            for (agent, task) in tasks {
                group.addTask {
                    await self.runAgentLoop(agent: agent, initialMessage: task)
                }
            }
        }
    }

    // MARK: - Team Orchestration

    /// Setup and run a team of agents based on team configuration
    func setupTeam(_ team: AgentTeam, projectPath: String) {
        self.projectPath = projectPath
        self.agents = team.agents.map { member in
            createAgentConfig(from: member)
        }

        // Initialize agent states
        for agent in agents {
            agentStates[agent.id] = AgentState(id: agent.id)
        }

        currentSession = MultiAgentSession(agents: agents, projectPath: projectPath)
    }

    /// Process a message using the configured team
    func processMessageWithTeam(_ userMessage: String, team: AgentTeam) async {
        guard !isProcessing else {
            conversationHistory.append(.error(agentId: "system", message: "A run is already in progress."))
            return
        }
        guard !projectPath.isEmpty else {
            conversationHistory.append(.error(agentId: "system", message: "No project path configured"))
            return
        }
        guard !agents.isEmpty else {
            conversationHistory.append(.error(agentId: "system", message: "No agents configured"))
            return
        }
        isProcessing = true
        defer { isProcessing = false }

        isRunning = true
        orchestrationCancelRequested = false
        conversationHistory.append(.user(userMessage))

        // Create + persist a fresh orchestration checkpoint.
        let mode: OrchestrationCheckpoint.Mode
        switch team.orchestrationMode {
        case .sequential: mode = .sequential
        case .parallel: mode = .parallel
        case .collaborative: mode = .collaborative
        case .debate: mode = .debate
        }
        var checkpoint = OrchestrationCheckpoint(
            mode: mode, userMessage: userMessage, projectPath: projectPath, agents: agents
        )
        checkpoint.conversationHistory = conversationHistory
        activeOrchestration = checkpoint
        persistOrchestration()

        switch team.orchestrationMode {
        case .sequential:
            await runSequentialOrchestration(message: userMessage, startIndex: 0)
        case .parallel:
            await runParallelOrchestration(message: userMessage)
        case .collaborative:
            await runCollaborativeOrchestration(message: userMessage)
        case .debate:
            await runDebateOrchestration(message: userMessage, startRound: 0, skipInitialPositions: false)
        }

        // Deliver any outstanding agent↔agent messages before wrapping up.
        await settleMessages()

        finalizeOrchestration()
        isRunning = false
    }

    /// Sequential: Each agent processes in order, passing context to next.
    /// `startIndex` lets resume pick up at the next un-run agent without
    /// re-running (and re-side-effecting) agents that already completed.
    func runSequentialOrchestration(message: String, startIndex: Int) async {
        var currentContext = message
        var index = max(0, startIndex)

        while index < agents.count {
            if orchestrationCancelRequested { return }
            let agent = agents[index]

            conversationHistory.append(.thinking(
                agentId: agent.id,
                content: "Starting \(agent.role.rawValue) phase..."
            ))

            await runAgentLoop(agent: agent, initialMessage: currentContext)

            // Get the agent's output to pass to next agent
            if let lastAssistant = conversationHistory.last(where: {
                if case .assistant(let id, _, _, _) = $0, id == agent.id { return true }
                return false
            }), case .assistant(_, let content, _, _) = lastAssistant {
                currentContext = "Previous agent (\(agent.name)) output:\n\(content)\n\nContinue the task."
            }

            // Checkpoint the cursor AFTER this agent: the next index to run.
            index += 1
            activeOrchestration?.phase = .sequential
            activeOrchestration?.sequentialIndex = index
            activeOrchestration?.conversationHistory = conversationHistory
            persistOrchestration()
        }
    }

    /// Parallel: All agents work on subtasks simultaneously
    private func runParallelOrchestration(message: String) async {
        // Create subtasks for each agent based on their role
        var tasks: [(agent: AgentConfig, task: String)] = []

        for agent in agents {
            let subtask: String
            switch agent.role {
            case .lead:
                subtask = "Analyze and plan the approach for: \(message)"
            case .coder:
                subtask = "Write the code implementation for: \(message)"
            case .reviewer:
                subtask = "Review the approach and identify potential issues for: \(message)"
            case .researcher:
                subtask = "Search and gather relevant information for: \(message)"
            case .builder:
                subtask = "Prepare build and test strategy for: \(message)"
            }
            tasks.append((agent, subtask))
        }

        await fanOut(tasks: tasks)

        // Synthesize results
        let leadAgent = agents.first { $0.role == .lead } ?? agents.first!
        let synthesisMessage = "Synthesize the team's outputs and provide a unified response."
        await runAgentLoop(agent: leadAgent, initialMessage: synthesisMessage)
    }

    /// Collaborative: Lead agent delegates to specialists as needed
    private func runCollaborativeOrchestration(message: String) async {
        guard let leadAgent = agents.first(where: { $0.role == .lead }) ?? agents.first else { return }

        // Enhance lead agent's system prompt to know about team members
        let teamInfo = agents.map { agent in
            "- \(agent.name) (\(agent.id)): \(agent.role.rawValue)"
        }.joined(separator: "\n")

        let enhancedMessage = """
        You are the lead agent coordinating a team. Your team members are:
        \(teamInfo)

        You can delegate tasks using <handoff agent="agent-id">task description</handoff>

        User request: \(message)
        """

        await runAgentLoop(agent: leadAgent, initialMessage: enhancedMessage)
    }

    /// Debate: Agents discuss and reach consensus.
    /// `startRound` + `skipInitialPositions` let resume continue from a
    /// completed round instead of re-running the whole debate.
    func runDebateOrchestration(message: String, startRound: Int, skipInitialPositions: Bool) async {
        let maxRounds = debateMaxRounds
        var round = max(0, startRound)
        var consensusReached = activeOrchestration?.consensusReached ?? false

        // Initial positions from all agents (skipped on resume past round 0)
        if !skipInitialPositions {
            for agent in agents {
                if orchestrationCancelRequested { return }
                let prompt = "Share your initial perspective on: \(message)"
                await runAgentLoop(agent: agent, initialMessage: prompt)
            }
            activeOrchestration?.phase = .debateRounds
            activeOrchestration?.debateRound = 0
            activeOrchestration?.conversationHistory = conversationHistory
            persistOrchestration()
        }

        // Debate rounds
        while round < maxRounds && !consensusReached {
            if orchestrationCancelRequested { return }
            round += 1

            for agent in agents {
                if orchestrationCancelRequested { return }
                // Get other agents' recent statements
                let otherStatements = conversationHistory.suffix(agents.count * 2)
                    .compactMap { msg -> String? in
                        if case .assistant(let id, let content, _, _) = msg, id != agent.id {
                            let agentName = agents.first { $0.id == id }?.name ?? id
                            return "\(agentName): \(content.prefix(500))"
                        }
                        return nil
                    }
                    .joined(separator: "\n\n")

                let debatePrompt = """
                Round \(round) of debate.

                Other team members said:
                \(otherStatements)

                Respond to their points. If you agree with the emerging consensus, say "CONSENSUS REACHED" at the end.
                Otherwise, present your counter-arguments or refinements.
                """

                await runAgentLoop(agent: agent, initialMessage: debatePrompt)

                // Check for consensus
                if let lastResponse = conversationHistory.last(where: {
                    if case .assistant(let id, _, _, _) = $0, id == agent.id { return true }
                    return false
                }), case .assistant(_, let content, _, _) = lastResponse {
                    if content.contains("CONSENSUS REACHED") {
                        consensusReached = true
                        break
                    }
                }
            }

            // Checkpoint after each completed round.
            activeOrchestration?.phase = .debateRounds
            activeOrchestration?.debateRound = round
            activeOrchestration?.consensusReached = consensusReached
            activeOrchestration?.conversationHistory = conversationHistory
            persistOrchestration()
        }

        if orchestrationCancelRequested { return }

        // Final synthesis by lead
        activeOrchestration?.phase = .synthesis
        activeOrchestration?.conversationHistory = conversationHistory
        persistOrchestration()
        if let leadAgent = agents.first(where: { $0.role == .lead }) {
            let finalPrompt = consensusReached
                ? "The team has reached consensus. Summarize the agreed-upon solution."
                : "Summarize the debate and present the best solution considering all perspectives."
            await runAgentLoop(agent: leadAgent, initialMessage: finalPrompt)
        }
    }

    /// Create an AgentConfig from a team member definition
    private func createAgentConfig(from member: AgentTeam.AgentTeamMember) -> AgentConfig {
        let agentRole: AgentConfig.AgentRole
        switch member.role {
        case .lead: agentRole = .lead
        case .coder: agentRole = .coder
        case .reviewer: agentRole = .reviewer
        case .researcher: agentRole = .researcher
        case .builder: agentRole = .builder
        }

        let color: String
        switch member.provider {
        case "claude": color = "#D97706"
        case "gpt", "openai": color = "#10B981"
        case "deepseek": color = "#3B82F6"
        case "mlx": color = "#34D399"
        case "ollama": color = "#8B5CF6"
        default: color = "#6B7280"
        }

        return AgentConfig(
            id: member.memberId,
            name: "\(member.provider.capitalized) \(member.role.rawValue.capitalized)",
            provider: member.provider,
            model: member.model,
            role: agentRole,
            color: color,
            systemPrompt: "You are specialized in: \(member.specialization)"
        )
    }
}

// MARK: - Preset Agent Configurations

extension AgentLoopEngine {
    /// Create an agent that uses whatever provider the user has selected in the UI
    static func createUserSelectedAgent(role: AgentConfig.AgentRole = .lead) -> AgentConfig {
        let provider = ProviderManager.shared.currentProvider
        let modelId = provider.selectedModel?.id ?? "default"

        return AgentConfig(
            id: "agent-\(UUID().uuidString.prefix(8))",
            name: provider.name,
            provider: "user_selected",  // Special flag to use user's selection
            model: modelId,
            role: role,
            color: provider.isLocal ? "#10B981" : "#D97706",  // Green for local, orange for cloud
            systemPrompt: nil
        )
    }

    static func createClaudeAgent(role: AgentConfig.AgentRole = .lead) -> AgentConfig {
        AgentConfig(
            id: "claude-\(UUID().uuidString.prefix(8))",
            name: "Claude",
            provider: "claude",
            model: "claude-fable-5",
            role: role,
            color: "#D97706",
            systemPrompt: nil
        )
    }

    static func createMLXAgent(role: AgentConfig.AgentRole = .lead) -> AgentConfig {
        let mlxProvider = MLXProvider()
        let modelId = mlxProvider.selectedModel?.id ?? "mlx-community/Llama-3.2-3B-Instruct-4bit"

        return AgentConfig(
            id: "mlx-\(UUID().uuidString.prefix(8))",
            name: "MLX Local",
            provider: "mlx",
            model: modelId,
            role: role,
            color: "#10B981",  // Green for local
            systemPrompt: "You are a helpful AI assistant running locally on Apple Silicon via MLX. You have access to tools to help the user with coding tasks."
        )
    }

    static func createDeepSeekAgent(role: AgentConfig.AgentRole = .coder) -> AgentConfig {
        AgentConfig(
            id: "deepseek-\(UUID().uuidString.prefix(8))",
            name: "DeepSeek",
            provider: "deepseek",
            model: "deepseek-v4-pro",
            role: role,
            color: "#3B82F6",
            systemPrompt: "You are specialized in writing high-quality Swift code. Focus on clean, efficient implementations."
        )
    }

    static func createGPTAgent(role: AgentConfig.AgentRole = .reviewer) -> AgentConfig {
        AgentConfig(
            id: "gpt-\(UUID().uuidString.prefix(8))",
            name: "GPT",
            provider: "gpt",
            model: "gpt-5.5",
            role: role,
            color: "#10B981",
            systemPrompt: "You are specialized in code review. Focus on finding bugs, security issues, and suggesting improvements."
        )
    }

    static func createLocalAgent(role: AgentConfig.AgentRole = .researcher) -> AgentConfig {
        AgentConfig(
            id: "local-\(UUID().uuidString.prefix(8))",
            name: "Local LLM",
            provider: "ollama",
            model: "codellama",
            role: role,
            color: "#8B5CF6",
            systemPrompt: "You are a fast local assistant for quick searches and file reading."
        )
    }
}
