import Foundation

public enum SMLWorkflowSurfaceError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidRole(String)
    case unavailableAction(String)
    case taskRequired(String)
    case invalidTask(String)
    case unknownInput(String)
    case missingInput(String)
    case invalidInput(name: String, expected: SMLStateType)
    case taskRevisionRequired
    case invalidEnvelope([String])

    public var description: String {
        switch self {
        case .invalidRole(let role):
            return "invalid SML workflow surface role: \(role)"
        case .unavailableAction(let action):
            return "workflow surface action is unavailable: \(action)"
        case .taskRequired(let action):
            return "workflow surface action requires a task id: \(action)"
        case .invalidTask(let task):
            return "invalid workflow task id: \(task)"
        case .unknownInput(let name):
            return "workflow input is not exposed: \(name)"
        case .missingInput(let name):
            return "required workflow input is missing: \(name)"
        case .invalidInput(let name, let expected):
            return "workflow input \(name) must be \(expected.rawValue)"
        case .taskRevisionRequired:
            return "state-changing task commands require a nonnegative integer expected_state.task_revision"
        case .invalidEnvelope(let diagnostics):
            return "generated SML command is invalid: " + diagnostics.joined(separator: "; ")
        }
    }
}

public enum SMLWorkflowControlAction: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case describe
    case start
    case watch
    case approve
    case refuse
    case rollback
    case receipts

    var runtimeOperation: String {
        switch self {
        case .describe: return SMLRuntimeCommandOperation.workflowInspect
        case .start: return SMLRuntimeCommandOperation.workflowRun
        case .watch: return SMLRuntimeCommandOperation.taskWatch
        case .approve: return SMLRuntimeCommandOperation.taskApprove
        case .refuse: return SMLRuntimeCommandOperation.taskRefuse
        case .rollback: return SMLRuntimeCommandOperation.taskRollback
        case .receipts: return SMLRuntimeCommandOperation.receiptsList
        }
    }
}

public struct SMLWorkflowFieldDescriptor: Sendable, Codable, Equatable {
    public let name: String
    public let type: SMLStateType
    public let required: Bool
    public let nullable: Bool
    public let description: String?

    init(_ field: SMLStateField) {
        name = field.name
        type = field.type
        required = field.required
        nullable = field.nullable
        description = field.description
    }
}

public struct SMLWorkflowCommandDescriptor: Sendable, Codable, Equatable {
    public let action: SMLWorkflowControlAction
    public let verb: String
    public let summary: String
    public let requiresTask: Bool
    public let changesTaskState: Bool

    public init(
        action: SMLWorkflowControlAction,
        verb: String,
        summary: String,
        requiresTask: Bool,
        changesTaskState: Bool
    ) {
        self.action = action
        self.verb = verb
        self.summary = summary
        self.requiresTask = requiresTask
        self.changesTaskState = changesTaskState
    }
}

