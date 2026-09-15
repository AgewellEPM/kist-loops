import Foundation
import AgentCore

/// Deterministic Builder evidence, independent-review, and durable receipt composition.
extension KistRunner {
    static func builderCommandEvidence(execution: PlanExecution?, contractFingerprint: String,
                                       subjectDigest: String,
                                       completedAt: Date = Date()) -> [BuilderCommandEvidenceReceipt] {
        guard let execution, execution.success else { return [] }
        let attempts = execution.attemptResults
        let lastMutation = attempts.lastIndex {
            ($0.effectObservation?.mutation ?? .none) != .none
        } ?? -1
        return attempts.enumerated().compactMap { index, result in
            guard index > lastMutation, result.tool == "run_command", result.success,
                  let fingerprint = result.argsFingerprint, !fingerprint.isEmpty,
                  let exitCode = result.metadata["exit_code"].flatMap(Int.init) else { return nil }
            let eligible = result.metadata["verification_eligible"] != "false"
            let semantic = result.metadata["semantic_status"] ?? "success"
            let status: BuilderCommandVerifierStatus = !eligible && semantic == "expected_domain_status"
                ? .expectedDomainStatus
                : (eligible && result.effectObservation?.verification == .buildOrTest ? .passed : .executed)
            return .bound(tool: result.tool, verifierStatus: status, exitCode: exitCode,
                          allowedExitCodes: result.metadata["allowed_exit_codes"] ?? "unknown",
                          semanticStatus: semantic, argsFingerprint: fingerprint, output: result.output,
                          subjectDigestAfter: subjectDigest, contractFingerprint: contractFingerprint,
                          executionPhase: result.executionPhase,
                          trustedCommandReference:
                            result.commandExecutionCapture?.trustedCommandReference,
                          completedAt: completedAt)
        }
    }

    static func builderFinalReplayEvidence(
        receipt: PlanFinalVerificationReceipt?,
        missionInstanceID: String,
        contractID: String,
        contractFingerprint: String,
        subjectDigest: String
    ) -> BuilderCommandEvidenceReceipt? {
        guard let receipt,
              receipt.missionInstanceID == missionInstanceID,
              receipt.contractID == contractID,
              receipt.tool == "run_command",
              receipt.hasValidEvidenceDigest,
              receipt.freshAfterMutationFrontier,
              receipt.captureOrdinal > (receipt.mutationFrontierOrdinal ?? -1),
              receipt.expectedExitCode == 0,
              receipt.actualExitCode == receipt.expectedExitCode,
              receipt.governedWorkspaceDigest == subjectDigest,
              !receipt.commandFingerprint.isEmpty,
              !receipt.outputDigest.isEmpty,
              !receipt.completionContractFingerprint.isEmpty,
              !receipt.executionPolicyFingerprint.isEmpty,
              let reference = receipt.trustedCommandReference,
              reference.isValid,
              reference.exitCode == receipt.actualExitCode,
              !reference.timedOut, !reference.wasSignalled,
              receipt.outputDigest == reference.fullStreamDigest else { return nil }
        return .boundPrehashed(
            tool: receipt.tool,
            verifierStatus: .passed,
            exitCode: Int(receipt.actualExitCode),
            allowedExitCodes: String(receipt.expectedExitCode),
            semanticStatus: "success",
            argsFingerprint: receipt.commandFingerprint,
            outputDigest: receipt.outputDigest,
            boundedRedactedOutputExcerpt: receipt.boundedRedactedOutputExcerpt,
            subjectDigestAfter: receipt.governedWorkspaceDigest,
            contractFingerprint: contractFingerprint,
            trustedCommandReference: receipt.trustedCommandReference,
            completedAt: receipt.verifiedAt
        )
    }

    /// A successful PlanExecute process is not itself an acceptance fact. The adapter worker may
    /// advance only when the host also observed the exact mission and authenticated its final replay.
    static func builderPlanExecuteCompletionGatePassed(
        adapterPassed: Bool,
        observedMissionID: String?,
        expectedMissionID: String?,
        finalReplay: BuilderCommandEvidenceReceipt?
    ) -> Bool {
        guard adapterPassed, let expectedMissionID, !expectedMissionID.isEmpty else {
            return false
        }
        return observedMissionID == expectedMissionID && finalReplay != nil
    }

    static func bindBuilderWorkspaceEvidence(
        _ worker: BuilderWorkerReceipt,
        mode: BuilderCompletionMode,
        root: String,
        baselineDigest: String,
        commandEvidence: [BuilderCommandEvidenceReceipt],
        requiredSupportingObligations: [PlanSupportingObligation]? = nil,
        supportingCommandReceipts: [PlanSupportingCommandReceipt]? = nil,
        planFinalVerificationReceipt: PlanFinalVerificationReceipt? = nil
    ) -> BuilderWorkerReceipt {
        let subject = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        let currentDigest = PlanExecuteLoop.governedWorkspaceDigest(projectRoot: subject)
        let digestAvailable = !baselineDigest.hasPrefix("unavailable:")
            && !currentDigest.hasPrefix("unavailable:")
        let changed = baselineDigest != currentDigest
        let policyPassed = digestAvailable && (mode == .verificationOnly ? !changed : changed)
        let policyDetails: String
        if !digestAvailable {
            policyDetails = "governed workspace digest unavailable; completion fails closed"
        } else if mode == .verificationOnly {
            policyDetails = changed
                ? "verification-only contract changed governed workspace content"
                : "verification-only evidence bound to unchanged digest \(currentDigest)"
        } else {
            policyDetails = changed
                ? "build mutation bound to governed digest \(currentDigest)"
                : "build/change contract produced no governed workspace mutation"
        }
        let manifest = KistREPL.workingTreeChangedFiles(projectRoot: root).sorted()
        let changedPaths = changed ? (manifest.isEmpty ? [subject] : manifest) : []
        return BuilderWorkerReceipt(
            nodeID: worker.nodeID, provider: worker.provider, model: worker.model,
            artifacts: worker.artifacts + [
                BuilderArtifact(path: subject, kind: "governed-workspace-baseline",
                                digest: baselineDigest),
                BuilderArtifact(path: subject, kind: "governed-workspace-subject",
                                digest: currentDigest),
            ],
            changedPaths: changedPaths,
            checks: worker.checks + [BuilderCheckReceipt(
                name: "governed workspace completion contract", passed: policyPassed,
                details: policyDetails)],
            unresolvedRisks: worker.unresolvedRisks + (policyPassed ? [] : [policyDetails]),
            usage: worker.usage,
            commandEvidence: commandEvidence,
            requiredSupportingObligations: requiredSupportingObligations,
            supportingCommandReceipts: supportingCommandReceipts,
            planFinalVerificationReceipt: planFinalVerificationReceipt,
            missionInstanceID: worker.missionInstanceID
        )
    }

