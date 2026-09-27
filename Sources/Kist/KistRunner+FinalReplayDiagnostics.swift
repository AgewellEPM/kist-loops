import Foundation
import AgentCore

/// Why `builderFinalReplayEvidence` declined a receipt (0.17.63). Mirrors its guard check for
/// check so the operator sees the field, not just "not admitted".
extension KistRunner {
    static func builderFinalReplayRejectionReasons(
        receipt: PlanFinalVerificationReceipt?,
        missionInstanceID: String,
        contractID: String,
        subjectDigest: String
    ) -> [String] {
        guard let receipt else { return ["no receipt was minted by the plan-execute loop"] }
        var reasons: [String] = []
        if receipt.missionInstanceID != missionInstanceID { reasons.append("missionInstanceID") }
        if receipt.contractID != contractID { reasons.append("contractID") }
        if receipt.tool != "run_command" { reasons.append("tool=\(receipt.tool)") }
        if !receipt.hasValidEvidenceDigest { reasons.append("evidenceDigest") }
        if !receipt.freshAfterMutationFrontier { reasons.append("freshAfterMutationFrontier") }
        if receipt.captureOrdinal <= (receipt.mutationFrontierOrdinal ?? -1) {
            reasons.append("captureOrdinal(\(receipt.captureOrdinal))<=mutationFrontier(\(receipt.mutationFrontierOrdinal ?? -1))")
        }
        if receipt.expectedExitCode != 0 || receipt.actualExitCode != receipt.expectedExitCode {
            reasons.append("exitCode(expected=\(receipt.expectedExitCode) actual=\(receipt.actualExitCode))")
        }
        if receipt.governedWorkspaceDigest != subjectDigest {
            reasons.append("governedWorkspaceDigest(receipt=\(receipt.governedWorkspaceDigest.prefix(12)) subject=\(subjectDigest.prefix(12)))")
        }
        if receipt.commandFingerprint.isEmpty { reasons.append("commandFingerprint empty") }
        if receipt.outputDigest.isEmpty { reasons.append("outputDigest empty") }
        if receipt.completionContractFingerprint.isEmpty { reasons.append("completionContractFingerprint empty") }
        if receipt.executionPolicyFingerprint.isEmpty { reasons.append("executionPolicyFingerprint empty") }
        if let reference = receipt.trustedCommandReference {
            if !reference.isValid { reasons.append("reference.invalid") }
            if reference.exitCode != receipt.actualExitCode { reasons.append("reference.exitCode") }
            if reference.timedOut || reference.wasSignalled { reasons.append("reference.exitState") }
            if receipt.outputDigest != reference.fullStreamDigest { reasons.append("outputDigest≠reference.fullStreamDigest") }
        } else {
            reasons.append("trustedCommandReference missing")
        }
        return reasons.isEmpty ? ["admitted"] : reasons
    }
}