/// One canonical callable surface derived from an admitted workflow.
///
/// REPL, API, model, and Onyx adapters consume this value rather than independently guessing a
/// command schema. The underlying workflow remains internal so only `SMLAdmittedWorkflow` can mint it.
public struct SMLWorkflowSurface: Sendable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let workflowName: String
    public let role: String
    public let sourceKind: SMLWorkflowSourceKind
    public let inputs: [SMLWorkflowFieldDescriptor]
    public let outputs: [SMLWorkflowFieldDescriptor]
    public let commands: [SMLWorkflowCommandDescriptor]
    let workflow: SMLWorkflow

    public static let modelDefaultActions: Set<SMLWorkflowControlAction> = [
        .describe, .start, .watch, .receipts,
    ]

    public static func compile(
        admitted: SMLAdmittedWorkflow,
        role: String
    ) throws -> SMLWorkflowSurface {
        guard SMLValidationSupport.identifierIsValid(role) else {
            throw SMLWorkflowSurfaceError.invalidRole(role)
        }
        let workflow = admitted.workflow
        let fields = Dictionary(uniqueKeysWithValues: workflow.stateSchema.map { ($0.name, $0) })
        let inputs = workflow.interface.inputFields.compactMap { fields[$0] }.map(SMLWorkflowFieldDescriptor.init)
        let outputs = workflow.interface.outputFields.compactMap { fields[$0] }.map(SMLWorkflowFieldDescriptor.init)
        let commands: [SMLWorkflowCommandDescriptor] = [
            .init(action: .describe, verb: "describe", summary: "Show this workflow's exact graph and interface", requiresTask: false, changesTaskState: false),
            .init(action: .start, verb: "start", summary: "Create a task pinned to this workflow revision", requiresTask: false, changesTaskState: true),
            .init(action: .watch, verb: "watch", summary: "Read the current task projection", requiresTask: true, changesTaskState: false),
            .init(action: .approve, verb: "approve", summary: "Approve the task's current human gate", requiresTask: true, changesTaskState: true),
            .init(action: .refuse, verb: "refuse", summary: "Refuse the task's current human gate", requiresTask: true, changesTaskState: true),
            .init(action: .rollback, verb: "rollback", summary: "Request terminal operator rollback", requiresTask: true, changesTaskState: true),
            .init(action: .receipts, verb: "receipts", summary: "List task receipts", requiresTask: true, changesTaskState: false),
        ]
        return SMLWorkflowSurface(
            workflowID: workflow.id,
            workflowVersion: workflow.version,
            workflowName: workflow.name,
            role: role,
            sourceKind: workflow.source.kind,
            inputs: inputs,
            outputs: outputs,
            commands: commands,
            workflow: workflow
        )
    }

    public func command(_ action: SMLWorkflowControlAction) -> SMLWorkflowCommandDescriptor? {
        commands.first { $0.action == action }
    }

    public func validateInitialState(_ state: SMLObject) throws {
        let exposed = Dictionary(uniqueKeysWithValues: inputs.map { ($0.name, $0) })
        for key in state.keys where exposed[key] == nil {
            throw SMLWorkflowSurfaceError.unknownInput(key)
        }
        for field in inputs {
            if field.required && state[field.name] == nil {
                throw SMLWorkflowSurfaceError.missingInput(field.name)
            }
            if let value = state[field.name],
               !Self.value(value, matches: field.type, nullable: field.nullable) {
                throw SMLWorkflowSurfaceError.invalidInput(
                    name: field.name, expected: field.type
                )
            }
        }
    }

    public func grammar(
        allowedActions: Set<SMLWorkflowControlAction>? = nil
    ) -> String {
        let allowed = allowedActions ?? Set(commands.map(\.action))
        var lines = commands.filter { allowed.contains($0.action) }.map { descriptor in
            switch descriptor.action {
            case .describe: return "describe"
            case .start: return "start [TASK_ID] [JSON_INPUT_OBJECT]"
            case .watch: return "watch TASK_ID"
            case .approve: return "approve TASK_ID {\"task_revision\":N}"
            case .refuse: return "refuse TASK_ID {\"task_revision\":N}"
            case .rollback: return "rollback TASK_ID {\"task_revision\":N}"
            case .receipts: return "receipts TASK_ID"
            }
        }
        if !inputs.isEmpty {
            let fields = inputs.map {
                "\($0.name):\($0.type.rawValue)\($0.required ? "" : "?")"
            }.joined(separator: ", ")
            lines.append("inputs {\(fields)}")
        }
        return lines.joined(separator: "\n")
    }

    /// The only model-facing function needed for this workflow. Its payload is the same bounded
    /// language the human REPL uses; the model never receives a direct runtime or ToolRegistry handle.
    public func modelCommandTool(
        allowedActions: Set<SMLWorkflowControlAction> = SMLWorkflowSurface.modelDefaultActions
    ) -> ToolSpec {
        ToolSpec(
            name: "propose_sml_command",
            description: "Propose exactly one command for \(workflowID)@\(workflowVersion). "
                + "The host validates authority and may refuse it. Allowed grammar:\n"
                + grammar(allowedActions: allowedActions),
            parameters: [
                ToolParameter(
                    name: "line",
                    type: "string",
                    description: "One exact command line from the allowed grammar"
                ),
            ]
        )
    }

    public var schemaSummary: String {
        let input = inputs.isEmpty ? "none" : inputs.map(Self.describeField).joined(separator: ", ")
        let output = outputs.isEmpty ? "none" : outputs.map(Self.describeField).joined(separator: ", ")
        return [
            "\(workflowID) \(workflowVersion) — \(workflowName)",
            "role: \(role) source: \(sourceKind.rawValue)",
            "inputs: \(input)",
            "outputs: \(output)",
        ].joined(separator: "\n")
    }

    private static func describeField(_ field: SMLWorkflowFieldDescriptor) -> String {
        "\(field.name):\(field.type.rawValue)\(field.required ? "" : "?")"
    }

    private static func value(_ value: SMLValue, matches type: SMLStateType, nullable: Bool) -> Bool {
        if case .null = value { return nullable }
        switch (type, value) {
        case (.string, .string), (.number, .number), (.boolean, .bool),
             (.object, .object), (.array, .array):
            return true
        case (.integer, .number(let number)):
            var input = number
            var rounded = Decimal()
            NSDecimalRound(&rounded, &input, 0, .plain)
            return rounded == number
        default:
            return false
        }
    }
}

