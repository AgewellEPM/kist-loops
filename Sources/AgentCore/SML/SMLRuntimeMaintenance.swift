import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct SMLRuntimeMaintenanceReport: Sendable, Codable, Equatable {
    public let action: String
    public let runtimeSHA256: String
    public let liveTaskCount: Int
    public let archivedTaskCount: Int
    public let receiptCount: Int
    public let quarantinedTaskCount: Int
    public let destinationPath: String?
}

struct SMLRuntimeBackupPayload: Codable {
    let schemaVersion: Int
    let createdAtEpoch: Double
    let runtime: Data
    let archiveObjects: [String: Data]
    let hostFiles: [String: Data]?

    init(schemaVersion: Int, createdAtEpoch: Double, runtime: Data,
        archiveObjects: [String: Data], hostFiles: [String: Data]? = nil) {
        self.schemaVersion = schemaVersion
        self.createdAtEpoch = createdAtEpoch
        self.runtime = runtime
        self.archiveObjects = archiveObjects
        self.hostFiles = hostFiles
    }
}

struct SMLRuntimeBackupEnvelope: Codable {
    let schemaVersion: Int
    let sha256: String
    let payload: Data
}

extension SMLRuntimeStore {
    /// A backup is a self-contained, checksummed evidence bundle. The checksum detects corruption;
    /// it does not assert signer identity or grant authority to execute restored workflows.
    public func backup(to destination: URL,
        additionalFiles: @Sendable (SMLRuntimeSnapshot) throws -> [String: Data] = { _ in [:] }
    ) throws -> SMLRuntimeMaintenanceReport {
        try withOfflineMaintenance {
            guard try readRuntimeFileIfPresentUnlocked() != nil else {
                throw SMLRuntimeStoreError.io("runtime store is absent")
            }
            let snapshot = try loadUnlocked()
            var objects: [String: Data] = [:]
            let archived = try collectArchive(root: snapshot.archiveRoot, objects: &objects)
            try Self.validateMaintenanceSnapshot(snapshot, archived: archived)
            let runtime = try Self.maintenanceEncode(snapshot)
            let payload = try Self.maintenanceEncode(SMLRuntimeBackupPayload(schemaVersion: 1,
                createdAtEpoch: clock(), runtime: runtime, archiveObjects: objects,
                hostFiles: try additionalFiles(snapshot)))
            let envelope = SMLRuntimeBackupEnvelope(schemaVersion: 1,
                sha256: Self.maintenanceDigest(payload), payload: payload)
            try Self.publishNewMaintenanceFile(try Self.maintenanceEncode(envelope), to: destination)
            return Self.maintenanceReport("backup", snapshot: snapshot, archived: archived,
                runtime: runtime, destination: destination.path)
        }
    }

    /// Verifies all pinned workflows, task/receipt relationships and the entire archive graph.
    public func verify() throws -> SMLRuntimeMaintenanceReport {
        try withOfflineMaintenance {
            guard let original = try readRuntimeFileIfPresentUnlocked() else {
                throw SMLRuntimeStoreError.io("runtime store is absent")
            }
            let snapshot = try loadUnlocked()
            var objects: [String: Data] = [:]
            let archived = try collectArchive(root: snapshot.archiveRoot, objects: &objects)
            try Self.validateMaintenanceSnapshot(snapshot, archived: archived)
            return Self.maintenanceReport("verify", snapshot: snapshot, archived: archived,
                runtime: original, destination: fileURL.path)
        }
    }

