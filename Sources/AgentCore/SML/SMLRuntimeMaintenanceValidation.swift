import Foundation

extension SMLRuntimeStore {
    static func isTerminal(_ status: SMLTaskStatus) -> Bool {
        [.completed, .failed, .escalated, .rolledBack, .refused].contains(status)
    }

    static func isArchivable(_ task: SMLRuntimeTask) -> Bool {
        isTerminal(task.status) && task.capabilityClaim == nil && task.waitingApprovalOwner == nil
    }

    static func validateMaintenanceSnapshot(_ snapshot: SMLRuntimeSnapshot,
        archived: [SMLRuntimeArchivedTask]) throws {
        func require(_ valid: Bool, _ reason: String) throws {
            if !valid { throw SMLRuntimeStoreError.decoding(reason) }
        }
        try require(snapshot.schemaVersion == SMLRuntimeSnapshot.currentSchemaVersion, "maintenance snapshot schema mismatch")
        try require(snapshot.archivedTaskCount == archived.count
            && (snapshot.archiveRoot == nil) == archived.isEmpty, "archive count/root mismatch")
        if let root = snapshot.archiveRoot { try require(isArchiveDigest(root), "invalid archive root") }
        for (key, record) in snapshot.workflows {
            try require(key == SMLRuntimeSnapshot.workflowStorageKey(id: record.workflow.id,
                version: record.workflow.version), "workflow storage key mismatch")
            try require(SMLValidationSupport.identifierIsValid(record.role)
                && record.installedAtEpoch.isFinite
                && SMLWorkflowValidator.validate(record.workflow).isValid, "invalid pinned workflow \(key)")
        }
        for (id, version) in snapshot.activeWorkflowVersions {
            try require(snapshot.workflows[SMLRuntimeSnapshot.workflowStorageKey(id: id, version: version)] != nil,
                "active workflow reference is missing")
        }
        try require(snapshot.replayClaims.allSatisfy { !$0.key.isEmpty && $0.value.isFinite }, "invalid replay claims")
        var allTaskIDs = Set<String>()
        var allReceiptIDs = Set<String>()
        for (key, task) in snapshot.tasks {
            try require(key == task.taskID, "task storage key mismatch")
            guard let workflow = snapshot.workflows[SMLRuntimeSnapshot.workflowStorageKey(
                id: task.workflowID, version: task.workflowVersion)] else {
                throw SMLRuntimeStoreError.decoding("task pinned workflow missing: \(key)")
            }
            let receipts = try task.receiptIDs.map { id -> SMLRuntimeReceipt in
                guard let receipt = snapshot.receipts[id], receipt.id == id else {
                    throw SMLRuntimeStoreError.decoding("task receipt missing or key mismatch: \(id)")
                }
                return receipt
            }
            try validateTaskHistory(task, workflow: workflow, receipts: receipts)
            try require(allTaskIDs.insert(key).inserted, "duplicate task identity")
            for receipt in receipts { try require(allReceiptIDs.insert(receipt.id).inserted, "duplicate receipt identity") }
        }
        try require(Set(snapshot.receipts.keys) == allReceiptIDs, "live receipt has no owning task")
        for archivedTask in archived {
            try require(isArchivable(archivedTask.task), "archive contains unfinished work or unresolved claim")
            try require(allTaskIDs.insert(archivedTask.task.taskID).inserted, "task identity exists in live and archived state")
            try validateTaskHistory(archivedTask.task, workflow: archivedTask.workflow, receipts: archivedTask.receipts)
            for receipt in archivedTask.receipts {
                try require(allReceiptIDs.insert(receipt.id).inserted, "duplicate archived receipt identity")
            }
        }
    }

