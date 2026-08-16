import Foundation

public struct DurableReasoningPlan: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let nodes: [ReasoningPlanNode]
    public let acceptedNodeIDs: Set<String>

    public init(id: String = UUID().uuidString, nodes: [ReasoningPlanNode],
                acceptedNodeIDs: Set<String>? = nil) {
        self.id = id
        self.nodes = nodes
        self.acceptedNodeIDs = acceptedNodeIDs ?? Set(nodes.map(\.id))
    }
}

public struct DurablePlanNodeRequest: Sendable {
    public let runID: String
    public let planID: String
    public let node: ReasoningPlanNode
    public let attempt: Int
    public let control: ReasoningControlState
}

public typealias DurablePlanNodeExecutor = @Sendable (DurablePlanNodeRequest) async throws
    -> PlanNodeExecutionReceipt
public typealias DurablePlanRepairer = @Sendable (DurablePlanNodeRequest, PlanNodeExecutionReceipt) async throws
    -> NodeScopedRepairReceipt?
public typealias DurablePlanStateFinalizer = @Sendable (
    inout ReasoningControlState, DurablePlanNodeRequest, PlanNodeExecutionReceipt
) throws -> Void

public enum DurablePlanExecuteStatus: String, Codable, Sendable, Equatable {
    case completed
    case blocked
}

public struct DurablePlanExecuteOutcome: Codable, Sendable, Equatable {
    public let status: DurablePlanExecuteStatus
    public let summary: String
    public let control: ReasoningControlState
}

/// Typed, checkpointed plan execution. Accepted node IDs are monotonic and survive targeted
/// replans; a selected repair can retry only the failed node or add replacement nodes without
/// discarding already accepted work.
public final class DurablePlanExecuteLoop: @unchecked Sendable {
    private let runID: String
    private let goalFingerprint: String?
    private let store: any ReasoningControlStateStoring
    private let maxReplans: Int

    public init(runID: String, goalFingerprint: String? = nil,
                store: any ReasoningControlStateStoring, maxReplans: Int = 4) {
        self.runID = runID
        self.goalFingerprint = goalFingerprint
        self.store = store
        self.maxReplans = max(0, maxReplans)
    }

    public func run(plan: DurableReasoningPlan, resume: Bool = true,
                    execute: @escaping DurablePlanNodeExecutor,
                    repair: DurablePlanRepairer? = nil,
                    finalizeState: DurablePlanStateFinalizer? = nil) async throws
        -> DurablePlanExecuteOutcome {
        var control: ReasoningControlState
        if let restored = try await store.load(runID: runID) {
            guard resume else { throw ReasoningControlError.stateAlreadyExists(runID) }
            if let expected = goalFingerprint, let actual = restored.goalFingerprint, expected != actual {
                throw ReasoningControlError.invalidState("checkpoint goal fingerprint does not match this run")
            }
            control = restored
            if control.activePlanNodeID != nil {
                control = try await store.update(runID: runID, create: nil) { state in
                    try state.recoverInterruptedPlanNode()
                }
            }
            let missing = plan.nodes.filter { control.planNodes[$0.id] == nil }
            if !missing.isEmpty {
                control = try await store.update(runID: runID, create: nil) { state in
                    try state.installPlanNodes(missing, acceptedIDs: Set(missing.map(\.id)))
                }
            }
        } else {
            var initial = ReasoningControlState(id: runID, route: .planned,
                                                goalFingerprint: goalFingerprint)
            try initial.installPlanNodes(plan.nodes, acceptedIDs: plan.acceptedNodeIDs)
            control = try await store.createIfAbsent(initial)
        }

        while true {
            let accepted = control.acceptedPlanNodeIDs.compactMap { control.planNodes[$0] }
            if accepted.allSatisfy({ $0.phase == .succeeded || $0.phase == .superseded }) {
                return DurablePlanExecuteOutcome(status: .completed,
                                                 summary: "all accepted plan nodes completed",
                                                 control: control)
            }

            guard let record = nextRunnableNode(in: control) else {
                return DurablePlanExecuteOutcome(status: .blocked,
                                                 summary: "no accepted plan node is runnable",
                                                 control: control)
            }
            let nodeID = record.node.id
            control = try await store.update(runID: runID, create: nil) { state in
                try state.activatePlanNode(nodeID)
            }
            guard let active = control.planNodes[nodeID] else {
                throw ReasoningControlError.unknownPlanNode(nodeID)
            }
            let request = DurablePlanNodeRequest(runID: runID, planID: plan.id,
                                                 node: active.node, attempt: active.attempts,
                                                 control: control)
            var receipt = try await execute(request)
            guard receipt.nodeID == nodeID else {
                throw ReasoningControlError.invalidPlanTransition("executor returned a receipt for another node")
            }
            if receipt.outcome == .succeeded && !satisfies(active.node.completionRequirement, receipt: receipt) {
                receipt = PlanNodeExecutionReceipt(
                    nodeID: receipt.nodeID, outcome: .failed,
                    summary: "completion receipt did not satisfy \(active.node.completionRequirement.rawValue)",
                    tokensSpent: receipt.tokensSpent, progress: receipt.progress,
                    evidence: receipt.evidence, childCheckpointID: receipt.childCheckpointID
                )
            }
            let finalizedReceipt = receipt
            control = try await store.update(runID: runID, create: nil) { state in
                try state.recordPlanNodeExecution(finalizedReceipt)
                try finalizeState?(&state, request, finalizedReceipt)
            }

            guard receipt.outcome != .succeeded else { continue }
            guard control.replanCount < maxReplans, let repair,
                  let repairReceipt = try await repair(request, receipt) else {
                return DurablePlanExecuteOutcome(status: .blocked,
                                                 summary: receipt.summary,
                                                 control: control)
            }
            guard repairReceipt.nodeID == nodeID else {
                throw ReasoningControlError.invalidRepair("repair receipt is not scoped to the failed node")
            }
            control = try await store.update(runID: runID, create: nil) { state in
                try state.applyRepair(repairReceipt)
            }
        }
    }

    private func nextRunnableNode(in state: ReasoningControlState) -> ReasoningPlanNodeRecord? {
        state.acceptedPlanNodeIDs.compactMap { state.planNodes[$0] }
            .filter { record in
                guard record.phase == .accepted else { return false }
                return record.node.dependencies.allSatisfy { dependency in
                    guard let phase = state.planNodes[dependency]?.phase else { return false }
                    return phase == .succeeded || phase == .superseded
                }
            }
            .sorted { $0.node.id < $1.node.id }
            .first
    }

    private func satisfies(_ requirement: PlanNodeCompletionRequirement,
                           receipt: PlanNodeExecutionReceipt) -> Bool {
        switch requirement {
        case .summary:
            return !receipt.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .artifact:
            return receipt.progress.contains { if case .artifact = $0.evidence { return true }; return false }
        case .passingCheck:
            return receipt.progress.contains {
                if case .checkTransition(let check) = $0.evidence { return check.state == .passed }
                return false
            }
        case .evidence:
            return !receipt.evidence.isEmpty || receipt.progress.contains {
                if case .evidence = $0.evidence { return true }; return false
            }
        case .delegation:
            return receipt.childCheckpointID != nil || receipt.progress.contains {
                if case .delegationCompleted = $0.evidence { return true }; return false
            }
        }
    }
}