public struct SMLWorkflowCommandCompiler: Sendable {
    public let surface: SMLWorkflowSurface
    private let actor: String
    private let commandID: @Sendable () -> String
    private let taskID: @Sendable () -> String

    public init(
        surface: SMLWorkflowSurface,
        actor: String,
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() }
    ) {
        self.surface = surface
        self.actor = actor
        self.commandID = commandID
        self.taskID = taskID
    }

    public func compile(
        action: SMLWorkflowControlAction,
        task requestedTask: String? = nil,
        initialState: SMLObject = [:],
        scope: SMLObject = [:],
        expectedState: SMLObject = [:],
        issuedAtEpoch: Double
    ) throws -> SMLCommandEnvelope {
        guard surface.command(action) != nil else {
            throw SMLWorkflowSurfaceError.unavailableAction(action.rawValue)
        }
        let task: String
        switch action {
        case .describe:
            task = "runtime"
        case .start:
            task = requestedTask ?? taskID()
            try surface.validateInitialState(initialState)
        case .watch, .approve, .refuse, .rollback, .receipts:
            guard let requestedTask else {
                throw SMLWorkflowSurfaceError.taskRequired(action.rawValue)
            }
            task = requestedTask
        }
        guard SMLValidationSupport.identifierIsValid(task),
              action == .describe || task != "runtime" else {
            throw SMLWorkflowSurfaceError.invalidTask(task)
        }
        if [.approve, .refuse, .rollback].contains(action),
           !Self.validTaskRevision(expectedState["task_revision"]) {
            throw SMLWorkflowSurfaceError.taskRevisionRequired
        }

        var arguments: SMLObject = [
            "workflow_id": .string(surface.workflowID),
            "workflow_version": .string(surface.workflowVersion),
        ]
        if action == .start, !initialState.isEmpty {
            arguments["initial_state"] = .object(initialState)
        }
        let envelope = SMLCommandEnvelope(
            commandID: commandID(),
            actor: actor,
            role: surface.role,
            task: task,
            op: action.runtimeOperation,
            arguments: arguments,
            scope: scope,
            expectedState: expectedState,
            issuedAtEpoch: issuedAtEpoch
        )
        let report = envelope.validate()
        guard report.isValid else {
            throw SMLWorkflowSurfaceError.invalidEnvelope(
                report.errors.map(\.description)
            )
        }
        return envelope
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
}

/// Shared typed choke point for generated transports. It cannot bypass structural validation,
/// authenticated host authority, replay admission, or the runtime's state machine.
public struct SMLCommandGateway: Sendable {
    private let runtime: SMLRuntime
    private let replayGuard: any SMLCommandReplayGuard

    public init(runtime: SMLRuntime, replayGuard: any SMLCommandReplayGuard) {
        self.runtime = runtime
        self.replayGuard = replayGuard
    }

    public func submit(
        _ command: SMLCommandEnvelope,
        authority: SMLCommandAuthority,
        nowEpoch: Double
    ) async throws -> SMLCommandResult {
        let admitted = try await SMLCommandAdmission.admit(
            command,
            authority: authority,
            nowEpoch: nowEpoch,
            replayGuard: replayGuard
        )
        return try await runtime.submit(admitted)
    }

    /// Capability dispatch has a distinct path because the opaque claim must be returned to the
    /// coordinator; submitting the same envelope through the generic bus cannot actuate a driver.
    public func claimCapability(
        _ command: SMLCommandEnvelope,
        authority: SMLCommandAuthority,
        nowEpoch: Double
    ) async throws -> SMLClaimedCapability {
        let admitted = try await SMLCommandAdmission.admit(
            command,
            authority: authority,
            nowEpoch: nowEpoch,
            replayGuard: replayGuard
        )
        return try await runtime.claimCapability(admitted)
    }

    /// Consumes the exact opaque dispatch and routed outcome in the same durable task transition.
    public func completeCapability(
        _ command: SMLCommandEnvelope,
        claimed: SMLClaimedCapability,
        routed: SMLRoutedCapabilityOutcome,
        authority: SMLCommandAuthority,
        nowEpoch: Double
    ) async throws -> SMLCommandResult {
        let admitted = try await SMLCommandAdmission.admit(
            command,
            authority: authority,
            nowEpoch: nowEpoch,
            replayGuard: replayGuard
        )
        return try await runtime.completeCapability(
            admitted, claimed: claimed, routed: routed
        )
    }
}