    static func finalBuilderWorkspaceEvidence(
        contract: BuilderContract,
        workers: [BuilderWorkerReceipt],
        root: String
    ) -> (check: BuilderCheckReceipt, subject: String, baseline: String,
          digest: String, commands: [BuilderCommandEvidenceReceipt]) {
        let subject = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        let currentDigest = PlanExecuteLoop.governedWorkspaceDigest(projectRoot: subject)
        let baseline = workers.lazy.flatMap(\.artifacts)
            .first { $0.kind == "governed-workspace-baseline" }?.digest
        let recorded = workers.reversed().lazy.flatMap { $0.artifacts.reversed() }
            .first { $0.kind == "governed-workspace-subject" }?.digest
        let available = baseline != nil && recorded != nil
            && !(baseline?.hasPrefix("unavailable:") ?? true)
            && !(recorded?.hasPrefix("unavailable:") ?? true)
            && !currentDigest.hasPrefix("unavailable:")
        let bound = available && recorded == currentDigest
        let changed = available && baseline != recorded
        let modePassed = contract.effectiveCompletionMode == .verificationOnly ? !changed : changed
        let fingerprint = builderObjectiveFingerprint(contractID: contract.id, goal: contract.objective)
        let commands = workers.flatMap { $0.commandEvidence ?? [] }
        let commandsPassed = !commands.isEmpty
            && commands.allSatisfy {
                $0.isBound(contractFingerprint: fingerprint, subjectDigest: currentDigest)
            } && commands.contains { $0.verifierStatus == .passed }
        let passed = bound && modePassed && commandsPassed
        let details: String
        if !available {
            details = "missing concrete governed workspace baseline/subject digest"
        } else if !bound {
            details = "governed workspace digest is stale: recorded \(recorded ?? "missing"), current \(currentDigest)"
        } else if !modePassed {
            details = contract.effectiveCompletionMode == .verificationOnly
                ? "verification-only contract observed a governed mutation"
                : "build/change contract produced no governed workspace mutation"
        } else if !commandsPassed {
            details = "typed command evidence is missing, stale, or has no passed deterministic verifier"
        } else {
            details = "fresh deterministic evidence bound to \(subject) at digest \(currentDigest)"
        }
        return (BuilderCheckReceipt(name: "governed workspace digest", passed: passed,
                                    details: details), subject, baseline ?? "unavailable:missing",
                currentDigest, commands)
    }

