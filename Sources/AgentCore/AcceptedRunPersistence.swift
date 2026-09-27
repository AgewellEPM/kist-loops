import Foundation

public struct AcceptedRunPersistenceResult: Sendable, Equatable {
    public let receipt: AcceptedRunReceipt
    public let ledgerWrite: RunLedgerTrustWrite

    public init(receipt: AcceptedRunReceipt, ledgerWrite: RunLedgerTrustWrite) {
        self.receipt = receipt
        self.ledgerWrite = ledgerWrite
    }
}

public enum AcceptedRunAuthorityError: Error, Sendable, Equatable, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason):
            return "accepted-run authority rejected: \(reason)"
        }
    }
}

/// The only ordered persistence composition for a dashboard-bindable accepted run.
///
/// The exact canonical ledger row is committed first and its sealed receipt/commit marker last. A
/// ledger-only interruption remains amber. Resume validates the same canonical row, then reuses or
/// mints exactly one receipt which signs that row's digest and the active project identity.
public final class AcceptedRunPersistence {
    private let projectRoot: String
    private let maxLedgerRecords: Int

    public init(projectRoot: String, maxLedgerRecords: Int = 1000) {
        self.projectRoot = projectRoot
        self.maxLedgerRecords = maxLedgerRecords
    }

    @discardableResult
    public func persistPlanExecuteAccepted(
        _ run: RunRecord,
        authorizing authority: BuilderFinalAcceptanceAuthority,
        now: Date = Date(),
        freshness: TimeInterval = AcceptedRunReceipt.defaultFreshness
    ) throws -> AcceptedRunPersistenceResult {
        // The opaque authority can only be constructed by BuilderRun after its accepted final snapshot
        // is durable. Public/fabricated BuilderFinalReceipt values cannot reach this mint boundary.
        try Self.validateIndependentPlanExecuteAuthority(authority, run: run, now: now)
        guard let projectIdentity = run.projectIdentity else {
            throw RunLedgerTrustError.invalidTrustedRecord("projectIdentity")
        }
        let rootSnapshot = try AcceptedRunProjectIdentitySnapshot.capture(
            projectRoot: projectRoot)
        guard rootSnapshot.digest == projectIdentity else {
            throw RunLedgerTrustError.invalidTrustedRecord("projectIdentity")
        }
        let receiptStore = AcceptedRunReceiptStore(projectRoot: rootSnapshot.canonicalRoot)
        let ledger = RunLedger(
            projectRoot: rootSnapshot.canonicalRoot, maxRecords: maxLedgerRecords)
        guard let contractID = run.contractID else {
            throw RunLedgerTrustError.invalidTrustedRecord("contractID")
        }
        guard let objectiveFingerprint = run.objectiveFingerprint else {
            throw RunLedgerTrustError.invalidTrustedRecord("objectiveFingerprint")
        }
        guard let verificationSubject = run.verificationSubject else {
            throw RunLedgerTrustError.invalidTrustedRecord("verificationSubject")
        }
        guard let verificationDigest = run.verificationDigest else {
            throw RunLedgerTrustError.invalidTrustedRecord("verificationDigest")
        }

        let ledgerRecordDigest = try RunLedger.canonicalRecordDigest(run)
        let write = try ledger.recordTrustCandidate(
            run, ledgerRecordDigest: ledgerRecordDigest)
        // Detect a rename/replacement across the ledger transaction. If this fails, the ledger-only
        // row remains non-authoritative and an exact resume may retry against the active root.
        guard try rootSnapshot.isStillCurrent() else {
            throw RunLedgerTrustError.persistence("project identity changed before receipt commit")
        }
        let receipt = try receiptStore.mintOrValidateAccepted(
            runID: run.id, projectIdentity: projectIdentity,
            contractID: contractID, exactGoal: run.goal,
            objectiveFingerprint: objectiveFingerprint,
            verificationSubject: verificationSubject,
            verificationDigest: verificationDigest,
            ledgerRecordDigest: ledgerRecordDigest,
            now: now, freshness: freshness)
        guard try rootSnapshot.isStillCurrent() else {
            throw RunLedgerTrustError.persistence("project identity changed after receipt commit")
        }
        return AcceptedRunPersistenceResult(receipt: receipt, ledgerWrite: write)
    }

