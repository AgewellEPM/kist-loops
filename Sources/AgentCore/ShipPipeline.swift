import Foundation

public struct PromotionCompletionEvidence: Sendable, Equatable {
    public let schemaVersion: Int; public let contractID: String; public let objectiveFingerprint: String
    public let completionMode: BuilderCompletionMode; public let verificationSubject: String
    public let baselineDigest: String; public let verifiedDigest: String; public let reviewEntryDigest: String
    public let verifiedAt: Date; public let commandReceipts: [BuilderCommandEvidenceReceipt]
    public let hostChecks: [BuilderCheckReceipt]; public let producerIdentities: [String]
    public let reviewerIdentity: String; public let hadChanges: Bool; public let changedPaths: [String]
    public let reviewGrade: EvolutionReviewGrade
    public let diffSummary: String
    public let mutationReceipts: [BuilderTransactionPromotionReceipt]
    public let requiredSupportingObligations: [PlanSupportingObligation]
    public let supportingCommandReceipts: [PlanSupportingCommandReceipt]
    public let finalVerificationReceipt: PlanFinalVerificationReceipt?
    public let missionInstanceID: String?
    public let fleetVerification: BuilderFleetVerificationBundle?
    /// Per-child verifier subjects accepted before aggregate merging. Fleet promotion receipts
    /// bind to these digests; the fleet bundle's subject digest identifies the later merged root.
    public let acceptedVerificationSubjectDigests: [String: String]

    public init(schemaVersion: Int = 1, contractID: String, objectiveFingerprint: String,
                completionMode: BuilderCompletionMode, verificationSubject: String,
                baselineDigest: String, verifiedDigest: String, reviewEntryDigest: String,
                verifiedAt: Date, commandReceipts: [BuilderCommandEvidenceReceipt],
                hostChecks: [BuilderCheckReceipt], producerIdentities: [String],
                reviewerIdentity: String,
                reviewGrade: EvolutionReviewGrade = .independent,
                hadChanges: Bool = false, changedPaths: [String] = [],
                diffSummary: String = "",
                mutationReceipts: [BuilderTransactionPromotionReceipt] = [],
                requiredSupportingObligations: [PlanSupportingObligation] = [],
                supportingCommandReceipts: [PlanSupportingCommandReceipt] = [],
                finalVerificationReceipt: PlanFinalVerificationReceipt? = nil,
                missionInstanceID: String? = nil,
                fleetVerification: BuilderFleetVerificationBundle? = nil,
                acceptedVerificationSubjectDigests: [String: String] = [:]) {
        self.schemaVersion = schemaVersion; self.contractID = contractID
        self.objectiveFingerprint = objectiveFingerprint; self.completionMode = completionMode
        self.verificationSubject = verificationSubject; self.baselineDigest = baselineDigest
        self.verifiedDigest = verifiedDigest; self.reviewEntryDigest = reviewEntryDigest
        self.verifiedAt = verifiedAt; self.commandReceipts = commandReceipts
        self.hostChecks = hostChecks; self.producerIdentities = producerIdentities
        self.reviewerIdentity = reviewerIdentity; self.hadChanges = hadChanges
        self.reviewGrade = reviewGrade
        self.changedPaths = changedPaths; self.diffSummary = diffSummary
        self.mutationReceipts = mutationReceipts.sorted {
            ($0.nodeID, $0.attempt, $0.receiptDigest)
                < ($1.nodeID, $1.attempt, $1.receiptDigest)
        }
        self.requiredSupportingObligations = requiredSupportingObligations
        self.supportingCommandReceipts = supportingCommandReceipts
        self.finalVerificationReceipt = finalVerificationReceipt
        self.missionInstanceID = missionInstanceID
        self.fleetVerification = fleetVerification
        self.acceptedVerificationSubjectDigests = acceptedVerificationSubjectDigests
    }

