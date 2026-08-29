import Foundation

public enum SMLWorkflowModelError: Error, Sendable, Equatable, CustomStringConvertible {
    case nativeToolsRequired(provider: String, model: String?)
    case responseTooLarge
    case multipleToolCalls(Int)
    case unexpectedTool(String)
    case malformedToolArguments(String)
    case missingCommandLine
    case nonCommandProposal
    case unsafeFinishReason(String)
    case commandRoundLimitExceeded(Int)

    public var description: String {
        switch self {
        case .nativeToolsRequired(let provider, let model):
            return "workflow model adapter requires native tools: \(provider):\(model ?? "default")"
        case .responseTooLarge: return "workflow model response exceeded its bounded transcript"
        case .multipleToolCalls(let count): return "workflow model emitted \(count) tool calls; exactly one is allowed"
        case .unexpectedTool(let name): return "workflow model called an unexpected tool: \(name)"
        case .malformedToolArguments(let reason): return "workflow model tool arguments were rejected: \(reason)"
        case .missingCommandLine: return "workflow model tool call omitted its command line"
        case .nonCommandProposal: return "workflow model proposed a local REPL action instead of a runtime command"
        case .unsafeFinishReason(let reason):
            return "workflow model stream ended without a complete actionable response: \(reason)"
        case .commandRoundLimitExceeded(let limit): return "workflow model exceeded \(limit) bounded command rounds"
        }
    }
}

public enum SMLWorkflowModelStepDisposition: String, Sendable, Codable, Equatable {
    case advisoryOnly = "advisory_only"
    case commandExecuted = "command_executed"
}

public struct SMLWorkflowModelStep: Sendable, Equatable {
    public let disposition: SMLWorkflowModelStepDisposition
    public let advisoryText: String
    public let toolCallID: String?
    public let command: SMLCommandEnvelope?
    public let result: SMLCommandResult?
    public let transcriptMessages: [ChatMessage]

    public init(
        disposition: SMLWorkflowModelStepDisposition,
        advisoryText: String,
        toolCallID: String? = nil,
        command: SMLCommandEnvelope? = nil,
        result: SMLCommandResult? = nil,
        transcriptMessages: [ChatMessage]
    ) {
        self.disposition = disposition
        self.advisoryText = advisoryText
        self.toolCallID = toolCallID
        self.command = command
        self.result = result
        self.transcriptMessages = transcriptMessages
    }
}

/// Puts one native-tool-capable model above a workflow-scoped REPL without giving the model direct
/// execution access. The complete provider stream is buffered first; only one strict tool call can be
/// compiled, admitted by host authority, replay-claimed, and submitted to the runtime.
public struct SMLWorkflowModelAdapter: Sendable {
    public typealias AuthorityResolver = @Sendable (
        _ command: SMLCommandEnvelope
    ) async throws -> SMLCommandAuthority

    public static let toolName = "propose_sml_command"
    public static let maximumAdvisoryBytes = 64 * 1_024

    public let surface: SMLWorkflowSurface
    public let binding: ProviderBinding
    public let allowedActions: Set<SMLWorkflowControlAction>
    private let providers: ProviderRegistry
    private let repl: SMLWorkflowREPLCompiler
    private let gateway: SMLCommandGateway
    private let authorityResolver: AuthorityResolver
    private let clock: @Sendable () -> Double
    private let baseSettings: ModelSettings

