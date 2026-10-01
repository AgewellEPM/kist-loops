import Foundation

/// Host-authenticated final receipt on the HEALTHY ordering (0.17.63).
///
/// The plan executor mints its final deterministic replay receipt only inside the replay branch,
/// and that branch used to open only when an earlier passed build/test had been INVALIDATED by a
/// later mutation. A plan whose last step is the passing sealed test — the ordering every good
/// plan uses — therefore produced no host receipt at all, and host-owned final review rejected
/// the finished build ("final deterministic replay receipt is missing or unbound") after the
/// files were already committed and the council had approved (live 2026-09-27, hello-world
/// unittest run: work retained as "acceptance-persistence-pending", exit 1).
///
/// This request has the same shape as an invalidation so the existing bounded replay path can
/// serve it unchanged: replay the LAST passed check once under host custody, bind the receipt to
/// the current workspace, and let the usual attempt limit / seen-state rules apply.
extension CompletionVerifier {
    /// Data parsing may bind a non-source artifact's replay receipt, but can never stand in
    /// for a build/test after source edits, opaque commands, or an unbound resume boundary.
    static func isFinalVerification(_ record: ActionRecord, in trajectory: [ActionRecord]) -> Bool {
        if record.observedEffects.verification == .buildOrTest { return true }
        return record.observedEffects.verification == .dataValidation
            && !trajectory.contains { $0.observedEffects.requiresBuildVerification }
    }

    /// The last passed build/test in `trajectory`, expressed as a replay request, or nil when the
    /// trajectory holds no passed check to replay (then nothing can be authenticated and the
    /// caller falls through to the existing "needs verification" outcome).
    public func hostReceiptReplayRequest(in trajectory: [ActionRecord]) -> InvalidatedVerification? {
        guard let lastPassed = trajectory.lastIndex(where: {
            $0.success && Self.isFinalVerification($0, in: trajectory)
        }) else { return nil }
        let check = trajectory[lastPassed]
        let fingerprint = check.argsFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = fingerprint.isEmpty ? check.tool : "\(check.tool): \(fingerprint.prefix(220))"
        return InvalidatedVerification(
            invalidatingStep: lastPassed + 1,
            invalidatingMutation: "host-authenticated final receipt required",
            invalidatingMutationSucceeded: true,
            lastPassedStep: lastPassed + 1,
            lastPassedCheck: label,
            lastPassedTool: check.tool,
            lastPassedFingerprint: check.argsFingerprint)
    }
}
