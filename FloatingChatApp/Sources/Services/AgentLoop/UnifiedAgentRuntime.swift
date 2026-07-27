import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.floatingchat.app", category: "UnifiedRuntime")

/// The Unified Agent Runtime - the "soul" that makes this a Claude Code-style agent.
///
/// This is the single entry point that:
/// 1. Calls LLM with structured JSON prompt
/// 2. Parses response into ExecutionPlan
/// 3. Executes actions sequentially
/// 4. Publishes state for UI binding
/// 5. Handles recovery on failures
///
/// ARCHITECTURE: Agent runs on background queue, posts updates to main thread.
/// This prevents "Publishing changes from within view updates" SwiftUI warnings.
///
/// The UI binds to @Published properties to show:
/// Intent → Plan → Actions → Results
@MainActor
final class UnifiedAgentRuntime: ObservableObject {
    static let shared = UnifiedAgentRuntime()

    // MARK: - Published State (UI binds to these)

    @Published var currentIntent: AgentIntent?
    @Published var currentPlan: ExecutionPlan?
    @Published var executionState: ExecutionState = .idle
    @Published var currentActionIndex: Int = 0
    @Published var actionResults: [ActionExecutionResult] = []
    @Published var isWaitingForApproval: Bool = false
    @Published var pendingQuestion: String?
    @Published var retryAttempt: Int = 0
    @Published var isRetrying: Bool = false

    // MARK: - Configuration

    var projectPath: String = ""
    var requirePlanApproval: Bool = false
    var maxRetryAttempts: Int = 3
    var maxIterations: Int = 3                   // Hard cap to prevent runaway loops
    var maxReplanAttempts: Int = 2               // Live re-plans before giving up
    var replanFailureThreshold: Int = 2          // Consecutive failures that trigger a re-plan
    var enforceProjectPathForProjectTools = true // Fail-fast when project path is invalid
    var oneShotMode: Bool = false                // Plan → 1 mutating action → verify → stop
    var planPreviewBeforeIterative: Bool = true  // Show plan before iterative run
    var runTestsAfterWrite: Bool = true          // Run tests after file writes
    var autoInstallDependencies: Bool = true     // Attempt to resolve/install deps on build failure

    // MARK: - Dependencies

    private let toolRegistry = ToolRegistry.shared
    private let runtimeService = AgentRuntimeService.shared
    var checkpointStore: CheckpointStore = .shared   // var for test injection

    // MARK: - Resumable run state
    //
    // The in-flight run, persisted after every iteration so it can be resumed
    // (see UnifiedAgentRuntime+Resume.swift). `activeRun` is the single source
    // of truth for the loop's serializable state.
    var activeRun: AgentCheckpoint?
    var activeCheckpointID: String?
    var persistCheckpoints: Bool = true
    /// Set by `cancel()`; the resumable loop checks this at each await boundary
    /// and stops cleanly (Codex MED-2).
    var cancelRequested: Bool = false
    /// Single-flight guard: the runtime runs one loop at a time. A second
    /// process()/resume() while one is active is rejected (it would corrupt the
    /// active run's state).
    var isProcessing: Bool = false
    /// Surfaced when a checkpoint write fails, so callers/UI don't trust a run
    /// as resumable when its state isn't actually on disk (Codex MED-2).
    @Published var lastCheckpointError: String?

    // For plan approval continuation
    private var approvalContinuation: CheckedContinuation<Bool, Never>?

    private init() {}

    // MARK: - Thread-Safe State Updates