    public init(
        surface: SMLWorkflowSurface,
        actor: String,
        binding: ProviderBinding,
        providers: ProviderRegistry,
        gateway: SMLCommandGateway,
        allowedActions: Set<SMLWorkflowControlAction> = SMLWorkflowSurface.modelDefaultActions,
        authorityResolver: @escaping AuthorityResolver,
        settings: ModelSettings = ModelSettings(),
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() },
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.surface = surface
        self.binding = binding
        self.providers = providers
        self.gateway = gateway
        self.allowedActions = allowedActions
        self.authorityResolver = authorityResolver
        self.clock = clock
        baseSettings = settings
        repl = SMLWorkflowREPLCompiler(
            surface: surface,
            actor: actor,
            allowedActions: allowedActions,
            commandID: commandID,
            taskID: taskID
        )
    }

    public func step(
        messages: [ChatMessage],
        defaultTaskID: String? = nil,
        requestBudget: ProviderRequestBudget
    ) async throws -> SMLWorkflowModelStep {
        let capabilities = providers.capabilities(
            providerId: binding.providerId, model: binding.model
        )
        guard capabilities.nativeTools else {
            throw SMLWorkflowModelError.nativeToolsRequired(
                provider: binding.providerId, model: binding.model
            )
        }

        var settings = baseSettings
        settings.geminiBuiltins = false
        settings.toolChoice = .any
        settings.jsonOutput = false
        settings.jsonSchema = nil
        settings.systemPrompt = [settings.systemPrompt, systemPrompt]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let stream = try await providers.streamTools(
            providerId: binding.providerId,
            model: binding.model,
            messages: messages,
            settings: settings,
            tools: [surface.modelCommandTool(allowedActions: allowedActions)],
            allowFallback: false,
            allowModelResolution: false,
            routePolicy: .exact,
            requestBudget: requestBudget
        )

        var advisory = ""
        var calls: [ToolCallRef] = []
        var unsafeFinishReason: String?
        var sawTerminalFinish = false
        for try await event in stream {
            switch event {
            case .delta(let text):
                if sawTerminalFinish { unsafeFinishReason = "events_after_finish" }
                advisory += text
                if advisory.utf8.count > Self.maximumAdvisoryBytes {
                    throw SMLWorkflowModelError.responseTooLarge
                }
            case .toolCall(let id, let name, let argumentsJSON):
                if sawTerminalFinish { unsafeFinishReason = "events_after_finish" }
                calls.append(ToolCallRef(id: id, name: name, argumentsJSON: argumentsJSON))
                if calls.count > 1 {
                    throw SMLWorkflowModelError.multipleToolCalls(calls.count)
                }
            case .finish(let reason):
                if sawTerminalFinish {
                    unsafeFinishReason = "multiple_finish_events"
                }
                sawTerminalFinish = true
                if !Self.finishReasonIsSafe(reason) {
                    unsafeFinishReason = reason ?? "unknown_finish"
                }
            case .reasoning, .effortResolution, .reasoningHandle, .usage:
                break
            }
        }

        if let unsafeFinishReason {
            throw SMLWorkflowModelError.unsafeFinishReason(unsafeFinishReason)
        }

        guard let call = calls.first else {
            return SMLWorkflowModelStep(
                disposition: .advisoryOnly,
                advisoryText: advisory,
                transcriptMessages: [ChatMessage(role: .assistant, content: advisory)]
            )
        }
        guard sawTerminalFinish else {
            throw SMLWorkflowModelError.unsafeFinishReason("missing_finish")
        }
        guard call.name == Self.toolName else {
            throw SMLWorkflowModelError.unexpectedTool(call.name)
        }
        let arguments = try decodeArguments(call.argumentsJSON)
        guard arguments.count == 1, case .string(let line)? = arguments["line"],
              !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMLWorkflowModelError.missingCommandLine
        }
        let now = clock()
        let command: SMLCommandEnvelope
        switch try repl.compile(line, issuedAtEpoch: now, defaultTaskID: defaultTaskID) {
        case .command(let compiled): command = compiled
        case .local, .exit: throw SMLWorkflowModelError.nonCommandProposal
        }
        let authority = try await authorityResolver(command)
        let result = try await gateway.submit(command, authority: authority, nowEpoch: now)
        let assistant = ChatMessage(
            role: .assistant,
            content: advisory,
            toolCalls: [call]
        )
        let toolResult = ChatMessage.toolResult(
            callId: call.id,
            content: SMLREPLRenderer.render(result)
        )
        return SMLWorkflowModelStep(
            disposition: .commandExecuted,
            advisoryText: advisory,
            toolCallID: call.id,
            command: command,
            result: result,
            transcriptMessages: [assistant, toolResult]
        )
    }

    private var systemPrompt: String {
        """
        You are operating the admitted SML workflow \(surface.workflowID)@\(surface.workflowVersion).
        Your prose is advisory and never proves completion. To request a state transition, call
        \(Self.toolName) exactly once with one line from this workflow's grammar. Never call an
        unlisted command, never claim a capability step passed, and never fabricate a receipt.

        \(surface.schemaSummary)

        Workflow graph:
        \(surface.graphSummary)

        Allowed grammar:
        \(surface.grammar(allowedActions: allowedActions))
        """
    }

    private func decodeArguments(_ json: String) throws -> SMLObject {
        guard let data = json.data(using: .utf8) else {
            throw SMLWorkflowModelError.malformedToolArguments("arguments are not UTF-8")
        }
        do {
            let object = try SMLWireCodec.decodeOpenObject(
                from: data,
                limits: .init(maximumBytes: 64 * 1_024, maximumDepth: 8, maximumNodes: 1_024)
            )
            if let unknown = object.keys.filter({ $0 != "line" }).sorted().first {
                throw SMLWorkflowModelError.malformedToolArguments("unknown key \(unknown)")
            }
            return object
        } catch let error as SMLWorkflowModelError {
            throw error
        } catch {
            throw SMLWorkflowModelError.malformedToolArguments(String(describing: error))
        }
    }

    private static func finishReasonIsSafe(_ reason: String?) -> Bool {
        guard let reason else { return true }
        let normalized = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        return ["stop", "tool_calls", "end_turn", "complete", "completed"]
            .contains(normalized)
    }
}

