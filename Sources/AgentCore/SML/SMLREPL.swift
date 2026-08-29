import Foundation

public enum SMLREPLCompileError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyInput
    case unknownCommand(String)
    case missingArgument(String)
    case invalidIdentifier(String)

    public var description: String {
        switch self {
        case .emptyInput:
            return "empty SML REPL input"
        case .unknownCommand(let command):
            return "unknown SML REPL command: \(command)"
        case .missingArgument(let name):
            return "missing SML REPL argument: \(name)"
        case .invalidIdentifier(let value):
            return "invalid SML REPL identifier: \(value)"
        }
    }
}

public struct SMLREPLCompiler: Sendable {
    private let actor: String
    private let role: String
    private let commandID: @Sendable () -> String
    private let taskID: @Sendable () -> String

    public init(
        actor: String,
        role: String,
        commandID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        taskID: @escaping @Sendable () -> String = {
            "task-" + UUID().uuidString.lowercased()
        }
    ) {
        self.actor = actor
        self.role = role
        self.commandID = commandID
        self.taskID = taskID
    }

    public func compile(_ line: String, issuedAtEpoch: Double) throws -> SMLCommandEnvelope {
        let parts = line
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .map(String.init)
        guard let verb = parts.first else { throw SMLREPLCompileError.emptyInput }

        let envelope: SMLCommandEnvelope
        switch verb {
        case "status":
            envelope = command(op: SMLRuntimeCommandOperation.status, task: "runtime",
                               issuedAtEpoch: issuedAtEpoch)
        case "roles":
            envelope = command(op: SMLRuntimeCommandOperation.rolesList, task: "runtime",
                               issuedAtEpoch: issuedAtEpoch)
        case "workflows":
            var arguments: SMLObject = [:]
            if parts.count > 1 { arguments["role_id"] = .string(try identifier(parts[1])) }
            envelope = command(
                op: SMLRuntimeCommandOperation.workflowsList,
                task: "runtime",
                arguments: arguments,
                issuedAtEpoch: issuedAtEpoch
            )
        case "inspect":
            let workflow = try required(parts, index: 1, name: "workflow_id")
            envelope = command(
                op: SMLRuntimeCommandOperation.workflowInspect,
                task: "runtime",
                arguments: ["workflow_id": .string(try identifier(workflow))],
                issuedAtEpoch: issuedAtEpoch
            )
        case "run":
            let workflow = try required(parts, index: 1, name: "workflow_id")
            let task = parts.count > 2 ? try identifier(parts[2]) : taskID()
            envelope = command(
                op: SMLRuntimeCommandOperation.workflowRun,
                task: task,
                arguments: ["workflow_id": .string(try identifier(workflow))],
                issuedAtEpoch: issuedAtEpoch
            )
        case "run-matching":
            let category = try required(parts, index: 1, name: "category")
            let task = parts.count > 2 ? try identifier(parts[2]) : taskID()
            envelope = command(
                op: SMLRuntimeCommandOperation.workflowRunMatching,
                task: task,
                arguments: [
                    "filters": .object(["category": .string(try identifier(category))]),
                ],
                issuedAtEpoch: issuedAtEpoch
            )
        case "watch":
            envelope = command(
                op: SMLRuntimeCommandOperation.taskWatch,
                task: try identifier(try required(parts, index: 1, name: "task_id")),
                issuedAtEpoch: issuedAtEpoch
            )
        case "approve":
            envelope = command(
                op: SMLRuntimeCommandOperation.taskApprove,
                task: try identifier(try required(parts, index: 1, name: "task_id")),
                issuedAtEpoch: issuedAtEpoch
            )
        case "refuse":
            envelope = command(
                op: SMLRuntimeCommandOperation.taskRefuse,
                task: try identifier(try required(parts, index: 1, name: "task_id")),
                issuedAtEpoch: issuedAtEpoch
            )
        case "rollback":
            envelope = command(
                op: SMLRuntimeCommandOperation.taskRollback,
                task: try identifier(try required(parts, index: 1, name: "task_id")),
                issuedAtEpoch: issuedAtEpoch
            )
        case "receipts":
            let task = parts.count > 1 ? try identifier(parts[1]) : "runtime"
            envelope = command(op: SMLRuntimeCommandOperation.receiptsList, task: task,
                               issuedAtEpoch: issuedAtEpoch)
        default:
            throw SMLREPLCompileError.unknownCommand(verb)
        }

        let report = envelope.validate()
        guard report.isValid else {
            throw SMLREPLCompileError.invalidIdentifier(
                report.errors.map(\.description).joined(separator: "; ")
            )
        }
        return envelope
    }

    private func command(
        op: String,
        task: String,
        arguments: SMLObject = [:],
        issuedAtEpoch: Double
    ) -> SMLCommandEnvelope {
        SMLCommandEnvelope(
            commandID: commandID(),
            actor: actor,
            role: role,
            task: task,
            op: op,
            arguments: arguments,
            issuedAtEpoch: issuedAtEpoch
        )
    }

    private func required(_ parts: [String], index: Int, name: String) throws -> String {
        guard parts.count > index else { throw SMLREPLCompileError.missingArgument(name) }
        return parts[index]
    }

    private func identifier(_ value: String) throws -> String {
        guard SMLValidationSupport.identifierIsValid(value, maximumLength: 160) else {
            throw SMLREPLCompileError.invalidIdentifier(value)
        }
        return value
    }
}

public enum SMLREPLRenderer {
    public static func render(_ result: SMLCommandResult) -> String {
        switch result.kind {
        case .status:
            guard let status = result.status else { return result.message }
            return [
                "SML runtime",
                "workflows: \(status.workflowCount)",
                "roles: \(status.roleCount)",
                "tasks: \(status.taskCount) active: \(status.activeTaskCount)",
                "receipts: \(status.receiptCount)",
            ].joined(separator: "\n")
        case .roles:
            if result.roles.isEmpty { return "No roles installed." }
            return result.roles.map {
                "\($0.role) workflows:\($0.workflows.count) tasks:\($0.taskCount)"
            }.joined(separator: "\n")
        case .workflows:
            if result.workflows.isEmpty { return "No workflows installed." }
            return result.workflows.map {
                "\($0.id) \($0.version) role:\($0.role) instructions:\($0.instructionCount)"
            }.joined(separator: "\n")
        case .workflow:
            guard let workflow = result.workflow else { return result.message }
            let header = "\(workflow.workflow.id) entry:\(workflow.entrypoint)"
            let body = workflow.instructions.map {
                let targets = $0.targets.isEmpty ? "" : " -> " + $0.targets.joined(separator: ",")
                return "\($0.id) \($0.op.rawValue)\(targets)"
            }
            return ([header] + body).joined(separator: "\n")
        case .task:
            guard let task = result.task else { return result.message }
            let op = task.currentOperation?.rawValue ?? "UNKNOWN"
            var lines = [
                "\(task.taskID) \(task.status.rawValue)",
                "workflow: \(task.workflowID) \(task.workflowVersion)",
                "next: \(task.currentInstructionID) \(op)",
            ]
            if let owner = task.waitingApprovalOwner {
                lines.append("approval: \(owner)")
            }
            lines.append("receipts: \(task.receiptIDs.count)")
            return lines.joined(separator: "\n")
        case .receipts:
            if result.receipts.isEmpty { return "No receipts." }
            return result.receipts.map {
                "\($0.id) \($0.kind.rawValue) task:\($0.taskID)"
            }.joined(separator: "\n")
        }
    }
}
