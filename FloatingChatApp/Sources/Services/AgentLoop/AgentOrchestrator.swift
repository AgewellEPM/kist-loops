import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.floatingchat.app", category: "Orchestrator")

/// The Agent Orchestrator - the "soul" that makes this a real agent, not a chat app.
///
/// Architecture:
/// ```
/// ┌────────────────────────────┐
/// │        Chat UI             │  ← text / voice / tiles
/// └──────────▲─────────────────┘
///            │
/// ┌──────────┴─────────────────┐
/// │     Agent Orchestrator     │  ← planning, memory, intent  ← YOU ARE HERE
/// └──────────▲─────────────────┘
///            │
/// ┌──────────┴─────────────────┐
/// │   Capability Backends      │  ← code, files, OS, vision
/// └────────────────────────────┘
/// ```
///
/// The key insight: AI outputs ACTIONS, not text. This executes them.
@MainActor
final class AgentOrchestrator: ObservableObject {
    static let shared = AgentOrchestrator()

    // MARK: - Published State

    @Published var currentIntent: AgentIntent?
    @Published var currentPlan: AgentPlan?
    @Published var executionState: ExecutionState = .idle
    @Published var actionHistory: [ExecutedAction] = []

    // MARK: - Capabilities

    private let codingCapability = CodingCapability()
    private let desktopCapability = DesktopCapability()
    private let visionCapability = VisionCapability()

    // MARK: - Configuration

    var projectPath: String = ""
    var maxPlanSteps: Int = 20
    var autoExecute: Bool = true

    private init() {}

    // MARK: - Main Entry Point

    /// Process user input through the full agent loop
    /// intent → plan → execute → observe → adjust → continue
    func process(_ userMessage: String) async -> AgentResponse {
        executionState = .planning

        // Step 1: Determine intent
        let intent = await classifyIntent(userMessage)
        currentIntent = intent
        logger.info("Intent: \(intent.type.rawValue) - \(intent.description)")

        // Step 2: Create plan
        let plan = await createPlan(for: intent, message: userMessage)
        currentPlan = plan
        logger.info("Plan created with \(plan.steps.count) steps")

        // Step 3: Execute plan (the loop)
        executionState = .executing
        var response = AgentResponse(intent: intent, plan: plan)

        for (index, step) in plan.steps.enumerated() {
            // Check for cancellation
            if executionState == .cancelled {
                response.status = .cancelled
                break
            }

            currentPlan?.currentStepIndex = index
            logger.info("Executing step \(index + 1)/\(plan.steps.count): \(step.description)")

            // Execute the step's actions
            for action in step.actions {
                let result = await executeAction(action)
                response.executedActions.append(result)
                actionHistory.append(result)

                // Step 4: Observe result
                if !result.success {
                    logger.warning("Action failed: \(result.error ?? "unknown")")

                    // Step 5: Adjust - try to recover or abort
                    if let recovery = await attemptRecovery(from: result, step: step) {
                        response.executedActions.append(recovery)
                        if !recovery.success {
                            response.status = .failed
                            response.error = "Recovery failed: \(recovery.error ?? "unknown")"
                            executionState = .failed
                            return response
                        }
                    } else {
                        response.status = .failed
                        response.error = result.error
                        executionState = .failed
                        return response
                    }
                }
            }

            currentPlan?.completedSteps.insert(index)
        }

        // Step 6: Final result
        response.status = .completed
        executionState = .completed
        logger.info("Plan completed successfully")

        return response
    }

    // MARK: - Intent Classification

    private func classifyIntent(_ message: String) async -> AgentIntent {
        let lowered = message.lowercased()

        // Simple keyword-based classification (can be upgraded to LLM later)
        if lowered.contains("build") || lowered.contains("create app") ||
           lowered.contains("write code") || lowered.contains("implement") ||
           lowered.contains("add feature") || lowered.contains("fix bug") {
            return AgentIntent(
                type: .coding,
                description: "Code/build task detected",
                confidence: 0.9,
                rawMessage: message
            )
        }

        if lowered.contains("open") || lowered.contains("click") ||
           lowered.contains("type") || lowered.contains("press") ||
           lowered.contains("window") || lowered.contains("move") {
            return AgentIntent(
                type: .desktopControl,
                description: "Desktop control task detected",
                confidence: 0.9,
                rawMessage: message
            )
        }

        if lowered.contains("volume") || lowered.contains("brightness") ||
           lowered.contains("wifi") || lowered.contains("bluetooth") {
            return AgentIntent(
                type: .systemControl,
                description: "System control task detected",
                confidence: 0.9,
                rawMessage: message
            )
        }

        if lowered.contains("search") || lowered.contains("find") ||
           lowered.contains("look up") || lowered.contains("google") {
            return AgentIntent(
                type: .search,
                description: "Search task detected",
                confidence: 0.8,
                rawMessage: message
            )
        }

        if lowered.contains("screenshot") || lowered.contains("what's on screen") ||
           lowered.contains("read this") || lowered.contains("ocr") {
            return AgentIntent(
                type: .vision,
                description: "Vision task detected",
                confidence: 0.85,
                rawMessage: message
            )
        }

        // Default to coding for ambiguous requests
        return AgentIntent(
            type: .coding,
            description: "General task (defaulting to coding)",
            confidence: 0.5,
            rawMessage: message
        )
    }