    /// Post state updates to defer SwiftUI "Publishing changes from within view updates" warnings
    /// Uses Task with delay to ensure updates happen after view cycle completes
    func postUpdate(_ update: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            // Small delay to ensure we're not in a view update cycle
            try? await Task.sleep(nanoseconds: 1_000_000) // 1ms delay
            update()
        }
    }

    // MARK: - Main Entry Point (ITERATIVE LOOP)

    /// Process a user message through the ITERATIVE agent loop:
    /// intent → action → observe → action → observe → ... → done
    ///
    /// This is the Claude Code architecture:
    /// - Request ONE action at a time from LLM
    /// - Execute it
    /// - Feed result back to LLM
    /// - LLM decides next action
    /// - Repeat until "done" or max iterations
    func process(_ userMessage: String) async -> ExecutionResult {
        guard !isProcessing else {
            return .failed("A run is already in progress. Cancel it before starting another.")
        }
        isProcessing = true
        defer { isProcessing = false }

        if oneShotMode {
            return await processOneShot(userMessage)
        }
        reset()
        postUpdate { [self] in
            executionState = ExecutionState.analyzing
        }

        // Optional plan preview before iterative loop
        if planPreviewBeforeIterative {
            let response = await callLLMForStructuredPlan(userMessage)
            if let plan = parseStructuredResponse(response) {
                postUpdate { [self, plan] in
                    currentIntent = plan.intent
                    currentPlan = plan
                    executionState = ExecutionState.planning
                }
                if requirePlanApproval && !(plan.actions.isEmpty) {
                    postUpdate { [self] in
                        isWaitingForApproval = true
                    }
                    let approved = await waitForApproval()
                    postUpdate { [self] in
                        isWaitingForApproval = false
                        executionState = approved ? .analyzing : .cancelled
                    }
                    if !approved { return .cancelled }
                } else {
                    // Move to analyzing for the iterative loop
                    postUpdate { [self] in
                        executionState = ExecutionState.analyzing
                    }
                }
            }
        }

        logger.info("Starting iterative loop for: \(userMessage.prefix(50))...")

        // Build a fresh, persistable run. The loop body + per-iteration
        // checkpointing + resume all live in UnifiedAgentRuntime+Resume.swift,
        // so fresh runs and resumed runs share ONE code path.
        var run = AgentCheckpoint(
            iterativeFor: userMessage,
            projectPath: projectPath,
            maxIterations: self.maxIterations
        )
        if let plan = currentPlan {
            run.plan = CheckpointPlan(plan)
        }
        activeRun = run
        activeCheckpointID = run.id
        persistActiveRun()

        return await runIterativeLoop()
    }

    // MARK: - One-Shot Mode (Plan → 1 action → verify → stop)

    private func processOneShot(_ userMessage: String) async -> ExecutionResult {
        reset()
        postUpdate { [self] in
            executionState = ExecutionState.analyzing
        }

        // 1) Request a structured plan
        let response = await callLLMForStructuredPlan(userMessage)
        guard let plan = parseStructuredResponse(response) else {
            postUpdate { [self] in
                executionState = ExecutionState.failed
            }
            return .failed("Failed to create a plan for the request.")
        }

        postUpdate { [self, plan] in
            currentIntent = plan.intent
            currentPlan = plan
            executionState = ExecutionState.planning
        }

        // 2) Require approval if configured
        if requirePlanApproval && !plan.actions.isEmpty {
            postUpdate { [self] in
                isWaitingForApproval = true
            }
            let approved = await waitForApproval()
            postUpdate { [self] in
                isWaitingForApproval = false
            }
            if !approved {
                postUpdate { [self] in
                    executionState = ExecutionState.cancelled
                }
                return .cancelled
            }
        }

        // 3) Execute the first mutating action only
        let actionTuple: (Int, ExecutableAction)?
        if let mutatingAction = firstMutatingAction(in: plan) {
            actionTuple = mutatingAction
        } else if let firstAction = plan.actions.first {
            actionTuple = (0, firstAction)
        } else {
            actionTuple = nil
        }

        guard let (actionIndex, action) = actionTuple else {
            postUpdate { [self] in
                executionState = ExecutionState.failed
            }
            return .failed("Plan contains no executable actions.")
        }

        postUpdate { [self, actionIndex] in
            executionState = ExecutionState.executing
            currentActionIndex = actionIndex
        }
        let result = await executeAction(action)
        postUpdate { [self, result] in
            actionResults.append(result)
        }

        // 4) Verify (lightweight): for file ops, check existence; for others, just summarize
        if (action.type == ExecutableAction.ActionType.createFile || action.type == ExecutableAction.ActionType.editFile),
           let path = action.parameters["path"] as? String {
            let fullPath = isRelativePath(path) && !projectPath.isEmpty ? "\(projectPath)/\(path)" : path
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
            let verification = ActionExecutionResult(
                action: ExecutableAction(
                    type: ExecutableAction.ActionType.observe,
                    tool: nil,
                    parameters: ["check": "filesystem", "path": path],
                    description: "Verify file exists",
                    stepIndex: action.stepIndex
                ),
                success: exists && !isDir.boolValue,
                output: exists ? "Verified file exists: \(path)" : "File not found: \(path)",
                error: exists ? nil : "Missing file after write",
                duration: 0.01,
                metadata: nil
            )
            postUpdate { [self, verification] in
                actionResults.append(verification)
            }
        }

        postUpdate { [self] in
            executionState = result.success ? .completed : .failed
        }
        return result.success ? .success("Executed one action successfully.") : .failed(result.error ?? "Action failed")
    }

    private func firstMutatingAction(in plan: ExecutionPlan) -> (Int, ExecutableAction)? {
        if let index = plan.actions.firstIndex(where: { $0.type == ExecutableAction.ActionType.createFile || $0.type == ExecutableAction.ActionType.editFile }) {
            return (index, plan.actions[index])
        }
        return nil
    }

    // MARK: - Legacy Batch Entry Point (kept for compatibility)

    /// Process using the old batch model (DEPRECATED - use process() instead)
    func processBatch(_ userMessage: String) async -> ExecutionResult {
        guard !isProcessing else {
            return .failed("A run is already in progress. Cancel it before starting another.")
        }
        isProcessing = true
        defer { isProcessing = false }
        reset()
        postUpdate { [self] in
            executionState = ExecutionState.analyzing
        }

        logger.info("Processing message (batch mode): \(userMessage.prefix(50))...")

        // Step 1: Get structured response from LLM
        let llmResponse = await callLLMForStructuredPlan(userMessage)

        // Step 2: Parse into ExecutionPlan
        guard let plan = parseStructuredResponse(llmResponse) else {
            postUpdate { [self] in
                executionState = ExecutionState.failed
            }
            logger.error("Failed to parse LLM response")
            return .failed("Failed to understand the request. Please try again.")
        }

        postUpdate { [self, plan] in
            currentIntent = plan.intent
            currentPlan = plan
            executionState = ExecutionState.planning
        }

        logger.info("Plan created: \(plan.planSteps.count) steps, \(plan.actions.count) actions")

        // Step 3: Optional approval gate
        if requirePlanApproval && !plan.actions.isEmpty {
            postUpdate { [self] in
                isWaitingForApproval = true
            }
            let approved = await waitForApproval()
            postUpdate { [self] in
                isWaitingForApproval = false
            }

            if !approved {
                postUpdate { [self] in
                    executionState = ExecutionState.cancelled
                }
                return .cancelled
            }
        }

        // Step 4: Execute plan
        postUpdate { [self] in
            executionState = ExecutionState.executing
        }
        return await executePlan(plan)
    }

    // MARK: - LLM Interaction (Iterative)

    /// Call LLM for the next single action (iterative mode)
    func callLLMForNextAction(_ prompt: String, history: [(role: String, content: String)]) async -> String {
        let provider = ProviderManager.shared.currentProvider

        // Use the iterative prompt that returns ONE action
        let systemPrompt = AgentPrompts.iterativeAgentPrompt(
            projectPath: projectPath,
            capabilities: AgentPrompts.capabilityList()
        )

        var settings = ModelSettings()
        settings.temperature = 0.3
        settings.topP = 0.9
        settings.maxTokens = 4096  // Needs room for file creation with code content
        settings.systemPrompt = systemPrompt

        // Build messages from history
        var messages: [ChatMessage] = []
        for (role, content) in history.suffix(10) {  // Keep last 10 turns for context
            switch role {
            case "user":
                messages.append(ChatMessage(role: .user, content: content))
            case "assistant":
                messages.append(ChatMessage(role: .assistant, content: content))
            case "system":
                // System results go as user messages (observation)
                messages.append(ChatMessage(role: .user, content: "[SYSTEM RESULT]\n\(content)"))
            default:
                break
            }
        }

        // Add current prompt if it's a continuation
        if !history.isEmpty && prompt != history.last?.content {
            messages.append(ChatMessage(role: .user, content: prompt))
        }

        do {
            var response = ""
            let stream = try await provider.sendMessage(
                messages: messages,
                settings: settings,
                stream: true
            )

            for try await chunk in stream {
                response += chunk
            }

            logger.info("LLM response for next action: \(response.prefix(200))...")
            return response
        } catch {
            logger.error("LLM call failed: \(error.localizedDescription)")
            return """
            {
                "thinking": "LLM API call failed",
                "next_action": {"type": "done", "parameters": {"summary": "API Error: \(error.localizedDescription). Check your API key in Settings and ensure your selected model is available."}},
                "message": "API Error: \(error.localizedDescription)"
            }
            """
        }
    }

    /// Parse a single-action iterative response
    func parseIterativeResponse(_ response: String) -> IterativeAgentResponse? {
        // Clean up the response
        var cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract JSON
        if let jsonStart = cleaned.firstIndex(of: "{"),
           let jsonEnd = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[jsonStart...jsonEnd])
        }

        // Repair truncated JSON
        cleaned = repairTruncatedJSON(cleaned)

        guard let data = cleaned.data(using: .utf8) else {
            logger.error("Failed to convert iterative response to data")
            return nil
        }

        do {
            let parsed = try JSONDecoder().decode(IterativeAgentResponseRaw.self, from: data)

            // Convert to our internal model
            let actionType = ExecutableAction.ActionType.from(string: parsed.nextAction.type)
            let action = ExecutableAction(
                type: actionType,
                tool: parsed.nextAction.tool,
                parameters: parsed.nextAction.parameters ?? [:],
                description: parsed.nextAction.description ?? "Execute \(parsed.nextAction.type)",
                stepIndex: currentActionIndex
            )

            return IterativeAgentResponse(
                thinking: parsed.thinking,
                nextAction: action,
                message: parsed.message
            )
        } catch {
            logger.error("Failed to parse iterative response: \(error)")
            logger.debug("Raw: \(cleaned.prefix(500))")

            // Try to extract action manually
            return attemptManualIterativeExtraction(from: response)
        }
    }

    /// Manual extraction for iterative response when JSON fails
    private func attemptManualIterativeExtraction(from response: String) -> IterativeAgentResponse? {
        // Look for "type": "xxx" pattern
        let typePattern = #""type"\s*:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: typePattern, options: []),
              let match = regex.firstMatch(in: response, options: [], range: NSRange(response.startIndex..., in: response)),
              let typeRange = Range(match.range(at: 1), in: response) else {
            return nil
        }

        let typeString = String(response[typeRange])
        let actionType = ExecutableAction.ActionType.from(string: typeString)

        // Check for "done"
        if actionType == .done {
            return IterativeAgentResponse(
                thinking: nil,
                nextAction: ExecutableAction(
                    type: .done,
                    tool: nil,
                    parameters: [:],
                    description: "Task complete",
                    stepIndex: currentActionIndex
                ),
                message: "Task completed"
            )
        }

        // Try to extract tool name
        var toolName: String? = nil
        let toolPattern = #""tool"\s*:\s*"([^"]+)""#
        if let toolRegex = try? NSRegularExpression(pattern: toolPattern, options: []),
           let toolMatch = toolRegex.firstMatch(in: response, options: [], range: NSRange(response.startIndex..., in: response)),
           let toolRange = Range(toolMatch.range(at: 1), in: response) {
            toolName = String(response[toolRange])
        }

        return IterativeAgentResponse(
            thinking: nil,
            nextAction: ExecutableAction(
                type: actionType,
                tool: toolName,
                parameters: [:],
                description: "Recovered: \(typeString)",
                stepIndex: currentActionIndex
            ),
            message: "Executing recovered action"
        )
    }

    // MARK: - LLM Interaction (Batch - Legacy)

    private func callLLMForStructuredPlan(_ message: String) async -> String {
        // Get the current provider
        let provider = ProviderManager.shared.currentProvider

        // Build system prompt that requests structured JSON output
        let systemPrompt = AgentPrompts.orchestratorPrompt(
            projectPath: projectPath,
            capabilities: AgentPrompts.capabilityList()
        )

        var settings = ModelSettings()
        settings.temperature = 0.3
        settings.topP = 0.9
        settings.maxTokens = 8192
        settings.systemPrompt = systemPrompt

        let messages = [
            ChatMessage(role: .user, content: message)
        ]

        do {
            var response = ""
            let stream = try await provider.sendMessage(
                messages: messages,
                settings: settings,
                stream: true
            )

            for try await chunk in stream {
                response += chunk
            }

            logger.info("LLM response received: \(response.count) chars")
            return response
        } catch {
            logger.error("LLM call failed: \(error.localizedDescription)")
            return """
            {
                "intent": "conversation",
                "plan": [],
                "actions": [],
                "message": "API Error: \(error.localizedDescription). Check your API key in Settings and ensure your selected model is available."
            }
            """
        }
    }

    // MARK: - Response Parsing

    private func parseStructuredResponse(_ response: String) -> ExecutionPlan? {
        // Strip markdown code blocks if present
        var cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to extract JSON from response if it contains other text
        if let jsonStart = cleaned.firstIndex(of: "{"),
           let jsonEnd = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[jsonStart...jsonEnd])
        }

        // RECOVERY: Try to fix truncated JSON
        cleaned = repairTruncatedJSON(cleaned)

        // Parse JSON
        guard let data = cleaned.data(using: .utf8) else {
            logger.error("Failed to convert response to data")
            return nil
        }

        do {
            let parsed = try JSONDecoder().decode(StructuredLLMResponse.self, from: data)
            let plan = ExecutionPlanBuilder.build(from: parsed)

            // VALIDATION: Don't accept empty plans from clearly structured responses
            if plan.actions.isEmpty && response.contains("\"actions\"") {
                logger.warning("Parser returned empty actions from a response that had actions - attempting recovery")
                if let recoveredPlan = attemptManualActionExtraction(from: response) {
                    return recoveredPlan
                }
            }

            return plan
        } catch {
            logger.error("JSON parsing failed: \(error.localizedDescription)")
            logger.debug("Raw response: \(cleaned.prefix(500))")

            // RECOVERY: Try manual extraction before giving up
            if let recoveredPlan = attemptManualActionExtraction(from: response) {
                logger.info("Recovered plan via manual extraction")
                return recoveredPlan
            }

            // Fallback: try XML-style parsing for backward compatibility
            return parseXMLFallback(response)
        }
    }

    /// Attempt to repair truncated JSON (missing closing braces, truncated strings)
    private func repairTruncatedJSON(_ json: String) -> String {
        var repaired = json

        // Count braces
        let openBraces = repaired.filter { $0 == "{" }.count
        let closeBraces = repaired.filter { $0 == "}" }.count
        let openBrackets = repaired.filter { $0 == "[" }.count
        let closeBrackets = repaired.filter { $0 == "]" }.count

        // Check for truncated string (odd number of quotes after last complete value)
        if let lastQuote = repaired.lastIndex(of: "\"") {
            let afterQuote = repaired[lastQuote...].dropFirst()
            // If string was truncated mid-value, close it
            if !afterQuote.contains("\"") && !afterQuote.contains("}") && !afterQuote.contains("]") {
                // Truncated in the middle of a string value
                repaired += "\""
                logger.info("Repaired truncated string")
            }
        }

        // Add missing closing brackets
        let missingBrackets = openBrackets - closeBrackets
        if missingBrackets > 0 {
            repaired += String(repeating: "]", count: missingBrackets)
            logger.info("Added \(missingBrackets) missing ]")
        }

        // Add missing closing braces
        let missingBraces = openBraces - closeBraces
        if missingBraces > 0 {
            repaired += String(repeating: "}", count: missingBraces)
            logger.info("Added \(missingBraces) missing }")
        }

        return repaired
    }

    /// Manual extraction of actions when JSON parsing fails
    private func attemptManualActionExtraction(from response: String) -> ExecutionPlan? {
        // Look for action patterns even in malformed JSON
        var actions: [ExecutableAction] = []
        var stepIndex = 0

        // Pattern: "type": "tool_call", "tool": "xxx"
        let toolCallPattern = #""type"\s*:\s*"tool_call"\s*,\s*"tool"\s*:\s*"([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: toolCallPattern, options: []) {
            let range = NSRange(response.startIndex..., in: response)
            let matches = regex.matches(in: response, options: [], range: range)

            for match in matches {
                if let toolRange = Range(match.range(at: 1), in: response) {
                    let toolName = String(response[toolRange])
                    actions.append(ExecutableAction(
                        type: .toolCall,
                        tool: toolName,
                        parameters: [:],
                        description: "Call \(toolName)",
                        stepIndex: stepIndex
                    ))
                    stepIndex += 1
                }
            }
        }

        // Pattern: "type": "create_file"
        let createFilePattern = #""type"\s*:\s*"create_file""#
        if let regex = try? NSRegularExpression(pattern: createFilePattern, options: []) {
            let range = NSRange(response.startIndex..., in: response)
            let matches = regex.matches(in: response, options: [], range: range)

            for _ in matches {
                actions.append(ExecutableAction(
                    type: .createFile,
                    tool: nil,
                    parameters: [:],
                    description: "Create file",
                    stepIndex: stepIndex
                ))
                stepIndex += 1
            }
        }

        guard !actions.isEmpty else { return nil }

        logger.info("Manually extracted \(actions.count) actions from malformed response")

        let intent = AgentIntent(
            type: .coding,
            description: "Recovered plan",
            confidence: 0.6,
            rawMessage: response
        )

        let steps = actions.enumerated().map { index, action in
            PlanStep(
                index: index,
                description: action.description,
                actionIndices: [index]
            )
        }

        return ExecutionPlan(
            intent: intent,
            planSteps: steps,
            actions: actions,
            summary: "Recovered \(actions.count) actions",
            estimatedDuration: nil
        )
    }

    private func parseXMLFallback(_ response: String) -> ExecutionPlan? {
        // Check for tool_use tags (old format)
        if let toolRange = response.range(of: "<tool_use>"),
           let endTool = response.range(of: "</tool_use>") {
            let toolJson = String(response[toolRange.upperBound..<endTool.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let data = toolJson.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let toolName = json["tool"] as? String,
               let args = json["arguments"] as? [String: Any] {

                // Create a simple single-action plan
                let intent = AgentIntent(
                    type: .coding,
                    description: "Executing tool: \(toolName)",
                    confidence: 0.8,
                    rawMessage: response
                )

                let action = ExecutableAction(
                    type: .toolCall,
                    tool: toolName,
                    parameters: args,
                    description: "Call \(toolName)",
                    stepIndex: 0
                )

                let step = PlanStep(
                    index: 0,
                    description: "Execute \(toolName)",
                    actionIndices: [0]
                )

                return ExecutionPlan(
                    intent: intent,
                    planSteps: [step],
                    actions: [action],
                    summary: "Single tool execution",
                    estimatedDuration: nil
                )
            }
        }

        // If no structured content, create a conversation-only plan
        let cleanResponse = response
            .replacingOccurrences(of: "<thinking>", with: "")
            .replacingOccurrences(of: "</thinking>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !cleanResponse.isEmpty {
            let intent = AgentIntent(
                type: .conversation,
                description: "Conversational response",
                confidence: 0.7,
                rawMessage: cleanResponse
            )

            return ExecutionPlan(
                intent: intent,
                planSteps: [],
                actions: [],
                summary: cleanResponse,
                estimatedDuration: nil
            )
        }

        return nil
    }

    // MARK: - Plan Execution

    private func executePlan(_ plan: ExecutionPlan) async -> ExecutionResult {
        var mutablePlan = plan

        // CRITICAL: Reorder actions to ensure proper sequencing
        // File creation MUST happen before builds/commands that depend on them
        let orderedActions = enforceActionOrdering(plan.actions)

        for (index, action) in orderedActions.enumerated() {
            // Update state (thread-safe)
            postUpdate { [self] in
                currentActionIndex = index
            }
            updateStepStatus(in: &mutablePlan, forActionIndex: index, status: .inProgress)
            postUpdate { [self, mutablePlan] in
                currentPlan = mutablePlan
            }

            logger.info("Executing action \(index + 1)/\(orderedActions.count): \(action.displaySummary)")

            // Execute the action
            let result = await executeAction(action)
            postUpdate { [self, result] in
                actionResults.append(result)
            }

            // Check result
            if result.success {
                updateStepStatus(in: &mutablePlan, forActionIndex: index, status: .completed)
                postUpdate { [self, mutablePlan] in
                    currentPlan = mutablePlan
                }
                logger.info("Action succeeded: \(action.displaySummary)")
            } else {
                logger.warning("Action failed: \(result.error ?? "unknown error")")

                // Attempt recovery
                if let recovery = await attemptRecovery(action: action, error: result.error) {
                    postUpdate { [self, recovery] in
                        actionResults.append(recovery)
                    }

                    if recovery.success {
                        updateStepStatus(in: &mutablePlan, forActionIndex: index, status: .completed)
                        postUpdate { [self, mutablePlan] in
                            currentPlan = mutablePlan
                        }
                    } else {
                        updateStepStatus(in: &mutablePlan, forActionIndex: index, status: .failed)
                        postUpdate { [self, mutablePlan] in
                            currentPlan = mutablePlan
                            executionState = ExecutionState.failed
                        }
                        return .failed(result.error ?? "Action failed")
                    }
                } else {
                    updateStepStatus(in: &mutablePlan, forActionIndex: index, status: .failed)
                    postUpdate { [self, mutablePlan] in
                        currentPlan = mutablePlan
                        executionState = ExecutionState.failed
                    }
                    return .failed(result.error ?? "Action failed")
                }
            }

            // Check for user questions
            if action.type == ExecutableAction.ActionType.askUser {
                postUpdate { [self, action] in
                    pendingQuestion = action.parameters["question"] as? String
                }
                return .askingUser(pendingQuestion ?? "")
            }
        }

        postUpdate { [self] in
            executionState = ExecutionState.completed
        }
        return .success(plan.summary)
    }

    // MARK: - Action Ordering

    /// Enforce proper action ordering to prevent "build before project exists" errors
    /// Rules:
    /// 1. create_file actions MUST come before any build/run_command actions
    /// 2. project_init/scaffold actions MUST come first
    /// 3. build actions MUST come last
    private func enforceActionOrdering(_ actions: [ExecutableAction]) -> [ExecutableAction] {
        guard actions.count > 1 else { return actions }

        // Categorize actions by priority
        var scaffoldActions: [ExecutableAction] = []   // Priority 1: project init
        var createActions: [ExecutableAction] = []     // Priority 2: file creation
        var editActions: [ExecutableAction] = []       // Priority 3: file edits
        var otherActions: [ExecutableAction] = []      // Priority 4: other tools
        var buildActions: [ExecutableAction] = []      // Priority 5: builds (last)
        var commandActions: [ExecutableAction] = []    // Priority 5: commands (last)

        for action in actions {
            switch action.type {
            case ExecutableAction.ActionType.createFile:
                createActions.append(action)

            case ExecutableAction.ActionType.editFile:
                editActions.append(action)

            case ExecutableAction.ActionType.toolCall:
                let toolName = action.tool ?? ""
                if toolName.contains("build") || toolName.contains("xcodebuild") {
                    buildActions.append(action)
                } else if toolName.contains("scaffold") || toolName.contains("init") || toolName.contains("setup") {
                    scaffoldActions.append(action)
                } else {
                    otherActions.append(action)
                }

            case ExecutableAction.ActionType.runCommand:
                let command = (action.parameters["command"] as? String) ?? ""
                if command.contains("xcodebuild") || command.contains("swift build") {
                    buildActions.append(action)
                } else if command.contains("mkdir") || command.contains("init") {
                    scaffoldActions.append(action)
                } else {
                    commandActions.append(action)
                }

            default:
                otherActions.append(action)
            }
        }

        // Combine in correct order
        let ordered = scaffoldActions + createActions + editActions + otherActions + commandActions + buildActions

        // Log if we reordered
        if ordered.map({ $0.description }) != actions.map({ $0.description }) {
            logger.info("Reordered actions for correct sequencing: scaffold(\(scaffoldActions.count)) → create(\(createActions.count)) → edit(\(editActions.count)) → other(\(otherActions.count)) → cmd(\(commandActions.count)) → build(\(buildActions.count))")
        }

        return ordered
    }

    private func updateStepStatus(in plan: inout ExecutionPlan, forActionIndex actionIndex: Int, status: PlanStep.StepStatus) {
        for i in 0..<plan.planSteps.count {
            if plan.planSteps[i].actionIndices.contains(actionIndex) {
                plan.planSteps[i].status = status
                break
            }
        }
    }

    // MARK: - Action Execution

    func executeAction(_ action: ExecutableAction) async -> ActionExecutionResult {
        let startTime = Date()

        let toolResult: ToolResult

        switch action.type {
        case ExecutableAction.ActionType.toolCall:
            guard let toolName = action.tool else {
                toolResult = ToolResult(success: false, output: "", error: "No tool specified")
                break
            }

            // Project-path guard: block project tools when path is invalid
            if enforceProjectPathForProjectTools,
               isProjectTool(toolName),
               !isProjectPathValid(projectPath) {
                toolResult = ToolResult(
                    success: false,
                    output: "",
                    error: missingProjectPathError()
                )
                break
            }

            do {
                var r = try await toolRegistry.executeWithRuntime(
                    toolName: toolName,
                    arguments: action.parameters,
                    projectPath: projectPath
                )
                // Auto-install dependencies and retry build if enabled
                if autoInstallDependencies && toolName == "run_build" && !r.success {
                    let install = try await toolRegistry.executeWithRuntime(toolName: "install_dependencies", arguments: [:], projectPath: projectPath)
                    postUpdate { [self] in
                        actionResults.append(ActionExecutionResult(
                            action: ExecutableAction(type: .toolCall, tool: "install_dependencies", parameters: [:], description: "Install dependencies", stepIndex: action.stepIndex),
                            success: install.success,
                            output: install.output,
                            error: install.error,
                            duration: 0,
                            metadata: install.metadata
                        ))
                    }

                    if install.success {
                        r = try await toolRegistry.executeWithRuntime(
                            toolName: toolName,
                            arguments: action.parameters,
                            projectPath: projectPath
                        )
                    }
                }
                toolResult = r
            } catch {
                toolResult = ToolResult(success: false, output: "", error: error.localizedDescription)
            }

        case ExecutableAction.ActionType.createFile:
            guard let path = action.parameters["path"] as? String,
                  let content = action.parameters["content"] as? String else {
                toolResult = ToolResult(success: false, output: "", error: "Missing path or content")
                break
            }

            if enforceProjectPathForProjectTools,
               isRelativePath(path),
               !isProjectPathValid(projectPath) {
                toolResult = ToolResult(success: false, output: "", error: missingProjectPathError())
                break
            }

            do {
                toolResult = try await toolRegistry.executeWithRuntime(
                    toolName: "write_file",
                    arguments: ["path": path, "content": content, "overwrite": true],
                    projectPath: projectPath
                )
            } catch {
                toolResult = ToolResult(success: false, output: "", error: error.localizedDescription)
            }

        case ExecutableAction.ActionType.editFile:
            guard let path = action.parameters["path"] as? String,
                  let oldText = action.parameters["old_text"] as? String,
                  let newText = action.parameters["new_text"] as? String else {
                toolResult = ToolResult(success: false, output: "", error: "Missing edit parameters")
                break
            }

            if enforceProjectPathForProjectTools,
               isRelativePath(path),
               !isProjectPathValid(projectPath) {
                toolResult = ToolResult(success: false, output: "", error: missingProjectPathError())
                break
            }

            do {
                toolResult = try await toolRegistry.executeWithRuntime(
                    toolName: "edit_file",
                    arguments: ["path": path, "old_text": oldText, "new_text": newText],
                    projectPath: projectPath
                )
            } catch {
                toolResult = ToolResult(success: false, output: "", error: error.localizedDescription)
            }

        case ExecutableAction.ActionType.runCommand:
            guard let command = action.parameters["command"] as? String else {
                toolResult = ToolResult(success: false, output: "", error: "Missing command")
                break
            }

            if enforceProjectPathForProjectTools,
               isBuildCommand(command),
               !isProjectPathValid(projectPath) {
                toolResult = ToolResult(success: false, output: "", error: missingProjectPathError())
                break
            }

            do {
                toolResult = try await toolRegistry.executeWithRuntime(
                    toolName: "run_command",
                    arguments: ["command": command],
                    projectPath: projectPath
                )
            } catch {
                toolResult = ToolResult(success: false, output: "", error: error.localizedDescription)
            }

        case ExecutableAction.ActionType.desktopAction:
            let actionType = action.parameters["action"] as? String ?? "unknown"

            do {
                // Route to appropriate desktop tool
                let toolName: String
                switch actionType {
                case "click", "move", "type", "key", "scroll":
                    toolName = "input_control"
                case "open_app", "applescript":
                    toolName = "applescript"
                case "window":
                    toolName = "window_management"
                default:
                    toolName = "input_control"
                }

                toolResult = try await toolRegistry.executeWithRuntime(
                    toolName: toolName,
                    arguments: action.parameters,
                    projectPath: projectPath
                )
            } catch {
                toolResult = ToolResult(success: false, output: "", error: error.localizedDescription)
            }

        case ExecutableAction.ActionType.wait:
            let seconds = action.parameters["seconds"] as? Double ?? 1.0
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            toolResult = ToolResult(success: true, output: "Waited \(seconds) seconds")

        case ExecutableAction.ActionType.askUser:
            // This is handled specially in executePlan
            toolResult = ToolResult(success: true, output: "Asking user...")

        case ExecutableAction.ActionType.observe:
            // Check state before acting - this is crucial for the iterative loop
            let check = action.parameters["check"] as? String ?? "filesystem"
            let path = action.parameters["path"] as? String

            switch check {
            case "filesystem":
                // Check if files/directories exist
                if let path = path {
                    let fullPath = projectPath.isEmpty ? path : "\(projectPath)/\(path)"
                    let exists = FileManager.default.fileExists(atPath: fullPath)
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)

                    if exists {
                        if isDir.boolValue {
                            // List directory contents
                            if let contents = try? FileManager.default.contentsOfDirectory(atPath: fullPath) {
                                toolResult = ToolResult(success: true, output: "Directory exists: \(path)\nContents:\n\(contents.joined(separator: "\n"))")
                            } else {
                                toolResult = ToolResult(success: true, output: "Directory exists: \(path)")
                            }
                        } else {
                            toolResult = ToolResult(success: true, output: "File exists: \(path)")
                        }
                    } else {
                        toolResult = ToolResult(success: true, output: "Path does not exist: \(path)")
                    }
                } else {
                    // General filesystem check - list project root
                    if !projectPath.isEmpty,
                       let contents = try? FileManager.default.contentsOfDirectory(atPath: projectPath) {
                        toolResult = ToolResult(success: true, output: "Project root contents:\n\(contents.joined(separator: "\n"))")
                    } else {
                        toolResult = ToolResult(success: true, output: "Project path: \(projectPath.isEmpty ? "Not set" : projectPath)")
                    }
                }

            case "project_structure":
                // Get project structure
                if enforceProjectPathForProjectTools, !isProjectPathValid(projectPath) {
                    toolResult = ToolResult(success: false, output: "", error: missingProjectPathError())
                    break
                }
                do {
                    let result = try await toolRegistry.executeWithRuntime(
                        toolName: "get_project_structure",
                        arguments: [:],
                        projectPath: projectPath
                    )
                    toolResult = result
                } catch {
                    toolResult = ToolResult(success: false, output: "", error: error.localizedDescription)
                }

            case "build_output":
                // Get last build output - check if there are pending errors
                if runtimeService.hasPendingErrors {
                    toolResult = ToolResult(success: true, output: "Build has errors. Use run_build to see details.")
                } else {
                    toolResult = ToolResult(success: true, output: "No pending build errors.")
                }

            default:
                toolResult = ToolResult(success: true, output: "Unknown check type: \(check)")
            }

        case ExecutableAction.ActionType.done:
            // Signal task completion - this is returned in executeAction but handled specially in the loop
            let summary = action.parameters["summary"] as? String ?? "Task completed"
            let artifacts = action.parameters["artifacts"] as? [String] ?? []
            toolResult = ToolResult(
                success: true,
                output: "DONE: \(summary)\nArtifacts: \(artifacts.joined(separator: ", "))"
            )
        }

        let duration = Date().timeIntervalSince(startTime)

        let base = ActionExecutionResult(
            action: action,
            success: toolResult.success,
            output: toolResult.output,
            error: toolResult.error,
            duration: duration,
            metadata: toolResult.metadata
        )

        // After file writes/edits, optionally run tests automatically
        if runTestsAfterWrite && (action.type == ExecutableAction.ActionType.createFile || action.type == ExecutableAction.ActionType.editFile) {
            do {
                let testResult = try await toolRegistry.executeWithRuntime(toolName: "run_tests", arguments: [:], projectPath: projectPath)
                let testAction = ExecutableAction(type: .toolCall, tool: "run_tests", parameters: [:], description: "Run tests", stepIndex: action.stepIndex)
                let testExec = ActionExecutionResult(action: testAction, success: testResult.success, output: testResult.output, error: testResult.error, duration: 0, metadata: testResult.metadata)
                postUpdate { [self, testExec] in
                    actionResults.append(testExec)
                }
            } catch {
                // Append a synthetic failure result
                let testAction = ExecutableAction(type: .toolCall, tool: "run_tests", parameters: [:], description: "Run tests", stepIndex: action.stepIndex)
                let testExec = ActionExecutionResult(action: testAction, success: false, output: "", error: error.localizedDescription, duration: 0, metadata: nil)
                postUpdate { [self, testExec] in
                    actionResults.append(testExec)
                }
            }
        }

        return base
    }

    // MARK: - Guards

    private func isProjectPathValid(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: path) {
            return contents.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") })
        }
        return false
    }

    private func isRelativePath(_ path: String) -> Bool {
        // Treat paths starting with "/" or "~" as absolute
        !(path.hasPrefix("/") || path.hasPrefix("~"))
    }

    private func isBuildCommand(_ command: String) -> Bool {
        let cmd = command.lowercased()
        return cmd.contains("xcodebuild") || cmd.contains("swift build")
    }

    private func isProjectTool(_ tool: String) -> Bool {
        let name = tool.lowercased()
        // Tools that operate on the project filesystem or build
        return name.contains("build") ||
               name.contains("run_tests") ||
               name.contains("list_files") ||
               name.contains("get_project_structure") ||
               name.contains("find_projects") ||
               name.contains("write_file") ||
               name.contains("edit_file")
    }

    private func missingProjectPathError() -> String {
        "Project path not set or invalid. Set it in Settings → Agent → Project Path (e.g., /Volumes/Untitled 1/FloatingChatApp)."
    }

    // MARK: - Recovery

    private func attemptRecovery(action: ExecutableAction, error: String?) async -> ActionExecutionResult? {
        // If this was a build that failed, trigger auto-retry loop
        if action.tool == "run_build" && runtimeService.hasPendingErrors {
            guard let retryPrompt = runtimeService.getRetryPrompt() else {
                logger.info("No retry prompt available or max retries exceeded")
                return nil
            }

            logger.info("Attempting auto-retry: attempt \(self.runtimeService.currentRetryAttempt)")
            postUpdate { [self] in
                isRetrying = true
                retryAttempt = self.runtimeService.currentRetryAttempt
            }

            // Call LLM with retry prompt to get fix actions
            let fixResponse = await callLLMForStructuredPlan(retryPrompt)
            guard let fixPlan = parseStructuredResponse(fixResponse) else {
                logger.error("Failed to parse retry response")
                postUpdate { [self] in
                    isRetrying = false
                }
                return nil
            }

            // Execute the fix actions
            for fixAction in fixPlan.actions {
                let fixResult = await executeAction(fixAction)
                postUpdate { [self, fixResult] in
                    actionResults.append(fixResult)
                }

                if !fixResult.success {
                    logger.warning("Fix action failed: \(fixResult.error ?? "unknown")")
                    postUpdate { [self] in
                        isRetrying = false
                    }
                    // Don't return failure here - let the retry loop continue
                }
            }

            // Re-run the build to see if fix worked
            let rebuildAction = ExecutableAction(
                type: .toolCall,
                tool: "run_build",
                parameters: action.parameters,
                description: "Retry build after fix",
                stepIndex: action.stepIndex
            )

            let rebuildResult = await executeAction(rebuildAction)
            postUpdate { [self] in
                isRetrying = false
            }

            if rebuildResult.success {
                logger.info("Retry build succeeded!")
                return rebuildResult
            } else {
                // Recurse for another retry attempt
                return await attemptRecovery(action: rebuildAction, error: rebuildResult.error)
            }
        }

        // For other failures, no recovery implemented yet
        return nil
    }

    // MARK: - User Interaction

    private func waitForApproval() async -> Bool {
        return await withCheckedContinuation { continuation in
            approvalContinuation = continuation
        }
    }

    /// Called by UI when user approves the plan
    func approvePlan() {
        approvalContinuation?.resume(returning: true)
        approvalContinuation = nil
    }

    /// Called by UI when user rejects the plan
    func rejectPlan() {
        approvalContinuation?.resume(returning: false)
        approvalContinuation = nil
    }

    /// Submit answer to a pending question
    func submitAnswer(_ answer: String) {
        pendingQuestion = nil
        // The answer would be processed in the next iteration
    }

    // MARK: - Control

    func cancel() {
        cancelRequested = true
        executionState = ExecutionState.cancelled
        approvalContinuation?.resume(returning: false)
        approvalContinuation = nil
        // Mark the run cancelled on disk so it isn't offered as "resumable".
        if activeRun != nil {
            activeRun!.status = .cancelled
            activeRun!.executionState = ExecutionStateCodec.string(.cancelled)
            persistActiveRun()
        }
    }

    func reset() {
        currentIntent = nil
        currentPlan = nil
        executionState = ExecutionState.idle
        currentActionIndex = 0
        actionResults = []
        isWaitingForApproval = false
        pendingQuestion = nil
        retryAttempt = 0
        isRetrying = false
        activeRun = nil
        activeCheckpointID = nil
        cancelRequested = false
        lastCheckpointError = nil
    }

    // MARK: - Convenience

    /// Get a summary of the current execution for display
    var executionSummary: String {
        guard let plan = currentPlan else { return "No active plan" }

        let completed = actionResults.filter { $0.success }.count
        let failed = actionResults.filter { !$0.success }.count
        let total = plan.actions.count

        switch executionState {
        case .idle:
            return "Ready"
        case .analyzing:
            return "Analyzing request..."
        case .planning:
            return "Plan: \(plan.planSteps.count) steps"
        case .executing:
            return "Executing: \(completed)/\(total) actions"
        case .completed:
            return "Completed: \(completed) actions"
        case .failed:
            return "Failed: \(failed) error(s)"
        case .cancelled:
            return "Cancelled"
        }
    }

    /// Total duration of all executed actions
    var totalDuration: TimeInterval {
        actionResults.reduce(0) { $0 + $1.duration }
    }
}

// ExecutionState is defined in AgentOrchestrator.swift
