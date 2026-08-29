import Foundation

public enum SMLTaskStatus: String, Sendable, Codable, Equatable {
    case ready
    case waitingCapability = "waiting_capability"
    case waitingApproval = "waiting_approval"
    case completed
    case escalated
    case rolledBack = "rolled_back"
    case refused
}

public enum SMLRuntimeReceiptKind: String, Sendable, Codable, Equatable {
    case taskCreated = "task_created"
    case checkpoint
    case stepRecorded = "step_recorded"
    case approvalRequested = "approval_requested"
    case approved
    case refused
    case rollback
    case escalated
    case completed
    case receiptEmitted = "receipt_emitted"
}

public struct SMLRuntimeWorkflowRecord: Sendable, Codable, Equatable {
    public let role: String
    public let workflow: SMLWorkflow
    public let installedAtEpoch: Double

    public init(role: String, workflow: SMLWorkflow, installedAtEpoch: Double) {
        self.role = role
        self.workflow = workflow
        self.installedAtEpoch = installedAtEpoch
    }

    enum CodingKeys: String, CodingKey {
        case role, workflow
        case installedAtEpoch = "installed_at_epoch"
    }
}

public struct SMLRuntimeTask: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var taskID: String
    public var role: String
    public var workflowID: String
    public var workflowVersion: String
    public var currentInstructionID: String
    public var status: SMLTaskStatus
    public var createdAtEpoch: Double
    public var updatedAtEpoch: Double
    public var state: SMLObject
    public var waitingApprovalOwner: String?
    public var retryCounts: [String: Int]
    public var receiptIDs: [String]

    public init(
        schemaVersion: Int = SMLRuntimeTask.currentSchemaVersion,
        taskID: String,
        role: String,
        workflowID: String,
        workflowVersion: String,
        currentInstructionID: String,
        status: SMLTaskStatus = .ready,
        createdAtEpoch: Double,
        updatedAtEpoch: Double,
        state: SMLObject = [:],
        waitingApprovalOwner: String? = nil,
        retryCounts: [String: Int] = [:],
        receiptIDs: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.taskID = taskID
        self.role = role
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.currentInstructionID = currentInstructionID
        self.status = status
        self.createdAtEpoch = createdAtEpoch
        self.updatedAtEpoch = updatedAtEpoch
        self.state = state
        self.waitingApprovalOwner = waitingApprovalOwner
        self.retryCounts = retryCounts
        self.receiptIDs = receiptIDs
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case taskID = "task_id"
        case role
        case workflowID = "workflow_id"
        case workflowVersion = "workflow_version"
        case currentInstructionID = "current_instruction_id"
        case status
        case createdAtEpoch = "created_at_epoch"
        case updatedAtEpoch = "updated_at_epoch"
        case state
        case waitingApprovalOwner = "waiting_approval_owner"
        case retryCounts = "retry_counts"
        case receiptIDs = "receipt_ids"
    }
}

public struct SMLRuntimeReceipt: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public let kind: SMLRuntimeReceiptKind
    public let taskID: String
    public let workflowID: String
    public let instructionID: String?
    public let commandID: String
    public let actor: String
    public let leaseID: String
    public let createdAtEpoch: Double
    public let payload: SMLObject

    public init(
        schemaVersion: Int = SMLRuntimeReceipt.currentSchemaVersion,
        id: String,
        kind: SMLRuntimeReceiptKind,
        taskID: String,
        workflowID: String,
        instructionID: String?,
        commandID: String,
        actor: String,
        leaseID: String,
        createdAtEpoch: Double,
        payload: SMLObject = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = kind
        self.taskID = taskID
        self.workflowID = workflowID
        self.instructionID = instructionID
        self.commandID = commandID
        self.actor = actor
        self.leaseID = leaseID
        self.createdAtEpoch = createdAtEpoch
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id, kind
        case taskID = "task_id"
        case workflowID = "workflow_id"
        case instructionID = "instruction_id"
        case commandID = "command_id"
        case actor
        case leaseID = "lease_id"
        case createdAtEpoch = "created_at_epoch"
        case payload
    }
}

