import Foundation
import AgentCore

// Outer Builder review, route validation and shared-budget accounting.
// Extracted from the verification module; deterministic verification remains separate.
extension KistRunner {
    private struct BuilderOuterReviewReservation {
        let id: Int
        let inputTokens: Int
        let outputTokens: Int
        let reservedUSD: Double

        var totalTokens: Int { inputTokens + outputTokens }
    }

    private static func builderReserveOuterReview(
        budget: BudgetLedger,
        reviewerProviderID: String,
        goal: String,
        evidenceOverride: String?,
        completionEvidence: PromotionCompletionEvidence?
    ) async -> BuilderOuterReviewReservation? {
        // Each of the four lenses receives the complete typed evidence packet.
        // Reflection includes every nested receipt; fixed overhead covers the
        // system/lens prompts plus runShipReview's maximum 8 KiB diff.
        let evidenceBytes = String(reflecting: completionEvidence as Any).utf8.count
            + goal.utf8.count + (evidenceOverride?.utf8.count ?? 0) + 12_000
        let perLensInput = max(1, (evidenceBytes + 3) / 4)
        let inputTokens = perLensInput * 4
        let outputTokens = 600 * 4
        let reservedUSD = CompetitiveBenchmark.priceUSD(
            vendor: reviewerProviderID, promptTokens: inputTokens,
            completionTokens: outputTokens) ?? 0
        guard let id = await budget.reserve(tokens: inputTokens + outputTokens,
                                            usd: reservedUSD) else { return nil }
        return BuilderOuterReviewReservation(
            id: id, inputTokens: inputTokens,
            outputTokens: outputTokens, reservedUSD: reservedUSD)
    }

    static func runBudgetedBuilderShipReview(
        goal: String,
        registry: ProviderRegistry,
        roles: RoleBindings,
        root: String,
        budget: BudgetLedger,
        reviewerProviderID: String,
        verifiedExecution: Bool? = nil,
        evidenceOverride: String? = nil,
        allowVerifiedReadOnly: Bool = false,
        verificationSubject: String? = nil,
        verificationDigest: String? = nil,
        completionEvidence: PromotionCompletionEvidence? = nil,
        reviewRoutePolicy: ProviderRoutePolicy = .sameProviderAdaptive,
        confirmDeployment: Bool = false
    ) async -> BuilderBudgetedShipReviewResult {
        guard let reservation = await builderReserveOuterReview(
            budget: budget, reviewerProviderID: reviewerProviderID,
            goal: goal, evidenceOverride: evidenceOverride,
            completionEvidence: completionEvidence) else {
            return BuilderBudgetedShipReviewResult(
                decision: nil,
                denialReason: "Outer four-lens review denied by the shared run budget before invocation",
                usage: .init(aggregateTokens: 0))
        }
        let decision = await runShipReview(
            goal: goal, registry: registry, roles: roles, root: root,
            verifiedExecution: verifiedExecution, evidenceOverride: evidenceOverride,
            allowVerifiedReadOnly: allowVerifiedReadOnly,
            verificationSubject: verificationSubject,
            verificationDigest: verificationDigest,
            completionEvidence: completionEvidence,
            reviewRoutePolicy: reviewRoutePolicy,
            confirmDeployment: confirmDeployment)
        // runShipReview does not expose provider usage. Commit the full bounded
        // four-lens estimate on both GO and NO-GO rather than under-accounting.
        await budget.commit(reservation: reservation.id,
                            actualTokens: reservation.totalTokens,
                            actualUSD: reservation.reservedUSD)
        return BuilderBudgetedShipReviewResult(
            decision: decision, denialReason: nil,
            usage: .init(inputTokens: reservation.inputTokens,
                         outputTokens: reservation.outputTokens,
                         aggregateTokens: reservation.totalTokens))
    }


    struct BuilderReviewContext: Sendable {
        let criticBinding: ProviderBinding
        let registry: ProviderRegistry
        let launch: BuilderCompatibilityLaunch
        let projectRoot: String
        let finalizedContract: BuilderContract
        let goal: String
        let sharedBudget: BudgetLedger?
    }

    struct BuilderAuthoritativeReviewRoute: Sendable, Equatable {
        let provider: String
        let model: String
        let identity: String
    }