    public func withChanges(hadChanges: Bool, changedPaths: [String], diffSummary: String) -> Self {
        Self(schemaVersion: schemaVersion, contractID: contractID,
             objectiveFingerprint: objectiveFingerprint, completionMode: completionMode,
             verificationSubject: verificationSubject, baselineDigest: baselineDigest,
             verifiedDigest: verifiedDigest, reviewEntryDigest: reviewEntryDigest,
             verifiedAt: verifiedAt, commandReceipts: commandReceipts, hostChecks: hostChecks,
             producerIdentities: producerIdentities, reviewerIdentity: reviewerIdentity,
             reviewGrade: reviewGrade,
             hadChanges: hadChanges, changedPaths: changedPaths, diffSummary: diffSummary,
             mutationReceipts: mutationReceipts,
             requiredSupportingObligations: requiredSupportingObligations,
             supportingCommandReceipts: supportingCommandReceipts,
             finalVerificationReceipt: finalVerificationReceipt,
             missionInstanceID: missionInstanceID,
             fleetVerification: fleetVerification,
             acceptedVerificationSubjectDigests: acceptedVerificationSubjectDigests)
    }

    public var validationFailure: String? {
        let reviewer = reviewerIdentity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let producers = producerIdentities.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard (schemaVersion == 1 || schemaVersion == 2 || schemaVersion == 3
                || schemaVersion == 4),
              !contractID.isEmpty, !objectiveFingerprint.isEmpty,
              !verificationSubject.isEmpty else { return "contract identity or verification subject is unavailable" }
        guard reviewer.contains(":"), !producers.isEmpty,
              producers.allSatisfy({ $0.contains(":") }) else {
            return "reviewer or producer identity is unknown"
        }
        switch reviewGrade {
        case .independent:
            guard !producers.contains(reviewer) else {
                return "independent reviewer identity is not distinct from producers"
            }
        case .freshContextSameModel:
            guard Set(producers) == [reviewer] else {
                return "fresh_context_same_model requires one exact producer/reviewer identity"
            }
        }
        guard [baselineDigest, verifiedDigest, reviewEntryDigest].allSatisfy({
            !$0.isEmpty && !$0.hasPrefix("unavailable:")
        }) else { return "one or more governed workspace digests is unavailable" }
        guard verifiedDigest == reviewEntryDigest else { return "verification evidence is stale at review entry" }
        guard mutationReceipts.allSatisfy(\.hasValidReceiptDigest),
              Set(mutationReceipts.map(\.receiptDigest)).count == mutationReceipts.count,
              mutationReceipts.allSatisfy({ $0.builderContractID == contractID }) else {
            return "governed mutation receipt is invalid, duplicated, or bound to another contract"
        }
        let observedMutations = mutationReceipts.flatMap(\.operations)
        let observedPaths = Array(Set(observedMutations.map(\.path))).sorted()
        guard observedPaths.count == observedMutations.count else {
            return "governed mutation receipts contain duplicate path observations"
        }
        switch completionMode {
        case .verificationOnly:
            guard baselineDigest == verifiedDigest, observedMutations.isEmpty,
                  !hadChanges, changedPaths.isEmpty else {
                return "verification-only contract requires unchanged baseline/verified/current digests and no changes"
            }
        case .build:
            guard baselineDigest != verifiedDigest else { return "build contract has no mutation proof" }
            guard !mutationReceipts.isEmpty, !observedMutations.isEmpty else {
                return "build digest changed without sealed observed mutation details"
            }
            guard hadChanges, changedPaths.sorted() == observedPaths else {
                return "build change facts do not match sealed observed mutation receipts"
            }
        }
        guard !hostChecks.isEmpty, hostChecks.allSatisfy(\.passed) else {
            return "host verification checks are missing or failed"
        }
        if let fleetVerification {
            guard schemaVersion == 4 else {
                return "fleet verification requires completion-evidence schema 4"
            }
            do {
                try fleetVerification.validate()
            } catch {
                return "fleet verification bundle is invalid: \(error)"
            }
            guard fleetVerification.parentContractFingerprint == objectiveFingerprint,
                  fleetVerification.verificationSubject == verificationSubject,
                  fleetVerification.subjectDigest == verifiedDigest else {
                return "fleet verification is not bound to the promotion contract and staged workspace"
            }
            guard verifiedAt >= (fleetVerification.children.map(\.verifiedAt).max() ?? verifiedAt)
            else {
                return "fleet completion evidence predates a child verification receipt"
            }
            // Fleet children prove only their sealed partitions. The outer command receipts are
            // therefore required to carry the one aggregate-root functional oracle; they must be
            // parent-bound and disjoint from every child command reference, never duplicates.
            let childCommandReceipts = fleetVerification.children.flatMap(\.commandEvidence)
            let childReferences = childCommandReceipts.compactMap(\.trustedCommandReference)
            let aggregateReferences = commandReceipts.compactMap(\.trustedCommandReference)
            guard !commandReceipts.isEmpty,
                  aggregateReferences.count == commandReceipts.count,
                  commandReceipts.allSatisfy({ receipt in
                      guard let reference = receipt.trustedCommandReference else { return false }
                      return reference.isValid && reference.exitCode == 0
                          && !reference.timedOut && !reference.wasSignalled
                          && receipt.verifierStatus == .passed && receipt.exitCode == 0
                          && receipt.argsFingerprint == reference.gateArgumentsDigest
                          && receipt.outputDigest == reference.fullStreamDigest
                          && receipt.isBound(
                            contractFingerprint: objectiveFingerprint,
                            subjectDigest: verifiedDigest)
                  }),
                  Set(aggregateReferences.map(\.observationID)).count
                    == aggregateReferences.count,
                  Set(aggregateReferences.map(\.invocationID)).count
                    == aggregateReferences.count,
                  Set(aggregateReferences.map(\.observationID)).isDisjoint(
                    with: Set(childReferences.map(\.observationID))),
                  Set(aggregateReferences.map(\.invocationID)).isDisjoint(
                    with: Set(childReferences.map(\.invocationID))) else {
                return "fleet aggregate command evidence is missing, unbound, stale, or duplicates child evidence"
            }
            let children = Dictionary(uniqueKeysWithValues:
                fleetVerification.children.map { ($0.nodeID, $0) })
            guard Set(acceptedVerificationSubjectDigests.keys) == Set(children.keys),
                  acceptedVerificationSubjectDigests.values.allSatisfy({ digest in
                      digest.count == 64 && digest.allSatisfy {
                          "0123456789abcdef".contains($0)
                      }
                  }) else {
                return "fleet accepted child verifier subjects are missing or malformed"
            }
            guard Set(mutationReceipts.map(\.nodeID)) == Set(children.keys),
                  mutationReceipts.allSatisfy({ receipt in
                      guard let child = children[receipt.nodeID] else { return false }
                      return receipt.contractFingerprint == child.contractFingerprint
                          && receipt.verifierSubjectDigest
                            == acceptedVerificationSubjectDigests[receipt.nodeID]
                  }) else {
                return "fleet mutation receipts are not bound to every verified child subject"
            }
        } else {
            guard acceptedVerificationSubjectDigests.isEmpty else {
                return "non-fleet completion contains fleet child verifier subjects"
            }
            guard schemaVersion != 4 else {
                return "completion-evidence schema 4 requires a fleet verification bundle"
            }
            guard !commandReceipts.isEmpty,
                  commandReceipts.allSatisfy({
                      $0.isBound(
                        contractFingerprint: objectiveFingerprint,
                        subjectDigest: verifiedDigest)
                  }), commandReceipts.contains(where: { $0.verifierStatus == .passed }) else {
                return "typed deterministic command evidence is unavailable, invalid, or unbound"
            }
            guard mutationReceipts.allSatisfy({
                $0.verifierSubjectDigest == verifiedDigest
            }) else {
                return "mutation receipts are not bound to the final verifier subject digest"
            }
        }
        let requiresTypedSupportingEvidence = schemaVersion == 2
            || (schemaVersion == 3 && completionMode == .verificationOnly)
        if requiresTypedSupportingEvidence, let failure = typedSupportingValidationFailure {
            return failure
        }
        if schemaVersion == 3 {
            guard let missionInstanceID,
                  missionInstanceID.count == 64,
                  missionInstanceID.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                return "PlanExecute mission identity is missing, malformed, or inconsistent across evidence"
            }
            if completionMode == .verificationOnly {
                guard finalVerificationReceipt?.missionInstanceID == missionInstanceID,
                      supportingCommandReceipts.allSatisfy({
                          $0.missionInstanceID == missionInstanceID
                      }) else {
                    return "PlanExecute mission identity is missing, malformed, or inconsistent across evidence"
                }
            } else {
                guard finalVerificationReceipt?.missionInstanceID == nil
                        || finalVerificationReceipt?.missionInstanceID == missionInstanceID,
                      supportingCommandReceipts.allSatisfy({
                          $0.missionInstanceID == missionInstanceID
                      }) else {
                    return "PlanExecute mission identity is inconsistent across optional build evidence"
                }
            }
        }
        return nil
    }

    private var typedSupportingValidationFailure: String? {
        guard completionMode == .verificationOnly else {
            return "typed supporting-evidence schema is currently restricted to verification-only contracts"
        }
        guard let final = finalVerificationReceipt,
              let missionInstanceID = final.missionInstanceID,
              !missionInstanceID.isEmpty,
              final.hasValidEvidenceDigest,
              final.freshAfterMutationFrontier,
              final.tool == "run_command",
              final.expectedExitCode == 0,
              final.actualExitCode == 0,
              final.captureOrdinal > (final.mutationFrontierOrdinal ?? -1),
              final.validatesBinding(
                missionInstanceID: missionInstanceID,
                contractID: contractID,
                completionContractFingerprint: final.completionContractFingerprint,
                obligationsFingerprint: final.obligationsFingerprint,
                executionPolicyFingerprint: final.executionPolicyFingerprint,
                workspaceManifestDigest: final.workspaceManifestDigest,
                governedWorkspaceDigest: verifiedDigest,
                canonicalFunctionalObjectiveFingerprint:
                    final.canonicalFunctionalObjectiveFingerprint,
                workspaceManifestPolicyFingerprint:
                    final.workspaceManifestPolicyFingerprint,
                workspaceManifestRevision: final.workspaceManifestRevision
              ) else {
            return "fresh typed final-verification receipt is missing, stale, or unbound"
        }
        let finalCommands = commandReceipts.filter { $0.verifierStatus == .passed }
        guard commandReceipts.count == 1, let finalCommand = finalCommands.first,
              finalCommands.count == 1,
              finalCommand.tool == final.tool,
              finalCommand.exitCode == final.actualExitCode,
              finalCommand.argsFingerprint == final.commandFingerprint,
              finalCommand.outputDigest == final.outputDigest,
              finalCommand.subjectDigestAfter == final.governedWorkspaceDigest,
              finalCommand.completedAt == final.verifiedAt else {
            return "the dedicated final replay must be the sole passed deterministic verifier"
        }
        let requiredIDs = requiredSupportingObligations.map(\.id)
        let requiredSet = Set(requiredIDs)
        guard requiredSet.count == requiredIDs.count,
              requiredSupportingObligations.allSatisfy({ !$0.id.isEmpty }) else {
            return "required supporting obligations contain empty or duplicate identifiers"
        }
        guard !final.obligationsFingerprint.isEmpty,
              !final.executionPolicyFingerprint.isEmpty,
              !final.workspaceManifestDigest.isEmpty,
              final.canonicalFunctionalObjectiveFingerprint?.isEmpty == false,
              final.workspaceManifestPolicyFingerprint?.isEmpty == false,
              final.workspaceManifestRevision != nil,
              final.planID?.isEmpty == false,
              final.planRevision != nil,
              final.workspaceActionReceiptDigest?.isEmpty == false else {
            return "final verification is missing objective, policy, manifest, plan, or action binding"
        }
        for receipt in supportingCommandReceipts {
            guard receipt.success,
                  receipt.tool == "run_command",
                  receipt.allowedExitCodes.contains(receipt.actualExitCode),
                  !receipt.wasSignalled,
                  !receipt.timedOut,
                  receipt.hasValidEvidenceDigest,
                  receipt.validatesBinding(
                    missionInstanceID: missionInstanceID,
                    contractID: contractID,
                    completionContractFingerprint: final.completionContractFingerprint,
                    obligationsFingerprint: final.obligationsFingerprint,
                    executionPolicyFingerprint: final.executionPolicyFingerprint,
                    workspaceManifestDigest: final.workspaceManifestDigest,
                    governedWorkspaceDigest: verifiedDigest,
                    requiredObligationIDs: requiredSet,
                    beforeFinalCaptureOrdinal: final.captureOrdinal,
                    canonicalFunctionalObjectiveFingerprint:
                        final.canonicalFunctionalObjectiveFingerprint,
                    workspaceManifestPolicyFingerprint:
                        final.workspaceManifestPolicyFingerprint,
                    maximumWorkspaceManifestRevision:
                        final.workspaceManifestRevision
                  ),
                  receipt.workspaceActionReceiptDigest?.isEmpty == false else {
                return "a supporting command receipt is failed, stale, incomplete, or unbound"
            }
        }
        for obligation in requiredSupportingObligations {
            guard supportingCommandReceipts.contains(where: {
                $0.satisfiedObligationIDs.contains(obligation.id)
                    && supports(obligation.kind, receipt: $0)
            }) else {
                return "required supporting probe is missing or semantically invalid: \(obligation.id)"
            }
        }
        return nil
    }

    private func supports(_ kind: PlanSupportingObligationKind,
                          receipt: PlanSupportingCommandReceipt) -> Bool {
        switch kind {
        case .build:
            return receipt.actualExitCode == 0
                && receipt.effectObservation.verification == .buildOrTest
        case .fixtureFileInput:
            // The typed obligation ID already binds the requested exit. A fixture probe may be the
            // valid exit-0 case or the invalid expected-exit case; require one exact allowed status
            // rather than silently redefining every fixture probe as exit 0 at the outer boundary.
            return receipt.allowedExitCodes == [receipt.actualExitCode]
                && receipt.argv.contains("--input")
                && !receipt.hasStandardInput
        case .expectedDomainFailure:
            let hasLineDiagnostic = receipt.boundedRedactedOutputExcerpt.range(
                of: #"(?i)\bline\s+[0-9]+\b"#, options: .regularExpression) != nil
            return receipt.actualExitCode != 0
                && receipt.allowedExitCodes == [receipt.actualExitCode]
                && receipt.semanticStatus == "expected_domain_status"
                && !receipt.verificationEligible
                && hasLineDiagnostic
        case .structuredStandardInput:
            return receipt.actualExitCode == 0
                && receipt.hasStandardInput
                && !(receipt.standardInputDigest ?? "").isEmpty
                && receipt.standardInputByteCount > 0
        case .custom:
            return true
        }
    }

    public var packetDigest: String {
        var fields = [
            String(schemaVersion), contractID, objectiveFingerprint, completionMode.rawValue,
            verificationSubject, baselineDigest, verifiedDigest, reviewEntryDigest,
            String(verifiedAt.timeIntervalSince1970), producerIdentities.sorted().joined(separator: ","),
            reviewerIdentity, String(hadChanges), changedPaths.sorted().joined(separator: ","),
            BuilderEvidenceDigest.sha256(diffSummary), commandReceipts.map(\.evidenceDigest).joined(separator: ","),
            hostChecks.map { "\($0.name):\($0.passed):\($0.details)" }.joined(separator: "|"),
            mutationReceipts.map(\.receiptDigest).joined(separator: ",")
        ]
        if schemaVersion >= 2 {
            fields.append(requiredSupportingObligations
                .map { "\($0.id):\($0.kind.rawValue)" }.sorted().joined(separator: ","))
            fields.append(supportingCommandReceipts
                .sorted { $0.captureOrdinal < $1.captureOrdinal }
                .map(\.evidenceDigest).joined(separator: ","))
            fields.append(finalVerificationReceipt?.evidenceDigest ?? "missing")
        }
        if schemaVersion == 3 {
            fields.append(missionInstanceID ?? "missing")
        }
        if schemaVersion == 4 {
            fields.append(fleetVerification?.aggregateDigest ?? "missing")
            fields.append(acceptedVerificationSubjectDigests.keys.sorted().map {
                "\($0):\(acceptedVerificationSubjectDigests[$0] ?? "missing")"
            }.joined(separator: ","))
        }
        if reviewGrade != .independent {
            fields.append(reviewGrade.rawValue)
            fields.append("independent=false")
        }
        return BuilderEvidenceDigest.sha256(fields.joined(separator: "\u{0}"))
    }
}

