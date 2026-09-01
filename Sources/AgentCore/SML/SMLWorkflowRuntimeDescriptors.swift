import Foundation

public struct SMLWorkflowModelToolDescriptor: Sendable, Codable, Equatable {
    public let name: String
    public let description: String
    public let parameters: [ToolParameter]

    public init(name: String, description: String, parameters: [ToolParameter]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    public init(_ tool: ToolSpec) {
        self.init(
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters
        )
    }
}

public enum SMLWorkflowREPLCommandKind: String, Sendable, Codable, Equatable {
    case local
    case runtime
}

public enum SMLWorkflowREPLJSONBodyKind: String, Sendable, Codable, Equatable {
    case none
    case workflowInput = "workflow_input"
    case expectedState = "expected_state"
}

public struct SMLWorkflowREPLCommandDescriptor: Sendable, Codable, Equatable {
    public let kind: SMLWorkflowREPLCommandKind
    public let action: SMLWorkflowControlAction?
    public let verb: String
    public let aliases: [String]
    public let usage: String
    public let summary: String
    public let requiresTask: Bool
    public let changesTaskState: Bool
    public let jsonBodyKind: SMLWorkflowREPLJSONBodyKind
    public let jsonFields: [SMLWorkflowFieldDescriptor]

    public init(
        kind: SMLWorkflowREPLCommandKind,
        action: SMLWorkflowControlAction?,
        verb: String,
        aliases: [String] = [],
        usage: String,
        summary: String,
        requiresTask: Bool,
        changesTaskState: Bool,
        jsonBodyKind: SMLWorkflowREPLJSONBodyKind = .none,
        jsonFields: [SMLWorkflowFieldDescriptor] = []
    ) {
        self.kind = kind
        self.action = action
        self.verb = verb
        self.aliases = Array(Set(aliases)).sorted()
        self.usage = usage
        self.summary = summary
        self.requiresTask = requiresTask
        self.changesTaskState = changesTaskState
        self.jsonBodyKind = jsonBodyKind
        self.jsonFields = jsonFields.sorted {
            if $0.required != $1.required { return $0.required && !$1.required }
            return $0.name < $1.name
        }
    }
}

public struct SMLWorkflowREPLExample: Sendable, Codable, Equatable {
    public let verb: String
    public let line: String
    public let summary: String

    public init(verb: String, line: String, summary: String) {
        self.verb = verb
        self.line = line
        self.summary = summary
    }
}

enum SMLWorkflowREPLDescriptorFormatter {
    static func modelCommandIndex(
        commands: [SMLWorkflowREPLCommandDescriptor],
        examples: [SMLWorkflowREPLExample],
        allowedActions: Set<SMLWorkflowControlAction>
    ) -> String {
        let modelCommands = commands.filter { command in
            guard command.kind == .runtime,
                  let action = command.action else { return false }
            return allowedActions.contains(action)
        }
        let modelVerbs = Set(modelCommands.map(\.verb))
        let modelExamples = examples.filter { modelVerbs.contains($0.verb) }
        return commandIndex(commands: modelCommands, examples: modelExamples)
    }

    static func commandIndex(
        commands: [SMLWorkflowREPLCommandDescriptor],
        examples: [SMLWorkflowREPLExample]
    ) -> String {
        """
        Structured REPL commands:
        \(commands.isEmpty ? "none" : commands.map(commandLine).joined(separator: "\n"))

        REPL examples:
        \(examples.isEmpty ? "none" : examples.map(exampleLine).joined(separator: "\n"))
        """
    }

    static func commandLine(_ command: SMLWorkflowREPLCommandDescriptor) -> String {
        let aliases = command.aliases.isEmpty
            ? ""
            : " aliases:\(command.aliases.joined(separator: ","))"
        let fields = command.jsonFields.isEmpty
            ? ""
            : " fields:\(command.jsonFields.map(\.name).joined(separator: ","))"
        return [
            "\(command.verb)\(aliases) [\(command.kind.rawValue)]",
            "usage:\(command.usage)",
            "task:\(command.requiresTask)",
            "mutates:\(command.changesTaskState)",
            "json:\(command.jsonBodyKind.rawValue)\(fields)",
            "- \(command.summary)",
        ].joined(separator: " ")
    }

    static func exampleLine(_ example: SMLWorkflowREPLExample) -> String {
        "\(example.line) - \(example.summary)"
    }
}

public struct SMLWorkflowREPLDescriptor: Sendable, Codable, Equatable {
    public let allowedActions: [SMLWorkflowControlAction]
    public let grammar: String
    public let helpText: String
    public let commands: [SMLWorkflowREPLCommandDescriptor]
    public let examples: [SMLWorkflowREPLExample]

