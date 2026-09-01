import Foundation

/// One model loop over many mounted workflows.
///
/// The model chooses a `workflow_id` and one line from that workflow's generated REPL grammar. The
/// adapter still compiles through `SMLWorkflowRuntimeRegistry`, so workflow selection cannot bypass
/// per-workflow allowed actions, command validation, host authority, replay admission, or runtime
/// state checks.
public struct SMLWorkflowRuntimeModelAdapter: Sendable {
    public typealias AuthorityResolver = @Sendable (
        _ command: SMLCommandEnvelope
    ) async throws -> SMLCommandAuthority

    public static let toolName = "propose_sml_runtime_command"

    public let registry: SMLWorkflowRuntimeRegistry
    public let binding: ProviderBinding
    private let providers: ProviderRegistry
    private let gateway: SMLCommandGateway
    private let authorityResolver: AuthorityResolver
    private let clock: @Sendable () -> Double
    private let baseSettings: ModelSettings

    public init(
        registry: SMLWorkflowRuntimeRegistry,
        binding: ProviderBinding,
        providers: ProviderRegistry,
        gateway: SMLCommandGateway,
        authorityResolver: @escaping AuthorityResolver,
        settings: ModelSettings = ModelSettings(),
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.registry = registry
        self.binding = binding
        self.providers = providers
        self.gateway = gateway
        self.authorityResolver = authorityResolver
        self.clock = clock
        baseSettings = settings
    }

    public static func modelCommandTool(catalog: SMLWorkflowRuntimeCatalog) -> ToolSpec {
        let commandIndex = catalog.workflows.isEmpty
            ? "none"
            : catalog.workflows.map { descriptor in
                let allowedActions = Set(descriptor.model.allowedActions)
                return """
                \(descriptor.workflowID)@\(descriptor.workflowVersion)
                \(SMLWorkflowREPLDescriptorFormatter.modelCommandIndex(
                    commands: descriptor.repl.commands,
                    examples: descriptor.repl.examples,
                    allowedActions: allowedActions
                ))
                """
            }.joined(separator: "\n\n")
        let metadataIndex = catalog.workflows.isEmpty
            ? "none"
            : catalog.workflows.map { descriptor in
                let metadata = SMLWorkflowRuntimeWorkflowMetadataLinks(descriptor)
                return """
                \(descriptor.workflowID)@\(descriptor.workflowVersion)
                \(workflowMetadataPromptLines(metadata))
                """
            }.joined(separator: "\n\n")
        return ToolSpec(
            name: toolName,
            description: "Propose exactly one command for one mounted SML workflow. "
                + "The host validates the selected workflow, command grammar, authority, and replay. "
                + "Mounted workflows: \(catalog.workflowIDs.joined(separator: ", "))."
                + "\n\nWorkflow metadata index:\n"
                + metadataIndex
                + "\n\nAllowed model command index:\n"
                + commandIndex,
            parameters: [
                ToolParameter(
                    name: "workflow_id",
                    type: "string",
                    description: "Exact workflow id from the mounted SML runtime catalog."
                ),
                ToolParameter(
                    name: "line",
                    type: "string",
                    description: "One exact command line from that workflow's allowed REPL grammar."
                ),
            ]
        )
    }

    public var modelCommandTool: ToolSpec {
        Self.modelCommandTool(catalog: registry.catalog)
    }

