import Foundation

/// Names the binding checks a final verification receipt fails (0.17.63). `validatesBinding`
/// answers yes/no; when a finished, council-approved build is rejected as "missing or unbound",
/// the operator needs the field, not the verdict. Mirrors `validatesBinding` check for check.
extension PlanFinalVerificationReceipt {
    public func bindingMismatchReasons(
        missionInstanceID expectedMissionInstanceID: String,
        contractID expectedContractID: String,
        completionContractFingerprint expectedCompletion: String,
        obligationsFingerprint expectedObligations: String,
        executionPolicyFingerprint expectedPolicy: String,
        workspaceManifestDigest expectedManifest: String,
        governedWorkspaceDigest expectedWorkspace: String,
        canonicalFunctionalObjectiveFingerprint expectedObjective: String? = nil,
        workspaceManifestPolicyFingerprint expectedManifestPolicy: String? = nil,
        workspaceManifestRevision expectedManifestRevision: Int? = nil
    ) -> [String] {
        var reasons: [String] = []
        if expectedMissionInstanceID.isEmpty || missionInstanceID != expectedMissionInstanceID { reasons.append("missionInstanceID") }
        if !hasValidEvidenceDigest { reasons.append("evidenceDigest") }
        if tool != "run_command" { reasons.append("tool=\(tool)") }
        if !freshAfterMutationFrontier { reasons.append("freshAfterMutationFrontier") }
        if trustedCommandReference?.isValid != true { reasons.append("trustedCommandReference") }
        if trustedCommandReference?.exitCode != actualExitCode { reasons.append("reference.exitCode") }
        if expectedExitCode != 0 || actualExitCode != 0 { reasons.append("exitCode(expected=\(expectedExitCode) actual=\(actualExitCode))") }
        if captureOrdinal <= 0 { reasons.append("captureOrdinal=\(captureOrdinal)") }
        if let frontier = mutationFrontierOrdinal, captureOrdinal <= frontier {
            reasons.append("captureOrdinal(\(captureOrdinal))<=mutationFrontierOrdinal(\(frontier))")
        }
        if contractID != expectedContractID { reasons.append("contractID") }
        if completionContractFingerprint != expectedCompletion { reasons.append("completionContractFingerprint") }
        if obligationsFingerprint != expectedObligations { reasons.append("obligationsFingerprint") }
        if executionPolicyFingerprint != expectedPolicy { reasons.append("executionPolicyFingerprint") }
        if workspaceManifestDigest != expectedManifest {
            reasons.append("workspaceManifestDigest(receipt=\(workspaceManifestDigest.prefix(12)) expected=\(expectedManifest.prefix(12)))")
        }
        if governedWorkspaceDigest != expectedWorkspace {
            reasons.append("governedWorkspaceDigest(receipt=\(governedWorkspaceDigest.prefix(12)) expected=\(expectedWorkspace.prefix(12)))")
        }
        if let expectedObjective, canonicalFunctionalObjectiveFingerprint != expectedObjective { reasons.append("canonicalFunctionalObjectiveFingerprint") }
        if let expectedManifestPolicy, workspaceManifestPolicyFingerprint != expectedManifestPolicy { reasons.append("workspaceManifestPolicyFingerprint") }
        if let expectedManifestRevision, workspaceManifestRevision != expectedManifestRevision {
            reasons.append("workspaceManifestRevision(receipt=\(workspaceManifestRevision.map(String.init) ?? "nil") expected=\(expectedManifestRevision))")
        }
        if expectedObjective != nil {
            if !(planID?.isEmpty == false) { reasons.append("planID") }
            if planRevision == nil { reasons.append("planRevision") }
            if !(workspaceActionReceiptDigest?.isEmpty == false) { reasons.append("workspaceActionReceiptDigest") }
        }
        let stdinConsistent: Bool = invocation.hasStandardInput
            ? invocation.standardInputSourceKind != .none
                && invocation.standardInputDigest?.isEmpty == false
                && invocation.standardInputByteCount > 0
                && (invocation.standardInputSourceKind == .governedPath
                    ? invocation.standardInputRelativePath?.isEmpty == false
                    : invocation.standardInputRelativePath == nil)
            : invocation.standardInputSourceKind == .none
                && invocation.standardInputDigest == nil
                && invocation.standardInputRelativePath == nil
                && invocation.standardInputByteCount == 0
        if !stdinConsistent { reasons.append("standardInput binding") }
        return reasons
    }
}
