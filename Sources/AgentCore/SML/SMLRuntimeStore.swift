import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
    case capabilityClaimed = "capability_claimed"
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

/// Durable single-flight lock acquired before a host driver may perform external work.
public struct SMLCapabilityClaimRecord: Sendable, Codable, Equatable {
    public let dispatchID: String
    public let driverID: String
    public let instructionID: String
    public let stateDigest: String
    public let commandID: String
    public let actor: String
    public let leaseID: String
    public let claimedAtEpoch: Double

    public init(
        dispatchID: String,
        driverID: String,
        instructionID: String,
        stateDigest: String,
        commandID: String,
        actor: String,
        leaseID: String,
        claimedAtEpoch: Double
    ) {
        self.dispatchID = dispatchID
        self.driverID = driverID
        self.instructionID = instructionID
        self.stateDigest = stateDigest
        self.commandID = commandID
        self.actor = actor
        self.leaseID = leaseID
        self.claimedAtEpoch = claimedAtEpoch
    }

    enum CodingKeys: String, CodingKey {
        case dispatchID = "dispatch_id"
        case driverID = "driver_id"
        case instructionID = "instruction_id"
        case stateDigest = "state_digest"
        case commandID = "command_id"
        case actor
        case leaseID = "lease_id"
        case claimedAtEpoch = "claimed_at_epoch"
    }
}

public struct SMLRuntimeTask: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var taskID: String
    public var role: String
    public var workflowID: String
    public var workflowVersion: String
    /// Monotonic optimistic-concurrency token for every durable task mutation.
    public var revision: Int
    public var currentInstructionID: String
    public var status: SMLTaskStatus
    public var createdAtEpoch: Double
    public var updatedAtEpoch: Double
    public var state: SMLObject
    public var waitingApprovalOwner: String?
    public var capabilityClaim: SMLCapabilityClaimRecord?
    public var retryCounts: [String: Int]
    public var receiptIDs: [String]

    public init(
        schemaVersion: Int = SMLRuntimeTask.currentSchemaVersion,
        taskID: String,
        role: String,
        workflowID: String,
        workflowVersion: String,
        revision: Int = 0,
        currentInstructionID: String,
        status: SMLTaskStatus = .ready,
        createdAtEpoch: Double,
        updatedAtEpoch: Double,
        state: SMLObject = [:],
        waitingApprovalOwner: String? = nil,
        capabilityClaim: SMLCapabilityClaimRecord? = nil,
        retryCounts: [String: Int] = [:],
        receiptIDs: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.taskID = taskID
        self.role = role
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.revision = revision
        self.currentInstructionID = currentInstructionID
        self.status = status
        self.createdAtEpoch = createdAtEpoch
        self.updatedAtEpoch = updatedAtEpoch
        self.state = state
        self.waitingApprovalOwner = waitingApprovalOwner
        self.capabilityClaim = capabilityClaim
        self.retryCounts = retryCounts
        self.receiptIDs = receiptIDs
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case taskID = "task_id"
        case role
        case workflowID = "workflow_id"
        case workflowVersion = "workflow_version"
        case revision = "task_revision"
        case currentInstructionID = "current_instruction_id"
        case status
        case createdAtEpoch = "created_at_epoch"
        case updatedAtEpoch = "updated_at_epoch"
        case state
        case waitingApprovalOwner = "waiting_approval_owner"
        case capabilityClaim = "capability_claim"
        case retryCounts = "retry_counts"
        case receiptIDs = "receipt_ids"
    }

    public init(from decoder: Decoder) throws {
        try self.init(from: decoder, requireRevision: false)
    }

    init(from decoder: Decoder, requireRevision: Bool) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported SML task schema \(schemaVersion)"
            )
        }
        taskID = try container.decode(String.self, forKey: .taskID)
        role = try container.decode(String.self, forKey: .role)
        workflowID = try container.decode(String.self, forKey: .workflowID)
        workflowVersion = try container.decode(String.self, forKey: .workflowVersion)
        if requireRevision {
            revision = try container.decode(Int.self, forKey: .revision)
        } else {
            revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        }
        guard revision >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .revision,
                in: container,
                debugDescription: "SML task revision cannot be negative"
            )
        }
        currentInstructionID = try container.decode(String.self, forKey: .currentInstructionID)
        status = try container.decode(SMLTaskStatus.self, forKey: .status)
        createdAtEpoch = try container.decode(Double.self, forKey: .createdAtEpoch)
        updatedAtEpoch = try container.decode(Double.self, forKey: .updatedAtEpoch)
        state = try container.decode(SMLObject.self, forKey: .state)
        waitingApprovalOwner = try container.decodeIfPresent(
            String.self, forKey: .waitingApprovalOwner
        )
        capabilityClaim = try container.decodeIfPresent(
            SMLCapabilityClaimRecord.self, forKey: .capabilityClaim
        )
        retryCounts = try container.decode([String: Int].self, forKey: .retryCounts)
        receiptIDs = try container.decode([String].self, forKey: .receiptIDs)
    }
}