    // MARK: - Plan Creation

    private func createPlan(for intent: AgentIntent, message: String) async -> AgentPlan {
        switch intent.type {
        case .coding:
            return await codingCapability.createPlan(for: message, projectPath: projectPath)
        case .desktopControl:
            return await desktopCapability.createPlan(for: message)
        case .systemControl:
            return await desktopCapability.createSystemControlPlan(for: message)
        case .vision:
            return await visionCapability.createPlan(for: message)
        case .search:
            return createSearchPlan(for: message)
        case .conversation:
            return AgentPlan(steps: [], description: "Conversational response")
        }
    }

    private func createSearchPlan(for message: String) -> AgentPlan {
        let searchAction = AgentAction(
            type: .toolCall,
            tool: "web_search",
            parameters: ["query": message]
        )
        let step = AgentPlanStep(
            description: "Search the web",
            actions: [searchAction],
            expectedOutcome: "Search results"
        )
        return AgentPlan(steps: [step], description: "Web search")
    }

    // MARK: - Action Execution

    private func executeAction(_ action: AgentAction) async -> ExecutedAction {
        let startTime = Date()

        switch action.type {
        case .toolCall:
            let result = await executeToolCall(action)
            return ExecutedAction(
                action: action,
                result: result,
                duration: Date().timeIntervalSince(startTime),
                success: result.success
            )

        case .createFile:
            guard let path = action.parameters["path"] as? String,
                  let content = action.parameters["content"] as? String else {
                return ExecutedAction(
                    action: action,
                    result: ToolResult(success: false, output: "", error: "Missing path or content"),
                    duration: Date().timeIntervalSince(startTime),
                    success: false
                )
            }
            let result = await codingCapability.createFile(path: path, content: content, projectPath: projectPath)
            return ExecutedAction(action: action, result: result, duration: Date().timeIntervalSince(startTime), success: result.success)

        case .editFile:
            guard let path = action.parameters["path"] as? String,
                  let oldText = action.parameters["old_text"] as? String,
                  let newText = action.parameters["new_text"] as? String else {
                return ExecutedAction(
                    action: action,
                    result: ToolResult(success: false, output: "", error: "Missing edit parameters"),
                    duration: Date().timeIntervalSince(startTime),
                    success: false
                )
            }
            let result = await codingCapability.editFile(path: path, oldText: oldText, newText: newText, projectPath: projectPath)
            return ExecutedAction(action: action, result: result, duration: Date().timeIntervalSince(startTime), success: result.success)

        case .runCommand:
            guard let command = action.parameters["command"] as? String else {
                return ExecutedAction(
                    action: action,
                    result: ToolResult(success: false, output: "", error: "Missing command"),
                    duration: Date().timeIntervalSince(startTime),
                    success: false
                )
            }
            let result = await codingCapability.runCommand(command, projectPath: projectPath)
            return ExecutedAction(action: action, result: result, duration: Date().timeIntervalSince(startTime), success: result.success)

        case .desktopAction:
            let result = await desktopCapability.executeAction(action)
            return ExecutedAction(action: action, result: result, duration: Date().timeIntervalSince(startTime), success: result.success)

        case .wait:
            let seconds = action.parameters["seconds"] as? Double ?? 1.0
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return ExecutedAction(
                action: action,
                result: ToolResult(success: true, output: "Waited \(seconds)s"),
                duration: seconds,
                success: true
            )
        }
    }

    private func executeToolCall(_ action: AgentAction) async -> ToolResult {
        guard let toolName = action.tool else {
            return ToolResult(success: false, output: "", error: "No tool specified")
        }

        do {
            return try await ToolRegistry.shared.executeWithRuntime(
                toolName: toolName,
                arguments: action.parameters,
                projectPath: projectPath
            )
        } catch {
            return ToolResult(success: false, output: "", error: error.localizedDescription)
        }
    }

    // MARK: - Recovery