    public func step(
        messages: [ChatMessage],
        defaultTaskIDs: [String: String] = [:],
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
            tools: [modelCommandTool],
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
                if advisory.utf8.count > SMLWorkflowModelAdapter.maximumAdvisoryBytes {
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
        let proposal = try decodeArguments(call.argumentsJSON)
        let now = clock()
        let command: SMLCommandEnvelope
        switch try registry.compileREPL(
            proposal.line,
            workflowID: proposal.workflowID,
            issuedAtEpoch: now,
            defaultTaskID: defaultTaskIDs[proposal.workflowID]
        ) {
        case .command(let compiled): command = compiled
        case .local, .exit: throw SMLWorkflowModelError.nonCommandProposal
        }
        try requireModelActionAllowed(command, workflowID: proposal.workflowID)
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
        Self.systemPrompt(catalog: registry.catalog)
    }

    private static func systemPrompt(catalog: SMLWorkflowRuntimeCatalog) -> String {
        let mountContract = catalog.mountContract
        let mountsByWorkflowID = Dictionary(
            uniqueKeysWithValues: mountContract.workflowMounts.map { ($0.workflowID, $0) }
        )
        let planning = catalog.planningManifest
        let skillIndexByWorkflowID = Dictionary(grouping: planning.skillIndex, by: \.workflowID)
        let toolsByWorkflowID = Dictionary(grouping: planning.toolIndex, by: \.workflowID)
        let decomposableByWorkflowID = Dictionary(grouping: planning.decomposableUnits, by: \.workflowID)
        let approvalsByWorkflowID = Dictionary(grouping: planning.approvalGates, by: \.workflowID)
        let commandBindingsByWorkflowID = Dictionary(grouping: planning.commandBindings, by: \.workflowID)
        let workflows = catalog.workflows
            .map { descriptor in
                modelPromptSection(
                    descriptor: descriptor,
                    mount: mountsByWorkflowID[descriptor.workflowID],
                    skillIndex: skillIndexByWorkflowID[descriptor.workflowID] ?? [],
                    planningToolIndex: toolsByWorkflowID[descriptor.workflowID] ?? [],
                    decomposableUnits: decomposableByWorkflowID[descriptor.workflowID] ?? [],
                    approvalGates: approvalsByWorkflowID[descriptor.workflowID] ?? [],
                    commandBindings: commandBindingsByWorkflowID[descriptor.workflowID] ?? []
                )
            }
            .joined(separator: "\n\n")
        return """
        You are operating a mounted SML workflow runtime.
        Your prose is advisory and never proves completion. To request a state transition, call
        \(toolName) exactly once with a mounted workflow_id and one line from that workflow's
        allowed model grammar. Never call an unlisted command, never claim a capability step
        passed, and never fabricate a receipt.

        Break work into small contextual workflow steps. Use the planning units, decomposable
        units, skill tree, API routes, model tools, and Onyx driver IDs below as the source of truth.
        Descriptor-only metadata is safe to inspect; mutations must use host_command_gateway
        routes and still require host authority plus replay admission.

        Model router tool:
        \(toolName)

        Mounted workflows:
        \(workflows)
        """
    }

    private static func modelPromptSection(
        descriptor: SMLWorkflowRuntimeDescriptor,
        mount: SMLWorkflowRuntimeWorkflowMount?,
        skillIndex: [SMLWorkflowRuntimePlanningSkillIndexEntry],
        planningToolIndex: [SMLWorkflowRuntimePlanningToolIndexEntry],
        decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit],
        approvalGates: [SMLWorkflowRuntimePlanningApprovalGate],
        commandBindings: [SMLWorkflowRuntimePlanningCommandBinding]
    ) -> String {
        let allowedActions = Set(descriptor.model.allowedActions)
        let modelCommands = descriptor.repl.commands.filter { command in
            guard command.kind == .runtime,
                  let action = command.action else { return false }
            return allowedActions.contains(action)
        }
        let grammar = modelCommands.isEmpty
            ? "none"
            : modelCommands.map(\.usage).joined(separator: "\n")
        let routes = (mount?.apiRoutes ?? [])
            .filter { route in
                guard let action = route.action else { return false }
                return allowedActions.contains(action)
            }
            .map {
                "\($0.method.rawValue) \($0.pathTemplate) [\($0.authority.rawValue)] body:\($0.bodyKind.rawValue) -> \($0.operationID)"
            }
            .joined(separator: "\n")
        let planningUnits = planningToolIndex.isEmpty
            ? "none"
            : planningToolIndex.map {
                "\($0.instructionID):\($0.operation.rawValue) ref:\($0.reference) unit:\($0.unitKind?.rawValue ?? "unknown")"
            }.joined(separator: "\n")
        let skillTree = skillIndex.isEmpty
            ? "none"
            : skillIndex.map {
                let reference = $0.reference ?? "none"
                let unit = $0.unitKind?.rawValue ?? "unknown"
                let pre = $0.prerequisites.isEmpty ? "none" : $0.prerequisites.joined(separator: ",")
                let next = $0.successors.isEmpty ? "none" : $0.successors.joined(separator: ",")
                return [
                    "\($0.instructionID):\($0.operation.rawValue)",
                    "kind:\($0.kind.rawValue)",
                    "unit:\(unit)",
                    "ref:\(reference)",
                    "pre:\(pre)",
                    "next:\(next)",
                    "decompose:\($0.canDecomposeFurther)",
                    "approval:\($0.requiresApproval)",
                    "terminal:\($0.terminal)",
                ].joined(separator: " ")
            }.joined(separator: "\n")
        let decomposable = decomposableUnits.isEmpty
            ? "none"
            : decomposableUnits.map {
                "\($0.instructionID):\($0.unitKind.rawValue) successors:\($0.successors.joined(separator: ","))"
            }.joined(separator: "\n")
        let approvals = approvalGates.isEmpty
            ? "none"
            : approvalGates.map {
                "\($0.instructionID) successors:\($0.successors.joined(separator: ","))"
            }.joined(separator: "\n")
        let workflowMetadata = mount?.workflowMetadata
            ?? SMLWorkflowRuntimeWorkflowMetadataLinks(descriptor)
        let modelCommandBindings = commandBindings.filter(\.modelEligible)
        let commandBindingIndex = modelCommandBindings.isEmpty
            ? "none"
            : modelCommandBindings.map { binding in
                let model = binding.modelEligible ? "model:eligible" : "model:blocked"
                let replFields = binding.replJSONFields.map(\.name).joined(separator: ",")
                let apiFields = binding.apiBodyFields.map(\.name).joined(separator: ",")
                return [
                    "\(binding.action.rawValue):",
                    #"repl="\#(binding.replLineTemplate)""#,
                    "json:\(binding.replJSONBodyKind.rawValue)",
                    "replFields:\(replFields.isEmpty ? "none" : replFields)",
                    "api:\(binding.apiMethod.rawValue) \(binding.apiPathTemplate)",
                    "body:\(binding.apiBodyKind.rawValue)",
                    "apiFields:\(apiFields.isEmpty ? "none" : apiFields)",
                    model,
                ].joined(separator: " ")
            }.joined(separator: "\n")
        return """
        \(descriptor.workflowID)@\(descriptor.workflowVersion) — \(descriptor.workflowName)
        role: \(descriptor.role)
        source: \(descriptor.sourceKind.rawValue) \(descriptor.sourceReference)
        entrypoint: \(descriptor.onyx.plan.entrypoint)
        api base path: \(descriptor.api.basePath)
        api workflow path: \(descriptor.api.workflowPath)
        model tool: \(descriptor.model.tool.name) via \(toolName)
        onyx driver: \(descriptor.onyx.driverID)
        workflow metadata:
        \(workflowMetadataPromptLines(workflowMetadata))

        \(descriptor.schemaSummary)

        Workflow graph:
        \(descriptor.graphSummary)

        Allowed REPL grammar:
        \(grammar)

        \(SMLWorkflowREPLDescriptorFormatter.modelCommandIndex(
            commands: descriptor.repl.commands,
            examples: descriptor.repl.examples,
            allowedActions: allowedActions
        ))

        API routes:
        \(routes.isEmpty ? "none" : routes)

        Skill tree:
        \(skillTree)

        Planning units:
        \(planningUnits)

        Decomposable units:
        \(decomposable)

        Approval gates:
        \(approvals)

        Command bindings:
        \(commandBindingIndex)
        """
    }

