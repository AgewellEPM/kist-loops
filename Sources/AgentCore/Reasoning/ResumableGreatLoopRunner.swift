import Foundation

public struct ResumableGreatLoopCycleRequest: Sendable {
    public let control: ReasoningControlState
    public let remainingTokens: Int?
    public let requestedEffort: ProviderReasoningEffort
}

public struct ResumableGreatLoopCycleResult: Sendable {
    /// This must be a verifier/referee fact, never the worker model's self-report.
    public let doneAndVerified: Bool
    public let tokensSpent: Int
    public let progress: [ReasoningProgressReceipt]
    public let summary: String
    public let evidence: [ReasoningEvidenceReference]
    public let feedback: [ReasoningEvidenceReference]
    public let childCheckpointIDs: [String: String]
    public let repairReceipts: [NodeScopedRepairReceipt]
    public let reasoningSummary: String?
    public let providerHandles: [OpaqueProviderReasoningHandle]
    public let providerEffortRecords: [ProviderEffortRecord]

    public init(doneAndVerified: Bool, tokensSpent: Int,
                progress: [ReasoningProgressReceipt], summary: String,
                evidence: [ReasoningEvidenceReference] = [],
                feedback: [ReasoningEvidenceReference] = [],
                childCheckpointIDs: [String: String] = [:],
                repairReceipts: [NodeScopedRepairReceipt] = [],
                reasoningSummary: String? = nil,
                providerHandles: [OpaqueProviderReasoningHandle] = [],
                providerEffortRecords: [ProviderEffortRecord] = []) {
        self.doneAndVerified = doneAndVerified
        self.tokensSpent = max(0, tokensSpent)
        self.progress = progress
        self.summary = String(summary.prefix(8_000))
        self.evidence = evidence
        self.feedback = feedback
        self.childCheckpointIDs = childCheckpointIDs
        self.repairReceipts = repairReceipts
        self.reasoningSummary = reasoningSummary
        self.providerHandles = providerHandles
        self.providerEffortRecords = Array(providerEffortRecords.suffix(32))
    }
}

public typealias ResumableGreatLoopCycle = @Sendable (ResumableGreatLoopCycleRequest) async throws
    -> ResumableGreatLoopCycleResult

/// A durable outer GreatLoop. It reconstructs GreatLoopState from ReasoningControlState on every
/// iteration, so process death resumes cycle/token/no-progress counters and child checkpoints.
/// Progress is derived only from typed material receipts; there is no Boolean success escape hatch.
public final class ResumableGreatLoopRunner: @unchecked Sendable {
    private let runID: String
    private let route: ReasoningRoute
    private let goalFingerprint: String?
    private let caps: GreatLoopCaps
    private let store: any ReasoningControlStateStoring
    private let effort: @Sendable (ReasoningControlState) -> ProviderReasoningEffort
    private let clock: @Sendable () -> Double
    private let runCycle: ResumableGreatLoopCycle

    public init(runID: String, route: ReasoningRoute, goalFingerprint: String? = nil,
                caps: GreatLoopCaps, store: any ReasoningControlStateStoring,
                effort: @escaping @Sendable (ReasoningControlState) -> ProviderReasoningEffort,
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                runCycle: @escaping ResumableGreatLoopCycle) {
        self.runID = runID
        self.route = route
        self.goalFingerprint = goalFingerprint
        self.caps = caps
        self.store = store
        self.effort = effort
        self.clock = clock
        self.runCycle = runCycle
    }

    public func run(resume: Bool = true) async throws -> GreatLoopDecision {
        var control: ReasoningControlState
        if let restored = try await store.load(runID: runID) {
            guard resume else { throw ReasoningControlError.stateAlreadyExists(runID) }
            control = restored
        } else {
            control = try await store.save(ReasoningControlState(
                id: runID, route: route, goalFingerprint: goalFingerprint, updatedAt: clock()
            ))
        }

        while true {
            let outer = GreatLoopState(cycle: control.cycle,
                                       tokensSpent: control.tokensSpent,
                                       nowEpoch: clock(),
                                       lastCycleDoneAndVerified: control.lastCycleDoneAndVerified,
                                       consecutiveNoProgress: control.consecutiveNoProgress)
            let decision = GreatLoopController.decide(state: outer, caps: caps)
            if decision.isTerminal { return decision }

            let remaining = caps.maxTokens.map { max(0, $0 - control.tokensSpent) }
            let request = ResumableGreatLoopCycleRequest(
                control: control, remainingTokens: remaining, requestedEffort: effort(control)
            )
            let result = try await runCycle(request)

            control = try await store.update(runID: runID, create: nil) { state in
                state.cycle += 1
                try state.recordTokenSpend(result.tokensSpent)
                state.lastCycleDoneAndVerified = result.doneAndVerified
                var advanced = false
                for receipt in result.progress {
                    if MonotonicProgressReducer.apply(receipt, to: &state.progress) { advanced = true }
                }
                state.consecutiveNoProgress = advanced ? 0 : state.consecutiveNoProgress + 1
                state.addEvidence(result.evidence)
                state.addFeedback(result.feedback)
                for (nodeID, checkpointID) in result.childCheckpointIDs {
                    state.childCheckpointIDs[nodeID] = checkpointID
                }
                for receipt in result.repairReceipts { state.recordRepair(receipt) }
                if let summary = result.reasoningSummary { state.setReasoningSummary(summary) }
                for handle in result.providerHandles { state.upsertProviderHandle(handle) }
                for record in result.providerEffortRecords { state.recordProviderEffort(record) }
            }
        }
    }
}