/// Schema v2 cannot use the task's standalone legacy decoder because a missing revision would reset
/// its optimistic-concurrency token. The enclosing snapshot selects this strict representation.
private struct SMLRuntimeTaskWithRequiredRevision: Decodable {
    let value: SMLRuntimeTask

    init(from decoder: Decoder) throws {
        value = try SMLRuntimeTask(from: decoder, requireRevision: true)
    }
}

public struct SMLRuntimeReceipt: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public let kind: SMLRuntimeReceiptKind
    public let taskID: String
    public let workflowID: String
    public let workflowVersion: String?
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
        workflowVersion: String? = nil,
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
        self.workflowVersion = workflowVersion
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
        case workflowVersion = "workflow_version"
        case instructionID = "instruction_id"
        case commandID = "command_id"
        case actor
        case leaseID = "lease_id"
        case createdAtEpoch = "created_at_epoch"
        case payload
    }
}

public struct SMLRuntimeSnapshot: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    /// Exact workflow revisions, keyed by `workflowStorageKey(id:version:)`.
    public var workflows: [String: SMLRuntimeWorkflowRecord]
    /// The revision selected for new tasks. Existing tasks remain pinned to their stored version.
    public var activeWorkflowVersions: [String: String]
    public var tasks: [String: SMLRuntimeTask]
    public var receipts: [String: SMLRuntimeReceipt]
    public var replayClaims: [String: Double]

    public init(
        schemaVersion: Int = SMLRuntimeSnapshot.currentSchemaVersion,
        workflows: [String: SMLRuntimeWorkflowRecord] = [:],
        activeWorkflowVersions: [String: String] = [:],
        tasks: [String: SMLRuntimeTask] = [:],
        receipts: [String: SMLRuntimeReceipt] = [:],
        replayClaims: [String: Double] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.workflows = workflows
        self.activeWorkflowVersions = activeWorkflowVersions
        self.tasks = tasks
        self.receipts = receipts
        self.replayClaims = replayClaims
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case workflows, tasks, receipts
        case activeWorkflowVersions = "active_workflow_versions"
        case replayClaims = "replay_claims"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 || schemaVersion == Self.currentSchemaVersion else {
            throw SMLRuntimeStoreError.unsupportedSchema(schemaVersion)
        }
        workflows = try container.decode(
            [String: SMLRuntimeWorkflowRecord].self, forKey: .workflows
        )
        receipts = try container.decode([String: SMLRuntimeReceipt].self, forKey: .receipts)
        replayClaims = try container.decode(
            [String: Double].self, forKey: .replayClaims
        )
        if schemaVersion == Self.currentSchemaVersion {
            activeWorkflowVersions = try container.decode(
                [String: String].self, forKey: .activeWorkflowVersions
            )
            let strictTasks = try container.decode(
                [String: SMLRuntimeTaskWithRequiredRevision].self,
                forKey: .tasks
            )
            tasks = strictTasks.mapValues { $0.value }
        } else {
            activeWorkflowVersions = try container.decodeIfPresent(
                [String: String].self, forKey: .activeWorkflowVersions
            ) ?? [:]
            tasks = try container.decode([String: SMLRuntimeTask].self, forKey: .tasks)
        }
    }

    public static func workflowStorageKey(id: String, version: String) -> String {
        "\(id)#\(version)"
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
    /// Exact schema-v1 bytes retained before this store first publishes schema v2.
    ///
    /// Rollback tooling can restore this deterministic sibling and then launch a schema-v1-only
    /// binary. The backup is write-once: later migrations and restores never replace it.
    public nonisolated let schemaV1BackupURL: URL

    public init(fileURL: URL, clock: @escaping @Sendable () -> Double = {
        Date().timeIntervalSince1970
    }) {
        self.fileURL = fileURL
        self.clock = clock
        self.schemaV1BackupURL = Self.schemaV1BackupURL(forRuntimeURL: fileURL)
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

    public static func schemaV1BackupURL(forRuntimeURL runtimeURL: URL) -> URL {
        runtimeURL.deletingLastPathComponent().appendingPathComponent(
            runtimeURL.lastPathComponent + ".schema-v1.backup",
            isDirectory: false
        )
    }

    public func load() throws -> SMLRuntimeSnapshot {
        try withSidecarLock(exclusive: false) {
            try loadUnlocked()
        }
    }

    private func loadUnlocked() throws -> SMLRuntimeSnapshot {
        guard let data = try readRuntimeFileIfPresentUnlocked() else {
            return SMLRuntimeSnapshot()
        }
        do {
            let decoded = try JSONDecoder().decode(SMLRuntimeSnapshot.self, from: data)
            switch decoded.schemaVersion {
            case SMLRuntimeSnapshot.currentSchemaVersion:
                return decoded
            case 1:
                var workflows: [String: SMLRuntimeWorkflowRecord] = [:]
                var active: [String: String] = [:]
                for record in decoded.workflows.values {
                    let workflow = record.workflow
                    let key = SMLRuntimeSnapshot.workflowStorageKey(
                        id: workflow.id, version: workflow.version
                    )
                    workflows[key] = record
                    active[workflow.id] = workflow.version
                }
                return SMLRuntimeSnapshot(
                    workflows: workflows,
                    activeWorkflowVersions: active,
                    tasks: decoded.tasks,
                    receipts: decoded.receipts,
                    replayClaims: decoded.replayClaims
                )
            default:
                throw SMLRuntimeStoreError.unsupportedSchema(decoded.schemaVersion)
            }
        } catch let error as SMLRuntimeStoreError {
            throw error
        } catch {
            throw SMLRuntimeStoreError.decoding(String(describing: error))
        }
    }

    /// Read through an owner-bound descriptor and verify that the pathname still names that exact
    /// regular file. This keeps ordinary loads on the same fail-closed path as migration/restore;
    /// `Data(contentsOf:)` would follow a substituted runtime.json symlink.
    private func readRuntimeFileIfPresentUnlocked() throws -> Data? {
        let directory = fileURL.deletingLastPathComponent()
        let directoryDescriptor = try Self.openStoreDirectory(directory)
        defer { _ = close(directoryDescriptor) }

        var descriptor: Int32
        repeat {
            descriptor = openat(
                directoryDescriptor,
                fileURL.lastPathComponent,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        } while descriptor < 0 && errno == EINTR
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else {
            throw Self.posixIOError("open runtime store")
        }
        defer { _ = close(descriptor) }

        var descriptorInfo = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0,
              fstatat(
                  directoryDescriptor,
                  fileURL.lastPathComponent,
                  &pathInfo,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              Self.isOwnedRegular(descriptorInfo),
              Self.sameIdentity(descriptorInfo, pathInfo) else {
            throw SMLRuntimeStoreError.io(
                "runtime store is not an owner-owned stable regular file"
            )
        }

        let data = try Self.readAll(descriptor)
        guard fstat(descriptor, &descriptorInfo) == 0,
              fstatat(
                  directoryDescriptor,
                  fileURL.lastPathComponent,
                  &pathInfo,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              Self.isOwnedRegular(descriptorInfo),
              Self.sameIdentity(descriptorInfo, pathInfo) else {
            throw SMLRuntimeStoreError.io("runtime store changed while it was read")
        }
        return data
    }

    public func save(_ snapshot: SMLRuntimeSnapshot) throws {
        try withSidecarLock(exclusive: true) {
            try saveUnlocked(snapshot)
        }
    }

    /// Restore the exact write-once schema-v1 snapshot for an explicit binary rollback.
    ///
    /// This does not remove or rewrite the backup. Callers must stop all runtime users before
    /// switching binaries; the sidecar lock only serializes cooperating store instances.
    public func restoreSchemaV1Backup() throws {
        try withSidecarLock(exclusive: true) {
            let backup = try readSchemaV1BackupUnlocked()
            try Self.writeDurableAtomic(backup, to: fileURL)
        }
    }

    private func saveUnlocked(_ snapshot: SMLRuntimeSnapshot) throws {
        guard snapshot.schemaVersion == SMLRuntimeSnapshot.currentSchemaVersion else {
            throw SMLRuntimeStoreError.unsupportedSchema(snapshot.schemaVersion)
        }
        guard snapshot.tasks.values.allSatisfy({
            $0.schemaVersion == SMLRuntimeTask.currentSchemaVersion && $0.revision >= 0
        }) else {
            throw SMLRuntimeStoreError.decoding(
                "runtime snapshot contains an invalid task schema or revision"
            )
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try preserveSchemaV1BackupIfNeededUnlocked()
            try Self.writeDurableAtomic(data, to: fileURL)
        } catch let error as EncodingError {
            throw SMLRuntimeStoreError.decoding(String(describing: error))
        } catch let error as SMLRuntimeStoreError {
            throw error
        } catch {
            throw SMLRuntimeStoreError.io(String(describing: error))
        }
    }

    public func update<T>(_ body: (inout SMLRuntimeSnapshot) throws -> T) throws -> T {
        try withSidecarLock(exclusive: true) {
            var snapshot = try loadUnlocked()
            let result = try body(&snapshot)
            try saveUnlocked(snapshot)
            return result
        }
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

    /// Preserve a valid schema-v1 runtime by adding a write-once hard link before v2 replaces the
    /// live pathname. Linking the already-written inode avoids a copy window: the exact bytes are
    /// file-synced first, the new directory entry is created with no-replace semantics, and the
    /// directory entry is synced before v2 publication. Once v2 is renamed into place, the backup
    /// is the sole link to the original inode.
    private func preserveSchemaV1BackupIfNeededUnlocked() throws {
        let directory = fileURL.deletingLastPathComponent()
        let runtimeName = fileURL.lastPathComponent
        let backupName = schemaV1BackupURL.lastPathComponent
        let directoryDescriptor = try Self.openStoreDirectory(directory)
        defer { _ = close(directoryDescriptor) }

        var runtimeDescriptor: Int32
        repeat {
            runtimeDescriptor = openat(
                directoryDescriptor,
                runtimeName,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        } while runtimeDescriptor < 0 && errno == EINTR
        if runtimeDescriptor < 0, errno == ENOENT { return }
        guard runtimeDescriptor >= 0 else {
            throw Self.posixIOError("open runtime store before schema migration")
        }
        defer { _ = close(runtimeDescriptor) }

        var runtimeInfo = stat()
        var runtimePathInfo = stat()
        guard fstat(runtimeDescriptor, &runtimeInfo) == 0,
              fstatat(
                  directoryDescriptor, runtimeName, &runtimePathInfo, AT_SYMLINK_NOFOLLOW
              ) == 0,
              Self.isOwnedRegular(runtimeInfo),
              Self.sameIdentity(runtimeInfo, runtimePathInfo) else {
            throw SMLRuntimeStoreError.io(
                "runtime store is not an owner-owned stable regular file"
            )
        }

        let runtimeBytes = try Self.readAll(runtimeDescriptor)
        let sourceSchema = try Self.decodeSnapshotSchema(
            runtimeBytes, context: "runtime store before schema migration"
        )
        guard sourceSchema == 1 else { return }

        if try Self.validateExistingSchemaV1Backup(
            directoryDescriptor: directoryDescriptor,
            runtimeName: runtimeName,
            backupName: backupName,
            missingIsAllowed: true
        ) != nil {
            return
        }

        // A pre-existing hard link other than the recognized backup makes write-once preservation
        // ambiguous. Refuse rather than publish v2 and risk losing the only rollback-compatible file.
        guard runtimeInfo.st_nlink == 1,
              fchmod(runtimeDescriptor, mode_t(0o600)) == 0 else {
            throw SMLRuntimeStoreError.io(
                "schema-v1 runtime cannot be secured for write-once backup"
            )
        }
        try Self.synchronizeFile(runtimeDescriptor)

        guard fstat(runtimeDescriptor, &runtimeInfo) == 0,
              fstatat(
                  directoryDescriptor, runtimeName, &runtimePathInfo, AT_SYMLINK_NOFOLLOW
              ) == 0,
              Self.sameIdentity(runtimeInfo, runtimePathInfo),
              runtimeInfo.st_nlink == 1,
              (runtimeInfo.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw SMLRuntimeStoreError.io(
                "schema-v1 runtime changed before write-once backup"
            )
        }

        guard linkat(
            directoryDescriptor, runtimeName,
            directoryDescriptor, backupName,
            0
        ) == 0 else {
            let code = errno
            if code == EEXIST {
                _ = try Self.validateExistingSchemaV1Backup(
                    directoryDescriptor: directoryDescriptor,
                    runtimeName: runtimeName,
                    backupName: backupName,
                    missingIsAllowed: false
                )
                return
            }
            throw Self.posixIOError("publish schema-v1 runtime backup", code: code)
        }

        _ = try Self.validateExistingSchemaV1Backup(
            directoryDescriptor: directoryDescriptor,
            runtimeName: runtimeName,
            backupName: backupName,
            missingIsAllowed: false
        )
        try Self.synchronizeDirectory(directoryDescriptor)
    }

    private func readSchemaV1BackupUnlocked() throws -> Data {
        let directory = fileURL.deletingLastPathComponent()
        let directoryDescriptor = try Self.openStoreDirectory(directory)
        defer { _ = close(directoryDescriptor) }
        guard let data = try Self.validateExistingSchemaV1Backup(
            directoryDescriptor: directoryDescriptor,
            runtimeName: fileURL.lastPathComponent,
            backupName: schemaV1BackupURL.lastPathComponent,
            missingIsAllowed: false
        ) else {
            throw SMLRuntimeStoreError.io("schema-v1 runtime backup is unavailable")
        }
        return data
    }

    private static func validateExistingSchemaV1Backup(
        directoryDescriptor: Int32,
        runtimeName: String,
        backupName: String,
        missingIsAllowed: Bool
    ) throws -> Data? {
        var descriptor: Int32
        repeat {
            descriptor = openat(
                directoryDescriptor,
                backupName,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        } while descriptor < 0 && errno == EINTR
        if descriptor < 0, errno == ENOENT, missingIsAllowed { return nil }
        if descriptor < 0, errno == ENOENT {
            throw SMLRuntimeStoreError.io("schema-v1 runtime backup is unavailable")
        }
        guard descriptor >= 0 else {
            throw posixIOError("open schema-v1 runtime backup")
        }
        defer { _ = close(descriptor) }

        var descriptorInfo = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0,
              fstatat(
                  directoryDescriptor, backupName, &pathInfo, AT_SYMLINK_NOFOLLOW
              ) == 0,
              isOwnedRegular(descriptorInfo),
              sameIdentity(descriptorInfo, pathInfo),
              (descriptorInfo.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw SMLRuntimeStoreError.io(
                "schema-v1 runtime backup is not an owner-only stable regular file"
            )
        }

        if descriptorInfo.st_nlink != 1 {
            // A crash after linkat but before v2 rename can legitimately leave the live v1 path and
            // backup as the only two names for one inode. No other multi-link shape is accepted.
            var runtimeInfo = stat()
            guard descriptorInfo.st_nlink == 2,
                  fstatat(
                      directoryDescriptor, runtimeName, &runtimeInfo, AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  sameIdentity(descriptorInfo, runtimeInfo) else {
                throw SMLRuntimeStoreError.io(
                    "schema-v1 runtime backup has an unrecognized hard link"
                )
            }
        }

        let data = try readAll(descriptor)
        let schema = try decodeSnapshotSchema(data, context: "schema-v1 runtime backup")
        guard schema == 1 else {
            throw SMLRuntimeStoreError.decoding(
                "schema-v1 runtime backup contains schema \(schema)"
            )
        }
        return data
    }

    private static func decodeSnapshotSchema(_ data: Data, context: String) throws -> Int {
        do {
            return try JSONDecoder().decode(SMLRuntimeSnapshot.self, from: data).schemaVersion
        } catch let error as SMLRuntimeStoreError {
            throw error
        } catch {
            throw SMLRuntimeStoreError.decoding(
                "\(context): \(String(describing: error))"
            )
        }
    }

    private static func openStoreDirectory(_ directory: URL) throws -> Int32 {
        var descriptor: Int32
        repeat {
            descriptor = open(
                directory.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        } while descriptor < 0 && errno == EINTR
        guard descriptor >= 0 else {
            throw posixIOError("open runtime store directory")
        }
        return descriptor
    }

    private static func isOwnedRegular(_ info: stat) -> Bool {
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && info.st_uid == geteuid()
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func readAll(_ descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixIOError("read runtime store file")
            }
            result.append(buffer, count: count)
        }
    }

    /// A stable sidecar coordinates the whole read-modify-write transaction across store actors and
    /// processes. Locking runtime.json itself would be ineffective because atomic saves replace it.
    private func withSidecarLock<T>(
        exclusive: Bool,
        _ body: () throws -> T
    ) throws -> T {
        let directory = fileURL.deletingLastPathComponent()
        let basename = fileURL.lastPathComponent
        guard !basename.isEmpty, basename != ".", basename != "..", !basename.contains("/") else {
            throw SMLRuntimeStoreError.io("invalid runtime store filename")
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } catch {
            throw SMLRuntimeStoreError.io("create runtime store directory: \(error)")
        }

        let lockPath = fileURL.path + ".lock"
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW
        let descriptor = Self.openOrCreateLock(path: lockPath, flags: flags)
        guard descriptor >= 0 else {
            throw SMLRuntimeStoreError.io("open runtime store lock (errno \(errno))")
        }
        defer { _ = close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw SMLRuntimeStoreError.io("runtime store lock is not an owner-only regular file")
        }

        let operation = exclusive ? LOCK_EX : LOCK_SH
        var lockResult: Int32
        repeat { lockResult = flock(descriptor, operation) }
        while lockResult < 0 && errno == EINTR
        guard lockResult == 0 else {
            throw SMLRuntimeStoreError.io("acquire runtime store lock (errno \(errno))")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// APFS/noowners volumes can transiently report ENOENT during concurrent O_CREAT opens. Open
    /// existing first, race an exclusive create, and retry the EEXIST/ENOENT handoff fail-closed.
    private static func openOrCreateLock(path: String, flags: Int32) -> Int32 {
        for _ in 0..<128 {
            var existing: Int32
            repeat { existing = open(path, flags) }
            while existing < 0 && errno == EINTR
            if existing >= 0 { return existing }
            let openError = errno
            guard openError == ENOENT else { return -1 }

            var created: Int32
            repeat {
                created = open(path, flags | O_CREAT | O_EXCL, mode_t(0o600))
            } while created < 0 && errno == EINTR
            if created >= 0 { return created }
            let createError = errno
            if createError == EEXIST || createError == ENOENT { continue }
            errno = createError
            return -1
        }
        errno = EAGAIN
        return -1
    }

    /// Publish a complete replacement before returning from a durable mutation. The temporary file
    /// lives beside the destination so `renameat` is atomic, and the parent directory sync makes the
    /// new directory entry survive a host crash after a capability claim has been acknowledged.
    private static func writeDurableAtomic(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let basename = url.lastPathComponent

        var directoryDescriptor: Int32
        repeat {
            directoryDescriptor = open(
                directory.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        } while directoryDescriptor < 0 && errno == EINTR
        guard directoryDescriptor >= 0 else {
            throw posixIOError("open runtime store directory")
        }
        defer { _ = close(directoryDescriptor) }

        let temporaryName = ".\(basename).\(UUID().uuidString).tmp"
        var descriptor: Int32
        repeat {
            descriptor = openat(
                directoryDescriptor,
                temporaryName,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        } while descriptor < 0 && errno == EINTR
        guard descriptor >= 0 else {
            throw posixIOError("create runtime store temporary")
        }

        var published = false
        defer {
            if descriptor >= 0 { _ = close(descriptor) }
            if !published { _ = unlinkat(directoryDescriptor, temporaryName, 0) }
        }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw SMLRuntimeStoreError.io(
                "runtime store temporary is not an owner-only regular file"
            )
        }
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(0o077)) == 0 else {
            throw SMLRuntimeStoreError.io(
                "runtime store temporary permissions are not owner-only"
            )
        }

        try writeAll(data, descriptor: descriptor)
        try synchronizeFile(descriptor)

        let closeResult = close(descriptor)
        descriptor = -1
        guard closeResult == 0 else {
            throw posixIOError("close runtime store temporary")
        }

        guard renameat(directoryDescriptor, temporaryName, directoryDescriptor, basename) == 0 else {
            throw posixIOError("publish runtime store")
        }
        published = true
        try synchronizeDirectory(directoryDescriptor)
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixIOError("write runtime store temporary")
                }
                guard written > 0 else {
                    throw SMLRuntimeStoreError.io(
                        "write runtime store temporary returned zero bytes"
                    )
                }
                offset += written
            }
        }
    }

    private static func synchronizeFile(_ descriptor: Int32) throws {
        var result: Int32
        repeat { result = fsync(descriptor) }
        while result < 0 && errno == EINTR
        guard result == 0 else {
            throw posixIOError("sync runtime store temporary")
        }

        #if canImport(Darwin)
        repeat { result = fcntl(descriptor, F_FULLFSYNC) }
        while result < 0 && errno == EINTR
        if result < 0 {
            let code = errno
            guard code == EINVAL || code == ENOTSUP else {
                throw posixIOError("full-sync runtime store temporary", code: code)
            }
            // Some Darwin filesystems do not implement F_FULLFSYNC; the successful fsync above is
            // the strongest durability primitive they expose.
        }
        #endif
    }

    private static func synchronizeDirectory(_ descriptor: Int32) throws {
        var result: Int32
        repeat { result = fsync(descriptor) }
        while result < 0 && errno == EINTR
        guard result == 0 else {
            throw posixIOError("sync runtime store directory")
        }
    }

    private static func posixIOError(
        _ operation: String,
        code: Int32 = errno
    ) -> SMLRuntimeStoreError {
        SMLRuntimeStoreError.io(
            "\(operation): \(String(cString: strerror(code))) (errno \(code))"
        )
    }
}