    private static func validateIndependentPlanExecuteAuthority(
        _ authority: BuilderFinalAcceptanceAuthority, run: RunRecord, now: Date
    ) throws {
        guard authority.isValid else {
            throw AcceptedRunAuthorityError.invalid(
                "Builder final authority is missing, fabricated, or detached from telemetry")
        }
        let final = authority.finalReceipt
        guard let objectiveFingerprint = run.objectiveFingerprint,
              authority.objectiveFingerprint == objectiveFingerprint else {
            throw AcceptedRunAuthorityError.invalid(
                "run objective is not bound to the sealed Builder authority")
        }
        guard run.success, run.verified else {
            throw AcceptedRunAuthorityError.invalid(
                "run outcome is not accepted and independently verified")
        }
        guard let contractID = run.contractID, final.contractID == contractID else {
            throw AcceptedRunAuthorityError.invalid("contract ID is missing or mismatched")
        }
        guard final.accepted else {
            throw AcceptedRunAuthorityError.invalid("Builder final receipt was not accepted")
        }
        guard final.route == .planned else {
            throw AcceptedRunAuthorityError.invalid("Builder final route is not PlanExecute")
        }
        guard run.route == final.route.rawValue,
              run.at.isFinite,
              run.at == final.completedAt.timeIntervalSince1970 else {
            throw AcceptedRunAuthorityError.invalid(
                "run route/timestamp projection does not match the sealed Builder final")
        }

        let verification = final.verification
        guard verification.scope == .final, verification.deterministic, verification.passed,
              verification.provider.caseInsensitiveCompare("kist") == .orderedSame,
              verification.model.caseInsensitiveCompare("deterministic") == .orderedSame,
              !verification.checks.isEmpty, verification.checks.allSatisfy(\.passed),
              verification.failureFingerprint == nil else {
            throw AcceptedRunAuthorityError.invalid(
                "final deterministic host verification is absent or failed")
        }
        guard verification.missionInstanceID == run.id else {
            throw AcceptedRunAuthorityError.invalid("final verification mission is mismatched")
        }
        guard let subject = run.verificationSubject,
              let digest = run.verificationDigest,
              verification.verificationSubject == subject,
              verification.subjectDigest == digest,
              isLowercaseHexDigest(digest),
              let baseline = verification.baselineDigest,
              isLowercaseHexDigest(baseline),
              let fingerprint = verification.contractFingerprint,
              isLowercaseHexDigest(fingerprint),
              verification.completionMode != nil,
              verification.verifiedAt != nil else {
            throw AcceptedRunAuthorityError.invalid(
                "final verification has no exact concrete subject/digest binding")
        }
        let commands = verification.commandEvidence ?? []
        guard !commands.isEmpty,
              commands.allSatisfy({
                  $0.isBound(contractFingerprint: fingerprint, subjectDigest: digest)
                      && $0.trustedCommandReference?.isValid == true
                      && $0.trustedCommandReference?.exitCode == $0.exitCode
                      && $0.trustedCommandReference?.timedOut == false
                      && $0.trustedCommandReference?.wasSignalled == false
              }) else {
            throw AcceptedRunAuthorityError.invalid(
                "final verification command evidence is missing or unauthenticated")
        }
        guard authenticatedTelemetry(
            authority.trustedTelemetry, commands: commands,
            contractFingerprint: fingerprint, subjectDigest: digest) else {
            throw AcceptedRunAuthorityError.invalid(
                "final command evidence is not present in authenticated Builder telemetry")
        }
        guard let planReceipt = verification.planFinalVerificationReceipt else {
            throw AcceptedRunAuthorityError.invalid(
                "PlanExecute final command receipt is missing (no host replay minted one)")
        }
        // Name the failing check (0.17.63): "missing, stale, or mismatched" hid which of a dozen
        // bindings broke on a finished, council-approved build.
        var receiptFaults: [String] = []
        if planReceipt.missionInstanceID != run.id { receiptFaults.append("missionInstanceID") }
        if planReceipt.contractID != final.contractID { receiptFaults.append("contractID") }
        if planReceipt.tool != "run_command" { receiptFaults.append("tool") }
        if !planReceipt.hasValidEvidenceDigest { receiptFaults.append("evidenceDigest") }
        if !planReceipt.freshAfterMutationFrontier { receiptFaults.append("freshAfterMutationFrontier") }
        if planReceipt.expectedExitCode != 0 || planReceipt.actualExitCode != 0 { receiptFaults.append("exitCode") }
        if planReceipt.governedWorkspaceDigest != digest {
            receiptFaults.append("governedWorkspaceDigest(receipt=\(planReceipt.governedWorkspaceDigest.prefix(12)) accepted=\(digest.prefix(12)))")
        }
        if let planReference = planReceipt.trustedCommandReference {
            if !planReference.isValid { receiptFaults.append("reference.invalid") }
            if planReference.exitCode != planReceipt.actualExitCode { receiptFaults.append("reference.exitCode") }
            if planReference.timedOut || planReference.wasSignalled { receiptFaults.append("reference.exitState") }
            if planReceipt.outputDigest != planReference.fullStreamDigest { receiptFaults.append("outputDigest≠fullStreamDigest") }
            if !authority.trustedTelemetry.contains(where: {
                $0.kind == .command && $0.id == planReference.observationID
                    && $0.commandReference == planReference && $0.success
            }) { receiptFaults.append("no matching successful command observation in trusted telemetry") }
        } else {
            receiptFaults.append("trustedCommandReference missing")
        }
        guard receiptFaults.isEmpty else {
            throw AcceptedRunAuthorityError.invalid(
                "PlanExecute final command receipt is stale or mismatched: " + receiptFaults.joined(separator: ", "))
        }
        guard !final.workers.isEmpty,
              final.workers.allSatisfy({
                  !$0.checks.isEmpty && $0.checks.allSatisfy(\.passed)
                      && $0.unresolvedRisks.isEmpty && $0.missionInstanceID == run.id
              }) else {
            throw AcceptedRunAuthorityError.invalid("producer receipts are incomplete or failed")
        }

        let review = final.review
        guard review.accepted, !review.checks.isEmpty, review.checks.allSatisfy(\.passed),
              review.reviewGrade == .independent, review.independent == true else {
            throw AcceptedRunAuthorityError.invalid(
                "review is not explicit fresh independent-provider authority")
        }
        guard let reviewer = canonicalIdentity(review.reviewerIdentity),
              reviewer == canonicalIdentity("\(review.provider):\(review.model)"),
              let producerValues = review.workerIdentities, !producerValues.isEmpty else {
            throw AcceptedRunAuthorityError.invalid("review identity provenance is incomplete")
        }
        let producers = producerValues.compactMap(canonicalIdentity)
        guard producers.count == producerValues.count,
              Set(producers).count == producers.count,
              !Set(producers).contains(reviewer) else {
            throw AcceptedRunAuthorityError.invalid(
                "reviewer identity is unknown, duplicated, or not distinct")
        }
        let workerIdentities = final.workers.compactMap {
            canonicalIdentity("\($0.provider):\($0.model)")
        }
        guard workerIdentities.count == final.workers.count,
              Set(workerIdentities).isSubset(of: Set(producers)) else {
            throw AcceptedRunAuthorityError.invalid(
                "declared producers do not cover the completed workers")
        }
        guard let packetDigest = review.evidencePacketDigest,
              isLowercaseHexDigest(packetDigest) else {
            throw AcceptedRunAuthorityError.invalid("review evidence-packet digest is unavailable")
        }
        let votes = review.votes ?? []
        let lensSet = Set(votes.map {
            $0.lens.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        guard review.reviewThreshold == 3, votes.count == 4,
              lensSet == ["Correctness", "Security", "Worth", "Completeness"],
              votes.filter(\.failed).allSatisfy({ !$0.accepted })
        else {
            throw AcceptedRunAuthorityError.invalid(
                "review threshold/lens set is not the sealed four-lens council protocol")
        }
        let completedVotes = votes.filter { !$0.failed }
        let shipCount = completedVotes.filter(\.accepted).count
        let holdCount = completedVotes.filter { !$0.accepted }.count
        guard shipCount >= 3, holdCount == 0 else {
            throw AcceptedRunAuthorityError.invalid(
                "review council does not satisfy the sealed zero-veto threshold")
        }
        let voteInvocationValues = completedVotes.compactMap(\.invocationID)
        let voteInvocations = Set(voteInvocationValues)
        guard !completedVotes.isEmpty,
              voteInvocationValues.count == completedVotes.count,
              voteInvocations.count == voteInvocationValues.count,
              voteInvocations.allSatisfy(validInvocationID),
              completedVotes.allSatisfy({ vote in
            vote.accepted && vote.freshConversation == true
                && canonicalIdentity("\(vote.provider ?? ""):\(vote.model ?? "")") == reviewer
                && vote.invocationID.map(voteInvocations.contains) == true
        }) else {
            throw AcceptedRunAuthorityError.invalid(
                "accepted review votes are missing or lack exact fresh invocation provenance")
        }
        switch (review.producerInvocationIDs, review.reviewerInvocationIDs) {
        case (nil, nil):
            // Independent Builder review already authenticates a provider:model route distinct from
            // every producer. Some non-CLI providers do not expose producer invocation IDs; absence is
            // not upgraded into invented provenance.
            break
        case (.some(let producerValues), .some(let reviewerValues)):
            let producerInvocations = Set(producerValues)
            let reviewerInvocations = Set(reviewerValues)
            guard !producerInvocations.isEmpty, !reviewerInvocations.isEmpty,
                  producerInvocations.count == producerValues.count,
                  reviewerInvocations.count == reviewerValues.count,
                  producerInvocations.isDisjoint(with: reviewerInvocations),
                  producerInvocations.allSatisfy(validInvocationID),
                  reviewerInvocations.allSatisfy(validInvocationID),
                  reviewerInvocations == voteInvocations else {
                throw AcceptedRunAuthorityError.invalid(
                    "provided producer/reviewer invocation provenance is inconsistent")
            }
        default:
            throw AcceptedRunAuthorityError.invalid(
                "partial producer/reviewer invocation provenance is refused")
        }

        let nowSeconds = now.timeIntervalSince1970
        guard nowSeconds.isFinite,
              final.completedAt.timeIntervalSince1970 <= nowSeconds + 300,
              final.completedAt.timeIntervalSince1970 >= nowSeconds
                - AcceptedRunReceipt.defaultFreshness else {
            throw AcceptedRunAuthorityError.invalid("Builder final receipt is stale or future-dated")
        }
    }

    private static func authenticatedTelemetry(
        _ telemetry: [BuilderTrustedTelemetryObservation],
        commands: [BuilderCommandEvidenceReceipt],
        contractFingerprint: String,
        subjectDigest: String
    ) -> Bool {
        guard !telemetry.isEmpty else { return false }
        for observation in telemetry {
            guard let binding = try? BuilderTrustedTelemetryBinding(
                contractFingerprint: observation.contractFingerprint,
                nodeID: observation.nodeID, attempt: observation.attempt,
                stage: observation.stage),
                  (try? observation.validate(binding: binding)) != nil else { return false }
        }
        let observedCommands = telemetry.filter { $0.kind == .command }
        guard Set(observedCommands.map(\.id)).count == observedCommands.count else { return false }
        let byID = Dictionary(uniqueKeysWithValues: observedCommands.map { ($0.id, $0) })
        return commands.allSatisfy { receipt in
            guard let reference = receipt.trustedCommandReference,
                  let observation = byID[reference.observationID] else { return false }
            return receipt.isBound(
                contractFingerprint: contractFingerprint, subjectDigest: subjectDigest)
                && reference.isValid
                && receipt.argsFingerprint == reference.gateArgumentsDigest
                && receipt.exitCode == reference.exitCode
                && observation.success && observation.exitCode == reference.exitCode
                && observation.commandReference == reference
                && observation.evidenceBindingDigest == reference.bindingDigest
        }
    }

    private static func canonicalIdentity(_ value: String?) -> String? {
        guard let value else { return nil }
        let canonical = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pieces = canonical.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty,
              !canonical.contains(where: { $0.isWhitespace }) else { return nil }
        return canonical
    }

    private static func validInvocationID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == value && !value.isEmpty && value.utf8.count <= 256
            && !value.contains(where: { $0.isWhitespace })
    }

    private static func isLowercaseHexDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