/// Hooks up Luke's intended system into ONE flow: a goal is built HANDS-FREE in a sandbox, then the
/// COUNCIL OF MINDS reviews the actual result (diff + tests), and only a council blessing makes it
/// deploy-eligible. This is the pure, testable orchestration — the runner injects the real autopilot
/// build and performs the deploy. FAIL-CLOSED + SAFETY INVARIANT: the council can only make the
/// decision STRICTER. Nothing is deploy-eligible without changes except a host-authorized,
/// digest-bound verification-only result, and deploy remains separately confirmed (never auto-armed).
public struct ShipPipeline: Sendable {
    /// What the sandboxed build actually produced — the evidence the council judges.
    public struct BuildResult: Sendable, Equatable {
        public var hadChanges: Bool
        public var diffSummary: String
        public var testsPassed: Bool
        public var testSummary: String
        public var signoffSummary: String
        public var verificationSubject: String?
        public var verificationDigest: String?
        public var completionEvidence: PromotionCompletionEvidence?
        /// Whether a test suite actually RAN. Distinguishes "tests failed" (ran=true, passed=false →
        /// VETO deploy) from "no suite ran" (ran=false → the council judges the code, the fresh-build
        /// case). Defaults true so existing callers/tests are unaffected. (R7 review catch: conflating
        /// absent-suite with failed-tests bricked the whole --ship flow.)
        public var testsRan: Bool
        public init(hadChanges: Bool, diffSummary: String, testsPassed: Bool,
                    testSummary: String, signoffSummary: String, testsRan: Bool = true,
                    verificationSubject: String? = nil, verificationDigest: String? = nil,
                    completionEvidence: PromotionCompletionEvidence? = nil) {
            self.hadChanges = hadChanges; self.diffSummary = diffSummary; self.testsPassed = testsPassed
            self.testSummary = testSummary; self.signoffSummary = signoffSummary; self.testsRan = testsRan
            self.verificationSubject = verificationSubject
            self.verificationDigest = verificationDigest
            self.completionEvidence = completionEvidence
        }
    }

