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
    public let apiCatalog: SMLWorkflowAPICatalog
    public let modelTool: SMLWorkflowModelToolDescriptor
    public let modelRouterToolName: String?
    public let onyxDriver: SMLOnyxDriverManifest
    private let compiler: SMLWorkflowCommandCompiler

    public init(
        surface: SMLWorkflowSurface,
        actor: String,
        allowedActions: Set<SMLWorkflowControlAction>? = nil,
        apiCatalog: SMLWorkflowAPICatalog? = nil,
        modelTool: SMLWorkflowModelToolDescriptor? = nil,
        modelRouterToolName: String? = nil,
        onyxDriver: SMLOnyxDriverManifest? = nil,
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = { "task-" + UUID().uuidString.lowercased() }
    ) {
        self.surface = surface
        self.allowedActions = allowedActions ?? Set(SMLWorkflowControlAction.allCases)
        self.apiCatalog = apiCatalog ?? SMLWorkflowAPICatalog(surface: surface)
        self.modelTool = modelTool ?? SMLWorkflowModelToolDescriptor(surface.modelCommandTool())
        self.modelRouterToolName = modelRouterToolName
        self.onyxDriver = onyxDriver ?? SMLOnyxDriverCompiler.compile(surface: surface)
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
        case "api":
            guard tail.isEmpty else { throw SMLWorkflowREPLCompileError.unexpectedArguments(verb) }
            return .local(apiText)
        case "model":
            guard tail.isEmpty else { throw SMLWorkflowREPLCompileError.unexpectedArguments(verb) }
            return .local(modelText)
        case "onyx":
            guard tail.isEmpty else { throw SMLWorkflowREPLCompileError.unexpectedArguments(verb) }
            return .local(onyxText)
        case "planning":
            guard tail.isEmpty else { throw SMLWorkflowREPLCompileError.unexpectedArguments(verb) }
            return .local(planningText)
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
        let examples = surface.replExamples(allowedActions: allowedActions)
        let exampleLines = examples.isEmpty
            ? []
            : ["examples:"] + examples.map { "\($0.line) - \($0.summary)" }
        return ([
            surface.schemaSummary,
            "graph:",
            surface.graphSummary,
            "commands:",
            surface.grammar(allowedActions: allowedActions),
            "help",
            "schema",
            "api",
            "model",
            "onyx",
            "planning",
            "exit",
        ] + exampleLines + [
            "Approve, refuse, and rollback require the task_revision returned by watch.",
        ]).joined(separator: "\n")
    }

    private var apiText: String {
        let endpoints = apiCatalog.endpoints.map { endpoint in
            let fields = endpoint.bodyFields.isEmpty
                ? "none"
                : endpoint.bodyFields.map(\.name).joined(separator: ",")
            let examples = endpoint.examples.isEmpty
                ? []
                : endpoint.examples.map {
                    "  e.g. \($0.method.rawValue) \($0.path)\(renderBody($0.body)) - \($0.summary)"
                }
            return ([
                "\(endpoint.method.rawValue) \(endpoint.pathTemplate)",
                "action:\(endpoint.action.rawValue)",
                "body:\(endpoint.bodyKind.rawValue)",
                "fields:\(fields)",
                "- \(endpoint.summary)",
            ] + examples).joined(separator: "\n")
        }
        return ([
            "api:",
            "\(apiCatalog.workflowID)@\(apiCatalog.workflowVersion)",
            "base path: \(apiCatalog.basePath)",
        ] + endpoints).joined(separator: "\n")
    }

    private var modelText: String {
        let parameters = modelTool.parameters.isEmpty
            ? ["none"]
            : modelTool.parameters.map {
                "\($0.name):\($0.type) required:\($0.required) - \($0.description)"
            }
        return ([
            "model:",
            "tool: \(modelTool.name)",
            "router: \(modelRouterToolName ?? "none")",
            "description: \(modelTool.description)",
            "parameters:",
        ] + parameters).joined(separator: "\n")
    }

    private var onyxText: String {
        let tools = onyxDriver.tools.isEmpty
            ? ["none"]
            : onyxDriver.tools.map {
                "\($0.instructionID):\($0.operation.rawValue) ref:\($0.reference)"
            }
        let nodes = onyxDriver.skillTree.map {
            let predecessors = $0.prerequisites.isEmpty
                ? "none"
                : $0.prerequisites.joined(separator: ",")
            let successors = $0.successors.isEmpty
                ? "none"
                : $0.successors.joined(separator: ",")
            return "\($0.id):\($0.kind.rawValue) prev:\(predecessors) next:\(successors)"
        }
        return ([
            "onyx:",
            "driver: \(onyxDriver.driverID)",
            "workflow: \(onyxDriver.workflowID)@\(onyxDriver.workflowVersion)",
            "role: \(onyxDriver.role)",
            "model tool: \(onyxDriver.modelToolName)",
            "plan entrypoint: \(onyxDriver.plan.entrypoint)",
            "tools:",
        ] + tools + [
            "skill tree:",
        ] + nodes).joined(separator: "\n")
    }

    private var planningText: String {
        let nodes = onyxDriver.skillTree.map { node in
            guard let planning = node.planning else {
                return "\(node.id):\(node.operation.rawValue) unit:unknown"
            }
            let preconditions = planning.statePreconditions.isEmpty
                ? "none"
                : planning.statePreconditions.joined(separator: ",")
            let outputs = planning.declaredOutputs.isEmpty
                ? "none"
                : planning.declaredOutputs.joined(separator: ",")
            return [
                "\(node.id):\(node.operation.rawValue)",
                "unit:\(planning.unitKind.rawValue)",
                "pre:\(preconditions)",
                "outputs:\(outputs)",
            ].joined(separator: " ")
        }
        return ([
            "planning:",
            "entrypoint: \(onyxDriver.plan.entrypoint)",
        ] + nodes).joined(separator: "\n")
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

    private func renderBody(_ body: SMLObject) -> String {
        body.isEmpty ? "" : " \(Self.renderJSONObject(body))"
    }

    private static func renderJSONObject(_ object: SMLObject) -> String {
        "{" + object.keys.sorted().map { key in
            "\(renderJSONString(key)):\(renderJSONValue(object[key] ?? .null))"
        }.joined(separator: ",") + "}"
    }

    private static func renderJSONValue(_ value: SMLValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let bool):
            return bool ? "true" : "false"
        case .number(let number):
            return NSDecimalNumber(decimal: number).stringValue
        case .string(let string):
            return renderJSONString(string)
        case .array(let array):
            return "[" + array.map(renderJSONValue).joined(separator: ",") + "]"
        case .object(let object):
            return renderJSONObject(object)
        }
    }

    private static func renderJSONString(_ string: String) -> String {
        let data = try? JSONEncoder().encode(string)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? #""""#
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
