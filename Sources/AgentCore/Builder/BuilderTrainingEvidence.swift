import Foundation

/// Read-only historical evidence inspection for dataset exports. This produces data,
/// never a BuilderFinalAcceptanceAuthority or permission to resume/promote a run.
public enum BuilderTrainingEvidence {
    public struct Report: Codable, Sendable {
        public let schema = "kist.builder-training-evidence.v1"
        public let scope = "historical sealed snapshot; not current deployment or evolution authority"
        public let snapshotSHA256: String
        public let contractID: String
        public let sequence: Int
        public let observedAt: Date
        public let historicalAccepted: Bool
        public let completionMode: BuilderCompletionMode?
        public let finalAuthority: BuilderFinalAuthority?
        public let verification: BuilderVerifierReceipt?
        public let review: BuilderReviewReceipt?
        public let mutations: [BuilderTransactionPromotionReceipt]
        public let usage: BuilderUsageReceipt?
        public let failures: [String]
        public let issues: [String]
    }

    public static func inspect(_ data: Data) throws -> Report {
        guard data.count <= BuilderDurableIO.maximumBytes else {
            throw ToolError.execution("Builder snapshot exceeds the inspection bound")
        }
        let envelope = try JSONDecoder().decode(SealedBuilderRunSnapshot.self, from: data)
        guard try BuilderDurableIO.canonicalData(envelope) == data else {
            throw ToolError.execution("Builder snapshot is not canonical")
        }
        let canonical = String(decoding: try BuilderDurableIO.canonicalData(envelope.snapshot), as: UTF8.self)
        guard ForgeSeal.verifyWithoutCreatingKey(canonical, seal: envelope.seal) else {
            throw ToolError.execution("Builder snapshot seal could not be authenticated")
        }
        let snapshot = envelope.snapshot
        let final = snapshot.finalReceipt
        var issues: [String] = []
        if snapshot.schemaVersion != 2 { issues.append("unsupported snapshot schema") }
        if snapshot.finalizationPending { issues.append("finalization is still pending") }
        if !snapshot.reviewAccepted { issues.append("review is not accepted") }
        if final?.accepted != true { issues.append("no accepted final receipt") }
        if final?.hasValidBuilderFinalAuthority != true { issues.append("accepted final authority is missing or invalid") }
        if let final, let authority = final.authority {
            let telemetryDigest = BuilderEvidenceDigest.sha256(String(
                decoding: try BuilderDurableIO.canonicalData(snapshot.trustedTelemetry), as: UTF8.self))
            if final.contractID != snapshot.contractID
                || authority.parentContractFingerprint != snapshot.parentContractFingerprint
                || authority.graphFingerprint != snapshot.graphFingerprint
                || authority.commitEpoch != snapshot.commitEpoch
                || authority.trustedTelemetryDigest != telemetryDigest {
                issues.append("final authority does not bind this snapshot and telemetry")
            }
            if !final.verification.passed || !final.verification.deterministic || !final.review.accepted {
                issues.append("final verification or review is not passing")
            }
        }
        var mutations: [BuilderTransactionPromotionReceipt] = []
        var failures: [String] = []
        for (node, state) in snapshot.nodeStates.sorted(by: { $0.key < $1.key }) {
            if let failure = state.failureReason { failures.append("\(node): \(SecretMasker.mask(failure))") }
            if let promotion = state.promotion {
                if !promotion.hasValidReceiptDigest || promotion.builderContractID != snapshot.contractID
                    || promotion.nodeID != node || promotion.attempt != state.attempts || state.phase != .accepted {
                    issues.append("mutation receipt is invalid or belongs to another attempt: \(node)")
                } else { mutations.append(promotion) }
            }
        }
        if final?.verification.completionMode == .build && mutations.flatMap(\.operations).isEmpty {
            issues.append("build completion has no accepted source mutations")
        }
        return Report(snapshotSHA256: BuilderEvidenceDigest.sha256(String(decoding: data, as: UTF8.self)),
            contractID: snapshot.contractID, sequence: snapshot.sequence, observedAt: snapshot.updatedAt,
            historicalAccepted: issues.isEmpty, completionMode: final?.verification.completionMode,
            finalAuthority: final?.authority, verification: final?.verification, review: final?.review,
            mutations: mutations, usage: snapshot.usage, failures: failures, issues: issues)
    }
}