    private func attemptRecovery(from failure: ExecutedAction, step: AgentPlanStep) async -> ExecutedAction? {
        // If it's a build error, try to fix it
        if failure.action.tool == "run_build" {
            if AgentRuntimeService.shared.hasPendingErrors,
               let _ = AgentRuntimeService.shared.getRetryPrompt() {
                // Auto-retry is handled by AgentRuntimeService
                return nil
            }
        }

        // For other failures, no automatic recovery yet
        return nil
    }

    // MARK: - Control

    func cancel() {
        executionState = .cancelled
    }

    func reset() {
        currentIntent = nil
        currentPlan = nil
        executionState = .idle
        actionHistory = []
    }
}

// MARK: - Data Models

struct AgentIntent: Identifiable {
    let id = UUID()
    let type: IntentType
    let description: String
    let confidence: Double
    let rawMessage: String

    enum IntentType: String, Codable {
        case coding = "coding"
        case desktopControl = "desktop_control"
        case systemControl = "system_control"
        case search = "search"
        case vision = "vision"
        case conversation = "conversation"
    }
}

struct AgentPlan: Identifiable {
    let id = UUID()
    var steps: [AgentPlanStep]
    let description: String
    var currentStepIndex: Int = 0
    var completedSteps: Set<Int> = []

    var progress: Double {
        guard !steps.isEmpty else { return 1.0 }
        return Double(completedSteps.count) / Double(steps.count)
    }
}

struct AgentPlanStep: Identifiable {
    let id = UUID()
    let description: String
    let actions: [AgentAction]
    let expectedOutcome: String
}

struct AgentAction: Identifiable {
    let id = UUID()
    let type: ActionType
    var tool: String?
    var parameters: [String: Any]

    enum ActionType: String, Codable {
        case toolCall = "tool_call"
        case createFile = "create_file"
        case editFile = "edit_file"
        case runCommand = "run_command"
        case desktopAction = "desktop_action"
        case wait = "wait"
    }

    // For display
    var summary: String {
        switch type {
        case .toolCall:
            return "Call \(tool ?? "unknown")"
        case .createFile:
            return "Create \(parameters["path"] as? String ?? "file")"
        case .editFile:
            return "Edit \(parameters["path"] as? String ?? "file")"
        case .runCommand:
            return "Run: \(parameters["command"] as? String ?? "command")"
        case .desktopAction:
            return "Desktop: \(parameters["action"] as? String ?? "action")"
        case .wait:
            return "Wait \(parameters["seconds"] as? Double ?? 1)s"
        }
    }
}

struct ExecutedAction: Identifiable {
    let id = UUID()
    let action: AgentAction
    let result: ToolResult
    let duration: TimeInterval
    let success: Bool
    let timestamp = Date()

    var error: String? {
        result.error
    }
}

struct AgentResponse {
    let intent: AgentIntent
    let plan: AgentPlan
    var executedActions: [ExecutedAction] = []
    var status: Status = .inProgress
    var error: String?

    enum Status {
        case inProgress
        case completed
        case failed
        case cancelled
    }

    var summary: String {
        switch status {
        case .completed:
            return "✅ Completed \(executedActions.count) actions"
        case .failed:
            return "❌ Failed: \(error ?? "Unknown error")"
        case .cancelled:
            return "⚠️ Cancelled"
        case .inProgress:
            return "⏳ In progress..."
        }
    }
}

enum ExecutionState {
    case idle
    case analyzing
    case planning
    case executing
    case completed
    case failed
    case cancelled
}

// MARK: - Coding Capability

final class CodingCapability {
    func createPlan(for message: String, projectPath: String) async -> AgentPlan {
        // For now, create a simple plan. This can be upgraded to use LLM for planning.
        var steps: [AgentPlanStep] = []

        let lowered = message.lowercased()

        // Analyze project first
        steps.append(AgentPlanStep(
            description: "Analyze current project state",
            actions: [
                AgentAction(type: .toolCall, tool: "get_project_structure", parameters: [:])
            ],
            expectedOutcome: "Project structure understood"
        ))

        // Build step (always verify)
        steps.append(AgentPlanStep(
            description: "Build and verify",
            actions: [
                AgentAction(type: .toolCall, tool: "run_build", parameters: ["configuration": "Debug"])
            ],
            expectedOutcome: "Build succeeds"
        ))

        return AgentPlan(steps: steps, description: "Coding task: \(message.prefix(50))")
    }

    func createFile(path: String, content: String, projectPath: String) async -> ToolResult {
        let tool = WriteFileTool()
        do {
            return try await tool.execute(
                arguments: ["path": path, "content": content, "overwrite": true],
                projectPath: projectPath
            )
        } catch {
            return ToolResult(success: false, output: "", error: error.localizedDescription)
        }
    }