    static func validateTaskHistory(_ task: SMLRuntimeTask, workflow record: SMLRuntimeWorkflowRecord,
        receipts: [SMLRuntimeReceipt]) throws {
        func require(_ valid: Bool, _ reason: String) throws {
            if !valid { throw SMLRuntimeStoreError.decoding("task \(task.taskID): \(reason)") }
        }
        let workflow = record.workflow
        try require(task.schemaVersion == SMLRuntimeTask.currentSchemaVersion && task.revision >= 0,
            "invalid schema/revision")
        try require(SMLValidationSupport.identifierIsValid(task.taskID)
            && record.role == task.role && workflow.id == task.workflowID && workflow.version == task.workflowVersion,
            "identity/workflow mismatch")
        try require(SMLWorkflowValidator.validate(workflow).isValid, "invalid archived workflow")
        try require(workflow.instructions.contains { $0.id == task.currentInstructionID }, "instruction is missing")
        try require(task.createdAtEpoch.isFinite && task.updatedAtEpoch.isFinite
            && task.updatedAtEpoch >= task.createdAtEpoch, "invalid task timestamps")
        try require(task.retryCounts.allSatisfy { retry in retry.value >= 0 && workflow.instructions.contains { $0.id == retry.key } },
            "negative retry count")
        let fields = Dictionary(uniqueKeysWithValues: workflow.stateSchema.map { ($0.name, $0) })
        for (name, value) in task.state {
            guard let field = fields[name] else { throw SMLRuntimeStoreError.decoding("unknown stored state field \(name)") }
            let matches: Bool
            switch (field.type, value) {
            case (_, .null): matches = field.nullable
            case (.string, .string), (.number, .number), (.boolean, .bool), (.object, .object), (.array, .array): matches = true
            case (.integer, .number(let number)):
                var original = number
                var rounded = Decimal()
                NSDecimalRound(&rounded, &original, 0, .plain)
                matches = rounded == number
            default: matches = false
            }
            try require(matches, "stored state field \(name) has wrong type")
        }
        try require(task.receiptIDs == receipts.map(\.id) && Set(task.receiptIDs).count == receipts.count,
            "receipt ordering or uniqueness mismatch")
        try require(!receipts.isEmpty && receipts.first?.kind == .taskCreated, "task creation receipt missing")
        for receipt in receipts {
            try require(receipt.schemaVersion == SMLRuntimeReceipt.currentSchemaVersion && receipt.taskID == task.taskID
                && receipt.workflowID == task.workflowID
                && (receipt.workflowVersion == nil || receipt.workflowVersion == task.workflowVersion)
                && receipt.createdAtEpoch.isFinite, "receipt schema or ownership mismatch")
            if let instruction = receipt.instructionID {
                try require(workflow.instructions.contains { $0.id == instruction }, "receipt instruction missing")
            }
        }
        if let claim = task.capabilityClaim {
            try require(task.status == .waitingCapability && !claim.dispatchID.isEmpty
                && !claim.leaseID.isEmpty && claim.instructionID == task.currentInstructionID
                && claim.claimedAtEpoch.isFinite, "invalid interrupted claim")
            try require(receipts.contains { $0.kind == .capabilityClaimed
                && $0.payload["dispatch_id"] == .string(claim.dispatchID) }, "claim receipt missing")
        }
        if task.status == .waitingApproval { try require(task.waitingApprovalOwner != nil, "approval owner missing") }
        if isTerminal(task.status) { try require(task.capabilityClaim == nil && task.waitingApprovalOwner == nil,
            "terminal task retains pending authority") }
    }

    static func validateBackupGraph(root: String?, objects: [String: Data]) throws -> [SMLRuntimeArchivedTask] {
        var visited = Set<String>()
        func walk(_ digest: String, depth: Int) throws -> [SMLRuntimeArchivedTask] {
            guard isArchiveDigest(digest), depth <= 128, visited.insert(digest).inserted,
                  let data = objects[digest], maintenanceDigest(data) == digest else {
                throw SMLRuntimeStoreError.decoding("backup archive missing, corrupt, cyclic, or too deep")
            }
            let object = try JSONDecoder().decode(SMLRuntimeArchiveObject.self, from: data)
            if let task = object.task {
                guard object.pivot == nil, object.left == nil, object.right == nil else {
                    throw SMLRuntimeStoreError.decoding("malformed backup leaf")
                }
                return [task]
            }
            guard let pivot = object.pivot, let left = object.left, let right = object.right else {
                throw SMLRuntimeStoreError.decoding("malformed backup branch")
            }
            let lower = try walk(left, depth: depth + 1)
            let upper = try walk(right, depth: depth + 1)
            guard let last = lower.last, let first = upper.first,
                  last.task.taskID < pivot, first.task.taskID == pivot else {
                throw SMLRuntimeStoreError.decoding("backup archive ordering mismatch")
            }
            return lower + upper
        }
        let tasks = try root.map { try walk($0, depth: 0) } ?? []
        guard Set(objects.keys) == visited else { throw SMLRuntimeStoreError.decoding("unreferenced objects in backup") }
        return tasks
    }
}