    /// Bounded selection, explicit cutoff, no age inference from filesystem metadata. Active tasks
    /// and unresolved claims are ineligible regardless of age. Every selected receipt is preserved.
    public func archiveTerminalTasks(updatedBeforeEpoch cutoff: Double, maximumTasks: Int = 1_000)
        throws -> SMLRuntimeMaintenanceReport {
        guard cutoff.isFinite, maximumTasks > 0, maximumTasks <= 10_000 else {
            throw SMLRuntimeStoreError.io("archive requires finite cutoff and maximumTasks in 1...10000")
        }
        return try withOfflineMaintenance {
            guard try readRuntimeFileIfPresentUnlocked() != nil else {
                throw SMLRuntimeStoreError.io("runtime store is absent")
            }
            var snapshot = try loadUnlocked()
            var objects: [String: Data] = [:]
            var archived = try collectArchive(root: snapshot.archiveRoot, objects: &objects)
            try Self.validateMaintenanceSnapshot(snapshot, archived: archived)
            let selected = snapshot.tasks.values.filter {
                Self.isArchivable($0) && $0.updatedAtEpoch < cutoff
            }.sorted {
                $0.updatedAtEpoch == $1.updatedAtEpoch ? $0.taskID < $1.taskID : $0.updatedAtEpoch < $1.updatedAtEpoch
            }.prefix(maximumTasks)
            for task in selected {
                let workflow = snapshot.workflows[SMLRuntimeSnapshot.workflowStorageKey(
                    id: task.workflowID, version: task.workflowVersion)]!
                archived.append(SMLRuntimeArchivedTask(task: task, workflow: workflow,
                    receipts: task.receiptIDs.map { snapshot.receipts[$0]! }))
                for id in task.receiptIDs { snapshot.receipts.removeValue(forKey: id) }
                snapshot.tasks.removeValue(forKey: task.taskID)
            }
            // All immutable objects reach stable storage before the root becomes visible.
            snapshot.archiveRoot = try buildArchive(archived)
            snapshot.archivedTaskCount = archived.count
            let liveWorkflowKeys = Set(snapshot.tasks.values.map {
                SMLRuntimeSnapshot.workflowStorageKey(id: $0.workflowID, version: $0.workflowVersion)
            }).union(snapshot.activeWorkflowVersions.map {
                SMLRuntimeSnapshot.workflowStorageKey(id: $0.key, version: $0.value)
            })
            snapshot.workflows = snapshot.workflows.filter { liveWorkflowKeys.contains($0.key) }
            try Self.validateMaintenanceSnapshot(snapshot, archived: archived)
            try saveUnlocked(snapshot)
            try pruneUnreferencedArchiveBranches(root: snapshot.archiveRoot)
            return Self.maintenanceReport("archive", snapshot: snapshot, archived: archived,
                runtime: try Self.readMaintenanceFile(fileURL), destination: archiveObjectsURL.path)
        }
    }