public struct SMLRuntimeSnapshot: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var workflows: [String: SMLRuntimeWorkflowRecord]
    public var tasks: [String: SMLRuntimeTask]
    public var receipts: [String: SMLRuntimeReceipt]
    public var replayClaims: [String: Double]

    public init(
        schemaVersion: Int = SMLRuntimeSnapshot.currentSchemaVersion,
        workflows: [String: SMLRuntimeWorkflowRecord] = [:],
        tasks: [String: SMLRuntimeTask] = [:],
        receipts: [String: SMLRuntimeReceipt] = [:],
        replayClaims: [String: Double] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.workflows = workflows
        self.tasks = tasks
        self.receipts = receipts
        self.replayClaims = replayClaims
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case workflows, tasks, receipts
        case replayClaims = "replay_claims"
    }
}

public enum SMLRuntimeStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedSchema(Int)
    case io(String)
    case decoding(String)

    public var description: String {
        switch self {
        case .unsupportedSchema(let version):
            return "unsupported SML runtime store schema \(version)"
        case .io(let reason):
            return "SML runtime store I/O failed: \(reason)"
        case .decoding(let reason):
            return "SML runtime store decoding failed: \(reason)"
        }
    }
}

public actor SMLRuntimeStore: SMLCommandReplayGuard {
    private let fileURL: URL
    private let clock: @Sendable () -> Double

    public init(fileURL: URL, clock: @escaping @Sendable () -> Double = {
        Date().timeIntervalSince1970
    }) {
        self.fileURL = fileURL
        self.clock = clock
    }

    public init(path: String, clock: @escaping @Sendable () -> Double = {
        Date().timeIntervalSince1970
    }) {
        self.init(fileURL: URL(fileURLWithPath: path), clock: clock)
    }

    public static func defaultURL(projectRoot: String) -> URL {
        URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".kist", isDirectory: true)
            .appendingPathComponent("sml", isDirectory: true)
            .appendingPathComponent("runtime.json", isDirectory: false)
    }

    public func load() throws -> SMLRuntimeSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SMLRuntimeSnapshot()
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw SMLRuntimeStoreError.io(String(describing: error))
        }
        do {
            let snapshot = try JSONDecoder().decode(SMLRuntimeSnapshot.self, from: data)
            guard snapshot.schemaVersion == SMLRuntimeSnapshot.currentSchemaVersion else {
                throw SMLRuntimeStoreError.unsupportedSchema(snapshot.schemaVersion)
            }
            return snapshot
        } catch let error as SMLRuntimeStoreError {
            throw error
        } catch {
            throw SMLRuntimeStoreError.decoding(String(describing: error))
        }
    }

    public func save(_ snapshot: SMLRuntimeSnapshot) throws {
        guard snapshot.schemaVersion == SMLRuntimeSnapshot.currentSchemaVersion else {
            throw SMLRuntimeStoreError.unsupportedSchema(snapshot.schemaVersion)
        }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch let error as EncodingError {
            throw SMLRuntimeStoreError.decoding(String(describing: error))
        } catch {
            throw SMLRuntimeStoreError.io(String(describing: error))
        }
    }

    public func update<T>(_ body: (inout SMLRuntimeSnapshot) throws -> T) throws -> T {
        var snapshot = try load()
        let result = try body(&snapshot)
        try save(snapshot)
        return result
    }

    public func claim(commandID: String, expiresAtEpoch: Double) throws -> Bool {
        try update { snapshot in
            let now = clock()
            snapshot.replayClaims = snapshot.replayClaims.filter { _, expiry in
                expiry > now
            }
            guard snapshot.replayClaims[commandID] == nil else { return false }
            snapshot.replayClaims[commandID] = expiresAtEpoch
            return true
        }
    }
}