    public init(
        allowedActions: [SMLWorkflowControlAction],
        grammar: String,
        helpText: String,
        commands: [SMLWorkflowREPLCommandDescriptor] = [],
        examples: [SMLWorkflowREPLExample] = []
    ) {
        self.allowedActions = allowedActions
        self.grammar = grammar
        self.helpText = helpText
        self.commands = commands.sorted {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.verb < $1.verb
        }
        self.examples = examples.sorted {
            if $0.verb != $1.verb { return $0.verb < $1.verb }
            return $0.line < $1.line
        }
    }

    enum CodingKeys: String, CodingKey {
        case allowedActions, grammar, helpText, commands, examples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            allowedActions: try container.decode(
                [SMLWorkflowControlAction].self,
                forKey: .allowedActions
            ),
            grammar: try container.decode(String.self, forKey: .grammar),
            helpText: try container.decode(String.self, forKey: .helpText),
            commands: try container.decodeIfPresent(
                [SMLWorkflowREPLCommandDescriptor].self,
                forKey: .commands
            ) ?? [],
            examples: try container.decodeIfPresent(
                [SMLWorkflowREPLExample].self,
                forKey: .examples
            ) ?? []
        )
    }
}

public struct SMLWorkflowModelDescriptor: Sendable, Codable, Equatable {
    public let requiresNativeTools: Bool
    public let allowedActions: [SMLWorkflowControlAction]
    public let tool: SMLWorkflowModelToolDescriptor
    public let maximumAdvisoryBytes: Int
    public let maximumCommandRounds: Int

    public init(
        requiresNativeTools: Bool,
        allowedActions: [SMLWorkflowControlAction],
        tool: SMLWorkflowModelToolDescriptor,
        maximumAdvisoryBytes: Int,
        maximumCommandRounds: Int
    ) {
        self.requiresNativeTools = requiresNativeTools
        self.allowedActions = allowedActions
        self.tool = tool
        self.maximumAdvisoryBytes = maximumAdvisoryBytes
        self.maximumCommandRounds = maximumCommandRounds
    }
}

/// Stable, codable description of every generated interface for one admitted workflow.
///
/// This value is intentionally authority-neutral. It contains no actor lease, credentials, replay
/// state, runtime handle, provider registry, or executable closure. Hosts can persist or serve it as
/// a descriptor, then route live mutations back through the generated compilers and admission gate.
public struct SMLWorkflowRuntimeDescriptor: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 4

    public let schemaVersion: Int
    public let workflowID: String
    public let workflowVersion: String
    public let workflowName: String
    public let role: String
    public let sourceKind: SMLWorkflowSourceKind
    public let sourceReference: String
    public let sourceDigest: String?
    public let inputs: [SMLWorkflowFieldDescriptor]
    public let outputs: [SMLWorkflowFieldDescriptor]
    public let commands: [SMLWorkflowCommandDescriptor]
    public let schemaSummary: String
    public let graphSummary: String
    public let repl: SMLWorkflowREPLDescriptor
    public let api: SMLWorkflowAPICatalog
    public let model: SMLWorkflowModelDescriptor
    public let onyx: SMLOnyxDriverManifest

    public init(
        schemaVersion: Int = SMLWorkflowRuntimeDescriptor.currentSchemaVersion,
        workflowID: String,
        workflowVersion: String,
        workflowName: String,
        role: String,
        sourceKind: SMLWorkflowSourceKind,
        sourceReference: String,
        sourceDigest: String?,
        inputs: [SMLWorkflowFieldDescriptor],
        outputs: [SMLWorkflowFieldDescriptor],
        commands: [SMLWorkflowCommandDescriptor],
        schemaSummary: String,
        graphSummary: String,
        repl: SMLWorkflowREPLDescriptor,
        api: SMLWorkflowAPICatalog,
        model: SMLWorkflowModelDescriptor,
        onyx: SMLOnyxDriverManifest
    ) {
        self.schemaVersion = schemaVersion
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.workflowName = workflowName
        self.role = role
        self.sourceKind = sourceKind
        self.sourceReference = sourceReference
        self.sourceDigest = sourceDigest
        self.inputs = inputs
        self.outputs = outputs
        self.commands = commands
        self.schemaSummary = schemaSummary
        self.graphSummary = graphSummary
        self.repl = repl
        self.api = api
        self.model = model
        self.onyx = onyx
    }
}