    static func builderRunRecordPayload(
        contractID: String,
        missionInstanceID: String? = nil,
        launch: BuilderCompatibilityLaunch,
        outcome: String,
        detail: String,
        usage: BuilderUsageReceipt? = nil,
        finalReceipt: BuilderFinalReceipt? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "receiptType": "kist.run-record", "schemaVersion": 2,
            "contractID": contractID,
            "route": launch.routeHint.resolve().rawValue,
            "adapter": launch.adapter.rawValue,
            "routerDecision": launch.routerDecision.route.rawValue,
            "routerReason": launch.routerDecision.reason,
            "complexity": launch.effort.complexity,
            "planning": launch.effort.planning.rawValue,
            "thinking": launch.effort.thinking.rawValue,
            "team": launch.effort.team.rawValue,
            "modelTier": launch.effort.modelTier.rawValue,
            "outcome": outcome,
            "detail": detail,
        ]
        if let missionInstanceID { payload["missionInstanceID"] = missionInstanceID }
        if let tokens = usage?.aggregateTokens { payload["aggregateTokens"] = tokens }
        if let stages = usage?.unmeteredStages { payload["unmeteredStages"] = stages }
        if let finalReceipt {
            payload["producerIdentities"] = finalReceipt.review.workerIdentities ?? []
            payload["reviewerIdentity"] = finalReceipt.review.reviewerIdentity ?? "unavailable"
            payload["verificationSubject"] = finalReceipt.verification.verificationSubject ?? "unavailable"
            payload["verificationDigest"] = finalReceipt.verification.subjectDigest ?? "unavailable"
            payload["baselineDigest"] = finalReceipt.verification.baselineDigest ?? "unavailable"
            payload["objectiveFingerprint"] = finalReceipt.verification.contractFingerprint ?? "unavailable"
            payload["completionMode"] = finalReceipt.verification.completionMode?.rawValue ?? "unavailable"
            payload["commandEvidence"] = (finalReceipt.verification.commandEvidence ?? []).map {
                ["tool": $0.tool, "verifierStatus": $0.verifierStatus.rawValue,
                 "exitCode": $0.exitCode, "argsFingerprint": $0.argsFingerprint,
                 "evidenceDigest": $0.evidenceDigest] as [String: Any]
            }
            payload["reviewEvidencePacketDigest"] = finalReceipt.review.evidencePacketDigest ?? "unavailable"
            if let verifiedAt = finalReceipt.verification.verifiedAt {
                payload["verifiedAt"] = ISO8601DateFormatter().string(from: verifiedAt)
            }
        }
        return payload
    }

    static func reviewAttemptPayload(_ attempt: BuilderReviewAttemptReceipt) -> [String: Any] {
        var payload: [String: Any] = [
            "receiptType": "kist.review-attempt", "schemaVersion": 2,
            "reviewerIdentity": attempt.reviewerIdentity,
            "producerIdentities": attempt.producerIdentities,
            "evidencePacketDigest": attempt.evidencePacketDigest,
            "decision": attempt.accepted ? "approve" : "reject",
            "attemptedAt": ISO8601DateFormatter().string(from: attempt.attemptedAt),
            "votes": attempt.votes.map {
                ["lens": $0.lens, "accepted": $0.accepted,
                 "reason": $0.reason, "failed": $0.failed] as [String: Any]
            },
        ]
        if let missionInstanceID = attempt.missionInstanceID {
            payload["missionInstanceID"] = missionInstanceID
        }
        return payload
    }

    /// Machine-readable proof for the narrow same-model Builder exception. Invocation IDs are the
    /// ForgeSeal-bound CLI telemetry observation IDs, not operating-system process identifiers.
    static func builderSameModelReviewReceiptPayload(
        _ final: BuilderFinalReceipt
    ) -> [String: Any]? {
        let review = final.review
        let votes = review.votes ?? []
        let completedVotes = votes.filter { !$0.failed }
        let expectedLenses: Set<String> = ["Correctness", "Security", "Worth", "Completeness"]
        guard final.hasValidBuilderFinalAuthority,
              final.accepted, review.accepted, review.checks.allSatisfy(\.passed),
              review.reviewGrade == .freshContextSameModel,
              review.independent == false,
              review.freshConversation == true,
              review.separateInvocation == true,
              let producers = review.workerIdentities, producers.count == 1,
              let reviewer = review.reviewerIdentity, !reviewer.isEmpty,
              Set(producers) == [reviewer],
              providerModelIdentity(provider: review.provider, model: review.model) == reviewer,
              review.reviewThreshold == 3,
              votes.count == expectedLenses.count,
              Set(votes.map(\.lens)) == expectedLenses,
              completedVotes.count >= 3,
              completedVotes.allSatisfy(\.accepted),
              votes.allSatisfy({ !$0.failed || !$0.accepted }),
              let producerInvocations = review.producerInvocationIDs,
              !producerInvocations.isEmpty,
              let reviewerInvocations = review.reviewerInvocationIDs,
              !reviewerInvocations.isEmpty,
              reviewerInvocations.count == completedVotes.count,
              Set(producerInvocations).count == producerInvocations.count,
              Set(reviewerInvocations).count == reviewerInvocations.count,
              Set(producerInvocations).isDisjoint(with: Set(reviewerInvocations)),
              let digest = review.evidencePacketDigest,
              digest.count == 64,
              digest.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return [
            "receiptType": "kist.builder-review",
            "schemaVersion": 1,
            "decision": final.accepted ? "approve" : "reject",
            "accepted": final.accepted,
            "grade": EvolutionReviewGrade.freshContextSameModel.rawValue,
            "independent": false,
            "freshConversation": true,
            "separateInvocation": true,
            "reviewThreshold": 3,
            "producerIdentities": producers,
            "reviewerIdentity": reviewer,
            "producerInvocationIDs": producerInvocations,
            "reviewerInvocationIDs": reviewerInvocations,
            "invocationIDKind": "sealed_cli_telemetry_observation_id",
            "evidencePacketDigest": digest,
        ]
    }

    static func emitBuilderRunRecord(contractID: String, missionInstanceID: String? = nil,
                                     launch: BuilderCompatibilityLaunch,
                                     outcome: String, detail: String,
                                     usage: BuilderUsageReceipt? = nil,
                                     finalReceipt: BuilderFinalReceipt? = nil) {
        let payload = builderRunRecordPayload(
            contractID: contractID, missionInstanceID: missionInstanceID,
            launch: launch, outcome: outcome, detail: detail,
            usage: BuilderRunAudit.current?.usage() ?? usage, finalReceipt: finalReceipt)
        BuilderRunAudit.current?.recordRun(payload)
        emitAutonomyReceipt(prefix: "KIST_RUN_RECORD:", payload: payload)
    }

    final class BuilderCompatibilityDossierBox: @unchecked Sendable {
        private let lock = NSLock()
        private var dossier: AutonomyMissionDossier?

        func set(_ value: AutonomyMissionDossier) {
            lock.lock()
            dossier = value
            lock.unlock()
        }

        func get() -> AutonomyMissionDossier? {
            lock.lock()
            defer { lock.unlock() }
            return dossier
        }
    }

    final class BuilderCompatibilityMissionStageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [String: AutonomyMissionStageResult] = [:]
        func set(_ result: AutonomyMissionStageResult, for nodeID: String) {
            lock.lock(); results[nodeID] = result; lock.unlock()
        }
        func get(_ nodeID: String) -> AutonomyMissionStageResult? {
            lock.lock(); defer { lock.unlock() }; return results[nodeID]
        }
    }

    final class BuilderCompatibilityStatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Int32?
        var value: Int32? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ value: Int32) { lock.lock(); stored = value; lock.unlock() }
    }

    final class BuilderCompatibilityPlanOutcomeBox: @unchecked Sendable {
        private let lock = NSLock(); private var stored: PlanOutcome?
        func set(_ value: PlanOutcome) { lock.lock(); stored = value; lock.unlock() }
        func get() -> PlanOutcome? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    final class BuilderCompatibilityCoboloEvidenceBox: @unchecked Sendable {
        private let lock = NSLock(); private var stored: CoboloBuilderEvidence?
        func set(_ value: CoboloBuilderEvidence) { lock.lock(); stored = value; lock.unlock() }
        func get() -> CoboloBuilderEvidence? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    final class BuilderCompatibilityTaskBoardBox: @unchecked Sendable {
        private let lock = NSLock(); private var stored: BuilderTaskBoardLineage?
        func set(_ value: BuilderTaskBoardLineage) { lock.lock(); stored = value; lock.unlock() }
        func get() -> BuilderTaskBoardLineage? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    final class BuilderCompatibilityCoboloContractBox: @unchecked Sendable {
        private let lock = NSLock(); private var stored: SealedBuilderExecutionContract?
        func set(_ value: SealedBuilderExecutionContract) { lock.lock(); stored = value; lock.unlock() }
        func get() -> SealedBuilderExecutionContract? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    struct BuilderValidatedCoboloEvidence {
        let subjectDigest: String
        let commandEvidence: [BuilderCommandEvidenceReceipt]
    }

    struct BuilderBudgetedShipReviewResult {
        let decision: ShipPipeline.Decision?
        let denialReason: String?
        let usage: BuilderUsageReceipt
    }


    static func builderCoboloCommandEvidence(
        _ receipt: CoboloCommandReceipt,
        contractFingerprint: String,
        subjectDigest: String
    ) throws -> BuilderCommandEvidenceReceipt {
        guard receipt.exitCode == 0, receipt.sandboxed, !receipt.timedOut, !receipt.wasSignalled,
              !receipt.stdoutTruncated, !receipt.stderrTruncated, !receipt.outputTruncated,
              let invocation = receipt.invocation,
              invocation.executable == receipt.executable,
              invocation.arguments == receipt.arguments,
              !invocation.workingDirectory.isEmpty,
              invocation.timeoutSeconds > 0,
              invocation.allowedExitCodes == [0],
              let reference = receipt.trustedCommandReference,
              reference.isValid,
              reference.exitCode == Int(receipt.exitCode),
              !reference.timedOut, !reference.wasSignalled,
              reference.gateArgumentsDigest == AuditLog.digest(invocation.toolArguments).digest,
              reference.stdoutDigest == BuilderEvidenceDigest.sha256(receipt.stdout),
              reference.stderrDigest == BuilderEvidenceDigest.sha256(receipt.stderr),
              reference.stdoutByteCount == receipt.stdout.utf8.count,
              reference.stderrByteCount == receipt.stderr.utf8.count else {
            throw BuilderRunError.finalVerificationFailed(
                "Cobolo command receipt \(receipt.stage) is not exact registered launcher evidence")
        }
        let output = "stdout:\n\(receipt.stdout)\nstderr:\n\(receipt.stderr)"
            + "\nsource-receipt:\(receipt.evidenceDigest)"
        return .bound(
            tool: "run_command", verifierStatus: .passed,
            exitCode: Int(receipt.exitCode), allowedExitCodes: "0", semanticStatus: "success",
            argsFingerprint: reference.gateArgumentsDigest,
            output: output, subjectDigestAfter: subjectDigest,
            contractFingerprint: contractFingerprint,
            trustedCommandReference: reference,
            completedAt: receipt.capturedAt)
    }

    static func builderValidatedCoboloEvidence(
        _ evidence: CoboloBuilderEvidence,
        root: String,
        contractFingerprint: String,
        builderContractID: String,
        builderNodeID: String,
        expectedExecutionContract: SealedBuilderExecutionContract
    ) throws -> BuilderValidatedCoboloEvidence {
        do {
            guard evidence.executionContract == expectedExecutionContract else {
                throw BuilderRunError.finalVerificationFailed(
                    "Cobolo returned a different Builder execution contract")
            }
            try evidence.executionContract.validate(
                builderContractID: builderContractID, graphNodeIDs: [builderNodeID])
            let prescribed = evidence.executionContract.contract
            guard prescribed.builderNodeID == builderNodeID,
                  prescribed.mutations.count == 1,
                  prescribed.mutations[0].path == evidence.target,
                  prescribed.mutations[0].kind != .delete,
                  prescribed.lineage.captainDecisionDigest != nil,
                  prescribed.lineage.research != nil,
                  prescribed.lineage.peelReceiptDigest != nil,
                  prescribed.lineage.councilArtifactDigest != nil else {
                throw BuilderRunError.finalVerificationFailed(
                    "Cobolo Builder contract is not a complete exact-target lineage contract")
            }
            let prescribedProducers = Set(prescribed.identities.producers.map { $0.canonicalID })
            guard prescribedProducers == Set(evidence.producerIdentities) else {
                throw BuilderRunError.finalVerificationFailed(
                    "Cobolo evidence producers drifted from its sealed identity plan")
            }
            guard prescribed.identities.reviewers.map({ $0.canonicalID }).contains(evidence.reviewerIdentity) else {
                throw BuilderRunError.reviewerNotIndependent(
                    "Cobolo promotion reviewer is not named by its sealed identity plan")
            }
            let confined = try ConfinedRoot(root: root)
            let targetDigest = try confined.fileSHA256(evidence.target)
                .map { String(format: "%02x", $0) }.joined()
            guard targetDigest == evidence.promotedSHA256 else {
                throw BuilderRunError.finalVerificationFailed(
                    "Cobolo promoted target descriptor hash no longer matches its acceptance evidence")
            }
            let currentWorkspaceDigest = PlanExecuteLoop.governedWorkspaceDigest(projectRoot: root)
            guard !evidence.observedWorkspaceDigest.hasPrefix("unavailable:"),
                  currentWorkspaceDigest == evidence.observedWorkspaceDigest else {
                throw BuilderRunError.finalVerificationFailed(
                    "Governed workspace changed between Cobolo acceptance and Builder receipt conversion")
            }
            let final = evidence.finalVerification
            guard final.phase == "post-promotion" || final.phase == "resume-post-promotion",
                  final.sourceSHA256 == evidence.promotedSHA256 else {
                throw BuilderRunError.finalVerificationFailed(
                    "Cobolo final verification is not bound to the promoted source")
            }
            // These are old command receipts. Bind them only to the workspace
            // observation captured with those receipts, never to a newer digest
            // supplied or observed by the caller.
            return BuilderValidatedCoboloEvidence(
                subjectDigest: evidence.observedWorkspaceDigest,
                commandEvidence: try [
                    builderCoboloCommandEvidence(
                        final.compile, contractFingerprint: contractFingerprint,
                        subjectDigest: evidence.observedWorkspaceDigest),
                    builderCoboloCommandEvidence(
                        final.run, contractFingerprint: contractFingerprint,
                        subjectDigest: evidence.observedWorkspaceDigest),
                ])
        } catch let error as BuilderRunError {
            throw error
        } catch {
            throw BuilderRunError.finalVerificationFailed(
                "Cobolo target descriptor validation failed: \(error.localizedDescription)")
        }
    }

    static func builderAggregateRunUsage(
        _ final: BuilderFinalReceipt,
        additional: [BuilderUsageReceipt] = []
    ) -> BuilderUsageReceipt {
        let receipts = final.workers.map(\.usage) + [final.review.usage] + additional
        let unmetered = Array(Set(receipts.flatMap { $0.unmeteredStages ?? [] })).sorted()
        let aggregates = receipts.compactMap(\.aggregateTokens)
        let aggregate = unmetered.isEmpty && aggregates.count == receipts.count
            ? aggregates.reduce(0, +) : nil
        return BuilderUsageReceipt(
            inputTokens: receipts.map(\.inputTokens).reduce(0, +),
            outputTokens: receipts.map(\.outputTokens).reduce(0, +),
            wallTimeSeconds: receipts.map(\.wallTimeSeconds).reduce(0, +),
            aggregateTokens: aggregate,
            unmeteredStages: unmetered.isEmpty ? nil : unmetered)
    }

    static func builderCompatibilityContractID(root: String, goal: String,
                                               adapter: BuilderCompatibilityAdapter) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in (root + "\u{0}" + goal + "\u{0}" + adapter.rawValue).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "kist-builder-" + String(hash, radix: 16)
    }

    /// Canonical launcher for the existing --loop/--plan-execute/--fleet/--mission surfaces.
    /// Adapter bodies never call this method, preventing nested BuilderRun recursion.

    struct BuilderVerificationContext: Sendable {
        let preflightEnvelope: BuilderPreflightEnvelope?
        let launch: BuilderCompatibilityLaunch
        let contractProvider: (any BuilderNodeExecutionContractProvider)?
        let mutationTransaction: BuilderIsolatedWorkspaceTransactionSource?
        let plannedVerificationStore: BuilderPlannedVerificationStore
        let artifactStore: BuilderCompositionArtifactStore
        let graph: BuilderGraph
        let toolContext: ToolContext
        let finalizedContract: BuilderContract
        let projectRoot: String
        let graphFingerprint: String
        let objectiveFingerprint: String
        let parentContractFingerprint: String
        let baselineDigest: String
    }

    static func builderCanonicalParentContractFingerprint(
        _ contract: BuilderContract
    ) throws -> String {
        try BuilderContractFingerprint.canonical(contract)
    }

    static func builderFreshFleetAggregateVerificationWorkspace(
        rootPath: String,
        rootIdentity: BuilderWorkspaceRootIdentity,
        contentDigest: String,
        builderContractID: String,
        parentContractFingerprint: String
    ) async throws -> BuilderExecutionWorkspace {
        let capturedIdentity = try BuilderWorkspaceRootIdentity.capture(rootPath: rootPath)
        guard capturedIdentity == rootIdentity,
              contentDigest.count == 64,
              !contentDigest.hasPrefix("unavailable:") else {
            throw BuilderRunError.persistedStateInvalid(
                "fleet aggregate root identity or content digest is unavailable")
        }
        let request = BuilderSandboxAttestationRequest(
            contractFingerprint: parentContractFingerprint,
            builderContractID: builderContractID,
            nodeID: "fleet-aggregate",
            attempt: 1,
            stagedRoot: rootIdentity.canonicalPath,
            governedRootDigest: contentDigest,
            challenge: UUID().uuidString.lowercased(),
            stage: .verification)
        let attestation = try await BuilderOSProcessSandboxAttestor().attest(request)
        try attestation.validate(request)
        return BuilderExecutionWorkspace(
            rootPath: rootIdentity.canonicalPath,
            rootIdentity: rootIdentity,
            attestation: attestation,
            workspaceDigest: contentDigest)
    }

    /// A worker loop's free-form "done" / "unverified" judgment is advisory once a sealed
    /// preflight plan exists. Only the host-run, contract-bound deterministic receipt decides
    /// whether the node verified. This is especially important for fleet children: each child
    /// proves its own partition, while the global functional oracle runs once on the aggregate.
    static func builderGovernedNodeVerificationDisposition(
        worker: BuilderWorkerReceipt,
        commandReceipt: BuilderVerifierReceipt
    ) -> (passed: Bool, checks: [BuilderCheckReceipt]) {
        _ = worker
        let checks = commandReceipt.checks
        let passed = commandReceipt.deterministic && commandReceipt.passed
            && !checks.isEmpty && checks.allSatisfy(\.passed)
        return (passed, checks)
    }

    /// Governed adapters are accepted or rejected by the sealed staged-workspace receipt below,
    /// not by the producing model's self-verdict. Legacy/unplanned adapters retain their historical
    /// worker-check behavior because they have no stronger host receipt to replace it.
    static func builderAdapterSourceEvidence(
        workers: [BuilderWorkerReceipt],
        governedByPreflight: Bool
    ) -> (passed: Bool, check: BuilderCheckReceipt) {
        if governedByPreflight {
            return (true, BuilderCheckReceipt(
                name: "adapter worker self-verdict",
                passed: true,
                details: "advisory only; sealed host verification is authoritative"))
        }
        let checks = workers.flatMap(\.checks)
        let passed = !checks.isEmpty && checks.allSatisfy(\.passed)
        return (passed, BuilderCheckReceipt(
            name: "final deterministic evidence", passed: passed,
            details: passed ? "all adapter verification gates passed"
                : checks.filter { !$0.passed }.map(\.details).joined(separator: "; ")))
    }

    static func builderVerify(
        _ request: BuilderVerificationRequest,
        context configuration: BuilderVerificationContext
    ) async throws -> BuilderVerifierReceipt {
        let preflightEnvelope = configuration.preflightEnvelope
        let launch = configuration.launch
        let contractProvider = configuration.contractProvider
        let mutationTransaction = configuration.mutationTransaction
        let plannedVerificationStore = configuration.plannedVerificationStore
        let artifactStore = configuration.artifactStore
        let graph = configuration.graph
        let context = configuration.toolContext
        let finalizedContract = configuration.finalizedContract
        let root = configuration.projectRoot
        let graphFingerprint = configuration.graphFingerprint
        let objectiveFingerprint = configuration.objectiveFingerprint
        let parentContractFingerprint = configuration.parentContractFingerprint
                    switch request {
                    case .node(_, let node, let worker, let executionWorkspace):
                        if let plan = preflightEnvelope?.plan,
                           builderPlannedExecutionNodeIDs(
                                for: launch.adapter, plan: plan).contains(node.id) {
                            guard let provider = contractProvider,
                                  let workspace = executionWorkspace,
                                  let wallDeadlineEpoch = preflightEnvelope?.wallDeadlineEpoch else {
                                throw BuilderRunError.finalVerificationFailed(
                                    "planned verifier did not receive its governance-issued workspace")
                            }
                            let workspaceRecord = try await plannedVerificationStore.load(
                                nodeID: node.id, stage: .executionWorkspace)
                            let selected = try await artifactStore.loadContract(
                                providerFingerprint: provider.identity.implementationFingerprint,
                                nodeID: node.id, attempt: workspaceRecord.attempt,
                                graphNodeIDs: graph.nodes.map(\.id))
                            guard workspace.rootPath == workspaceRecord.workspaceRoot,
                                  workspace.attestation.contractFingerprint == selected.fingerprint,
                                  workspace.attestation.nodeID == node.id,
                                  workspace.attestation.attempt == workspaceRecord.attempt,
                                  workspace.attestation.stage == .verification else {
                                throw BuilderRunError.persistedStateInvalid(
                                    "governance-issued verification workspace drifted from durable staged state")
                            }
                            let verificationPlan = launch.adapter == .fleet
                                ? try builderFleetChildVerificationPlan(
                                    plan: plan, nodeID: node.id)
                                : plan
                            let commandReceipt = try await builderRunPlannedVerification(
                                plan: verificationPlan, workspace: workspace, context: context,
                                builderContractID: finalizedContract.id,
                                contractFingerprint: selected.fingerprint,
                                nodeID: node.id,
                                wallDeadline: Date(timeIntervalSince1970: wallDeadlineEpoch))
                            let disposition = builderGovernedNodeVerificationDisposition(
                                worker: worker, commandReceipt: commandReceipt)
                            let checks = disposition.checks
                            let passed = disposition.passed
                            let receipt = BuilderVerifierReceipt(
                                scope: .node(node.id), provider: "host", model: "deterministic",
                                deterministic: true, passed: passed, checks: checks,
                                failureFingerprint: passed ? nil
                                    : checks.filter { !$0.passed }.map(\.details).joined(separator: "; "),
                                verificationSubject: commandReceipt.verificationSubject,
                                baselineDigest: commandReceipt.baselineDigest,
                                subjectDigest: commandReceipt.subjectDigest,
                                contractFingerprint: commandReceipt.contractFingerprint,
                                completionMode: .build,
                                commandEvidence: commandReceipt.commandEvidence,
                                verifiedAt: commandReceipt.verifiedAt,
                                missionInstanceID: worker.missionInstanceID)
                            try await plannedVerificationStore.save(
                                BuilderPlannedVerificationRecord(
                                    builderContractID: finalizedContract.id,
                                    nodeID: node.id, stage: .nodeVerification,
                                    workspace: workspace,
                                    contractFingerprint: selected.fingerprint,
                                    receipt: receipt))
                            return receipt
                        }
                        let passed = !worker.checks.isEmpty && worker.checks.allSatisfy(\.passed)
                        return BuilderVerifierReceipt(
                            scope: .node(node.id), provider: "kist", model: "deterministic",
                            deterministic: true, passed: passed, checks: worker.checks,
                            failureFingerprint: passed ? nil : worker.checks.map(\.details).joined(separator: "; "),
                            missionInstanceID: worker.missionInstanceID
                        )
                    case .final(_, _, let workers):
                        let sourceEvidence = builderAdapterSourceEvidence(
                            workers: workers, governedByPreflight: preflightEnvelope != nil)
                        let sourcePassed = sourceEvidence.passed
                        let sourceCheck = sourceEvidence.check
                        let workspace = finalBuilderWorkspaceEvidence(
                            contract: finalizedContract, workers: workers, root: root)
                        let plannedReceipt: BuilderVerifierReceipt?
                        if let envelope = preflightEnvelope,
                           let provider = contractProvider,
                           let mutationTransaction {
                            let executionNodeIDs = builderPlannedExecutionNodeIDs(
                                for: launch.adapter, plan: envelope.plan).sorted()
                            var childReceipts: [BuilderVerifierReceipt] = []
                            var fleetChildren: [BuilderFleetChildVerificationBundle] = []
                            var fleetAggregateRootPath: String?
                            var fleetAggregateRootIdentity: BuilderWorkspaceRootIdentity?
                            var fleetAggregateContentDigest: String?
                            for nodeID in executionNodeIDs {
                                guard let node = graph.nodes.first(where: { $0.id == nodeID }) else {
                                    throw BuilderRunError.persistedStateInvalid(
                                        "planned final verifier references an unknown graph node")
                                }
                                let workspaceRecord = try await plannedVerificationStore.load(
                                    nodeID: nodeID, stage: .executionWorkspace)
                                let selected = try await artifactStore.loadContract(
                                    providerFingerprint: provider.identity.implementationFingerprint,
                                    nodeID: nodeID, attempt: workspaceRecord.attempt,
                                    graphNodeIDs: graph.nodes.map(\.id))
                                let verificationContext = try BuilderStageContext(
                                    contract: selected.contract, node: node,
                                    attempt: workspaceRecord.attempt, stage: .verification)
                                let freshWorkspace = try await mutationTransaction.executionWorkspace(
                                    for: verificationContext)
                                guard freshWorkspace.attestation.contractFingerprint
                                        == selected.fingerprint else {
                                    throw BuilderRunError.persistedStateInvalid(
                                        "final workspace attestation drifted from its selected contract")
                                }
                                if launch.adapter == .fleet {
                                    guard let contentDigest = freshWorkspace.workspaceDigest else {
                                        throw BuilderRunError.persistedStateInvalid(
                                            "fleet final verifier received no aggregate content digest")
                                    }
                                    if let aggregatePath = fleetAggregateRootPath,
                                       let aggregateIdentity = fleetAggregateRootIdentity,
                                       let aggregateDigest = fleetAggregateContentDigest {
                                        guard aggregatePath == freshWorkspace.rootPath,
                                              aggregateIdentity == freshWorkspace.rootIdentity,
                                              aggregateDigest == contentDigest else {
                                            throw BuilderRunError.persistedStateInvalid(
                                                "fleet final verifier received divergent aggregate workspaces")
                                        }
                                    } else {
                                        fleetAggregateRootPath = freshWorkspace.rootPath
                                        fleetAggregateRootIdentity = freshWorkspace.rootIdentity
                                        fleetAggregateContentDigest = contentDigest
                                    }
                                }
                                let verificationPlan = launch.adapter == .fleet
                                    ? try builderFleetChildVerificationPlan(
                                        plan: envelope.plan, nodeID: nodeID)
                                    : envelope.plan
                                let freshFinal = try await BuilderOSProcessSandboxAttestor
                                    .withRegisteredScope(
                                        workspace: freshWorkspace,
                                        builderContractID: finalizedContract.id
                                    ) {
                                        try await builderRunPlannedVerification(
                                            plan: verificationPlan,
                                            workspace: freshWorkspace,
                                            context: context,
                                            builderContractID: finalizedContract.id,
                                            contractFingerprint: selected.fingerprint,
                                            nodeID: nodeID,
                                            wallDeadline: Date(
                                                timeIntervalSince1970: envelope.wallDeadlineEpoch))
                                    }
                                try await plannedVerificationStore.save(
                                    BuilderPlannedVerificationRecord(
                                        builderContractID: finalizedContract.id,
                                        nodeID: nodeID, stage: .finalVerification,
                                        workspace: freshWorkspace,
                                        contractFingerprint: selected.fingerprint,
                                        receipt: freshFinal))
                                childReceipts.append(freshFinal)
                                if launch.adapter == .fleet {
                                    guard let verificationSubject = freshFinal.verificationSubject,
                                          let childBaseline = freshFinal.baselineDigest,
                                          let childSubject = freshFinal.subjectDigest,
                                          let commandEvidence = freshFinal.commandEvidence,
                                          let verifiedAt = freshFinal.verifiedAt else {
                                        throw BuilderRunError.finalVerificationFailed(
                                            "fleet child final evidence is incomplete")
                                    }
                                    fleetChildren.append(try BuilderFleetChildVerificationBundle(
                                        nodeID: nodeID, attempt: workspaceRecord.attempt,
                                        partitionPaths: selected.contract.mutations.map(\.path),
                                        contractFingerprint: selected.fingerprint,
                                        verifierIdentity: BuilderModelIdentity(
                                            providerID: freshFinal.provider,
                                            modelID: freshFinal.model),
                                        verificationSubject: verificationSubject,
                                        baselineDigest: childBaseline,
                                        subjectDigest: childSubject,
                                        commandEvidence: commandEvidence,
                                        verifiedAt: verifiedAt))
                                }
                            }
                            if launch.adapter == .fleet {
                                guard let aggregateRootPath = fleetAggregateRootPath,
                                      let aggregateRootIdentity = fleetAggregateRootIdentity,
                                      let aggregateContentDigest = fleetAggregateContentDigest else {
                                    throw BuilderRunError.persistedStateInvalid(
                                        "fleet final verifier has no aggregate workspace")
                                }
                                let aggregateWorkspace = try await
                                    builderFreshFleetAggregateVerificationWorkspace(
                                        rootPath: aggregateRootPath,
                                        rootIdentity: aggregateRootIdentity,
                                        contentDigest: aggregateContentDigest,
                                        builderContractID: finalizedContract.id,
                                        parentContractFingerprint: parentContractFingerprint)
                                let aggregateFinal = try await BuilderOSProcessSandboxAttestor
                                    .withRegisteredScope(
                                        workspace: aggregateWorkspace,
                                        builderContractID: finalizedContract.id
                                    ) {
                                        try await builderRunPlannedVerification(
                                            plan: envelope.plan,
                                            workspace: aggregateWorkspace,
                                            context: context,
                                            builderContractID: finalizedContract.id,
                                            contractFingerprint: parentContractFingerprint,
                                            nodeID: "fleet-aggregate",
                                            wallDeadline: Date(
                                                timeIntervalSince1970: envelope.wallDeadlineEpoch))
                                    }
                                let bundle = try BuilderFleetVerificationBundle(
                                    parentContractFingerprint: parentContractFingerprint,
                                    graphFingerprint: graphFingerprint,
                                    children: fleetChildren)
                                guard aggregateFinal.verificationSubject == bundle.verificationSubject,
                                      aggregateFinal.subjectDigest == bundle.subjectDigest,
                                      aggregateFinal.contractFingerprint
                                        == parentContractFingerprint else {
                                    throw BuilderRunError.finalVerificationFailed(
                                        "fleet aggregate oracle is not bound to the verified merged workspace")
                                }
                                let childChecks = childReceipts.flatMap(\.checks)
                                let aggregateChecks = aggregateFinal.checks
                                let aggregatePassed = !aggregateChecks.isEmpty
                                    && aggregateFinal.passed
                                    && aggregateChecks.allSatisfy(\.passed)
                                let childPassed = !childChecks.isEmpty
                                    && childReceipts.allSatisfy(\.passed)
                                    && childChecks.allSatisfy(\.passed)
                                let allChecks = childChecks + aggregateChecks
                                let passed = childPassed && aggregatePassed
                                plannedReceipt = BuilderVerifierReceipt(
                                    scope: .final, provider: "kist", model: "deterministic",
                                    deterministic: true, passed: passed,
                                    checks: allChecks,
                                    failureFingerprint: passed ? nil
                                        : allChecks.filter { !$0.passed }
                                            .map(\.details).joined(separator: "; "),
                                    verificationSubject: aggregateFinal.verificationSubject,
                                    baselineDigest: aggregateFinal.baselineDigest,
                                    subjectDigest: aggregateFinal.subjectDigest,
                                    contractFingerprint: parentContractFingerprint,
                                    completionMode: finalizedContract.effectiveCompletionMode,
                                    commandEvidence: aggregateFinal.commandEvidence,
                                    verifiedAt: aggregateFinal.verifiedAt,
                                    fleetVerification: bundle)
                            } else {
                                guard childReceipts.count == 1 else {
                                    throw BuilderRunError.persistedStateInvalid(
                                        "non-fleet final verification selected multiple child contracts")
                                }
                                plannedReceipt = childReceipts[0]
                            }
                        } else {
                            plannedReceipt = nil
                        }
                        let plannedWorkspaceCheck = BuilderCheckReceipt(
                            name: "sealed staged workspace verification",
                            passed: plannedReceipt?.passed == true,
                            details: plannedReceipt?.passed == true
                                ? "fresh deterministic commands passed in the selected child-contract workspace"
                                : "selected child-contract workspace has no accepted deterministic verification receipt")
                        let requiredSupportingObligations = workers.compactMap {
                            $0.requiredSupportingObligations
                        }.first
                        let supportingCommandReceipts = workers.flatMap {
                            $0.supportingCommandReceipts ?? []
                        }
                        let planFinalVerificationReceipt = workers.compactMap {
                            $0.planFinalVerificationReceipt
                        }.first
                        let missionBound = launch.adapter != .planExecute
                            || (!workers.isEmpty && workers.allSatisfy {
                                $0.missionInstanceID == finalizedContract.checkpointIdentity
                            })
                        let missionCheck = BuilderCheckReceipt(
                            name: "plan mission identity",
                            passed: missionBound,
                            details: missionBound
                                ? "worker evidence is bound to the host mission instance"
                                : "worker mission identity is missing or mismatched"
                        )
                        let finalChecks = launch.adapter == .planExecute
                            ? [sourceCheck, preflightEnvelope == nil ? workspace.check : plannedWorkspaceCheck,
                               missionCheck]
                            : [sourceCheck, preflightEnvelope == nil ? workspace.check : plannedWorkspaceCheck]
                        let workspacePassed = preflightEnvelope == nil
                            ? workspace.check.passed : plannedReceipt?.passed == true
                        let passed = sourcePassed && workspacePassed && missionBound
                        return BuilderVerifierReceipt(
                            scope: .final, provider: "kist", model: "deterministic",
                            deterministic: true, passed: passed,
                            checks: finalChecks,
                            failureFingerprint: passed ? nil
                                : finalChecks.filter { !$0.passed }
                                    .map(\.details).joined(separator: "; "),
                            verificationSubject: plannedReceipt?.verificationSubject ?? workspace.subject,
                            baselineDigest: plannedReceipt?.baselineDigest ?? workspace.baseline,
                            subjectDigest: plannedReceipt?.subjectDigest ?? workspace.digest,
                            contractFingerprint: plannedReceipt?.contractFingerprint ?? objectiveFingerprint,
                            completionMode: finalizedContract.effectiveCompletionMode,
                            commandEvidence: preflightEnvelope == nil
                                ? workspace.commands : plannedReceipt?.commandEvidence,
                            verifiedAt: plannedReceipt?.verifiedAt ?? Date(),
                            requiredSupportingObligations: requiredSupportingObligations,
                            supportingCommandReceipts: supportingCommandReceipts,
                            planFinalVerificationReceipt: planFinalVerificationReceipt,
                            missionInstanceID: launch.adapter == .planExecute
                                ? finalizedContract.checkpointIdentity : nil,
                            fleetVerification: plannedReceipt?.fleetVerification
                        )
                    }
    }


}