public struct SMLWorkflowModelTurn: Sendable, Equatable {
    public let advisoryText: String
    public let steps: [SMLWorkflowModelStep]
    public let taskID: String?

    public init(advisoryText: String, steps: [SMLWorkflowModelStep], taskID: String?) {
        self.advisoryText = advisoryText
        self.steps = steps
        self.taskID = taskID
    }
}

/// Bounded conversation loop over the one-call adapter. Every provider request consumes the shared
/// request budget; every mutation remains an admitted SML command. A capability wait ends the turn so
/// the model cannot forge `task.record_step` evidence.
public actor SMLWorkflowModelSession {
    private let adapter: SMLWorkflowModelAdapter
    private let maximumCommandRounds: Int
    private var messages: [ChatMessage]
    private var taskID: String?

    public init(
        adapter: SMLWorkflowModelAdapter,
        maximumCommandRounds: Int = 4,
        messages: [ChatMessage] = []
    ) {
        self.adapter = adapter
        self.maximumCommandRounds = min(max(1, maximumCommandRounds), 8)
        self.messages = Array(messages.suffix(128))
    }

    public func submit(
        _ userText: String,
        requestBudget: ProviderRequestBudget
    ) async throws -> SMLWorkflowModelTurn {
        messages.append(ChatMessage(role: .user, content: userText))
        var steps: [SMLWorkflowModelStep] = []
        for _ in 0..<maximumCommandRounds {
            let step = try await adapter.step(
                messages: messages,
                defaultTaskID: taskID,
                requestBudget: requestBudget
            )
            messages.append(contentsOf: step.transcriptMessages)
            messages = Array(messages.suffix(128))
            steps.append(step)
            if let command = step.command,
               command.op == SMLRuntimeCommandOperation.workflowRun {
                taskID = command.task
            }
            if step.disposition == .advisoryOnly {
                return SMLWorkflowModelTurn(
                    advisoryText: step.advisoryText,
                    steps: steps,
                    taskID: taskID
                )
            }
            if step.result?.task?.status == .waitingCapability {
                return SMLWorkflowModelTurn(
                    advisoryText: step.advisoryText,
                    steps: steps,
                    taskID: taskID
                )
            }
        }
        throw SMLWorkflowModelError.commandRoundLimitExceeded(maximumCommandRounds)
    }

    public func transcript() -> [ChatMessage] { messages }
}