    static func builderAuthoritativeReviewRoute(
        _ decision: ShipPipeline.Decision,
        expectedProviderID: String,
        producingIdentities: Set<String>,
        expectedReviewerIdentity: String? = nil,
        reviewGrade: EvolutionReviewGrade = .independent
    ) -> BuilderAuthoritativeReviewRoute? {
        guard let votes = decision.verdict?.votes else { return nil }
        let completed = votes.filter { !$0.failed }
        guard !completed.isEmpty else { return nil }
        let routes = completed.compactMap { vote -> BuilderAuthoritativeReviewRoute? in
            guard let provider = vote.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let model = vote.modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let identity = providerModelIdentity(provider: provider, model: model) else {
                return nil
            }
            return BuilderAuthoritativeReviewRoute(
                provider: provider, model: model, identity: identity)
        }
        guard routes.count == completed.count,
              Set(routes.map(\.identity)).count == 1,
              routes[0].provider.caseInsensitiveCompare(expectedProviderID) == .orderedSame else {
            return nil
        }
        switch reviewGrade {
        case .independent:
            guard !producingIdentities.contains(routes[0].identity) else { return nil }
        case .freshContextSameModel:
            guard expectedReviewerIdentity == routes[0].identity,
                  producingIdentities == [routes[0].identity] else { return nil }
        }
        return routes[0]
    }

    static func builderReviewRouteFailureFindings(
        _ decision: ShipPipeline.Decision,
        reviewGrade: EvolutionReviewGrade = .independent
    ) -> [String] {
        let headline = reviewGrade == .freshContextSameModel
            ? "Outer review did not produce the exact fresh-context same-model reviewer route (independent=false)"
            : "Outer review did not produce one distinct concrete reviewer route"
        let lensFailures = (decision.verdict?.votes ?? []).filter(\.failed).map {
            "\($0.name): \($0.reason)"
        }
        return [headline] + lensFailures
    }

    private struct BuilderCompletionMutationFacts {
        let receipts: [BuilderTransactionPromotionReceipt]
        let paths: [String]
        var hadChanges: Bool { !paths.isEmpty }
    }

    static func builderFleetPromotionMatchesPartition(
        _ receipt: BuilderTransactionPromotionReceipt,
        nodeID: String,
        contractFingerprint: String,
        partitionPaths: [String],
        acceptedVerifierSubjectDigest: String
    ) -> Bool {
        guard receipt.nodeID == nodeID,
              receipt.contractFingerprint == contractFingerprint,
              receipt.verifierSubjectDigest == acceptedVerifierSubjectDigest else {
            return false
        }
        let operationPaths = receipt.operations.map(\.path)
        return operationPaths.count == partitionPaths.count
            && Set(operationPaths) == Set(partitionPaths)
    }

    static func builderFleetReviewNodeSetsMatch(
        receipts: [BuilderTransactionPromotionReceipt],
        childNodeIDs: Set<String>,
        acceptedVerificationSubjectDigests: [String: String]
    ) -> Bool {
        let receiptNodeIDs = receipts.map(\.nodeID)
        return Set(receiptNodeIDs).count == receiptNodeIDs.count
            && Set(receiptNodeIDs) == childNodeIDs
            && Set(acceptedVerificationSubjectDigests.keys) == childNodeIDs
    }

