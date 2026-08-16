import Foundation

public enum MonotonicProgressReducer {
    /// Applies a typed receipt and returns true only when it advances material state.
    /// Duplicate receipts, unchanged artifacts, and repeated check states are idempotent.
    @discardableResult
    public static func apply(_ receipt: ReasoningProgressReceipt,
                             to snapshot: inout MonotonicProgressSnapshot) -> Bool {
        guard !snapshot.receipts.contains(where: { $0.id == receipt.id }) else { return false }
        let advanced: Bool
        switch receipt.evidence {
        case .artifact(let artifact):
            advanced = snapshot.artifactRevisions[artifact.id] != artifact.revision
            if advanced { snapshot.artifactRevisions[artifact.id] = artifact.revision }
        case .workspaceMutation(let effectID, _), .externalStateChange(let effectID, _),
             .delegationCompleted(let effectID, _, _):
            advanced = snapshot.effectIDs.insert(effectID).inserted
        case .evidence(let reference):
            advanced = snapshot.evidenceIDs.insert(reference.id).inserted
        case .checkTransition(let check):
            advanced = snapshot.checkStates[check.id] != check.state
            if advanced { snapshot.checkStates[check.id] = check.state }
        }
        guard advanced else { return false }
        snapshot.revision += 1
        snapshot.receipts.append(receipt)
        if snapshot.receipts.count > 2_000 {
            snapshot.receipts = Array(snapshot.receipts.suffix(2_000))
        }
        return true
    }
}

public actor MonotonicProgressTracker {
    private var state: MonotonicProgressSnapshot

    public init(restoring state: MonotonicProgressSnapshot = MonotonicProgressSnapshot()) {
        self.state = state
    }

    @discardableResult
    public func observe(_ receipt: ReasoningProgressReceipt) -> Bool {
        MonotonicProgressReducer.apply(receipt, to: &state)
    }

    public func snapshot() -> MonotonicProgressSnapshot { state }

    public func restore(_ snapshot: MonotonicProgressSnapshot) throws {
        guard snapshot.revision >= state.revision else {
            throw ReasoningControlError.nonMonotonicUpdate("progress revision regressed")
        }
        state = snapshot
    }
}
