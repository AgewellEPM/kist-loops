import Foundation

public enum SMLWorkflowREPLCompileError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyInput
    case unknownCommand(String)
    case actionDenied(String)
    case unexpectedArguments(String)
    case invalidJSON(String)

    public var description: String {
        switch self {
        case .emptyInput: return "empty workflow REPL input"
        case .unknownCommand(let command): return "unknown workflow REPL command: \(command)"
        case .actionDenied(let command): return "workflow REPL command is not granted: \(command)"
        case .unexpectedArguments(let command): return "unexpected arguments for workflow REPL command: \(command)"
        case .invalidJSON(let reason): return "invalid workflow REPL JSON object: \(reason)"
        }
    }
}

public enum SMLWorkflowREPLCompilation: Sendable, Equatable {
    case local(String)
    case command(SMLCommandEnvelope)
    case exit
}

/// A workflow-scoped compiler. The workflow id/version/role are fixed by its admitted surface, so a
/// line can select only a lifecycle action and task—not redirect execution to another workflow.
public struct SMLWorkflowREPLCompiler: Sendable {
    public let surface: SMLWorkflowSurface
    public let allowedActions: Set<SMLWorkflowControlAction>
    private let compiler: SMLWorkflowCommandCompiler

    public init(
        surface: SMLWorkflowSurface,
        actor: String,
        allowedActions: Set<SMLWorkflowControlAction>? = nil,
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() }
    ) {
        self.surface = surface
        self.allowedActions = allowedActions ?? Set(SMLWorkflowControlAction.allCases)
        compiler = SMLWorkflowCommandCompiler(
            surface: surface, actor: actor, commandID: commandID, taskID: taskID
        )
    }

    public func compile(
        _ line: String,
        issuedAtEpoch: Double,
        defaultTaskID: String? = nil
    ) throws -> SMLWorkflowREPLCompilation {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SMLWorkflowREPLCompileError.emptyInput }
        let (verb, tail) = splitHead(trimmed)

        switch verb {
        case "help":
            guard tail.isEmpty else { throw SMLWorkflowREPLCompileError.unexpectedArguments(verb) }
            return .local(helpText)
        case "schema":
            guard tail.isEmpty else { throw SMLWorkflowREPLCompileError.unexpectedArguments(verb) }
            return .local(surface.schemaSummary)
        case "exit", "quit":
            guard tail.isEmpty else { throw SMLWorkflowREPLCompileError.unexpectedArguments(verb) }
            return .exit
        case "describe":
            try require(.describe, verb: verb)
            guard tail.isEmpty else { throw SMLWorkflowREPLCompileError.unexpectedArguments(verb) }
            return .command(try compiler.compile(action: .describe, issuedAtEpoch: issuedAtEpoch))
        case "start", "run":
            try require(.start, verb: verb)
            let parsed = try parseStart(tail)
            return .command(try compiler.compile(
                action: .start,
                task: parsed.task,
                initialState: parsed.state,
                issuedAtEpoch: issuedAtEpoch
            ))
        case "watch":
            return try taskCommand(.watch, verb: verb, tail: tail, defaultTaskID: defaultTaskID, issuedAtEpoch: issuedAtEpoch)
        case "approve":
            return try taskCommand(.approve, verb: verb, tail: tail, defaultTaskID: defaultTaskID, issuedAtEpoch: issuedAtEpoch)
        case "refuse":
            return try taskCommand(.refuse, verb: verb, tail: tail, defaultTaskID: defaultTaskID, issuedAtEpoch: issuedAtEpoch)
        case "rollback":
            return try taskCommand(.rollback, verb: verb, tail: tail, defaultTaskID: defaultTaskID, issuedAtEpoch: issuedAtEpoch)
        case "receipts":
            return try taskCommand(.receipts, verb: verb, tail: tail, defaultTaskID: defaultTaskID, issuedAtEpoch: issuedAtEpoch)
        default:
            throw SMLWorkflowREPLCompileError.unknownCommand(verb)
        }
    }

    public var helpText: String {
        [
            surface.schemaSummary,
            "graph:",
            surface.graphSummary,
            "commands:",
            surface.grammar(allowedActions: allowedActions),
            "help",
            "schema",
            "exit",
            "Approve, refuse, and rollback require the task_revision returned by watch.",
        ].joined(separator: "\n")
    }

    private func require(_ action: SMLWorkflowControlAction, verb: String) throws {
        guard allowedActions.contains(action) else {
            throw SMLWorkflowREPLCompileError.actionDenied(verb)
        }
    }

    private func taskCommand(
        _ action: SMLWorkflowControlAction,
        verb: String,
        tail: String,
        defaultTaskID: String?,
        issuedAtEpoch: Double
    ) throws -> SMLWorkflowREPLCompilation {
        try require(action, verb: verb)
        let parsed = try parseTaskAndExpectedState(tail, defaultTaskID: defaultTaskID)
        return .command(try compiler.compile(
            action: action,
            task: parsed.task,
            expectedState: parsed.expectedState,
            issuedAtEpoch: issuedAtEpoch
        ))
    }

    private func parseStart(_ tail: String) throws -> (task: String?, state: SMLObject) {
        guard !tail.isEmpty else { return (nil, [:]) }
        if tail.first == "{" {
            return (nil, try decodeObject(tail))
        }
        let (task, remainder) = splitHead(tail)
        guard !task.isEmpty else { return (nil, [:]) }
        var stateText = remainder
        if stateText.hasPrefix("--state") {
            stateText = String(stateText.dropFirst("--state".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let state = stateText.isEmpty ? [:] : try decodeObject(stateText)
        return (task, state)
    }

    private func parseTaskAndExpectedState(
        _ tail: String,
        defaultTaskID: String?
    ) throws -> (task: String?, expectedState: SMLObject) {
        guard !tail.isEmpty else { return (defaultTaskID, [:]) }
        if tail.first == "{" {
            return (defaultTaskID, try decodeObject(tail))
        }
        let (task, remainder) = splitHead(tail)
        let expected = remainder.isEmpty ? [:] : try decodeObject(remainder)
        return (task, expected)
    }

    private func decodeObject(_ text: String) throws -> SMLObject {
        guard let data = text.data(using: .utf8) else {
            throw SMLWorkflowREPLCompileError.invalidJSON("input is not UTF-8")
        }
        do {
            return try SMLWireCodec.decodeOpenObject(
                from: data,
                limits: .init(maximumBytes: 256 * 1_024, maximumDepth: 16, maximumNodes: 8_192)
            )
        } catch {
            throw SMLWorkflowREPLCompileError.invalidJSON(String(describing: error))
        }
    }

    private func splitHead(_ text: String) -> (String, String) {
        guard let boundary = text.firstIndex(where: { $0.isWhitespace }) else {
            return (text, "")
        }
        let head = String(text[..<boundary])
        let tail = String(text[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (head, tail)
    }
}

public struct SMLWorkflowREPLResponse: Sendable, Equatable {
    public let output: String
    public let command: SMLCommandEnvelope?
    public let result: SMLCommandResult?
    public let shouldExit: Bool

    public init(
        output: String,
        command: SMLCommandEnvelope? = nil,
        result: SMLCommandResult? = nil,
        shouldExit: Bool = false
    ) {
        self.output = output
        self.command = command
        self.result = result
        self.shouldExit = shouldExit
    }
}

/// Stateful convenience for a host terminal. Authentication/leases are resolved by the host after
/// compilation, using the exact generated task and operation; a model or line cannot mint authority.
public actor SMLWorkflowREPLSession {
    public typealias AuthorityResolver = @Sendable (
        _ command: SMLCommandEnvelope
    ) async throws -> SMLCommandAuthority

    private let compiler: SMLWorkflowREPLCompiler
    private let gateway: SMLCommandGateway
    private let authorityResolver: AuthorityResolver
    private let clock: @Sendable () -> Double
    private var lastTaskID: String?

    public init(
        compiler: SMLWorkflowREPLCompiler,
        gateway: SMLCommandGateway,
        authorityResolver: @escaping AuthorityResolver,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.compiler = compiler
        self.gateway = gateway
        self.authorityResolver = authorityResolver
        self.clock = clock
    }

    public func submit(_ line: String) async throws -> SMLWorkflowREPLResponse {
        let now = clock()
        switch try compiler.compile(line, issuedAtEpoch: now, defaultTaskID: lastTaskID) {
        case .local(let output):
            return SMLWorkflowREPLResponse(output: output)
        case .exit:
            return SMLWorkflowREPLResponse(output: "Leaving \(compiler.surface.workflowID).", shouldExit: true)
        case .command(let command):
            let authority = try await authorityResolver(command)
            let result = try await gateway.submit(command, authority: authority, nowEpoch: now)
            if command.op == SMLRuntimeCommandOperation.workflowRun {
                lastTaskID = command.task
            }
            return SMLWorkflowREPLResponse(
                output: SMLREPLRenderer.render(result),
                command: command,
                result: result
            )
        }
    }
}