    /// Restore defaults to a fresh runtime. Existing-path recovery requires an exact digest and
    /// durably quarantines the replaced bytes before publication. No unfinished work from an old
    /// backup may automatically dispatch: unclaimed tasks are closed with an unknown-outcome
    /// restoration receipt; existing interrupted claims remain available for explicit reconciliation.
    public func restore(from source: URL, replacingExpectedSHA256 expected: String? = nil,
        restoreAdditionalFiles: @Sendable ([String: Data], String?) throws -> Void = { _, _ in }
    ) throws -> SMLRuntimeMaintenanceReport {
        let envelope = try JSONDecoder().decode(SMLRuntimeBackupEnvelope.self,
            from: Self.readMaintenanceFile(source))
        guard envelope.schemaVersion == 1, Self.maintenanceDigest(envelope.payload) == envelope.sha256 else {
            throw SMLRuntimeStoreError.decoding("backup envelope schema or checksum mismatch")
        }
        let payload = try JSONDecoder().decode(SMLRuntimeBackupPayload.self, from: envelope.payload)
        guard payload.schemaVersion == 1, payload.createdAtEpoch.isFinite else {
            throw SMLRuntimeStoreError.decoding("backup payload schema or timestamp invalid")
        }
        var restored = try JSONDecoder().decode(SMLRuntimeSnapshot.self, from: payload.runtime)
        guard restored.schemaVersion == SMLRuntimeSnapshot.currentSchemaVersion else {
            throw SMLRuntimeStoreError.unsupportedSchema(restored.schemaVersion)
        }
        let backupArchive = try Self.validateBackupGraph(root: restored.archiveRoot, objects: payload.archiveObjects)
        try Self.validateMaintenanceSnapshot(restored, archived: backupArchive)
        return try withOfflineMaintenance {
            let current = try readRuntimeFileIfPresentUnlocked()
            var quarantinePath: String?
            if let current {
                guard let expected, Self.isArchiveDigest(expected), Self.maintenanceDigest(current) == expected else {
                    throw SMLRuntimeStoreError.io("existing runtime requires its exact current --sml-replace-sha256 digest")
                }
                quarantinePath = try quarantineCurrentStore(current).path
                // A valid newer store may know about task IDs absent from the older backup. Keep
                // those tasks, and keep the newer record of overlapping tasks, to prevent replay.
                if let existing = try? loadUnlocked() {
                    for (key, workflow) in existing.workflows {
                        if let prior = restored.workflows[key], prior.role != workflow.role
                            || prior.workflow != workflow.workflow {
                            throw SMLRuntimeStoreError.decoding("conflicting pinned workflow histories: \(key)")
                        }
                        restored.workflows[key] = workflow
                    }
                    for (id, task) in existing.tasks {
                        if let prior = restored.tasks[id], prior.revision == task.revision, prior != task {
                            throw SMLRuntimeStoreError.decoding("conflicting task histories at equal revision: \(id)")
                        }
                    }
                    for (id, receipt) in existing.receipts {
                        if let prior = restored.receipts[id], prior != receipt {
                            throw SMLRuntimeStoreError.decoding("conflicting receipt histories: \(id)")
                        }
                    }
                    for (id, task) in existing.tasks where restored.tasks[id] == nil
                        || task.revision > restored.tasks[id]!.revision {
                        if let previous = restored.tasks[id] {
                            for receiptID in previous.receiptIDs { restored.receipts.removeValue(forKey: receiptID) }
                        }
                        restored.tasks[id] = task
                        for receiptID in task.receiptIDs {
                            guard let receipt = existing.receipts[receiptID] else {
                                throw SMLRuntimeStoreError.decoding("existing task is missing receipts; recovery remains quarantined")
                            }
                            restored.receipts[receiptID] = receipt
                        }
                    }
                    for (id, expiry) in existing.replayClaims {
                        restored.replayClaims[id] = max(restored.replayClaims[id] ?? expiry, expiry)
                    }
                }
            } else if expected != nil {
                throw SMLRuntimeStoreError.io("replacement digest was supplied but runtime is absent")
            }
            var archiveByID = Dictionary(uniqueKeysWithValues: backupArchive.map { ($0.task.taskID, $0) })
            // Recover every surviving leaf, including leaves whose old index root was corrupted.
            // Orphan leaves are safe terminal history; they still reserve their task identity.
            for archived in try existingArchiveLeaves(recoverableObjects: Set(payload.archiveObjects.keys)) {
                if let prior = archiveByID[archived.task.taskID], prior != archived {
                    throw SMLRuntimeStoreError.decoding("conflicting archived histories for \(archived.task.taskID)")
                }
                archiveByID[archived.task.taskID] = archived
            }
            for archived in archiveByID.values {
                if let live = restored.tasks[archived.task.taskID] {
                    guard live.revision <= archived.task.revision else {
                        throw SMLRuntimeStoreError.decoding("live task is newer than its terminal archive")
                    }
                    for receiptID in live.receiptIDs { restored.receipts.removeValue(forKey: receiptID) }
                    restored.tasks.removeValue(forKey: live.taskID)
                }
            }
            var quarantined = 0
            let restoredAt = clock()
            for (id, var task) in restored.tasks where !Self.isTerminal(task.status) && task.capabilityClaim == nil {
                guard task.revision < Int.max else { throw SMLRuntimeStoreError.decoding("task revision overflow during restore") }
                let receiptID = id + ".restore-" + UUID().uuidString.lowercased()
                let receipt = SMLRuntimeReceipt(id: receiptID, kind: .restored, taskID: id,
                    workflowID: task.workflowID, workflowVersion: task.workflowVersion,
                    instructionID: task.currentInstructionID, commandID: "restore-" + envelope.sha256,
                    actor: "host-maintenance", leaseID: "offline-restore", createdAtEpoch: restoredAt,
                    payload: ["outcome": .string("quarantined"), "external_outcome": .string("unknown"),
                        "previous_status": .string(task.status.rawValue), "backup_sha256": .string(envelope.sha256)])
                task.receiptIDs.append(receiptID)
                task.status = .failed
                task.waitingApprovalOwner = nil
                task.revision += 1
                task.updatedAtEpoch = restoredAt
                restored.tasks[id] = task
                restored.receipts[receiptID] = receipt
                quarantined += 1
            }
            // Validation occurs in memory before any restored archive/root publication.
            let archives = archiveByID.values.sorted { $0.task.taskID < $1.task.taskID }
            restored.archivedTaskCount = archives.count
            restored.archiveRoot = archives.isEmpty ? nil : String(repeating: "0", count: 64)
            try Self.validateMaintenanceSnapshot(restored, archived: archives)
            // Backup graph was validated before taking the lock. Publishing a rebuilt tree also
            // incorporates surviving newer task identities from the quarantined current store.
            for (digest, bytes) in payload.archiveObjects {
                let url = try archiveObjectURL(digest)
                if current != nil, FileManager.default.fileExists(atPath: url.path),
                   (try? Self.readMaintenanceFile(url)) != bytes {
                    // Original corrupt bytes are already in the durable quarantine.
                    try Self.writeDurableAtomic(bytes, to: url)
                }
            }
            restored.archiveRoot = try buildArchive(archives)
            try restoreAdditionalFiles(payload.hostFiles ?? [:], quarantinePath)
            try Self.writeDurableAtomic(try Self.maintenanceEncode(restored), to: fileURL)
            return Self.maintenanceReport("restore", snapshot: restored, archived: archives,
                runtime: try Self.readMaintenanceFile(fileURL), quarantined: quarantined,
                destination: quarantinePath ?? fileURL.path)
        }
    }

