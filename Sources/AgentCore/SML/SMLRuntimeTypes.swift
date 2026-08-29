import Foundation

public enum SMLRuntimeCommandOperation {
    public static let status = "runtime.status"
    public static let rolesList = "roles.list"
    public static let workflowsList = "workflows.list"
    public static let workflowInspect = "workflow.inspect"
    public static let workflowRun = "workflow.run"
    public static let workflowRunMatching = "workflow.run_matching"
    public static let taskWatch = "task.watch"
    public static let taskApprove = "task.approve_request"
    public static let taskRefuse = "task.refuse_request"
    public static let taskRollback = "task.rollback"
    public static let taskRecordStep = "task.record_step"
    public static let receiptsList = "receipts.list"

    public static let all: Set<String> = [
        status, rolesList, workflowsList, workflowInspect, workflowRun, workflowRunMatching,
        taskWatch, taskApprove, taskRefuse, taskRollback, taskRecordStep, receiptsList,
    ]
}

public enum SMLCommandResultKind: String, Sendable, Codable, Equatable {
    case status
    case roles
    case workflows
    case workflow
    case task
    case receipts
}

public struct SMLRuntimeStatusSummary: Sendable, Codable, Equatable {
    public let workflowCount: Int
    public let roleCount: Int
    public let taskCount: Int
    public let activeTaskCount: Int
    public let receiptCount: Int

    public init(
        workflowCount: Int,
        roleCount: Int,
        taskCount: Int,
        activeTaskCount: Int,
        receiptCount: Int
    ) {
        self.workflowCount = workflowCount
        self.roleCount = roleCount
        self.taskCount = taskCount
        self.activeTaskCount = activeTaskCount
        self.receiptCount = receiptCount
    }

    enum CodingKeys: String, CodingKey {
        case workflowCount = "workflow_count"
        case roleCount = "role_count"
        case taskCount = "task_count"
        case activeTaskCount = "active_task_count"
        case receiptCount = "receipt_count"
    }
}

public struct SMLRoleProjection: Sendable, Codable, Equatable {
    public let role: String
    public let workflows: [String]
    public let taskCount: Int

    public init(role: String, workflows: [String], taskCount: Int) {
        self.role = role
        self.workflows = workflows
        self.taskCount = taskCount
    }

    enum CodingKeys: String, CodingKey {
        case role, workflows
        case taskCount = "task_count"
    }
}

public struct SMLWorkflowProjection: Sendable, Codable, Equatable {
    public let id: String
    public let version: String
    public let name: String
    public let role: String
    public let sourceKind: SMLWorkflowSourceKind
    public let triggerKind: SMLTrigger.Kind
    public let instructionCount: Int

    public init(
        id: String,
        version: String,
        name: String,
        role: String,
        sourceKind: SMLWorkflowSourceKind,
        triggerKind: SMLTrigger.Kind,
        instructionCount: Int
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.role = role
        self.sourceKind = sourceKind
        self.triggerKind = triggerKind
        self.instructionCount = instructionCount
    }

    enum CodingKeys: String, CodingKey {
        case id, version, name, role
        case sourceKind = "source_kind"
        case triggerKind = "trigger_kind"
        case instructionCount = "instruction_count"
    }
}

public struct SMLInstructionProjection: Sendable, Codable, Equatable {
    public let id: String
    public let op: SMLInstructionOperation
    public let source: String?
    public let capability: String?
    public let purpose: String?
    public let verifier: String?
    public let workflow: String?
    public let targets: [String]

    public init(
        id: String,
        op: SMLInstructionOperation,
        source: String?,
        capability: String?,
        purpose: String?,
        verifier: String?,
        workflow: String?,
        targets: [String]
    ) {
        self.id = id
        self.op = op
        self.source = source
        self.capability = capability
        self.purpose = purpose
        self.verifier = verifier
        self.workflow = workflow
        self.targets = targets
    }
}

public struct SMLWorkflowInspection: Sendable, Codable, Equatable {
    public let workflow: SMLWorkflowProjection
    public let entrypoint: String
    public let instructions: [SMLInstructionProjection]

    public init(
        workflow: SMLWorkflowProjection,
        entrypoint: String,
        instructions: [SMLInstructionProjection]
    ) {
        self.workflow = workflow
        self.entrypoint = entrypoint
        self.instructions = instructions
    }
}

public struct SMLRuntimeReceiptProjection: Sendable, Codable, Equatable {
    public let id: String
    public let kind: SMLRuntimeReceiptKind
    public let taskID: String
    public let workflowID: String
    public let instructionID: String?
    public let actor: String
    public let createdAtEpoch: Double
    public let payload: SMLObject

