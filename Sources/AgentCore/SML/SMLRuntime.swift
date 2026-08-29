import Foundation

public actor SMLRuntime {
    private let store: SMLRuntimeStore
    private let clock: @Sendable () -> Double

    public init(
        store: SMLRuntimeStore,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.store = store
        self.clock = clock
    }

    public func installWorkflow(
        _ admitted: SMLAdmittedWorkflow,
        role: String
    ) async throws -> SMLWorkflowProjection {
        guard SMLValidationSupport.identifierIsValid(role) else {
            throw SMLRuntimeError.invalidIdentifier(role)
        }
        let now = clock()
        return try await store.update { snapshot in
            let record = SMLRuntimeWorkflowRecord(
                role: role, workflow: admitted.workflow, installedAtEpoch: now
            )
            snapshot.workflows[admitted.id] = record
            return Self.projectWorkflow(record)
        }
    }

    public func status() async throws -> SMLCommandResult {
        let snapshot = try await store.load()
        return SMLCommandResult(
            kind: .status,
            message: "runtime status",
            status: Self.statusSummary(snapshot)
        )
    }

    public func submit(_ admitted: SMLAdmittedCommand) async throws -> SMLCommandResult {
        switch admitted.op {
        case SMLRuntimeCommandOperation.status, "status":
            return try await status()
        case SMLRuntimeCommandOperation.rolesList, "roles":
            return try await listRoles()
        case SMLRuntimeCommandOperation.workflowsList, "workflows":
            return try await listWorkflows(role: roleFilter(from: admitted.command))
        case SMLRuntimeCommandOperation.workflowInspect, "inspect":
            return try await inspectWorkflow(command: admitted.command)
        case SMLRuntimeCommandOperation.workflowRun, "run":
            return try await runWorkflow(command: admitted)
        case SMLRuntimeCommandOperation.workflowRunMatching:
            return try await runMatchingWorkflow(command: admitted)
        case SMLRuntimeCommandOperation.taskWatch, "watch":
            return try await watchTask(command: admitted.command)
        case SMLRuntimeCommandOperation.taskApprove, "task.approve":
            return try await approveTask(command: admitted)
        case SMLRuntimeCommandOperation.taskRefuse, "task.refuse":
            return try await refuseTask(command: admitted)
        case SMLRuntimeCommandOperation.taskRollback, "rollback":
            return try await rollbackTask(command: admitted)
        case SMLRuntimeCommandOperation.taskRecordStep:
            return try await recordStep(command: admitted)
        case SMLRuntimeCommandOperation.receiptsList, "receipts":
            return try await listReceipts(command: admitted.command)
        default:
            throw SMLRuntimeError.unsupportedOperation(admitted.op)
        }
    }

    private func listRoles() async throws -> SMLCommandResult {
        let snapshot = try await store.load()
        return SMLCommandResult(
            kind: .roles,
            message: "roles",
            roles: Self.roleProjections(snapshot)
        )
    }

    private func listWorkflows(role: String?) async throws -> SMLCommandResult {
        let snapshot = try await store.load()
        let workflows = snapshot.workflows.values
            .filter { role == nil || $0.role == role }
            .map(Self.projectWorkflow)
            .sorted { $0.id < $1.id }
        return SMLCommandResult(kind: .workflows, message: "workflows", workflows: workflows)
    }

    private func inspectWorkflow(command: SMLCommandEnvelope) async throws -> SMLCommandResult {
        let workflowID = try Self.workflowID(from: command)
        let snapshot = try await store.load()
        guard let record = snapshot.workflows[workflowID] else {
            throw SMLRuntimeError.workflowNotInstalled(workflowID)
        }
        let inspection = SMLWorkflowInspection(
            workflow: Self.projectWorkflow(record),
            entrypoint: record.workflow.entrypoint,
            instructions: record.workflow.instructions.map(Self.projectInstruction)
        )
        return SMLCommandResult(
            kind: .workflow,
            message: "workflow \(workflowID)",
            workflow: inspection
        )
    }

    private func runWorkflow(command admitted: SMLAdmittedCommand) async throws -> SMLCommandResult {
        try await createTask(command: admitted, workflowID: Self.workflowID(from: admitted.command))
    }

    private func runMatchingWorkflow(command admitted: SMLAdmittedCommand) async throws -> SMLCommandResult {
        let command = admitted.command
        if let roleID = Self.stringValue(command.arguments["role_id"]), roleID != command.role {
            throw SMLRuntimeError.invalidArgument("role_id must match the command role")
        }
        let snapshot = try await store.load()
        let candidates = Self.matchingWorkflows(command: command, snapshot: snapshot)
        guard !candidates.isEmpty else {
            throw SMLRuntimeError.workflowNotInstalled(command.role)
        }
        guard candidates.count == 1, let selected = candidates.first else {
            throw SMLRuntimeError.ambiguousWorkflowMatch(candidates.map(\.workflow.id).sorted())
        }
        return try await createTask(command: admitted, workflowID: selected.workflow.id)
    }

    private func createTask(
        command admitted: SMLAdmittedCommand,
        workflowID: String
    ) async throws -> SMLCommandResult {
        let now = clock()
        return try await store.update { snapshot in
            guard let record = snapshot.workflows[workflowID] else {
                throw SMLRuntimeError.workflowNotInstalled(workflowID)
            }
            guard record.role == admitted.command.role else {
                throw SMLRuntimeError.commandRoleMismatch(
                    expected: record.role, actual: admitted.command.role
                )
            }
            guard snapshot.tasks[admitted.task] == nil else {
                throw SMLRuntimeError.taskAlreadyExists(admitted.task)
            }
            let initialState = try Self.objectArgument(
                "initial_state", in: admitted.command.arguments, default: [:]
            )
            try Self.validateStatePatch(initialState, workflow: record.workflow)
            var task = SMLRuntimeTask(
                taskID: admitted.task,
                role: admitted.command.role,
                workflowID: record.workflow.id,
                workflowVersion: record.workflow.version,
                currentInstructionID: record.workflow.entrypoint,
                createdAtEpoch: now,
                updatedAtEpoch: now,
                state: initialState
            )
            Self.appendReceipt(
                kind: .taskCreated,
                task: &task,
                workflow: record.workflow,
                command: admitted,
                instructionID: nil,
                payload: ["workflow_id": .string(record.workflow.id)],
                snapshot: &snapshot,
                now: now
            )
            try Self.driveUntilBlocked(
                task: &task, workflow: record.workflow,
                command: admitted, snapshot: &snapshot, now: now
            )
            snapshot.tasks[task.taskID] = task
            return SMLCommandResult(
                kind: .task,
                message: "task \(task.taskID) created",
                task: Self.projectTask(task, workflow: record.workflow)
            )
        }
    }

    private func watchTask(command: SMLCommandEnvelope) async throws -> SMLCommandResult {
        let snapshot = try await store.load()
        let task = try Self.task(command.task, snapshot: snapshot)
        let workflow = try Self.workflow(for: task, snapshot: snapshot)
        return SMLCommandResult(
            kind: .task,
            message: "task \(task.taskID)",
            task: Self.projectTask(task, workflow: workflow)
        )
    }

    private func approveTask(command admitted: SMLAdmittedCommand) async throws -> SMLCommandResult {
        try await continueApproval(command: admitted, approved: true)
    }

    private func refuseTask(command admitted: SMLAdmittedCommand) async throws -> SMLCommandResult {
        try await continueApproval(command: admitted, approved: false)
    }

    private func continueApproval(
        command admitted: SMLAdmittedCommand,
        approved: Bool
    ) async throws -> SMLCommandResult {
        let now = clock()
        return try await store.update { snapshot in
            var task = try Self.task(admitted.task, snapshot: snapshot)
            guard task.role == admitted.command.role else {
                throw SMLRuntimeError.commandRoleMismatch(
                    expected: task.role, actual: admitted.command.role
                )
            }
            let workflow = try Self.workflow(for: task, snapshot: snapshot)
            let instruction = try Self.currentInstruction(task: task, workflow: workflow)
            guard instruction.op == .waitApproval, task.status == .waitingApproval else {
                throw SMLRuntimeError.invalidTaskState(
                    "task is not waiting for approval at \(task.currentInstructionID)"
                )
            }
            let target = approved ? instruction.next : instruction.onFailure
            guard let target else {
                throw SMLRuntimeError.invalidTaskState(
                    "approval instruction has no \(approved ? "next" : "on_failure") target"
                )
            }
            Self.appendReceipt(
                kind: approved ? .approved : .refused,
                task: &task,
                workflow: workflow,
                command: admitted,
                instructionID: instruction.id,
                payload: ["owner": .string(instruction.owner ?? "")],
                snapshot: &snapshot,
                now: now
            )
            task.currentInstructionID = target
            task.waitingApprovalOwner = nil
            task.updatedAtEpoch = now
            try Self.driveUntilBlocked(
                task: &task, workflow: workflow,
                command: admitted, snapshot: &snapshot, now: now
            )
            snapshot.tasks[task.taskID] = task
            return SMLCommandResult(
                kind: .task,
                message: approved ? "task approved" : "task refused",
                task: Self.projectTask(task, workflow: workflow)
            )
        }
    }

    private func rollbackTask(command admitted: SMLAdmittedCommand) async throws -> SMLCommandResult {
        let now = clock()
        return try await store.update { snapshot in
            var task = try Self.task(admitted.task, snapshot: snapshot)
            guard task.role == admitted.command.role else {
                throw SMLRuntimeError.commandRoleMismatch(
                    expected: task.role, actual: admitted.command.role
                )
            }
            let workflow = try Self.workflow(for: task, snapshot: snapshot)
            task.status = .rolledBack
            task.waitingApprovalOwner = nil
            task.updatedAtEpoch = now
            Self.appendReceipt(
                kind: .rollback,
                task: &task,
                workflow: workflow,
                command: admitted,
                instructionID: task.currentInstructionID,
                payload: ["reason": .string("operator_rollback")],
                snapshot: &snapshot,
                now: now
            )
            snapshot.tasks[task.taskID] = task
            return SMLCommandResult(
                kind: .task,
                message: "task rolled back",
                task: Self.projectTask(task, workflow: workflow)
            )
        }
    }

    private func recordStep(command admitted: SMLAdmittedCommand) async throws -> SMLCommandResult {
        let now = clock()
        return try await store.update { snapshot in
            var task = try Self.task(admitted.task, snapshot: snapshot)
            guard task.role == admitted.command.role else {
                throw SMLRuntimeError.commandRoleMismatch(
                    expected: task.role, actual: admitted.command.role
                )
            }
            let workflow = try Self.workflow(for: task, snapshot: snapshot)
            let instruction = try Self.currentInstruction(task: task, workflow: workflow)
            guard task.status == .waitingCapability,
                  Self.isExternallyAdvanced(instruction.op) else {
                throw SMLRuntimeError.currentInstructionCannotBeAdvanced(instruction.id)
            }
            let patch = try Self.objectArgument(
                "state_patch", in: admitted.command.arguments, default: [:]
            )
            try Self.validateStatePatch(patch, workflow: workflow)
            for (key, value) in patch {
                task.state[key] = value
            }
            let outcome = Self.stringValue(admitted.command.arguments["outcome"]) ?? "passed"
            let target: String?
            switch (instruction.op, outcome) {
            case (.verify, "passed"):
                target = instruction.onPass
            case (.verify, "failed"):
                target = instruction.onFailure
            case (.commit, "passed"):
                target = instruction.next
            case (_, "passed"):
                target = instruction.next
            default:
                throw SMLRuntimeError.currentInstructionCannotBeAdvanced(instruction.id)
            }
            guard let target else {
                throw SMLRuntimeError.currentInstructionCannotBeAdvanced(instruction.id)
            }
            Self.appendReceipt(
                kind: .stepRecorded,
                task: &task,
                workflow: workflow,
                command: admitted,
                instructionID: instruction.id,
                payload: [
                    "op": .string(instruction.op.rawValue),
                    "outcome": .string(outcome),
                ],
                snapshot: &snapshot,
                now: now
            )
            task.currentInstructionID = target
            task.waitingApprovalOwner = nil
            task.updatedAtEpoch = now
            try Self.driveUntilBlocked(
                task: &task, workflow: workflow,
                command: admitted, snapshot: &snapshot, now: now
            )
            snapshot.tasks[task.taskID] = task
            return SMLCommandResult(
                kind: .task,
                message: "task step recorded",
                task: Self.projectTask(task, workflow: workflow)
            )
        }
    }

    private func listReceipts(command: SMLCommandEnvelope) async throws -> SMLCommandResult {
        let snapshot = try await store.load()
        let receipts = snapshot.receipts.values
            .filter { command.task == "runtime" || $0.taskID == command.task }
            .sorted { $0.createdAtEpoch == $1.createdAtEpoch ? $0.id < $1.id : $0.createdAtEpoch < $1.createdAtEpoch }
            .map(SMLRuntimeReceiptProjection.init)
        return SMLCommandResult(
            kind: .receipts,
            message: "receipts",
            receipts: receipts
        )
    }

    private func roleFilter(from command: SMLCommandEnvelope) throws -> String? {
        guard let role = Self.stringValue(command.arguments["role_id"]) else { return nil }
        guard SMLValidationSupport.identifierIsValid(role) else {
            throw SMLRuntimeError.invalidIdentifier(role)
        }
        return role
    }

    private static func driveUntilBlocked(
        task: inout SMLRuntimeTask,
        workflow: SMLWorkflow,
        command: SMLAdmittedCommand,
        snapshot: inout SMLRuntimeSnapshot,
        now: Double
    ) throws {
        let instructions = Dictionary(uniqueKeysWithValues: workflow.instructions.map { ($0.id, $0) })
        for _ in 0..<SMLWorkflowValidator.maximumInstructions {
            let instruction = try currentInstruction(task: task, workflow: workflow)
            task.waitingApprovalOwner = nil
            switch instruction.op {
            case .checkpoint:
                appendReceipt(
                    kind: .checkpoint,
                    task: &task,
                    workflow: workflow,
                    command: command,
                    instructionID: instruction.id,
                    payload: ["state": .object(task.state)],
                    snapshot: &snapshot,
                    now: now
                )
                task.currentInstructionID = try requiredTarget(instruction.next, instruction.id)
            case .branch:
                let passed = try evaluate(condition: instruction.condition, state: task.state)
                task.currentInstructionID = try requiredTarget(
                    passed ? instruction.trueTarget : instruction.falseTarget,
                    instruction.id
                )
            case .assert:
                let passed = try evaluate(condition: instruction.condition, state: task.state)
                task.currentInstructionID = try requiredTarget(
                    passed ? instruction.onPass : instruction.onFailure,
                    instruction.id
                )
            case .retry:
                guard let retry = instruction.retryPolicy else {
                    throw SMLRuntimeError.invalidTaskState("retry policy missing at \(instruction.id)")
                }
                let used = task.retryCounts[instruction.id] ?? 0
                if used < retry.maximumAttempts {
                    task.retryCounts[instruction.id] = used + 1
                    task.currentInstructionID = retry.target
                } else {
                    task.currentInstructionID = try requiredTarget(instruction.onFailure, instruction.id)
                }
            case .waitApproval:
                task.status = .waitingApproval
                task.waitingApprovalOwner = instruction.owner
                task.updatedAtEpoch = now
                appendReceipt(
                    kind: .approvalRequested,
                    task: &task,
                    workflow: workflow,
                    command: command,
                    instructionID: instruction.id,
                    payload: [
                        "owner": .string(instruction.owner ?? ""),
                        "reason": .string(instruction.reason ?? ""),
                    ],
                    snapshot: &snapshot,
                    now: now
                )
                return
            case .rollback:
                appendReceipt(
                    kind: .rollback,
                    task: &task,
                    workflow: workflow,
                    command: command,
                    instructionID: instruction.id,
                    payload: ["reason": .string(instruction.reason ?? "")],
                    snapshot: &snapshot,
                    now: now
                )
                task.currentInstructionID = try requiredTarget(instruction.next, instruction.id)
            case .escalate:
                task.status = .escalated
                task.updatedAtEpoch = now
                appendReceipt(
                    kind: .escalated,
                    task: &task,
                    workflow: workflow,
                    command: command,
                    instructionID: instruction.id,
                    payload: [
                        "owner": .string(instruction.owner ?? ""),
                        "reason": .string(instruction.reason ?? ""),
                    ],
                    snapshot: &snapshot,
                    now: now
                )
                return
            case .complete:
                task.status = .completed
                task.updatedAtEpoch = now
                appendReceipt(
                    kind: .completed,
                    task: &task,
                    workflow: workflow,
                    command: command,
                    instructionID: instruction.id,
                    snapshot: &snapshot,
                    now: now
                )
                return
            case .emitReceipt:
                task.status = .completed
                task.updatedAtEpoch = now
                appendReceipt(
                    kind: .receiptEmitted,
                    task: &task,
                    workflow: workflow,
                    command: command,
                    instructionID: instruction.id,
                    payload: receiptPayload(
                        fields: instruction.receiptFields,
                        task: task,
                        workflow: workflow,
                        command: command
                    ),
                    snapshot: &snapshot,
                    now: now
                )
                return
            case .observe, .retrieve, .callTool, .callModel, .invokeVCard,
                 .runPlugin, .runWorkflow, .verify, .commit:
                guard instructions[instruction.id] != nil else {
                    throw SMLRuntimeError.invalidTaskState(
                        "missing current instruction \(instruction.id)"
                    )
                }
                task.status = .waitingCapability
                task.updatedAtEpoch = now
                return
            }
        }
        throw SMLRuntimeError.executionLimitExceeded
    }

    private static func appendReceipt(
        kind: SMLRuntimeReceiptKind,
        task: inout SMLRuntimeTask,
        workflow: SMLWorkflow,
        command: SMLAdmittedCommand,
        instructionID: String?,
        payload: SMLObject = [:],
        snapshot: inout SMLRuntimeSnapshot,
        now: Double
    ) {
        let id = nextReceiptID(taskID: task.taskID, snapshot: snapshot)
        let receipt = SMLRuntimeReceipt(
            id: id,
            kind: kind,
            taskID: task.taskID,
            workflowID: workflow.id,
            instructionID: instructionID,
            commandID: command.commandID,
            actor: command.command.actor,
            leaseID: command.leaseID,
            createdAtEpoch: now,
            payload: payload
        )
        snapshot.receipts[id] = receipt
        task.receiptIDs.append(id)
    }

    private static func nextReceiptID(taskID: String, snapshot: SMLRuntimeSnapshot) -> String {
        let ordinal = snapshot.receipts.values.filter { $0.taskID == taskID }.count + 1
        return "\(taskID.lowercased()).receipt-\(ordinal)"
    }

    private static func receiptPayload(
        fields: [String],
        task: SMLRuntimeTask,
        workflow: SMLWorkflow,
        command: SMLAdmittedCommand
    ) -> SMLObject {
        var payload: SMLObject = [:]
        for field in fields {
            switch field {
            case "actor":
                payload[field] = .string(command.command.actor)
            case "task":
                payload[field] = .string(task.taskID)
            case "workflow", "workflow_id":
                payload[field] = .string(workflow.id)
            case "role":
                payload[field] = .string(task.role)
            case "status":
                payload[field] = .string(task.status.rawValue)
            default:
                if let value = task.state[field] {
                    payload[field] = value
                }
            }
        }
        return payload
    }

    private static func matchingWorkflows(
        command: SMLCommandEnvelope,
        snapshot: SMLRuntimeSnapshot
    ) -> [SMLRuntimeWorkflowRecord] {
        var candidates = snapshot.workflows.values.filter { $0.role == command.role }
        if let workflowID = stringValue(command.arguments["workflow_id"]) {
            candidates = candidates.filter { $0.workflow.id == workflowID }
        }
        if case .object(let filters) = command.arguments["filters"],
           let category = stringValue(filters["category"]) {
            candidates = candidates.filter {
                $0.workflow.id == category || $0.workflow.id.hasPrefix(category + ".")
            }
        }
        return candidates.sorted { $0.workflow.id < $1.workflow.id }
    }

    private static func workflowID(from command: SMLCommandEnvelope) throws -> String {
        if let workflowID = stringValue(command.arguments["workflow_id"]) {
            guard SMLValidationSupport.identifierIsValid(workflowID) else {
                throw SMLRuntimeError.invalidIdentifier(workflowID)
            }
            return workflowID
        }
        throw SMLRuntimeError.missingArgument("workflow_id")
    }

    private static func objectArgument(
        _ key: String,
        in object: SMLObject,
        default defaultValue: SMLObject
    ) throws -> SMLObject {
        guard let value = object[key] else { return defaultValue }
        guard case .object(let nested) = value else {
            throw SMLRuntimeError.invalidArgument("\(key) must be an object")
        }
        return nested
    }

    private static func stringValue(_ value: SMLValue?) -> String? {
        guard case .string(let text) = value else { return nil }
        return text
    }

    private static func task(_ id: String, snapshot: SMLRuntimeSnapshot) throws -> SMLRuntimeTask {
        guard let task = snapshot.tasks[id] else { throw SMLRuntimeError.taskNotFound(id) }
        return task
    }

    private static func workflow(
        for task: SMLRuntimeTask,
        snapshot: SMLRuntimeSnapshot
    ) throws -> SMLWorkflow {
        guard let record = snapshot.workflows[task.workflowID] else {
            throw SMLRuntimeError.taskWorkflowMissing(task.workflowID)
        }
        return record.workflow
    }

    private static func currentInstruction(
        task: SMLRuntimeTask,
        workflow: SMLWorkflow
    ) throws -> SMLInstruction {
        guard let instruction = workflow.instructions.first(where: {
            $0.id == task.currentInstructionID
        }) else {
            throw SMLRuntimeError.invalidTaskState(
                "missing current instruction \(task.currentInstructionID)"
            )
        }
        return instruction
    }

    private static func requiredTarget(_ target: String?, _ instructionID: String) throws -> String {
        guard let target else {
            throw SMLRuntimeError.invalidTaskState("missing transition from \(instructionID)")
        }
        return target
    }

    private static func validateStatePatch(_ patch: SMLObject, workflow: SMLWorkflow) throws {
        let fields = Dictionary(uniqueKeysWithValues: workflow.stateSchema.map { ($0.name, $0) })
        for (key, value) in patch {
            guard let field = fields[key] else {
                throw SMLRuntimeError.statePatchRejected("unknown state field \(key)")
            }
            guard valueMatchesStateType(value, type: field.type, nullable: field.nullable) else {
                throw SMLRuntimeError.statePatchRejected(
                    "field \(key) does not match \(field.type.rawValue)"
                )
            }
        }
    }

    private static func valueMatchesStateType(
        _ value: SMLValue,
        type: SMLStateType,
        nullable: Bool
    ) -> Bool {
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

    private static func evaluate(condition: SMLCondition?, state: SMLObject) throws -> Bool {
        guard let condition else {
            throw SMLRuntimeError.invalidTaskState("condition missing")
        }
        let results = try condition.clauses.map { try evaluate(clause: $0, state: state) }
        switch condition.combination {
        case .all:
            return results.allSatisfy { $0 }
        case .any:
            return results.contains(true)
        }
    }

    private static func evaluate(clause: SMLConditionClause, state: SMLObject) throws -> Bool {
        let current = state[clause.field]
        switch clause.op {
        case .exists:
            if case .null = current { return false }
            return current != nil
        case .isNull:
            if current == nil { return true }
            if case .null = current { return true }
            return false
        case .equals:
            return current == clause.value
        case .notEquals:
            return current != clause.value
        case .contains:
            guard let needle = clause.value else { return false }
            switch (current, needle) {
            case (.string(let haystack), .string(let text)):
                return haystack.contains(text)
            case (.array(let values), _):
                return values.contains(needle)
            default:
                return false
            }
        case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
            guard case .number(let left) = current,
                  case .number(let right) = clause.value else { return false }
            switch clause.op {
            case .lessThan: return left < right
            case .lessThanOrEqual: return left <= right
            case .greaterThan: return left > right
            case .greaterThanOrEqual: return left >= right
            default: return false
            }
        }
    }

    private static func statusSummary(_ snapshot: SMLRuntimeSnapshot) -> SMLRuntimeStatusSummary {
        let roles = Set(snapshot.workflows.values.map(\.role))
        let active = snapshot.tasks.values.filter {
            ![SMLTaskStatus.completed, .escalated, .rolledBack, .refused].contains($0.status)
        }.count
        return SMLRuntimeStatusSummary(
            workflowCount: snapshot.workflows.count,
            roleCount: roles.count,
            taskCount: snapshot.tasks.count,
            activeTaskCount: active,
            receiptCount: snapshot.receipts.count
        )
    }

    private static func roleProjections(_ snapshot: SMLRuntimeSnapshot) -> [SMLRoleProjection] {
        let workflowsByRole = Dictionary(grouping: snapshot.workflows.values, by: \.role)
        return workflowsByRole.keys.sorted().map { role in
            SMLRoleProjection(
                role: role,
                workflows: (workflowsByRole[role] ?? []).map(\.workflow.id).sorted(),
                taskCount: snapshot.tasks.values.filter { $0.role == role }.count
            )
        }
    }

    private static func projectWorkflow(
        _ record: SMLRuntimeWorkflowRecord
    ) -> SMLWorkflowProjection {
        SMLWorkflowProjection(
            id: record.workflow.id,
            version: record.workflow.version,
            name: record.workflow.name,
            role: record.role,
            sourceKind: record.workflow.source.kind,
            triggerKind: record.workflow.trigger.kind,
            instructionCount: record.workflow.instructions.count
        )
    }

    private static func projectInstruction(_ instruction: SMLInstruction) -> SMLInstructionProjection {
        SMLInstructionProjection(
            id: instruction.id,
            op: instruction.op,
            source: instruction.source,
            capability: instruction.capability,
            purpose: instruction.purpose,
            verifier: instruction.verifier,
            workflow: instruction.workflow,
            targets: successors(of: instruction)
        )
    }

    private static func isExternallyAdvanced(_ op: SMLInstructionOperation) -> Bool {
        switch op {
        case .observe, .retrieve, .callTool, .callModel, .invokeVCard,
             .runPlugin, .runWorkflow, .verify, .commit:
            return true
        case .branch, .assert, .checkpoint, .waitApproval, .retry, .rollback,
             .escalate, .emitReceipt, .complete:
            return false
        }
    }

    private static func projectTask(
        _ task: SMLRuntimeTask,
        workflow: SMLWorkflow
    ) -> SMLTaskProjection {
        let instruction = workflow.instructions.first { $0.id == task.currentInstructionID }
        return SMLTaskProjection(
            taskID: task.taskID,
            role: task.role,
            workflowID: task.workflowID,
            workflowVersion: task.workflowVersion,
            status: task.status,
            currentInstructionID: task.currentInstructionID,
            currentOperation: instruction?.op,
            waitingApprovalOwner: task.waitingApprovalOwner,
            state: task.state,
            receiptIDs: task.receiptIDs
        )
    }

    private static func successors(of instruction: SMLInstruction) -> [String] {
        let values: [String?]
        switch instruction.op {
        case .branch:
            values = [instruction.trueTarget, instruction.falseTarget]
        case .assert, .verify:
            values = [instruction.onPass, instruction.onFailure]
        case .waitApproval:
            values = [instruction.next, instruction.onFailure]
        case .retry:
            values = [instruction.retryPolicy?.target, instruction.onFailure]
        case .escalate, .emitReceipt, .complete:
            values = []
        default:
            values = [instruction.next]
        }
        return Array(Set(values.compactMap { $0 })).sorted()
    }
}