    public struct Decision: Sendable {
        public var verdict: CouncilPromotionVerdict?   // nil = the build produced nothing to review
        public var canDeploy: Bool                     // council blessed it → eligible (still needs your OK)
        public var reason: String
        public var evidencePacketDigest: String?
    }

    private let council: PromotionCouncil
    private let threshold: Int

    public init(council: PromotionCouncil, threshold: Int = 3) {
        self.council = council
        self.threshold = threshold
    }

    /// Review a sandboxed build. No changes are eligible only with explicit host authorization and a
    /// valid verification-only evidence packet; otherwise the council judges the real diff/tests.
    public func review(goal: String, build: BuildResult,
                       allowVerifiedReadOnly: Bool = false) async -> Decision {
        // The council has an 8,000-character source allowance. A sealed packet must
        // never silently lose changed lines when the model prompt is constructed.
        if build.completionEvidence != nil && build.diffSummary.count > 8_000 {
            return Decision(verdict: nil, canDeploy: false,
                reason: "Complete review material exceeds the council input allowance; split the change before review",
                evidencePacketDigest: build.completionEvidence?.packetDigest)
        }
        if let failure = build.completionEvidence?.validationFailure {
            return Decision(verdict: nil, canDeploy: false,
                            reason: "host completion evidence rejected: \(failure)",
                            evidencePacketDigest: build.completionEvidence?.packetDigest)
        }
        let verifiedReadOnly = allowVerifiedReadOnly && build.testsRan && build.testsPassed
            && build.completionEvidence?.completionMode == .verificationOnly
            && build.completionEvidence != nil
        guard build.hadChanges || verifiedReadOnly else {
            return Decision(verdict: nil, canDeploy: false, reason: "nothing was built — no changes to ship",
                            evidencePacketDigest: build.completionEvidence?.packetDigest)
        }
        let ctx = PromotionContext(goal: goal, diffSummary: build.diffSummary, testsPassed: build.testsPassed,
                                   testSummary: build.testSummary, signoffSummary: build.signoffSummary,
                                   completionEvidence: build.completionEvidence)
        let verdict = await council.judge(ctx, threshold: threshold)
        // R7 SYMBOLIC-FIRST: real execution evidence gates the LLM council, never the reverse. A build
        // whose tests RAN and FAILED is not deploy-eligible no matter how the council votes — the
        // council's blessing is NECESSARY, not SUFFICIENT. But "no suite ran" (fresh build) is NOT a
        // failure — the council judges the code itself there (conflating the two bricked --ship, review
        // catch). So only a RAN-AND-FAILED suite vetoes.
        let testsFailed = build.testsRan && !build.testsPassed
        let canDeploy = verdict.isShipWorthy && !testsFailed
        let reason = testsFailed
            ? "blocked — tests ran and FAILED; execution evidence gates deploy regardless of the council vote (\(verdict.summary))"
            : verdict.summary
        return Decision(verdict: verdict, canDeploy: canDeploy, reason: reason,
                        evidencePacketDigest: build.completionEvidence?.packetDigest)
    }
}