    public init(receipt: SMLRuntimeReceipt) {
        id = receipt.id
        kind = receipt.kind
        taskID = receipt.taskID
        workflowID = receipt.workflowID
        instructionID = receipt.instructionID
        actor = receipt.actor
        createdAtEpoch = receipt.createdAtEpoch
        payload = receipt.payload
    }

    enum CodingKeys: String, CodingKey {
        case id, kind
        case taskID = "task_id"
        case workflowID = "workflow_id"
        case instructionID = "instruction_id"
        case actor
        case createdAtEpoch = "created_at_epoch"
        case payload
    }
}

public struct SMLTaskProjection: Sendable, Codable, Equatable {
    public let taskID: String
    public let role: String
    public let workflowID: String
    public let workflowVersion: String
    public let status: SMLTaskStatus
    public let currentInstructionID: String
    public let currentOperation: SMLInstructionOperation?
    public let waitingApprovalOwner: String?
    public let state: SMLObject
    public let receiptIDs: [String]

    public init(
        taskID: String,
        role: String,
        workflowID: String,
        workflowVersion: String,
        status: SMLTaskStatus,
        currentInstructionID: String,
        currentOperation: SMLInstructionOperation?,
        waitingApprovalOwner: String?,
        state: SMLObject,
        receiptIDs: [String]
    ) {
        self.taskID = taskID
        self.role = role
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.status = status
        self.currentInstructionID = currentInstructionID
        self.currentOperation = currentOperation
        self.waitingApprovalOwner = waitingApprovalOwner
        self.state = state
        self.receiptIDs = receiptIDs
    }

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case role
        case workflowID = "workflow_id"
        case workflowVersion = "workflow_version"
        case status
        case currentInstructionID = "current_instruction_id"
        case currentOperation = "current_operation"
        case waitingApprovalOwner = "waiting_approval_owner"
        case state
        case receiptIDs = "receipt_ids"
    }
}

public struct SMLCommandResult: Sendable, Codable, Equatable {
    public let kind: SMLCommandResultKind
    public let message: String
    public let status: SMLRuntimeStatusSummary?
    public let roles: [SMLRoleProjection]
    public let workflows: [SMLWorkflowProjection]
    public let workflow: SMLWorkflowInspection?
    public let task: SMLTaskProjection?
    public let receipts: [SMLRuntimeReceiptProjection]

    public init(
        kind: SMLCommandResultKind,
        message: String,
        status: SMLRuntimeStatusSummary? = nil,
        roles: [SMLRoleProjection] = [],
        workflows: [SMLWorkflowProjection] = [],
        workflow: SMLWorkflowInspection? = nil,
        task: SMLTaskProjection? = nil,
        receipts: [SMLRuntimeReceiptProjection] = []
    ) {
        self.kind = kind
        self.message = message
        self.status = status
        self.roles = roles
        self.workflows = workflows
        self.workflow = workflow
        self.task = task
        self.receipts = receipts
    }
}

public enum SMLRuntimeError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidIdentifier(String)
    case unsupportedOperation(String)
    case missingArgument(String)
    case invalidArgument(String)
    case workflowNotInstalled(String)
    case ambiguousWorkflowMatch([String])
    case taskAlreadyExists(String)
    case taskNotFound(String)
    case commandRoleMismatch(expected: String, actual: String)
    case taskWorkflowMissing(String)
    case invalidTaskState(String)
    case currentInstructionCannotBeAdvanced(String)
    case statePatchRejected(String)
    case executionLimitExceeded

    public var description: String {
        switch self {
        case .invalidIdentifier(let value):
            return "invalid SML runtime identifier: \(value)"
        case .unsupportedOperation(let op):
            return "unsupported SML runtime operation: \(op)"
        case .missingArgument(let name):
            return "missing SML runtime command argument: \(name)"
        case .invalidArgument(let reason):
            return "invalid SML runtime command argument: \(reason)"
        case .workflowNotInstalled(let id):
            return "workflow is not installed: \(id)"
        case .ambiguousWorkflowMatch(let ids):
            return "workflow match is ambiguous: \(ids.joined(separator: ", "))"
        case .taskAlreadyExists(let id):
            return "task already exists: \(id)"
        case .taskNotFound(let id):
            return "task not found: \(id)"
        case .commandRoleMismatch(let expected, let actual):
            return "command role \(actual) does not match task role \(expected)"
        case .taskWorkflowMissing(let id):
            return "task references a missing workflow: \(id)"
        case .invalidTaskState(let reason):
            return "invalid SML task state: \(reason)"
        case .currentInstructionCannotBeAdvanced(let id):
            return "current instruction cannot be advanced by this command: \(id)"
        case .statePatchRejected(let reason):
            return "state patch rejected: \(reason)"
        case .executionLimitExceeded:
            return "SML runtime execution limit exceeded"
        }
    }
}