    private static func workflowMetadataPromptLines(
        _ metadata: SMLWorkflowRuntimeWorkflowMetadataLinks
    ) -> String {
        """
        attachment: GET \(metadata.attachmentPath)
        repl mount: GET \(metadata.replMountPath)
        api mount: GET \(metadata.apiMountPath)
        model tool: GET \(metadata.modelToolPath)
        onyx driver: GET \(metadata.onyxDriverPath)
        skill tree: GET \(metadata.skillTreePath)
        tool bindings: GET \(metadata.toolBindingsPath)
        planning bundle: GET \(metadata.planningBundlePath)
        """
    }

    private func requireModelActionAllowed(
        _ command: SMLCommandEnvelope,
        workflowID: String
    ) throws {
        let descriptor = try registry.descriptor(workflowID: workflowID)
        let action = try Self.modelAction(for: command, descriptor: descriptor)
        guard descriptor.model.allowedActions.contains(action) else {
            throw SMLWorkflowREPLCompileError.actionDenied(action.rawValue)
        }
    }

    static func modelAction(
        for command: SMLCommandEnvelope,
        descriptor: SMLWorkflowRuntimeDescriptor
    ) throws -> SMLWorkflowControlAction {
        guard command.role == descriptor.role,
              case .string(let workflowID)? = command.arguments["workflow_id"],
              workflowID == descriptor.workflowID,
              case .string(let workflowVersion)? = command.arguments["workflow_version"],
              workflowVersion == descriptor.workflowVersion else {
            throw SMLWorkflowModelError.nonCommandProposal
        }

        let actions = descriptor.commands.compactMap { candidate -> SMLWorkflowControlAction? in
            candidate.action.runtimeOperation == command.op ? candidate.action : nil
        }
        guard actions.count == 1,
              let action = actions.first,
              commandShapeMatches(action: action, command: command) else {
            throw SMLWorkflowModelError.nonCommandProposal
        }
        return action
    }