    func editFile(path: String, oldText: String, newText: String, projectPath: String) async -> ToolResult {
        let tool = EditFileTool()
        do {
            return try await tool.execute(
                arguments: ["path": path, "old_text": oldText, "new_text": newText],
                projectPath: projectPath
            )
        } catch {
            return ToolResult(success: false, output: "", error: error.localizedDescription)
        }
    }

    func runCommand(_ command: String, projectPath: String) async -> ToolResult {
        let tool = RunCommandTool()
        do {
            return try await tool.execute(
                arguments: ["command": command],
                projectPath: projectPath
            )
        } catch {
            return ToolResult(success: false, output: "", error: error.localizedDescription)
        }
    }
}

// MARK: - Desktop Capability

final class DesktopCapability {
    func createPlan(for message: String) async -> AgentPlan {
        var steps: [AgentPlanStep] = []

        let lowered = message.lowercased()

        if lowered.contains("open") {
            // Extract app name (simplified)
            let words = message.components(separatedBy: " ")
            if let openIndex = words.firstIndex(where: { $0.lowercased() == "open" }), openIndex + 1 < words.count {
                let appName = Array(words.suffix(from: openIndex + 1)).joined(separator: " ")
                steps.append(AgentPlanStep(
                    description: "Open \(appName)",
                    actions: [
                        AgentAction(type: .toolCall, tool: "applescript", parameters: [
                            "preset": "open_app",
                            "app_name": appName
                        ])
                    ],
                    expectedOutcome: "\(appName) is open and active"
                ))
            }
        }

        if lowered.contains("click") {
            // Would need coordinates or element identification
            steps.append(AgentPlanStep(
                description: "Click action",
                actions: [
                    AgentAction(type: .toolCall, tool: "input_control", parameters: [
                        "action": "click",
                        "x": 500,  // Would be determined by vision
                        "y": 500
                    ])
                ],
                expectedOutcome: "Click performed"
            ))
        }

        return AgentPlan(steps: steps, description: "Desktop control: \(message.prefix(50))")
    }

    func createSystemControlPlan(for message: String) async -> AgentPlan {
        var steps: [AgentPlanStep] = []
        let lowered = message.lowercased()

        if lowered.contains("volume") {
            // Extract percentage if present
            let numbers = message.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            let value = numbers.first.flatMap { Int($0) } ?? 50

            steps.append(AgentPlanStep(
                description: "Set volume to \(value)%",
                actions: [
                    AgentAction(type: .toolCall, tool: "system_control", parameters: [
                        "setting": "volume",
                        "action": "set",
                        "value": value
                    ])
                ],
                expectedOutcome: "Volume set to \(value)%"
            ))
        }

        if lowered.contains("brightness") {
            let numbers = message.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            let value = numbers.first.flatMap { Int($0) } ?? 50

            steps.append(AgentPlanStep(
                description: "Set brightness to \(value)%",
                actions: [
                    AgentAction(type: .toolCall, tool: "system_control", parameters: [
                        "setting": "brightness",
                        "action": "set",
                        "value": value
                    ])
                ],
                expectedOutcome: "Brightness set to \(value)%"
            ))
        }

        return AgentPlan(steps: steps, description: "System control: \(message.prefix(50))")
    }

    func executeAction(_ action: AgentAction) async -> ToolResult {
        guard let actionType = action.parameters["action"] as? String else {
            return ToolResult(success: false, output: "", error: "Missing action type")
        }

        switch actionType {
        case "click", "move", "type", "key":
            let tool = InputControlTool()
            do {
                return try await tool.execute(arguments: action.parameters, projectPath: "")
            } catch {
                return ToolResult(success: false, output: "", error: error.localizedDescription)
            }

        case "open_app", "activate":
            let tool = AppleScriptTool()
            do {
                return try await tool.execute(arguments: action.parameters, projectPath: "")
            } catch {
                return ToolResult(success: false, output: "", error: error.localizedDescription)
            }

        default:
            return ToolResult(success: false, output: "", error: "Unknown desktop action: \(actionType)")
        }
    }
}

// MARK: - Vision Capability

final class VisionCapability {
    func createPlan(for message: String) async -> AgentPlan {
        var steps: [AgentPlanStep] = []

        // Capture screen
        steps.append(AgentPlanStep(
            description: "Capture current screen",
            actions: [
                AgentAction(type: .toolCall, tool: "playwright_capture", parameters: [
                    "action": "screenshot"
                ])
            ],
            expectedOutcome: "Screenshot captured"
        ))

        return AgentPlan(steps: steps, description: "Vision task: \(message.prefix(50))")
    }
}