    private static func builderCompletionMutationFacts(
        request: BuilderReviewRequest,
        contractID: String,
        completionMode: BuilderCompletionMode,
        verifiedDigest: String,
        fleetVerification: BuilderFleetVerificationBundle?
    ) -> (facts: BuilderCompletionMutationFacts?, failure: String?) {
        let receipts = request.promotionReceipts.sorted {
            ($0.nodeID, $0.attempt, $0.receiptDigest)
                < ($1.nodeID, $1.attempt, $1.receiptDigest)
        }
        guard receipts.allSatisfy(\.hasValidReceiptDigest),
              Set(receipts.map(\.receiptDigest)).count == receipts.count,
              receipts.allSatisfy({ $0.builderContractID == contractID }) else {
            return (nil, "a transaction mutation receipt is invalid, duplicated, or contract-mismatched")
        }
        let operations = receipts.flatMap(\.operations)
        let paths = Array(Set(operations.map(\.path))).sorted()
        guard paths.count == operations.count else {
            return (nil, "transaction mutation receipts contain duplicate path observations")
        }
        switch completionMode {
        case .build:
            guard !receipts.isEmpty, !operations.isEmpty else {
                return (nil, "build digest changed without sealed observed mutation details")
            }
        case .verificationOnly:
            guard operations.isEmpty else {
                return (nil, "verification-only completion contains a mutation receipt")
            }
        }
        let receiptNodeIDs = receipts.map(\.nodeID)
        guard Set(receiptNodeIDs).count == receiptNodeIDs.count,
              Set(request.acceptedAttempts.keys) == Set(receiptNodeIDs),
              Set(request.selectedContractFingerprints.keys) == Set(receiptNodeIDs),
              receipts.allSatisfy({ receipt in
                  request.acceptedAttempts[receipt.nodeID] == receipt.attempt
                      && request.selectedContractFingerprints[receipt.nodeID]
                          == receipt.contractFingerprint
              }) else {
            return (nil, "transaction mutation receipt is stale or not bound to the accepted retry attempt and selected execution contract")
        }
        if let fleetVerification {
            let children = Dictionary(uniqueKeysWithValues:
                fleetVerification.children.map { ($0.nodeID, $0) })
            guard builderFleetReviewNodeSetsMatch(
                      receipts: receipts,
                      childNodeIDs: Set(children.keys),
                      acceptedVerificationSubjectDigests:
                        request.acceptedVerificationSubjectDigests),
                  receipts.allSatisfy({ receipt in
                      guard let child = children[receipt.nodeID],
                            let acceptedDigest = request
                                .acceptedVerificationSubjectDigests[receipt.nodeID] else {
                          return false
                      }
                      return builderFleetPromotionMatchesPartition(
                          receipt,
                          nodeID: child.nodeID,
                          contractFingerprint: child.contractFingerprint,
                          partitionPaths: child.partitionPaths,
                          acceptedVerifierSubjectDigest: acceptedDigest)
                  }) else {
                return (nil, "fleet mutation receipts do not match every verified child subject")
            }
        } else {
            guard receipts.allSatisfy({ $0.verifierSubjectDigest == verifiedDigest }) else {
                return (nil, "transaction mutation receipt is not bound to the final verifier subject digest")
            }
        }
        return (BuilderCompletionMutationFacts(receipts: receipts, paths: paths), nil)
    }