    private static func commandShapeMatches(
        action: SMLWorkflowControlAction,
        command: SMLCommandEnvelope
    ) -> Bool {
        switch action {
        case .describe:
            return command.task == "runtime"
                && command.arguments["initial_state"] == nil
        case .start:
            return command.task != "runtime"
                && optionalInitialStateIsValid(command.arguments["initial_state"])
        case .watch, .receipts:
            return command.task != "runtime"
                && command.arguments["initial_state"] == nil
        case .approve, .refuse, .rollback:
            return command.task != "runtime"
                && command.arguments["initial_state"] == nil
                && validTaskRevision(command.expectedState["task_revision"])
        }
    }

    private static func optionalInitialStateIsValid(_ value: SMLValue?) -> Bool {
        guard let value else { return true }
        guard case .object = value else { return false }
        return true
    }

    private static func validTaskRevision(_ value: SMLValue?) -> Bool {
        guard case .number(let revision)? = value,
              revision >= 0,
              revision <= Decimal(Int.max) else {
            return false
        }
        var input = revision
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .plain)
        return rounded == revision
    }

    private func decodeArguments(_ json: String) throws -> (workflowID: String, line: String) {
        guard let data = json.data(using: .utf8) else {
            throw SMLWorkflowModelError.malformedToolArguments("arguments are not UTF-8")
        }
        do {
            let object = try SMLWireCodec.decodeOpenObject(
                from: data,
                limits: .init(maximumBytes: 64 * 1_024, maximumDepth: 8, maximumNodes: 1_024)
            )
            if let unknown = object.keys
                .filter({ !["workflow_id", "line"].contains($0) })
                .sorted()
                .first {
                throw SMLWorkflowModelError.malformedToolArguments("unknown key \(unknown)")
            }
            guard case .string(let workflowID)? = object["workflow_id"],
                  !workflowID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SMLWorkflowModelError.malformedToolArguments("missing workflow_id")
            }
            guard case .string(let line)? = object["line"],
                  !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SMLWorkflowModelError.missingCommandLine
            }
            return (workflowID, line)
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

public struct SMLWorkflowRuntimeModelTurn: Sendable, Equatable {
    public let advisoryText: String
    public let steps: [SMLWorkflowModelStep]
    public let taskIDsByWorkflowID: [String: String]

    public init(
        advisoryText: String,
        steps: [SMLWorkflowModelStep],
        taskIDsByWorkflowID: [String: String]
    ) {
        self.advisoryText = advisoryText
        self.steps = steps
        self.taskIDsByWorkflowID = taskIDsByWorkflowID
    }
}

public actor SMLWorkflowRuntimeModelSession {
    private let adapter: SMLWorkflowRuntimeModelAdapter
    private let maximumCommandRounds: Int
    private var messages: [ChatMessage]
    private var taskIDsByWorkflowID: [String: String]

    public init(
        adapter: SMLWorkflowRuntimeModelAdapter,
        maximumCommandRounds: Int = 4,
        messages: [ChatMessage] = [],
        taskIDsByWorkflowID: [String: String] = [:]
    ) {
        self.adapter = adapter
        self.maximumCommandRounds = min(max(1, maximumCommandRounds), 8)
        self.messages = Array(messages.suffix(128))
        self.taskIDsByWorkflowID = taskIDsByWorkflowID
    }

    public func submit(
        _ userText: String,
        requestBudget: ProviderRequestBudget
    ) async throws -> SMLWorkflowRuntimeModelTurn {
        messages.append(ChatMessage(role: .user, content: userText))
        var steps: [SMLWorkflowModelStep] = []
        for _ in 0..<maximumCommandRounds {
            let step = try await adapter.step(
                messages: messages,
                defaultTaskIDs: taskIDsByWorkflowID,
                requestBudget: requestBudget
            )
            messages.append(contentsOf: step.transcriptMessages)
            messages = Array(messages.suffix(128))
            steps.append(step)
            if let command = step.command,
               command.op == SMLRuntimeCommandOperation.workflowRun,
               case .string(let workflowID)? = command.arguments["workflow_id"] {
                taskIDsByWorkflowID[workflowID] = command.task
            }
            if step.disposition == .advisoryOnly {
                return SMLWorkflowRuntimeModelTurn(
                    advisoryText: step.advisoryText,
                    steps: steps,
                    taskIDsByWorkflowID: taskIDsByWorkflowID
                )
            }
            if step.result?.task?.status == .waitingCapability {
                return SMLWorkflowRuntimeModelTurn(
                    advisoryText: step.advisoryText,
                    steps: steps,
                    taskIDsByWorkflowID: taskIDsByWorkflowID
                )
            }
        }
        throw SMLWorkflowModelError.commandRoundLimitExceeded(maximumCommandRounds)
    }

    public func transcript() -> [ChatMessage] { messages }

    public func taskIDs() -> [String: String] { taskIDsByWorkflowID }
}

