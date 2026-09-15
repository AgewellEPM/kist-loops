import Foundation

/// Applies the host approval policy using the same predicate as workflow gate injection.
/// Existing author-supplied gates still require approval under a relaxed policy.
///
/// Gate injection (`SMLWorkflowApprovalGating`) is structurally sufficient — a task cannot reach
/// `waitingCapability` without crossing its `WAIT_APPROVAL` — but this wrapper makes the
/// approve-everything contract independent of graph shape: even a workflow admitted WITHOUT gates
/// (author error, policy drift, hand-edited store) will not dispatch a capability unless its
/// current instruction is guarded by a gate whose approval is the task's most recent
/// approval-relevant receipt. The checked task revision is passed into the coordinator so
/// subsequent request construction and the durable claim remain bound to that same state.
public struct SMLApprovalGatedCoordinator: Sendable {
    private let coordinator: SMLCapabilityCoordinator
    private let store: SMLRuntimeStore
    private let policy: SMLApprovalPolicy

    public init(
        coordinator: SMLCapabilityCoordinator,
        store: SMLRuntimeStore,
        policy: SMLApprovalPolicy = SMLApprovalPolicy()
    ) {
        self.coordinator = coordinator
        self.store = store
        self.policy = policy
    }

    public enum ApprovalGateError: Error, Equatable, CustomStringConvertible {
        case unknownTask(String)
        case workflowRecordMissing(taskID: String, workflowID: String, version: String)
        case instructionNotGated(taskID: String, instructionID: String)
        case approvalMissing(taskID: String, gateID: String)
        case approvalSuperseded(taskID: String, gateID: String, laterReceiptKind: String)

        public var description: String {
            switch self {
            case .unknownTask(let id):
                return "approval gate: task '\(id)' does not exist"
            case .workflowRecordMissing(let taskID, let workflowID, let version):
                return "approval gate: task '\(taskID)' references workflow '\(workflowID)' "
                    + "version '\(version)' which is not installed in the store"
            case .instructionNotGated(let taskID, let instructionID):
                return "approval gate: task '\(taskID)' is parked at '\(instructionID)' which has "
                    + "no WAIT_APPROVAL gate — under approve-everything, ungated capability "
                    + "instructions never dispatch; re-import the workflow through approval gating"
            case .approvalMissing(let taskID, let gateID):
                return "approval gate: task '\(taskID)' has no approval receipt for gate "
                    + "'\(gateID)' — approve it first (task.approve_request with the current "
                    + "task_revision)"
            case .approvalSuperseded(let taskID, let gateID, let kind):
                return "approval gate: task '\(taskID)' approval for '\(gateID)' is not the most "
                    + "recent approval-relevant receipt (a '\(kind)' receipt follows it) — "
                    + "re-approve at the current revision"
            }
        }
    }

    /// Executes the task's pending capability step if and only if the approval contract holds.
    /// The gate for the current instruction must exist, and the task's receipt trail must show
    /// its approval as the latest approval-relevant event (no refusal/rollback/escalation after).
    public func executeNext(taskID: String) async throws -> SMLCommandResult {
        let revision = try await requireApprovedGate(taskID: taskID)
        return try await coordinator.executeNext(taskID: taskID, expectedTaskRevision: revision)
    }

    private func requireApprovedGate(taskID: String) async throws -> Int {
        let snapshot = try await store.load()
        guard let task = snapshot.tasks[taskID] else {
            throw ApprovalGateError.unknownTask(taskID)
        }
        let key = SMLRuntimeSnapshot.workflowStorageKey(
            id: task.workflowID, version: task.workflowVersion
        )
        guard let record = snapshot.workflows[key] else {
            throw ApprovalGateError.workflowRecordMissing(
                taskID: taskID, workflowID: task.workflowID, version: task.workflowVersion
            )
        }
        let gates = record.workflow.instructions.filter {
            $0.op == .waitApproval && $0.next == task.currentInstructionID
        }
        if gates.isEmpty,
           let instruction = record.workflow.instructions.first(where: {
               $0.id == task.currentInstructionID
           }),
           !SMLWorkflowApprovalGating.shouldGate(instruction, policy: policy) {
            return task.revision
        }
        guard let gate = gates.first else {
            throw ApprovalGateError.instructionNotGated(
                taskID: taskID, instructionID: task.currentInstructionID
            )
        }

        // Walk the task's receipts newest-first: the FIRST approval-relevant receipt must be the
        // approval of a gate leading to this instruction. Branch-specific gates are alternatives:
        // the task's actual receipt trail identifies the path it took.
        let gateIDs = Set(gates.map(\.id))
        let approvalRelevant: Set<SMLRuntimeReceiptKind> = [
            .approved, .refused, .rollback, .escalated,
        ]
        for receiptID in task.receiptIDs.reversed() {
            guard let receipt = snapshot.receipts[receiptID],
                  approvalRelevant.contains(receipt.kind) else { continue }
            if receipt.kind == .approved,
               let instructionID = receipt.instructionID,
               gateIDs.contains(instructionID) {
                return task.revision
            }
            throw ApprovalGateError.approvalSuperseded(
                taskID: taskID, gateID: gate.id, laterReceiptKind: receipt.kind.rawValue
            )
        }
        throw ApprovalGateError.approvalMissing(taskID: taskID, gateID: gate.id)
    }
}