    static func builderReview(
        _ request: BuilderReviewRequest,
        context configuration: BuilderReviewContext
    ) async -> BuilderReviewReceipt {
        let criticBinding = configuration.criticBinding
        let registry = configuration.registry
        let launch = configuration.launch
        let finalizedContract = configuration.finalizedContract
        let goal = configuration.goal
        let sharedBudget = configuration.sharedBudget
                    let workerIdentities = request.workers.compactMap {
                        providerModelIdentity(provider: $0.provider, model: $0.model)
                    }
                    let producingIdentities = Set(
                        workerIdentities + (request.contract.producerIdentities ?? []))
                    let reviewPolicy = finalizedContract.effectiveReviewPolicy
                    let reviewCheckName = reviewPolicy.grade.evidenceLabel
                    let selection = reviewPolicy.grade == .freshContextSameModel
                        ? freshContextSameModelReviewerSelection(
                            preferred: criticBinding,
                            producingIdentities: producingIdentities,
                            registry: registry,
                            policy: reviewPolicy)
                        : independentReviewerSelection(
                            preferred: criticBinding,
                            producingIdentities: producingIdentities,
                            registry: registry,
                            benched: liveProviderBenched())
                    guard workerIdentities.count == request.workers.count,
                          let selection else {
                        let reason = reviewPolicy.grade == .freshContextSameModel
                            ? "Fresh-context same-model reviewer does not exactly match the sole producing worker: "
                                + producingIdentities.sorted().joined(separator: ", ")
                            : "No available configured reviewer is distinct from every producing worker: "
                                + producingIdentities.sorted().joined(separator: ", ")
                        return BuilderReviewReceipt(
                            provider: "", model: "", accepted: false,
                            checks: [.init(name: reviewCheckName, passed: false,
                                           details: reason)],
                            findings: [reason], workerIdentities: producingIdentities.sorted(),
                            reviewerIdentity: nil
                        )
                    }
                    let fleetEvidence: String? = launch.adapter == .fleet
                        ? "Fleet supervisor/Foreman evidence:\n" + request.workers
                            .flatMap(\.checks).map { "- \($0.name): \($0.details)" }.joined(separator: "\n")
                        : nil
                    let reviewRoles = independentReviewRoles(selection)
                    let promotionMissionID = request.verification.missionInstanceID
                    let promotionMissionBound = launch.adapter != .planExecute
                        || (promotionMissionID != nil
                            && promotionMissionID == request.contract.checkpointIdentity)
                    guard let baseline = request.verification.baselineDigest,
                          let verified = request.verification.subjectDigest,
                          let fingerprint = request.verification.contractFingerprint,
                          let subject = request.verification.verificationSubject,
                          let verifiedAt = request.verification.verifiedAt,
                          promotionMissionBound else {
                        let reason = "Typed outer review evidence is incomplete"
                        return BuilderReviewReceipt(provider: selection.binding.providerId,
                            model: selection.binding.model ?? "", accepted: false,
                            checks: [.init(name: reviewCheckName, passed: false, details: reason)],
                            findings: [reason], workerIdentities: selection.workerIdentities,
                            reviewerIdentity: selection.identity)
                    }
                    let commands = request.verification.commandEvidence ?? []
                    let fleetVerification = request.verification.fleetVerification
                    let mutationFacts: BuilderCompletionMutationFacts
                    let mutationResult = builderCompletionMutationFacts(
                        request: request, contractID: finalizedContract.id,
                        completionMode: finalizedContract.effectiveCompletionMode,
                        verifiedDigest: verified, fleetVerification: fleetVerification)
                    if let facts = mutationResult.facts {
                        mutationFacts = facts
                    } else {
                        let failure = mutationResult.failure ?? "mutation evidence is unavailable"
                        let reason = "Typed outer review mutation evidence rejected: \(failure)"
                        return BuilderReviewReceipt(provider: selection.binding.providerId,
                            model: selection.binding.model ?? "", accepted: false,
                            checks: [.init(name: reviewCheckName, passed: false,
                                           details: reason)],
                            findings: [reason], workerIdentities: selection.workerIdentities,
                            reviewerIdentity: selection.identity)
                    }
                    // Deferred publication leaves source untouched until independent review accepts.
                    // Review must therefore hash and inspect the exact verified staged subject for every
                    // adapter, never the source root that intentionally still contains the old bytes.
                    let reviewRoot = subject
                    let reviewEntryDigest = PlanExecuteLoop.governedWorkspaceDigest(
                        projectRoot: reviewRoot)
                    let completionEvidence = PromotionCompletionEvidence(
                        schemaVersion: launch.adapter == .fleet ? 4
                            : (launch.adapter == .planExecute ? 3 : 1),
                        contractID: finalizedContract.id, objectiveFingerprint: fingerprint,
                        completionMode: finalizedContract.effectiveCompletionMode,
                        verificationSubject: subject, baselineDigest: baseline,
                        verifiedDigest: verified, reviewEntryDigest: reviewEntryDigest,
                        verifiedAt: verifiedAt, commandReceipts: commands,
                        hostChecks: request.verification.checks,
                        producerIdentities: selection.workerIdentities,
                        reviewerIdentity: selection.identity,
                        reviewGrade: selection.reviewGrade,
                        hadChanges: mutationFacts.hadChanges,
                        changedPaths: mutationFacts.paths,
                        mutationReceipts: mutationFacts.receipts,
                        requiredSupportingObligations:
                            request.verification.requiredSupportingObligations ?? [],
                        supportingCommandReceipts:
                            request.verification.supportingCommandReceipts ?? [],
                        finalVerificationReceipt:
                            request.verification.planFinalVerificationReceipt,
                        missionInstanceID: promotionMissionID,
                        fleetVerification: fleetVerification,
                        acceptedVerificationSubjectDigests:
                            launch.adapter == .fleet
                                ? request.acceptedVerificationSubjectDigests : [:])
                    if let failure = completionEvidence.validationFailure {
                        let reason = "Typed outer review evidence rejected: \(failure)"
                        return BuilderReviewReceipt(provider: selection.binding.providerId,
                            model: selection.binding.model ?? "", accepted: false,
                            checks: [.init(name: reviewCheckName, passed: false, details: reason)],
                            findings: [reason], workerIdentities: selection.workerIdentities,
                            reviewerIdentity: selection.identity,
                            evidencePacketDigest: completionEvidence.packetDigest)
                    }
                    guard let sharedBudget else {
                        let reason = "Shared BudgetLedger unavailable for authoritative outer review"
                        return BuilderReviewReceipt(
                            provider: selection.binding.providerId,
                            model: selection.binding.model ?? "", accepted: false,
                            checks: [.init(name: reviewCheckName, passed: false,
                                           details: reason)], findings: [reason],
                            usage: .init(aggregateTokens: 0),
                            workerIdentities: selection.workerIdentities,
                            reviewerIdentity: selection.identity,
                            evidencePacketDigest: completionEvidence.packetDigest)
                    }
                    let sourceMaterial: String
                    do {
                        sourceMaterial = try BuilderReviewSourceContext.capture(
                            baselineRoot: configuration.projectRoot, verifiedRoot: reviewRoot,
                            mutations: mutationFacts.receipts.flatMap(\.operations))
                    } catch {
                        let reason = "Source review material unavailable: \(error)"
                        return BuilderReviewReceipt(
                            provider: selection.binding.providerId,
                            model: selection.binding.model ?? "", accepted: false,
                            checks: [.init(name: reviewCheckName, passed: false, details: reason)],
                            findings: [reason], workerIdentities: selection.workerIdentities,
                            reviewerIdentity: selection.identity,
                            evidencePacketDigest: completionEvidence.packetDigest)
                    }
                    let reviewMaterial = [sourceMaterial, fleetEvidence].compactMap { $0 }
                        .joined(separator: "\n\n")
                    let budgetedReview = await runBudgetedBuilderShipReview(
                        goal: goal, registry: registry, roles: reviewRoles, root: reviewRoot,
                        budget: sharedBudget,
                        reviewerProviderID: selection.binding.providerId,
                        verifiedExecution: request.verification.passed,
                        evidenceOverride: reviewMaterial,
                        allowVerifiedReadOnly: launch.allowsVerifiedReadOnlyPromotion,
                        verificationSubject: request.verification.verificationSubject,
                        verificationDigest: request.verification.subjectDigest,
                        completionEvidence: completionEvidence,
                        reviewRoutePolicy: selection.reviewGrade == .freshContextSameModel
                            ? .exact : .sameProviderAdaptive,
                        confirmDeployment: false
                    )
                    guard let decision = budgetedReview.decision else {
                        let reason = budgetedReview.denialReason
                            ?? "Outer four-lens review was not invoked"
                        return BuilderReviewReceipt(
                            provider: selection.binding.providerId,
                            model: selection.binding.model ?? "", accepted: false,
                            checks: [.init(name: reviewCheckName, passed: false,
                                           details: reason)], findings: [reason],
                            usage: budgetedReview.usage,
                            workerIdentities: selection.workerIdentities,
                            reviewerIdentity: selection.identity,
                            evidencePacketDigest: completionEvidence.packetDigest)
                    }
                    guard let authoritativeRoute = builderAuthoritativeReviewRoute(
                        decision, expectedProviderID: selection.binding.providerId,
                        producingIdentities: producingIdentities,
                        expectedReviewerIdentity: selection.identity,
                        reviewGrade: selection.reviewGrade) else {
                        let findings = builderReviewRouteFailureFindings(
                            decision, reviewGrade: selection.reviewGrade)
                        let reason = findings.joined(separator: "; ")
                        return BuilderReviewReceipt(
                            provider: "", model: "", accepted: false,
                            checks: [.init(name: reviewCheckName, passed: false,
                                           details: reason)], findings: findings,
                            usage: budgetedReview.usage,
                            workerIdentities: selection.workerIdentities,
                            reviewerIdentity: nil,
                            evidencePacketDigest: decision.evidencePacketDigest,
                            votes: decision.verdict?.votes.map {
                                BuilderReviewVoteReceipt(
                                    lens: $0.name, accepted: $0.shipWorthy,
                                    reason: $0.reason, failed: $0.failed,
                                    provider: $0.providerID, model: $0.modelID,
                                    invocationID: $0.invocationID,
                                    freshConversation: $0.freshConversation)
                            },
                            reviewThreshold: decision.verdict?.threshold)
                    }
                    let check = BuilderCheckReceipt(name: reviewCheckName,
                                                    passed: decision.canDeploy,
                                                    details: decision.reason)
                    return BuilderReviewReceipt(
                        provider: authoritativeRoute.provider,
                        model: authoritativeRoute.model,
                        accepted: decision.canDeploy,
                        checks: [check],
                        findings: decision.canDeploy ? [] : [decision.reason],
                        usage: budgetedReview.usage,
                        workerIdentities: selection.workerIdentities,
                        reviewerIdentity: authoritativeRoute.identity,
                        evidencePacketDigest: decision.evidencePacketDigest,
                        votes: decision.verdict?.votes.map {
                            BuilderReviewVoteReceipt(
                                lens: $0.name, accepted: $0.shipWorthy,
                                reason: $0.reason, failed: $0.failed,
                                provider: $0.providerID, model: $0.modelID,
                                invocationID: $0.invocationID,
                                freshConversation: $0.freshConversation)
                        },
                        reviewThreshold: decision.verdict?.threshold
                    )
    }
}
