import Foundation

public actor SMLRuntime {
    private let store: SMLRuntimeStore
    private let clock: @Sendable () -> Double
    /// Process-local host admission proofs. Durable workflow bytes are descriptive; after a restart
    /// the host must re-admit/reinstall an exact revision before it can start or advance capability work.
    private var activeAdmissions: [String: SMLAdmittedWorkflow] = [:]

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
        let key = Self.workflowStorageKey(id: admitted.id, version: admitted.version)
        let projection = try await store.update { snapshot in
            if let existing = snapshot.workflows[key],
               existing.role != role || existing.workflow != admitted.workflow {
                throw SMLRuntimeError.workflowVersionConflict(
                    id: admitted.id, version: admitted.version
                )
            }
            let record = SMLRuntimeWorkflowRecord(
                role: role, workflow: admitted.workflow, installedAtEpoch: now
            )
            snapshot.workflows[key] = record
            snapshot.activeWorkflowVersions[admitted.id] = admitted.version
            return Self.projectWorkflow(record)
        }
        activeAdmissions[key] = admitted
        return projection
    }

    public func status() async throws -> SMLCommandResult {
        let snapshot = try await store.load()
        return SMLCommandResult(
            kind: .status,
            message: "runtime status",
            status: Self.statusSummary(snapshot)
        )
    }

    /// Returns one immutable, version-pinned unit of capability work. The request is descriptive;
    /// only a host-owned driver may execute it, and its completion must return through command
    /// admission with the request's state digest as an optimistic-concurrency token.
    public func pendingCapability(taskID: String) async throws -> SMLCapabilityRequest {
        let snapshot = try await store.load()
        let task = try Self.task(taskID, snapshot: snapshot)
        let workflow = try Self.workflow(for: task, snapshot: snapshot)
        let workflowKey = Self.workflowStorageKey(
            id: workflow.id, version: workflow.version
        )
        guard let admission = activeAdmissions[workflowKey],
              admission.workflow == workflow else {
            throw SMLRuntimeError.workflowAdmissionNotBound(
                id: workflow.id, version: workflow.version
            )
        }
        let instruction = try Self.currentInstruction(task: task, workflow: workflow)
        guard task.status == .waitingCapability,
              Self.isExternallyAdvanced(instruction.op) else {
            throw SMLRuntimeError.currentInstructionCannotBeAdvanced(instruction.id)
        }
        if let claim = task.capabilityClaim {
            throw SMLRuntimeError.capabilityAlreadyClaimed(claim.dispatchID)
        }
        return try Self.capabilityRequest(
            task: task, instruction: instruction, admission: admission
        )
    }

    func claimCapability(
        _ admitted: SMLAdmittedCommand
    ) async throws -> SMLClaimedCapability {
        guard admitted.op == SMLRuntimeCommandOperation.taskClaimCapability else {
            throw SMLRuntimeError.unsupportedOperation(admitted.op)
        }
        let now = clock()
        let admissions = activeAdmissions
        return try await store.update { snapshot in
            var task = try Self.task(admitted.task, snapshot: snapshot)
            guard task.role == admitted.command.role else {
                throw SMLRuntimeError.commandRoleMismatch(
                    expected: task.role, actual: admitted.command.role
                )
            }
            let workflow = try Self.workflow(for: task, snapshot: snapshot)
            try Self.assertWorkflowBinding(admitted.command, task: task)
            let workflowKey = Self.workflowStorageKey(
                id: workflow.id, version: workflow.version
            )
            guard let admission = admissions[workflowKey],
                  admission.workflow == workflow else {
                throw SMLRuntimeError.workflowAdmissionNotBound(
                    id: workflow.id, version: workflow.version
                )
            }
            let instruction = try Self.currentInstruction(task: task, workflow: workflow)
            guard task.status == .waitingCapability,
                  Self.isExternallyAdvanced(instruction.op) else {
                throw SMLRuntimeError.currentInstructionCannotBeAdvanced(instruction.id)
            }
            if let claim = task.capabilityClaim {
                throw SMLRuntimeError.capabilityAlreadyClaimed(claim.dispatchID)
            }

            let request = try Self.capabilityRequest(
                task: task, instruction: instruction, admission: admission
            )
            try Self.assertExpectedState(
                admitted.command.expectedState,
                task: task,
                workflow: workflow,
                capabilityStateDigest: request.stateDigest
            )
            try Self.validateClaimCommand(admitted.command, request: request)
            let dispatchID = try Self.requiredStringArgument(
                "dispatch_id", in: admitted.command.arguments
            )
            let driverID = try Self.requiredStringArgument(
                "driver_id", in: admitted.command.arguments
            )
            guard SMLValidationSupport.identifierIsValid(dispatchID),
                  SMLValidationSupport.identifierIsValid(driverID) else {
                throw SMLRuntimeError.invalidArgument(
                    "dispatch_id and driver_id must be identifiers"
                )
            }

            task.updatedAtEpoch = now
            Self.appendReceipt(
                kind: .capabilityClaimed,
                task: &task,
                workflow: workflow,
                command: admitted,
                instructionID: instruction.id,
                payload: [
                    "dispatch_id": .string(dispatchID),
                    "driver_id": .string(driverID),
                    "request_state_digest": .string(request.stateDigest),
                ],
                snapshot: &snapshot,
                now: now
            )
            try Self.incrementRevision(&task)
            let claimedRequest = try Self.capabilityRequest(
                task: task, instruction: instruction, admission: admission
            )
            let record = SMLCapabilityClaimRecord(
                dispatchID: dispatchID,
                driverID: driverID,
                instructionID: instruction.id,
                stateDigest: claimedRequest.stateDigest,
                commandID: admitted.commandID,
                actor: admitted.command.actor,
                leaseID: admitted.leaseID,
                claimedAtEpoch: now
            )
            task.capabilityClaim = record
            snapshot.tasks[task.taskID] = task
            return SMLClaimedCapability(request: claimedRequest, record: record)
        }
    }

    func completeCapability(
        _ admitted: SMLAdmittedCommand,
        claimed: SMLClaimedCapability,
        routed: SMLRoutedCapabilityOutcome
    ) async throws -> SMLCommandResult {
        guard admitted.op == SMLRuntimeCommandOperation.taskRecordStep else {
            throw SMLRuntimeError.unsupportedOperation(admitted.op)
        }
        guard routed.claimRecord == claimed.record,
              routed.dispatchID == claimed.dispatchID,
              routed.driverID == claimed.driverID else {
            throw SMLRuntimeError.capabilityClaimMismatch
        }
        guard admitted.command.actor == claimed.record.actor,
              admitted.leaseID == claimed.record.leaseID else {
            throw SMLRuntimeError.capabilityClaimMismatch
        }
        let now = clock()
        let admissions = activeAdmissions
        return try await store.update { snapshot in
            var task = try Self.task(admitted.task, snapshot: snapshot)
            guard task.role == admitted.command.role else {
                throw SMLRuntimeError.commandRoleMismatch(
                    expected: task.role, actual: admitted.command.role
                )
            }
            let workflow = try Self.workflow(for: task, snapshot: snapshot)
            try Self.assertWorkflowBinding(admitted.command, task: task)
            let workflowKey = Self.workflowStorageKey(
                id: workflow.id, version: workflow.version
            )
            guard let admission = admissions[workflowKey],
                  admission.workflow == workflow else {
                throw SMLRuntimeError.workflowAdmissionNotBound(
                    id: workflow.id, version: workflow.version
                )
            }
            let instruction = try Self.currentInstruction(task: task, workflow: workflow)
            guard task.status == .waitingCapability,
                  Self.isExternallyAdvanced(instruction.op) else {
                throw SMLRuntimeError.currentInstructionCannotBeAdvanced(instruction.id)
            }
            guard task.capabilityClaim == claimed.record,
                  claimed.record.instructionID == instruction.id else {
                throw SMLRuntimeError.capabilityClaimMismatch
            }
            let currentRequest = try Self.capabilityRequest(
                task: task, instruction: instruction, admission: admission
            )
            guard currentRequest == claimed.request,
                  currentRequest.stateDigest == claimed.record.stateDigest else {
                throw SMLRuntimeError.capabilityClaimMismatch
            }
            try Self.assertExpectedState(
                admitted.command.expectedState,
                task: task,
                workflow: workflow,
                capabilityStateDigest: currentRequest.stateDigest
            )
            try Self.validateCompletionCommand(
                admitted.command, claimed: claimed, routed: routed
            )

            let outcome = routed.outcome
            // A definite unsuccessful result completes this dispatch. It must not be confused
            // with a driver exception, whose external result remains unknown and keeps its claim.
            let terminalFailure = outcome.status == .failed && instruction.op != .verify
            let target: String?
            switch (instruction.op, outcome.status) {
            case (.verify, .passed): target = instruction.onPass
            case (.verify, .failed): target = instruction.onFailure
            case (.commit, .passed): target = instruction.next
            case (_, .passed): target = instruction.next
            default: target = nil
            }
            guard terminalFailure || target != nil else {
                throw SMLRuntimeError.currentInstructionCannotBeAdvanced(instruction.id)
            }
            if !terminalFailure {
                try Self.validateStatePatch(outcome.statePatch, workflow: workflow)
                for (key, value) in outcome.statePatch {
                    task.state[key] = value
                }
            }
            let evidence = Self.capabilityEvidenceObject(outcome)
            Self.appendReceipt(
                kind: .stepRecorded,
                task: &task,
                workflow: workflow,
                command: admitted,
                instructionID: instruction.id,
                payload: [
                    "op": .string(instruction.op.rawValue),
                    "outcome": .string(outcome.status.rawValue),
                    "dispatch_id": .string(claimed.dispatchID),
                    "driver_id": .string(claimed.driverID),
                    "evidence": .object(evidence),
                ],
                snapshot: &snapshot,
                now: now
            )
            task.waitingApprovalOwner = nil
            task.capabilityClaim = nil
            task.updatedAtEpoch = now
            if terminalFailure {
                task.status = .failed
            } else if let target {
                task.currentInstructionID = target
                try Self.driveUntilBlocked(
                    task: &task, workflow: workflow,
                    command: admitted, snapshot: &snapshot, now: now
                )
            }
            try Self.incrementRevision(&task)
            snapshot.tasks[task.taskID] = task
            return SMLCommandResult(
                kind: .task,
                message: terminalFailure ? "task capability failed" : "task capability completed",
                task: Self.projectTask(task, workflow: workflow)
            )
        }
    }

    public func submit(_ admitted: SMLAdmittedCommand) async throws -> SMLCommandResult {
        switch admitted.op {
        case SMLRuntimeCommandOperation.status, "status":
            return try await status(role: admitted.command.role)
        case SMLRuntimeCommandOperation.rolesList, "roles":
            return try await listRoles(role: admitted.command.role)
        case SMLRuntimeCommandOperation.workflowsList, "workflows":
            return try await listWorkflows(command: admitted.command)
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
        case SMLRuntimeCommandOperation.taskReconcile:
            return try await reconcileTask(command: admitted)
        case SMLRuntimeCommandOperation.receiptsList, "receipts":
            return try await listReceipts(command: admitted.command)
        default:
            throw SMLRuntimeError.unsupportedOperation(admitted.op)
        }
    }

    private func status(role: String) async throws -> SMLCommandResult {
        let snapshot = try await store.load()
        return SMLCommandResult(
            kind: .status,
            message: "runtime status",
            status: Self.statusSummary(snapshot, role: role)
        )
    }

    private func listRoles(role: String) async throws -> SMLCommandResult {
        let snapshot = try await store.load()
        return SMLCommandResult(
            kind: .roles,
            message: "roles",
            roles: Self.roleProjections(snapshot).filter { $0.role == role }
        )
    }

    private func listWorkflows(command: SMLCommandEnvelope) async throws -> SMLCommandResult {
        let role = try roleFilter(from: command) ?? command.role
        guard role == command.role else {
            throw SMLRuntimeError.invalidArgument("role_id must match the command role")
        }
        let snapshot = try await store.load()
        let workflows = Self.activeWorkflowRecords(snapshot)
            .filter { $0.role == role }
            .map(Self.projectWorkflow)
            .sorted { $0.id < $1.id }
        return SMLCommandResult(kind: .workflows, message: "workflows", workflows: workflows)
    }

    private func inspectWorkflow(command: SMLCommandEnvelope) async throws -> SMLCommandResult {
        let workflowID = try Self.workflowID(from: command)
        let requestedVersion = try Self.workflowVersion(from: command)
        let snapshot = try await store.load()
        let record = requestedVersion.flatMap {
            snapshot.workflows[Self.workflowStorageKey(id: workflowID, version: $0)]
        } ?? Self.activeWorkflowRecord(id: workflowID, snapshot: snapshot)
        guard let record,
              requestedVersion == nil || record.workflow.version == requestedVersion else {
            throw SMLRuntimeError.workflowNotInstalled(workflowID)
        }
        guard record.role == command.role else {
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
        try await createTask(
            command: admitted,
            workflowID: Self.workflowID(from: admitted.command),
            workflowVersion: Self.workflowVersion(from: admitted.command)
        )
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
        return try await createTask(
            command: admitted,
            workflowID: selected.workflow.id,
            workflowVersion: Self.workflowVersion(from: command)
        )
    }

    /// Runs the same pure state transition before replay admission. It invokes no driver and
    /// writes no store state, so bounded admission failures cannot consume replay capacity.
    public func preflightAdmission(_ command: SMLCommandEnvelope, authority: SMLCommandAuthority,
        nowEpoch: Double) async throws {
        guard SMLRuntimeLeaseRegistry.taskCreatingOperations.contains(command.op) else { return }
        let admitted = SMLAdmittedCommand(command: command, leaseID: authority.leaseID,
            approvalAuthorities: authority.approvalAuthorities, admittedAtEpoch: nowEpoch)
        let admissions = activeAdmissions.mapValues(\.workflow)
        try await store.preflightTaskCreation(command: command, authority: authority, nowEpoch: nowEpoch) { snapshot in
            let workflowID: String
            if command.op == SMLRuntimeCommandOperation.workflowRunMatching {
                if let roleID = Self.stringValue(command.arguments["role_id"]), roleID != command.role {
                    throw SMLRuntimeError.invalidArgument("role_id must match the command role")
                }
                let candidates = Self.matchingWorkflows(command: command, snapshot: snapshot)
                guard !candidates.isEmpty else { throw SMLRuntimeError.workflowNotInstalled(command.role) }
                guard candidates.count == 1, let selected = candidates.first else {
                    throw SMLRuntimeError.ambiguousWorkflowMatch(candidates.map(\.workflow.id).sorted())
                }
                workflowID = selected.workflow.id
            } else {
                workflowID = try Self.workflowID(from: command)
            }
            _ = try Self.prepareTaskCreation(command: admitted, workflowID: workflowID,
                workflowVersion: Self.workflowVersion(from: command), admissions: admissions,
                snapshot: &snapshot, now: nowEpoch)
        }
    }

    private func createTask(command admitted: SMLAdmittedCommand, workflowID: String,
        workflowVersion: String?) async throws -> SMLCommandResult {
        let now = clock()
        let admissions = activeAdmissions.mapValues(\.workflow)
        return try await store.update { snapshot in
            try Self.prepareTaskCreation(command: admitted, workflowID: workflowID,
                workflowVersion: workflowVersion, admissions: admissions, snapshot: &snapshot, now: now)
        }
    }

    private static func prepareTaskCreation(command admitted: SMLAdmittedCommand, workflowID: String,
        workflowVersion: String?, admissions: [String: SMLWorkflow], snapshot: inout SMLRuntimeSnapshot,
        now: Double) throws -> SMLCommandResult {
        guard admitted.command.expectedState.isEmpty else {
            throw SMLRuntimeError.invalidArgument("expected_state must be empty when creating a task")
        }
        let record = workflowVersion.flatMap {
            snapshot.workflows[Self.workflowStorageKey(id: workflowID, version: $0)]
        } ?? Self.activeWorkflowRecord(id: workflowID, snapshot: snapshot)
        guard let record,
              workflowVersion == nil || record.workflow.version == workflowVersion else {
            throw SMLRuntimeError.workflowNotInstalled(workflowID)
        }
        let workflowKey = Self.workflowStorageKey(
            id: record.workflow.id, version: record.workflow.version
        )
        guard admissions[workflowKey] == record.workflow else {
            throw SMLRuntimeError.workflowAdmissionNotBound(
                id: record.workflow.id, version: record.workflow.version
            )
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
        try Self.validateInitialState(initialState, workflow: record.workflow)
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
        try Self.incrementRevision(&task)
        snapshot.tasks[task.taskID] = task
        return SMLCommandResult(
            kind: .task,
            message: "task \(task.taskID) created",
            task: Self.projectTask(task, workflow: record.workflow)
        )
    }

    private func watchTask(command: SMLCommandEnvelope) async throws -> SMLCommandResult {
        let snapshot = try await snapshotIncludingArchivedHistory(taskID: command.task)
        let task = try Self.task(command.task, snapshot: snapshot)
        let workflow = try Self.workflow(for: task, snapshot: snapshot)
        guard task.role == command.role else {
            throw SMLRuntimeError.commandRoleMismatch(
                expected: task.role, actual: command.role
            )
        }
        try Self.assertWorkflowBinding(command, task: task)
        try Self.assertExpectedState(command.expectedState, task: task, workflow: workflow)
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
        let admissions = activeAdmissions.mapValues(\.workflow)
        return try await store.update { snapshot in
            var task = try Self.task(admitted.task, snapshot: snapshot)
            guard task.role == admitted.command.role else {
                throw SMLRuntimeError.commandRoleMismatch(
                    expected: task.role, actual: admitted.command.role
                )
            }
            let workflow = try Self.workflow(for: task, snapshot: snapshot)
            let workflowKey = Self.workflowStorageKey(
                id: workflow.id, version: workflow.version
            )
            guard admissions[workflowKey] == workflow else {
                throw SMLRuntimeError.workflowAdmissionNotBound(
                    id: workflow.id, version: workflow.version
                )
            }
            try Self.assertWorkflowBinding(admitted.command, task: task)
            try Self.assertRequiredTaskRevision(
                admitted.command.expectedState, task: task
            )
            try Self.assertExpectedState(
                admitted.command.expectedState, task: task, workflow: workflow
            )
            let instruction = try Self.currentInstruction(task: task, workflow: workflow)
            guard instruction.op == .waitApproval, task.status == .waitingApproval else {
                throw SMLRuntimeError.invalidTaskState(
                    "task is not waiting for approval at \(task.currentInstructionID)"
                )
            }
            guard let owner = instruction.owner,
                  admitted.approvalAuthorities.contains(owner) else {
                throw SMLRuntimeError.approvalAuthorityDenied(
                    instruction.owner ?? "missing_owner"
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
            try Self.incrementRevision(&task)
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
        let admissions = activeAdmissions.mapValues(\.workflow)
        return try await store.update { snapshot in
            var task = try Self.task(admitted.task, snapshot: snapshot)
            guard task.role == admitted.command.role else {
                throw SMLRuntimeError.commandRoleMismatch(
                    expected: task.role, actual: admitted.command.role
                )
            }
            let workflow = try Self.workflow(for: task, snapshot: snapshot)
            let workflowKey = Self.workflowStorageKey(
                id: workflow.id, version: workflow.version
            )
            guard admissions[workflowKey] == workflow else {
                throw SMLRuntimeError.workflowAdmissionNotBound(
                    id: workflow.id, version: workflow.version
                )
            }
            try Self.assertWorkflowBinding(admitted.command, task: task)
            try Self.assertRequiredTaskRevision(
                admitted.command.expectedState, task: task
            )
            try Self.assertExpectedState(
                admitted.command.expectedState, task: task, workflow: workflow
            )
            guard ![SMLTaskStatus.completed, .failed, .escalated, .rolledBack, .refused]
                .contains(task.status) else {
                throw SMLRuntimeError.invalidTaskState(
                    "terminal task cannot be rolled back again"
                )
            }
            guard task.capabilityClaim == nil else {
                throw SMLRuntimeError.invalidTaskState(
                    "claimed capability requires reconciliation before rollback"
                )
            }
            task.status = .rolledBack
            task.waitingApprovalOwner = nil
            task.capabilityClaim = nil
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
            try Self.incrementRevision(&task)
            snapshot.tasks[task.taskID] = task
            return SMLCommandResult(
                kind: .task,
                message: "task rolled back",
                task: Self.projectTask(task, workflow: workflow)
            )
        }
    }

    /// Close an interrupted earlier-session dispatch without retrying or claiming its effect succeeded.
    private func reconcileTask(command admitted: SMLAdmittedCommand) async throws -> SMLCommandResult {
        let now = clock()
        return try await store.update { snapshot in
            var task = try Self.task(admitted.task, snapshot: snapshot)
            guard task.role == admitted.command.role else {
                throw SMLRuntimeError.commandRoleMismatch(expected: task.role, actual: admitted.command.role)
            }
            let workflow = try Self.workflow(for: task, snapshot: snapshot)
            try Self.assertWorkflowBinding(admitted.command, task: task)
            try Self.assertRequiredTaskRevision(admitted.command.expectedState, task: task)
            try Self.assertExpectedState(admitted.command.expectedState, task: task, workflow: workflow)
            guard task.status == .waitingCapability, let claim = task.capabilityClaim else {
                throw SMLRuntimeError.invalidTaskState("task has no interrupted capability claim")
            }
            guard claim.leaseID != admitted.leaseID else {
                throw SMLRuntimeError.invalidTaskState(
                    "stop and restart this host before reconciling a claim from its current session"
                )
            }
            let dispatchID = try Self.requiredStringArgument("dispatch_id", in: admitted.command.arguments)
            guard dispatchID == claim.dispatchID else {
                throw SMLRuntimeError.capabilityClaimMismatch
            }
            let note = try Self.requiredStringArgument("note", in: admitted.command.arguments)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !note.isEmpty, note.utf8.count <= 4_096 else {
                throw SMLRuntimeError.invalidArgument("reconciliation note must contain 1...4096 UTF-8 bytes")
            }
            Self.appendReceipt(
                kind: .reconciled, task: &task, workflow: workflow, command: admitted,
                instructionID: claim.instructionID,
                payload: [
                    "dispatch_id": .string(claim.dispatchID),
                    "driver_id": .string(claim.driverID),
                    "original_lease_id": .string(claim.leaseID),
                    "request_state_digest": .string(claim.stateDigest),
                    "outcome": .string("abandoned"),
                    "external_outcome": .string("unknown"),
                    "note": .string(note),
                ],
                snapshot: &snapshot, now: now
            )
            task.capabilityClaim = nil
            task.waitingApprovalOwner = nil
            task.status = .failed
            task.updatedAtEpoch = now
            try Self.incrementRevision(&task)
            snapshot.tasks[task.taskID] = task
            return SMLCommandResult(
                kind: .task,
                message: "interrupted task closed as failed; external outcome remains unknown",
                task: Self.projectTask(task, workflow: workflow)
            )
        }
    }

    private func listReceipts(command: SMLCommandEnvelope) async throws -> SMLCommandResult {
        let snapshot = try await snapshotIncludingArchivedHistory(
            taskID: command.task == "runtime" ? nil : command.task)
        let allowedTaskIDs: Set<String>
        if command.task == "runtime" {
            guard command.arguments["workflow_id"] == nil,
                  command.arguments["workflow_version"] == nil else {
                throw SMLRuntimeError.invalidArgument(
                    "workflow-scoped receipt queries require a concrete task id"
                )
            }
            allowedTaskIDs = Set(snapshot.tasks.values.filter {
                $0.role == command.role
            }.map(\.taskID))
        } else {
            let task = try Self.task(command.task, snapshot: snapshot)
            guard task.role == command.role else {
                throw SMLRuntimeError.commandRoleMismatch(
                    expected: task.role, actual: command.role
                )
            }
            try Self.assertWorkflowBinding(command, task: task)
            allowedTaskIDs = [task.taskID]
        }
        let receipts = snapshot.receipts.values
            .filter { allowedTaskIDs.contains($0.taskID) }
            .sorted { $0.createdAtEpoch == $1.createdAtEpoch ? $0.id < $1.id : $0.createdAtEpoch < $1.createdAtEpoch }
            .map(SMLRuntimeReceiptProjection.init)
        return SMLCommandResult(
            kind: .receipts,
            message: "receipts",
            receipts: receipts
        )
    }

    private func snapshotIncludingArchivedHistory(taskID: String?) async throws -> SMLRuntimeSnapshot {
        var snapshot = try await store.load()
        let archived: [SMLRuntimeArchivedTask]
        if let taskID {
            if snapshot.tasks[taskID] != nil { return snapshot }
            archived = try await store.archivedTask(id: taskID).map { [$0] } ?? []
        } else {
            archived = try await store.archivedTasks()
        }
        for entry in archived {
            snapshot.tasks[entry.task.taskID] = entry.task
            snapshot.workflows[SMLRuntimeSnapshot.workflowStorageKey(
                id: entry.task.workflowID, version: entry.task.workflowVersion)] = entry.workflow
            for receipt in entry.receipts { snapshot.receipts[receipt.id] = receipt }
        }
        return snapshot
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
            try assertInstructionExpectedState(instruction, task: task)
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
        let id = nextReceiptID(task: task, snapshot: snapshot)
        let receipt = SMLRuntimeReceipt(
            id: id,
            kind: kind,
            taskID: task.taskID,
            workflowID: workflow.id,
            workflowVersion: workflow.version,
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

    private static func nextReceiptID(task: SMLRuntimeTask, snapshot: SMLRuntimeSnapshot) -> String {
        var ordinal = task.receiptIDs.count + 1
        var id = "\(task.taskID).receipt-\(ordinal)"
        while snapshot.receipts[id] != nil {
            ordinal += 1
            id = "\(task.taskID).receipt-\(ordinal)"
        }
        return id
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
        var candidates = activeWorkflowRecords(snapshot).filter { $0.role == command.role }
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

    private static func workflowVersion(from command: SMLCommandEnvelope) throws -> String? {
        guard let value = command.arguments["workflow_version"] else { return nil }
        guard case .string(let version) = value,
              version.range(
                of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#,
                options: .regularExpression
              ) != nil else {
            throw SMLRuntimeError.invalidArgument(
                "workflow_version must use semantic version syntax"
            )
        }
        return version
    }

    private static func assertWorkflowBinding(
        _ command: SMLCommandEnvelope,
        task: SMLRuntimeTask
    ) throws {
        if let value = command.arguments["workflow_id"] {
            guard case .string(let workflowID) = value,
                  workflowID == task.workflowID else {
                throw SMLRuntimeError.workflowBindingMismatch("workflow_id")
            }
        }
        if let version = try workflowVersion(from: command),
           version != task.workflowVersion {
            throw SMLRuntimeError.workflowBindingMismatch("workflow_version")
        }
    }

    private static func capabilityRequest(
        task: SMLRuntimeTask,
        instruction: SMLInstruction,
        admission: SMLAdmittedWorkflow
    ) throws -> SMLCapabilityRequest {
        let pluginExecutionAttestation = try pluginExecutionAttestation(
            instruction: instruction,
            workflow: admission.workflow,
            admittedPluginAttestations: admission.pluginAttestations
        )
        return SMLCapabilityRequest(
            taskID: task.taskID,
            role: task.role,
            workflowID: task.workflowID,
            workflowVersion: task.workflowVersion,
            taskRevision: task.revision,
            instructionID: instruction.id,
            operation: instruction.op,
            reference: try capabilityReference(instruction),
            outputSchema: instruction.outputSchema,
            verifier: instruction.verifier ?? instruction.plugin?.verifier,
            plugin: instruction.plugin,
            pluginExecutionAttestation: pluginExecutionAttestation,
            arguments: instruction.arguments,
            scope: instruction.scope,
            expectedState: instruction.expectedState,
            state: task.state,
            stateDigest: try SMLCapabilityStateDigest.compute(
                task: task,
                instruction: instruction,
                pluginAttestationBindingDigest: pluginExecutionAttestation?.bindingDigest
            )
        )
    }

    private static func pluginExecutionAttestation(
        instruction: SMLInstruction,
        workflow: SMLWorkflow,
        admittedPluginAttestations: [String: SMLPluginAttestation]
    ) throws -> SMLPluginExecutionAttestation? {
        guard instruction.op == .runPlugin else { return nil }
        guard let contract = instruction.plugin,
              let attestation = admittedPluginAttestations[contract.id],
              attestation.contract == contract else {
            throw SMLRuntimeError.invalidTaskState(
                "RUN_PLUGIN is missing its exact host admission attestation at \(instruction.id)"
            )
        }
        return try SMLPluginExecutionAttestation(
            attestation: attestation,
            workflowID: workflow.id,
            workflowVersion: workflow.version,
            instructionID: instruction.id
        )
    }

    private static func capabilityExpectedState(
        _ request: SMLCapabilityRequest
    ) -> SMLObject {
        var expected = request.state
        expected["instruction_id"] = .string(request.instructionID)
        expected["workflow_version"] = .string(request.workflowVersion)
        expected["task_status"] = .string(SMLTaskStatus.waitingCapability.rawValue)
        expected["task_revision"] = .number(Decimal(request.taskRevision))
        expected["capability_state_digest"] = .string(request.stateDigest)
        return expected
    }

    private static func validateClaimCommand(
        _ command: SMLCommandEnvelope,
        request: SMLCapabilityRequest
    ) throws {
        let keys: Set<String> = [
            "workflow_id", "workflow_version", "instruction_id",
            "capability_operation", "reference", "driver_id", "dispatch_id",
            "request_state_digest",
        ]
        guard Set(command.arguments.keys) == keys,
              command.scope == request.scope,
              command.expectedState == capabilityExpectedState(request),
              try requiredStringArgument("workflow_id", in: command.arguments)
                == request.workflowID,
              try requiredStringArgument("workflow_version", in: command.arguments)
                == request.workflowVersion,
              try requiredStringArgument("instruction_id", in: command.arguments)
                == request.instructionID,
              try requiredStringArgument("capability_operation", in: command.arguments)
                == request.operation.rawValue,
              try requiredStringArgument("reference", in: command.arguments)
                == request.reference,
              try requiredStringArgument("request_state_digest", in: command.arguments)
                == request.stateDigest else {
            throw SMLRuntimeError.capabilityClaimMismatch
        }
    }

    private static func validateCompletionCommand(
        _ command: SMLCommandEnvelope,
        claimed: SMLClaimedCapability,
        routed: SMLRoutedCapabilityOutcome
    ) throws {
        let keys: Set<String> = [
            "workflow_id", "workflow_version", "dispatch_id", "driver_id",
            "outcome", "state_patch", "evidence",
        ]
        let outcome = routed.outcome
        guard Set(command.arguments.keys) == keys,
              command.scope == claimed.request.scope,
              command.expectedState == capabilityExpectedState(claimed.request),
              try requiredStringArgument("workflow_id", in: command.arguments)
                == claimed.request.workflowID,
              try requiredStringArgument("workflow_version", in: command.arguments)
                == claimed.request.workflowVersion,
              try requiredStringArgument("dispatch_id", in: command.arguments)
                == claimed.dispatchID,
              try requiredStringArgument("driver_id", in: command.arguments)
                == claimed.driverID,
              try requiredStringArgument("outcome", in: command.arguments)
                == outcome.status.rawValue,
              command.arguments["state_patch"] == .object(outcome.statePatch),
              command.arguments["evidence"] == .object(capabilityEvidenceObject(outcome)) else {
            throw SMLRuntimeError.capabilityClaimMismatch
        }
        try SMLCapabilityRouter.validate(outcome.evidence)
        if [.verify, .commit].contains(claimed.request.operation) {
            throw SMLCapabilityRouterError.insufficientEvidence(
                operation: claimed.request.operation.rawValue
            )
        }
    }

    private static func capabilityEvidenceObject(
        _ outcome: SMLCapabilityOutcome
    ) -> SMLObject {
        [
            "receipt_id": .string(outcome.evidence.receiptID),
            "source": .string(outcome.evidence.source),
            "digest": .string(outcome.evidence.digest),
            "authority": .string(outcome.evidence.authority.rawValue),
            "observed_at_epoch": .number(Decimal(outcome.evidence.observedAtEpoch)),
            "request_state_digest": .string(outcome.requestStateDigest),
        ]
    }

    private static func requiredStringArgument(
        _ key: String,
        in arguments: SMLObject
    ) throws -> String {
        guard case .string(let value)? = arguments[key], !value.isEmpty else {
            throw SMLRuntimeError.invalidArgument("\(key) must be a non-empty string")
        }
        return value
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
        let key = workflowStorageKey(id: task.workflowID, version: task.workflowVersion)
        guard let record = snapshot.workflows[key],
              record.workflow.id == task.workflowID,
              record.workflow.version == task.workflowVersion else {
            throw SMLRuntimeError.taskWorkflowMissing(task.workflowID)
        }
        return record.workflow
    }

    private static func workflowStorageKey(id: String, version: String) -> String {
        SMLRuntimeSnapshot.workflowStorageKey(id: id, version: version)
    }

    private static func activeWorkflowRecord(
        id: String,
        snapshot: SMLRuntimeSnapshot
    ) -> SMLRuntimeWorkflowRecord? {
        guard let version = snapshot.activeWorkflowVersions[id] else { return nil }
        return snapshot.workflows[workflowStorageKey(id: id, version: version)]
    }

    private static func activeWorkflowRecords(
        _ snapshot: SMLRuntimeSnapshot
    ) -> [SMLRuntimeWorkflowRecord] {
        snapshot.activeWorkflowVersions.keys.sorted().compactMap {
            activeWorkflowRecord(id: $0, snapshot: snapshot)
        }
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

    private static func validateInitialState(
        _ state: SMLObject,
        workflow: SMLWorkflow
    ) throws {
        let exposed = Set(workflow.interface.inputFields)
        for key in state.keys where !exposed.contains(key) {
            throw SMLRuntimeError.inputFieldDenied(key)
        }
        try validateStatePatch(state, workflow: workflow)
        let fields = Dictionary(uniqueKeysWithValues: workflow.stateSchema.map { ($0.name, $0) })
        for name in workflow.interface.inputFields {
            guard let field = fields[name] else { continue }
            if field.required && state[name] == nil {
                throw SMLRuntimeError.missingRequiredInput(name)
            }
        }
    }

    private static func assertExpectedState(
        _ expected: SMLObject,
        task: SMLRuntimeTask,
        workflow: SMLWorkflow,
        capabilityStateDigest: String? = nil
    ) throws {
        let fields = Set(workflow.stateSchema.map(\.name))
        for key in expected.keys.sorted() {
            let actual: SMLValue?
            switch key {
            case "task_status":
                actual = .string(task.status.rawValue)
            case "task_revision":
                actual = .number(Decimal(task.revision))
            case "instruction_id":
                actual = .string(task.currentInstructionID)
            case "workflow_version":
                actual = .string(task.workflowVersion)
            case "capability_state_digest":
                if let capabilityStateDigest {
                    actual = .string(capabilityStateDigest)
                } else {
                    let instruction = try currentInstruction(task: task, workflow: workflow)
                    actual = .string(try SMLCapabilityStateDigest.compute(
                        task: task, instruction: instruction
                    ))
                }
            default:
                guard fields.contains(key) else {
                    throw SMLRuntimeError.expectedStateMismatch("expected_state.\(key)")
                }
                actual = task.state[key]
            }
            if actual != expected[key] {
                throw SMLRuntimeError.expectedStateMismatch("expected_state.\(key)")
            }
        }
    }

    private static func assertRequiredTaskRevision(
        _ expected: SMLObject,
        task: SMLRuntimeTask
    ) throws {
        guard expected["task_revision"] == .number(Decimal(task.revision)) else {
            throw SMLRuntimeError.expectedStateMismatch("expected_state.task_revision")
        }
    }

    private static func incrementRevision(_ task: inout SMLRuntimeTask) throws {
        let (next, overflow) = task.revision.addingReportingOverflow(1)
        guard !overflow else {
            throw SMLRuntimeError.invalidTaskState("task revision overflow")
        }
        task.revision = next
    }

    private static func assertInstructionExpectedState(
        _ instruction: SMLInstruction,
        task: SMLRuntimeTask
    ) throws {
        for key in instruction.expectedState.keys.sorted()
            where task.state[key] != instruction.expectedState[key] {
            throw SMLRuntimeError.invalidTaskState(
                "instruction \(instruction.id) expected state mismatch at \(key)"
            )
        }
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

    private static func statusSummary(
        _ snapshot: SMLRuntimeSnapshot,
        role: String? = nil
    ) -> SMLRuntimeStatusSummary {
        let activeWorkflows = activeWorkflowRecords(snapshot).filter {
            role == nil || $0.role == role
        }
        let roles = Set(activeWorkflows.map(\.role))
        let tasks = snapshot.tasks.values.filter { role == nil || $0.role == role }
        let taskIDs = Set(tasks.map(\.taskID))
        let active = tasks.filter {
            ![SMLTaskStatus.completed, .failed, .escalated, .rolledBack, .refused].contains($0.status)
        }.count
        return SMLRuntimeStatusSummary(
            workflowCount: activeWorkflows.count,
            roleCount: roles.count,
            taskCount: tasks.count,
            activeTaskCount: active,
            receiptCount: snapshot.receipts.values.filter {
                taskIDs.contains($0.taskID)
            }.count
        )
    }

    private static func roleProjections(_ snapshot: SMLRuntimeSnapshot) -> [SMLRoleProjection] {
        let workflowsByRole = Dictionary(grouping: activeWorkflowRecords(snapshot), by: \.role)
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

    private static func capabilityReference(_ instruction: SMLInstruction) throws -> String {
        let reference: String?
        switch instruction.op {
        case .observe, .retrieve:
            reference = instruction.source
        case .callTool, .invokeVCard:
            reference = instruction.capability
        case .callModel:
            reference = instruction.purpose
        case .runPlugin:
            reference = instruction.plugin?.id
        case .runWorkflow:
            reference = instruction.workflow
        case .verify, .commit:
            reference = instruction.verifier
        case .branch, .assert, .checkpoint, .waitApproval, .retry, .rollback,
             .escalate, .emitReceipt, .complete:
            reference = nil
        }
        guard let reference, !reference.isEmpty else {
            throw SMLRuntimeError.invalidTaskState(
                "capability reference missing at \(instruction.id)"
            )
        }
        return reference
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
            taskRevision: task.revision,
            status: task.status,
            currentInstructionID: task.currentInstructionID,
            currentOperation: instruction?.op,
            waitingApprovalOwner: task.waitingApprovalOwner,
            capabilityDispatchID: task.capabilityClaim?.dispatchID,
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