    func withOfflineMaintenance<T>(_ body: () throws -> T) throws -> T {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("host.lock").path
        let descriptor = Self.openOrCreateLock(path: path, flags: O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Self.posixIOError("open offline SML host lock") }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_nlink == 1 else {
            throw SMLRuntimeStoreError.io("offline SML host lock must be an owned regular file")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw SMLRuntimeStoreError.io("stop the SML host before maintenance; host.lock is held")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try withSidecarLock(exclusive: true, body)
    }

    static func publishNewMaintenanceFile(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".sml-backup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writeDurableAtomic(data, to: temporary)
        guard link(temporary.path, url.path) == 0 else { throw posixIOError("publish new backup without replacing existing file") }
        let descriptor = try openStoreDirectory(directory)
        defer { _ = close(descriptor) }
        try synchronizeDirectory(descriptor)
    }

    func quarantineCurrentStore(_ current: Data) throws -> URL {
        let directory = fileURL.deletingLastPathComponent().appendingPathComponent(
            "quarantine-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try Self.writeDurableAtomic(current, to: directory.appendingPathComponent("runtime.json"))
        if let enumerator = FileManager.default.enumerator(at: archiveObjectsURL,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where url.pathExtension == "json" {
                let data = try Self.readMaintenanceFile(url)
                let target = directory.appendingPathComponent("archive-" + url.lastPathComponent)
                try Self.writeDurableAtomic(data, to: target)
            }
        }
        let parent = try Self.openStoreDirectory(fileURL.deletingLastPathComponent())
        defer { _ = close(parent) }
        try Self.synchronizeDirectory(parent)
        return directory
    }

    func existingArchiveLeaves(recoverableObjects: Set<String>) throws -> [SMLRuntimeArchivedTask] {
        guard let enumerator = FileManager.default.enumerator(at: archiveObjectsURL,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var leaves: [SMLRuntimeArchivedTask] = []
        for case let url as URL in enumerator where url.pathExtension == "json" {
            let data = try Self.readMaintenanceFile(url)
            let digest = url.deletingPathExtension().lastPathComponent
            guard Self.maintenanceDigest(data) == digest else {
                // Never drop an unknown damaged history object: it may reserve task identities
                // absent from this older backup. Only a verified exact replacement permits repair.
                guard recoverableObjects.contains(digest) else {
                    throw SMLRuntimeStoreError.decoding(
                        "damaged archive object is absent from backup; recover its evidence before restore: \(digest)")
                }
                continue
            }
            let object = try JSONDecoder().decode(SMLRuntimeArchiveObject.self, from: data)
            if let task = object.task { leaves.append(task) }
        }
        return leaves
    }

    static func maintenanceReport(_ action: String, snapshot: SMLRuntimeSnapshot,
        archived: [SMLRuntimeArchivedTask], runtime: Data, quarantined: Int = 0,
        destination: String? = nil) -> SMLRuntimeMaintenanceReport {
        SMLRuntimeMaintenanceReport(action: action, runtimeSHA256: maintenanceDigest(runtime),
            liveTaskCount: snapshot.tasks.count, archivedTaskCount: archived.count,
            receiptCount: snapshot.receipts.count + archived.reduce(0) { $0 + $1.receipts.count },
            quarantinedTaskCount: quarantined, destinationPath: destination)
    }
}
