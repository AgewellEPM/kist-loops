import Foundation
import AgentCore

/// Compatibility composition for the existing heavy build routes. BuilderRun owns the durable
/// execution -> deterministic verification -> independent review state machine; the established
/// Kist route bodies remain adapters so their safety gates, receipts, and terminal UX stay intact.
extension KistRunner {
    struct BuilderCompatibilityGoals: Equatable {
        let authorityGoal: String
        let contextualWorkerGoal: String
        let executionGoal: String
        let canonicalFunctionalGoal: String
        let functionalExecutionGoal: String
    }

    /// Keep operator authority and generated/advisory planning material on separate planes. Every
    /// classifier, contract, fingerprint, and deterministic completion obligation consumes
    /// `authorityGoal`; only planner/worker prompts receive `advisoryContext`.
    static func builderCompatibilityGoals(
        authorityGoal: String,
        advisoryContext: PriorResultContext?,
        effortContext: String
    ) -> BuilderCompatibilityGoals {
        let advisoryBlock = advisoryContext.flatMap { $0.isEmpty ? nil : $0.promptBlock }
        let contextualWorkerGoal = authorityGoal
            + (advisoryBlock.map { "\n\n" + $0 } ?? "")
        let executionGoal = contextualWorkerGoal + "\n\n" + effortContext
        let canonicalFunctionalGoal =
            PlanExecuteCompletionContract.functionalObjective(from: authorityGoal)
        return BuilderCompatibilityGoals(
            authorityGoal: authorityGoal,
            contextualWorkerGoal: contextualWorkerGoal,
            executionGoal: executionGoal,
            canonicalFunctionalGoal: canonicalFunctionalGoal,
            functionalExecutionGoal: canonicalFunctionalGoal + "\n\n" + effortContext)
    }

    static func runBuilderCompatibility(
        _ opts: KistOptions,
        goal: String,
        registry: ProviderRegistry,
        root: String,
        tools: ToolRegistry,
        context: ToolContext,
        checkpoints: LoopCheckpointStore?,
        toolMode: ToolMode,
        providerId: String,
        model: String?,
        rolesOverride: RoleBindings? = nil,
        budgetOverride: BudgetLedger? = nil,
        riskObjective: String? = nil,
        advisoryContext: PriorResultContext? = nil
    ) async -> Int32 {
        let launch = builderCompatibilityLaunch(for: opts, goal: goal)
        let contractID = builderCompatibilityContractID(root: root, goal: goal, adapter: launch.adapter)
        if BuilderRunAudit.current == nil {
            let audit = BuilderRunAudit(root: root, provider: providerId, model: model, contractID: contractID)
            let status = await audit.run(goal: goal) {
                await runBuilderCompatibility(
                    opts, goal: goal, registry: registry, root: root, tools: tools, context: context,
                    checkpoints: checkpoints, toolMode: toolMode, providerId: providerId, model: model,
                    rolesOverride: rolesOverride, budgetOverride: budgetOverride,
                    riskObjective: riskObjective, advisoryContext: advisoryContext)
            }
            note("builder replay · kist --project \(root) --replay \(audit.replay.manifest.runID)")
            return status
        }
        let planExecuteResumeID = launch.adapter == .planExecute ? opts.planExecuteResumeID : nil
        let planExecuteMissionID = launch.adapter == .planExecute
            ? (planExecuteResumeID ?? PlanExecuteMissionID.fresh()) : nil
        let planExecuteLaunchMode = planExecuteResumeID.map(PlanExecuteLaunchMode.resume) ?? .fresh
        guard launch.adapter.compatibleRoute == launch.routeHint.resolve() else {
            err("builder refused inconsistent route/adapter composition")
            emitBuilderRunRecord(contractID: contractID,
                                 missionInstanceID: planExecuteMissionID?.rawValue,
                                 launch: launch, outcome: "rejected",
                                 detail: "route and adapter are incompatible")
            return 2
        }
        guard let roles = rolesOverride ?? resolveRoles(opts, registry, providerId: providerId, model: model) else {
            return 2
        }
        guard let plannerBinding = builderPreflightBinding(roles: roles, registry: registry),
              let plannerProvider = registry.provider(id: plannerBinding.providerId) else {
            err("builder refused to start: planner provider could not be resolved")
            return 2
        }
        let plannerModel = plannerProvider.resolvedModel(plannerBinding.model)
        let builderBinding = roles.binding(for: .coder)
        let criticBinding = roles.binding(for: .critic)
        guard let builderProvider = registry.provider(id: builderBinding.providerId) else {
            err("builder refused to start: unknown coder provider \(builderBinding.providerId)")
            return 2
        }
        let builderModel = builderProvider.resolvedModel(builderBinding.model)
        let configuredBuilderIdentity = providerModelIdentity(
            provider: builderProvider.id, model: builderModel) ?? autonomyIdentity(builderBinding)
        guard let roleProducerIdentities = configuredProducerIdentities(
            roles: roles, registry: registry) else {
            let reason = "one or more producer roles has no concrete provider:model identity"
            err("builder refused to start: \(reason)")
            emitBuilderRunRecord(contractID: contractID,
                                 missionInstanceID: planExecuteMissionID?.rawValue,
                                 launch: launch, outcome: "rejected",
                                 detail: reason)
            return 2
        }
        let configuredProducerIdentities: Set<String>
        if launch.adapter == .cobolo {
            guard let driverProvider = registry.provider(id: providerId),
                  let driverIdentity = providerModelIdentity(
                    provider: driverProvider.id, model: driverProvider.resolvedModel(model)),
                  let coderIdentity = providerModelIdentity(
                    provider: builderProvider.id, model: builderModel),
                  let cobolProvider = registry.provider(id: "cobol"),
                  let cobolIdentity = providerModelIdentity(
                    provider: cobolProvider.id, model: cobolProvider.resolvedModel(nil)) else {
                let reason = "Cobolo producer identities could not be resolved to concrete provider:model values"
                err("builder refused to start: \(reason)")
                emitBuilderRunRecord(contractID: contractID,
                                     missionInstanceID: planExecuteMissionID?.rawValue,
                                     launch: launch, outcome: "rejected", detail: reason)
                return 2
            }
            configuredProducerIdentities = Set([driverIdentity, coderIdentity, cobolIdentity])
        } else {
            configuredProducerIdentities = roleProducerIdentities
        }
        let reviewPolicy: BuilderReviewPolicy
        let selectedIndependentReviewer: IndependentReviewerSelection?
        if opts.reviewGrade == .freshContextSameModel {
            guard let explicitCriticSpec = opts.criticSpec,
                  let exactCriticBinding = ProviderBinding.parse(explicitCriticSpec),
                  exactCriticBinding.model != nil,
                  launch.allowsFreshContextSameModelReviewCandidate,
                  builderDisposableReviewRootEligible(root),
                  let rootIdentity = try? builderProjectRootIdentity(root) else {
                let reason = "fresh_context_same_model Builder review requires an explicit exact --critic on a sandboxed, non-git disposable temp-root headless mutation with no high-risk/live/ship authority"
                err("builder refused to start: \(reason)")
                emitBuilderRunRecord(contractID: contractID,
                                     missionInstanceID: planExecuteMissionID?.rawValue,
                                     launch: launch, outcome: "rejected", detail: reason)
                return 2
            }
            reviewPolicy = .lowRiskFreshContextSameModel(
                disposableRootIdentity: rootIdentity)
            selectedIndependentReviewer = freshContextSameModelReviewerSelection(
                preferred: exactCriticBinding,
                producingIdentities: configuredProducerIdentities,
                registry: registry,
                policy: reviewPolicy)
        } else {
            reviewPolicy = .independent
            selectedIndependentReviewer = independentReviewerSelection(
                preferred: criticBinding,
                producingIdentities: configuredProducerIdentities,
                registry: registry)
        }
        guard let selectedIndependentReviewer else {
            let reason = reviewPolicy.grade == .freshContextSameModel
                ? "explicit critic must resolve to the sole exact producer provider:model for fresh_context_same_model"
                : "no available configured provider:model is distinct from coder \(configuredBuilderIdentity)"
            err("builder refused to start: \(reason)")
            if launch.adapter == .mission {
                emitAutonomyReceipt(prefix: "KIST_OBJECTIVE_RECEIPT:", payload: [
                    "receiptType": "kist.objective-stages", "schemaVersion": 1,
                    "stages": [["name": "review", "status": "failed",
                                "evidence": reason]],
                ])
            }
            emitBuilderRunRecord(contractID: contractID,
                                 missionInstanceID: planExecuteMissionID?.rawValue,
                                 launch: launch, outcome: "rejected",
                                 detail: reason)
            return 2
        }

        let effortContext = builderEffortContext(launch.effort)
        // Authority, completion mode, contract identity, and risk were frozen from `goal` above.
        // Only now may bounded prior-result evidence enter the worker prompt. The sealed preflight
        // below still receives the canonical goal alone, so advisory prose cannot mint paths/checks.
        let currentAdvisoryContext = advisoryContext.map {
            PriorResultContext(
                substantiveSummary: $0.substantiveSummary,
                artifactReferences: HeavyRouteResult.revalidatedArtifactReferences(
                    $0.artifactReferences, projectRoot: root))
        }
        let compatibilityGoals = builderCompatibilityGoals(
            authorityGoal: goal, advisoryContext: currentAdvisoryContext,
            effortContext: effortContext)
        let executionGoal = compatibilityGoals.executionGoal
        // Functional obligations and verification remain canonical. Advisory findings may help the
        // planner choose an implementation, but they cannot add done-when requirements.
        let canonicalFunctionalExecutionGoal = compatibilityGoals.canonicalFunctionalGoal
        let functionalExecutionGoal = compatibilityGoals.functionalExecutionGoal
        let completionMode = builderCompletionMode(for: goal)
        let effectiveTokenBudget = max(1, opts.budgetTokens ?? 200_000)
        let configuredBudget = budgetOverride ?? opts.makeBudget()
        if let configuredBudget, await configuredBudget.remaining() == nil {
            let reason = "Builder requires a finite per-run token cap; uncapped BudgetLedger authority is refused"
            err("builder refused to start: \(reason)")
            emitBuilderRunRecord(contractID: contractID,
                                 missionInstanceID: planExecuteMissionID?.rawValue,
                                 launch: launch, outcome: "rejected", detail: reason)
            return 2
        }
        let sharedBudget: BudgetLedger? = configuredBudget
            ?? BudgetLedger(maxTokens: effectiveTokenBudget)
        let preflightEnvelope: BuilderPreflightEnvelope?
        if completionMode == .build, launch.adapter != .cobolo {
            guard launch.mutationIntent else {
                let reason = "host intent did not authorize a mutation preflight"
                err("builder refused unsafe compatibility mutation: \(reason)")
                emitBuilderRunRecord(contractID: contractID,
                                     missionInstanceID: planExecuteMissionID?.rawValue,
                                     launch: launch, outcome: "rejected", detail: reason)
                return 2
            }
            do {
                preflightEnvelope = try await builderGeneratePreflightEnvelope(
                    adapter: launch.adapter, projectRoot: root, goal: goal,
                    contractID: contractID, registry: registry,
                    providerID: plannerProvider.id, model: plannerModel,
                    budget: sharedBudget!, maxPartitions: max(1, opts.agents),
                    allowsDelegatedRepairAuthority:
                        launch.mutationIntent && (opts.auto || opts.yolo))
            } catch {
                let reason = error.localizedDescription
                err("builder refused unsafe compatibility mutation: \(reason)")
                emitBuilderRunRecord(contractID: contractID,
                                     missionInstanceID: planExecuteMissionID?.rawValue,
                                     launch: launch, outcome: "rejected", detail: reason)
                return 2
            }
        } else {
            preflightEnvelope = nil
        }
        if reviewPolicy.grade == .freshContextSameModel {
            guard let plan = preflightEnvelope?.plan,
                  plan.operations.count == 1,
                  Set(plan.operations.map(\.path)).count == 1,
                  plan.verificationCommands.count == 1,
                  plan.partitions.isEmpty,
                  builderDisposableReviewTargetsEligible(
                      root: root, paths: plan.operations.map(\.path)) else {
                let reason = "fresh_context_same_model Builder review requires one sealed file mutation and one deterministic verifier"
                err("builder refused unsafe disposable mutation: \(reason)")
                emitBuilderRunRecord(contractID: contractID,
                                     missionInstanceID: planExecuteMissionID?.rawValue,
                                     launch: launch, outcome: "rejected", detail: reason)
                return 2
            }
        }
        let routeTools: ToolRegistry
        if launch.adapter == .headless {
            routeTools = builderScopedHeadlessTools(
                from: tools, sealedPlan: preflightEnvelope?.plan)
        } else {
            routeTools = tools
        }
        let baselineDigest = PlanExecuteLoop.governedWorkspaceDigest(projectRoot: root)
        let objectiveFingerprint = builderObjectiveFingerprint(contractID: contractID, goal: goal)
        let captainDecisionReceipt = builderCaptainDecisionReceipt(
            contractID: contractID, goal: goal, launch: launch)

        let resumeIdentity = opts.resumeId ?? (opts.resumeLast ? "last" : nil)
        let checkpointIdentity = planExecuteMissionID?.rawValue ?? resumeIdentity
        var contract = BuilderContract(
            id: contractID,
            objective: goal,
            constraints: [
                "Preserve Kist authorization, sandbox, approval, and budget policy",
                "Do not promote or deploy without the separate captain confirmation",
            ] + (completionMode == .verificationOnly
                ? ["Verification-only contract: do not mutate governed workspace content"] : []),
            allowedPaths: launch.adapter == .cobolo
                ? [opts.cobolTarget ?? ""]
                : (preflightEnvelope?.plan.allowedPaths ?? []),
            capabilities: routeTools.all().map(\.name).sorted(),
            doneWhen: [
                "the selected build adapter exits successfully",
                "deterministic execution evidence passes",
                reviewPolicy.grade == .independent
                    ? (completionMode == .verificationOnly
                        ? "an independent critic accepts digest-bound verification evidence"
                        : "an independent critic accepts the completed build")
                    : "a fresh-context same-model critic accepts the completed disposable build (independent=false)",
            ],
            routeHint: launch.routeHint,
            checkpointIdentity: checkpointIdentity,
            maxTokens: effectiveTokenBudget,
            completionMode: completionMode,
            producerIdentities: configuredProducerIdentities.sorted(),
            reviewPolicy: reviewPolicy.grade == .independent ? nil : reviewPolicy
        )
        let graph: BuilderGraph
        do {
            if launch.adapter == .cobolo {
                guard let target = opts.cobolTarget else {
                    throw BuilderRunError.invalidConfiguration("Cobolo graph requires --cobol-target")
                }
                graph = try coboloBuilderGraph(root: root, goal: goal, target: target)
            } else if let plan = preflightEnvelope?.plan {
                graph = try builderPlannedGraph(
                    adapter: launch.adapter, goal: goal, plan: plan)
            } else {
                graph = try BuilderGraph(nodes: [BuilderNode(
                    id: "build",
                    objective: goal,
                    resources: [BuilderResourceClaim(path: ".", access: .read)],
                    isolation: .sandbox,
                    role: .builder,
                    retryLimit: 0
                )])
            }
        } catch {
            err("builder graph rejected: \(error.localizedDescription)")
            return 2
        }

        let graphPolicy: BuilderGraphExecutionPolicy
        let coboloIdentityPlan: CoboloIdentityPlan?
        do {
            if launch.adapter == .cobolo {
                graphPolicy = builderCoboloGraphPolicy()
                coboloIdentityPlan = try coboloProductionIdentityPlan(
                    providerId: providerId, model: model, roles: roles, registry: registry)
            } else if preflightEnvelope != nil {
                graphPolicy = builderPlannedGraphPolicy(
                    graph: graph,
                    executionNodeIDs: builderPlannedExecutionNodeIDs(
                        for: launch.adapter, plan: preflightEnvelope?.plan))
                coboloIdentityPlan = nil
            } else {
                graphPolicy = .init(nodeClasses: Dictionary(
                    uniqueKeysWithValues: graph.nodes.map { ($0.id, .readOnly) }))
                coboloIdentityPlan = nil
            }
        } catch {
            err("builder governance policy rejected: \(error.localizedDescription)")
            return 2
        }

        let builderStateID = planExecuteMissionID.map {
            contract.id + "-mission-" + $0.rawValue
        } ?? contract.id
        let durableStateRoot = builderDurableStateDirectory(
            projectRoot: root, contractID: builderStateID)
        let stateURL = durableStateRoot.appendingPathComponent("run.json")
        let statusBox = BuilderCompatibilityStatusBox()
        let dossierBox = BuilderCompatibilityDossierBox()
        let missionStageBox = BuilderCompatibilityMissionStageBox()
        let missionReasoningStore = AtomicReasoningControlStore(projectRoot: root)
        let missionReasoningRunID = contract.id + "-mission"
        let planOutcomeBox = BuilderCompatibilityPlanOutcomeBox()
        let coboloEvidenceBox = BuilderCompatibilityCoboloEvidenceBox()
        let runStore = BuilderJSONStore(fileURL: stateURL)

        do {
            try FileManager.default.createDirectory(
                at: durableStateRoot, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let graphFingerprint = try builderGraphFingerprint(graph)
            let artifactStore = try BuilderCompositionArtifactStore(
                rootURL: durableStateRoot.appendingPathComponent("composition", isDirectory: true),
                builderContractID: contract.id, graphFingerprint: graphFingerprint)
            let planStore = try BuilderPreflightStore(
                rootURL: durableStateRoot.appendingPathComponent("preflight-state", isDirectory: true),
                builderContractID: contract.id, goal: goal, projectRoot: root)
            let plannedVerificationStore = try BuilderPlannedVerificationStore(
                rootURL: durableStateRoot.appendingPathComponent(
                    "verification-state", isDirectory: true),
                builderContractID: contract.id)
            if let preflightEnvelope {
                try await planStore.save(preflightEnvelope)
            }
            let contractProvider: (any BuilderNodeExecutionContractProvider)?
            let observationProvider: (any BuilderNodeObservationSourceProvider)?
            let mutationTransaction: BuilderIsolatedWorkspaceTransactionSource?
            if let identityPlan = coboloIdentityPlan, let target = opts.cobolTarget {
                let provider = try BuilderCoboloContractProvider(
                    store: artifactStore, projectRoot: root, target: target,
                    captainDecisionDigest: captainDecisionReceipt.digest,
                    identityPlan: identityPlan,
                    maxRevisions: opts.cobolMaxRevisions,
                    maxTokens: opts.budgetTokens)
                let transaction = try BuilderIsolatedWorkspaceTransactionSource(
                    projectRoot: URL(fileURLWithPath: root, isDirectory: true),
                    stagingBase: durableStateRoot.appendingPathComponent(
                        "transactions", isDirectory: true),
                    attestor: BuilderOSProcessSandboxAttestor())
                contractProvider = provider
                mutationTransaction = transaction
                observationProvider = BuilderCoboloObservationProvider(
                    source: transaction, store: artifactStore,
                    providerFingerprint: provider.identity.implementationFingerprint)
                contract.governanceAdmission = try BuilderGraphGovernanceAdmission.make(
                    graph: graph, policy: graphPolicy,
                    providerIdentity: provider.identity)
            } else if preflightEnvelope != nil {
                let provider = try BuilderPlannedContractProvider(
                    store: artifactStore, planStore: planStore,
                    executionNodeIDs: builderPlannedExecutionNodeIDs(
                        for: launch.adapter, plan: preflightEnvelope?.plan),
                    captainDecisionDigest: captainDecisionReceipt.digest,
                    producerIdentities: configuredProducerIdentities.sorted(),
                    reviewerIdentity: selectedIndependentReviewer.identity,
                    reviewGrade: reviewPolicy.grade,
                    maxTokens: effectiveTokenBudget, budget: sharedBudget!,
                    requiresMissionLineage:
                        launch.adapter == .mission || launch.adapter == .greatLoop)
                let transaction = try BuilderIsolatedWorkspaceTransactionSource(
                    projectRoot: URL(fileURLWithPath: root, isDirectory: true),
                    stagingBase: durableStateRoot.appendingPathComponent(
                        "transactions", isDirectory: true),
                    attestor: BuilderOSProcessSandboxAttestor())
                contractProvider = provider
                mutationTransaction = transaction
                observationProvider = BuilderCoboloObservationProvider(
                    source: transaction, store: artifactStore,
                    providerFingerprint: provider.identity.implementationFingerprint)
                contract.governanceAdmission = try BuilderGraphGovernanceAdmission.make(
                    graph: graph, policy: graphPolicy,
                    providerIdentity: provider.identity)
            } else {
                contractProvider = nil
                mutationTransaction = nil
                observationProvider = nil
                contract.governanceAdmission = try BuilderGraphGovernanceAdmission.make(
                    graph: graph, policy: graphPolicy, providerIdentity: nil)
            }
            let finalizedContract = contract
            let parentContractFingerprint = try builderCanonicalParentContractFingerprint(
                finalizedContract)
            let builderVerificationContext = BuilderVerificationContext(
                preflightEnvelope: preflightEnvelope, launch: launch,
                contractProvider: contractProvider,
                mutationTransaction: mutationTransaction,
                plannedVerificationStore: plannedVerificationStore,
                artifactStore: artifactStore, graph: graph,
                toolContext: context, finalizedContract: finalizedContract,
                projectRoot: root, graphFingerprint: graphFingerprint,
                objectiveFingerprint: objectiveFingerprint,
                parentContractFingerprint: parentContractFingerprint,
                baselineDigest: baselineDigest)
            let builderReviewContext = BuilderReviewContext(
                criticBinding: selectedIndependentReviewer.binding,
                registry: registry, launch: launch,
                projectRoot: root, finalizedContract: finalizedContract,
                goal: goal, sharedBudget: sharedBudget)
            let builderExecutionContext = BuilderAdapterExecutionContext(
                opts: opts, goal: goal, registry: registry, projectRoot: root,
                routeTools: routeTools, toolContext: context,
                checkpoints: checkpoints, toolMode: toolMode,
                providerID: providerId, model: model, roles: roles, launch: launch,
                dossierBox: dossierBox, missionStageBox: missionStageBox,
                artifactStore: artifactStore, finalizedContract: finalizedContract,
                contractProvider: contractProvider, graph: graph,
                preflightEnvelope: preflightEnvelope,
                plannedVerificationStore: plannedVerificationStore,
                coboloIdentityPlan: coboloIdentityPlan, executionGoal: executionGoal,
                sharedBudget: sharedBudget, durableStateRoot: durableStateRoot,
                coboloEvidenceBox: coboloEvidenceBox,
                planExecuteLaunchMode: planExecuteLaunchMode,
                planExecuteMissionID: planExecuteMissionID,
                riskObjective: riskObjective,
                functionalExecutionGoal: functionalExecutionGoal,
                canonicalFunctionalExecutionGoal: canonicalFunctionalExecutionGoal,
                planOutcomeBox: planOutcomeBox, builderBinding: builderBinding,
                statusBox: statusBox, baselineDigest: baselineDigest,
                completionMode: completionMode,
                objectiveFingerprint: objectiveFingerprint,
                configuredProducerIdentities: configuredProducerIdentities,
                selectedIndependentReviewer: selectedIndependentReviewer,
                missionReasoningStore: missionReasoningStore,
                missionReasoningRunID: missionReasoningRunID,
                builderModel: builderModel)
            let finalAcceptanceCommit: BuilderFinalAcceptanceCommit?
            if launch.adapter == .planExecute {
                guard let missionID = planExecuteMissionID else {
                    throw BuilderRunError.invalidConfiguration(
                        "PlanExecute acceptance persistence requires an exact mission identity")
                }
                let iterationBudget = graph.nodes.reduce(0) {
                    $0 + 1 + $1.retryLimit
                }
                finalAcceptanceCommit = { authority in
                    _ = try persistAcceptedPlanExecuteRun(
                        authority: authority, missionID: missionID, goal: goal,
                        projectRoot: root, launch: launch,
                        planOutcome: planOutcomeBox.get(),
                        iterationBudget: iterationBudget)
                }
            } else {
                finalAcceptanceCommit = nil
            }
            let run = try BuilderRun(
                contract: finalizedContract,
                graph: graph,
                store: runStore,
                maxParallelism: launch.adapter == .fleet ? max(1, opts.agents)
                    : (launch.adapter == .mission ? 2 : 1),
                resumeExisting: launch.adapter == .cobolo
                    ? FileManager.default.fileExists(atPath: stateURL.path)
                    : (launch.adapter == .planExecute
                        ? planExecuteResumeID != nil : resumeIdentity != nil),
                graphExecutionPolicy: graphPolicy,
                nodeExecutionContractProvider: contractProvider,
                nodeObservationSourceProvider: observationProvider,
                readOnlyObservationSourceProvider:
                    BuilderProjectReadOnlyObservationProvider(projectRoot: root),
                finalAcceptanceCommit: finalAcceptanceCommit,
                execute: { request in
                    try await builderExecuteNode(request, context: builderExecutionContext)
                },
                verify: { request in
                    try await builderVerify(request, context: builderVerificationContext)
                },
                review: { request in
                    await builderReview(request, context: builderReviewContext)
                }
            )
            let final = try await run.run()
            var additionalReviewUsage: [BuilderUsageReceipt] = []
            let reviewAttempt = (try? await runStore.load())?.reviewAttempt
            if let reviewAttempt {
                emitAutonomyReceipt(prefix: "KIST_REVIEW_ATTEMPT_RECEIPT:",
                                    payload: reviewAttemptPayload(reviewAttempt))
            }
            if let payload = builderSameModelReviewReceiptPayload(final) {
                emitAutonomyReceipt(
                    prefix: "KIST_BUILDER_REVIEW_RECEIPT:", payload: payload)
            }
            if launch.adapter == .headless, opts.ship {
                if let sharedBudget {
                    let explicitShip = await runBudgetedBuilderShipReview(
                        goal: goal, registry: registry, roles: roles, root: root,
                        budget: sharedBudget, reviewerProviderID: criticBinding.providerId,
                        verifiedExecution: true, confirmDeployment: true)
                    additionalReviewUsage.append(explicitShip.usage)
                    if let denial = explicitShip.denialReason { err("ship · \(denial)") }
                }
            }
            if launch.adapter == .mission {
                let passed = final.accepted ? "passed" : "failed"
                func missionEvidence(_ nodeID: String, fallback: String) -> String {
                    missionStageBox.get(nodeID)?.evidence ?? fallback
                }
                emitAutonomyReceipt(prefix: "KIST_OBJECTIVE_RECEIPT:", payload: [
                    "receiptType": "kist.objective-stages", "schemaVersion": 1,
                    "stages": [
                        ["name": "research", "status": passed, "evidence": missionEvidence("research", fallback: "research stage completed")],
                        ["name": "council", "status": passed, "evidence": missionEvidence("research", fallback: "research council completed")],
                        ["name": "simulation", "status": passed, "evidence": missionEvidence("simulation", fallback: "simulation stage completed")],
                        ["name": "trial", "status": passed, "evidence": missionEvidence("trial", fallback: "trial stage completed")],
                        ["name": "execute", "status": passed, "evidence": missionEvidence("execution", fallback: "execution stage completed")],
                        ["name": "verify", "status": passed, "evidence": final.verification.checks.map(\.details).joined(separator: " | ")],
                        ["name": "review", "status": passed, "evidence": final.review.checks.map(\.details).joined(separator: " | ")],
                    ],
                ])
                emitAutonomyReceipt(prefix: "KIST_REVIEW_RECEIPT:", payload: [
                    "receiptType": "kist.independent-review", "schemaVersion": 1,
                    "builderIdentity": final.review.workerIdentities?.joined(separator: ",")
                        ?? configuredBuilderIdentity,
                    "reviewerIdentity": final.review.reviewerIdentity ?? "unavailable",
                    "verification": passed, "decision": final.accepted ? "approve" : "reject",
                    "evidence": final.review.checks.map(\.details).joined(separator: " | "),
                ])
            }
            emitBuilderRunRecord(contractID: finalizedContract.id,
                                 missionInstanceID: planExecuteMissionID?.rawValue,
                                 launch: launch,
                                 outcome: final.accepted ? "accepted" : "rejected",
                                 detail: final.review.checks.map(\.details).joined(separator: " | "),
                                 usage: builderAggregateRunUsage(
                                    final, additional: additionalReviewUsage),
                                 finalReceipt: final)
            return final.accepted ? 0 : 1
        } catch let builderError as BuilderRunError {
            if case .acceptancePersistencePending(let pendingReason) = builderError {
                let mission = planExecuteMissionID?.rawValue ?? "the durable Builder run"
                let reason = "accepted evidence persistence pending: \(pendingReason)"
                err(reason)
                note("accepted work remains retained; resume with: kist --resume \(mission)")
                let reviewAttempt = (try? await runStore.load())?.reviewAttempt
                if let reviewAttempt {
                    emitAutonomyReceipt(
                        prefix: "KIST_REVIEW_ATTEMPT_RECEIPT:",
                        payload: reviewAttemptPayload(reviewAttempt))
                }
                emitBuilderRunRecord(
                    contractID: contract.id,
                    missionInstanceID: planExecuteMissionID?.rawValue,
                    launch: launch, outcome: "acceptance-persistence-pending",
                    detail: reason)
                return 1
            }
            let error: Error = builderError
            let reason = error.localizedDescription
            err("builder failed: \(reason)")
            if launch.adapter == .mission {
                let verificationPassed: Bool
                if case .finalVerificationFailed = builderError { verificationPassed = false }
                else { verificationPassed = missionStageBox.get("execution")?.passed == true }
                func stageStatus(_ nodeID: String) -> String {
                    missionStageBox.get(nodeID)?.passed == true ? "passed" : "failed"
                }
                func stageEvidence(_ nodeID: String) -> String {
                    missionStageBox.get(nodeID)?.evidence ?? "stage was not reached: \(reason)"
                }
                emitAutonomyReceipt(prefix: "KIST_OBJECTIVE_RECEIPT:", payload: [
                    "receiptType": "kist.objective-stages", "schemaVersion": 1,
                    "stages": [
                        ["name": "research", "status": stageStatus("research"), "evidence": stageEvidence("research")],
                        ["name": "council", "status": stageStatus("research"), "evidence": stageEvidence("research")],
                        ["name": "simulation", "status": stageStatus("simulation"), "evidence": stageEvidence("simulation")],
                        ["name": "trial", "status": stageStatus("trial"), "evidence": stageEvidence("trial")],
                        ["name": "execute", "status": stageStatus("execution"), "evidence": stageEvidence("execution")],
                        ["name": "verify", "status": verificationPassed ? "passed" : "failed", "evidence": reason],
                        ["name": "review", "status": "failed", "evidence": reason],
                    ],
                ])
                emitAutonomyReceipt(prefix: "KIST_REVIEW_RECEIPT:", payload: [
                    "receiptType": "kist.independent-review", "schemaVersion": 1,
                    "builderIdentity": configuredBuilderIdentity, "reviewerIdentity": "unavailable",
                    "verification": "failed", "decision": "reject", "evidence": reason,
                ])
            }
            let reviewAttempt = (try? await runStore.load())?.reviewAttempt
            if let reviewAttempt {
                emitAutonomyReceipt(prefix: "KIST_REVIEW_ATTEMPT_RECEIPT:",
                                    payload: reviewAttemptPayload(reviewAttempt))
            }
            let detail = reviewAttempt.map { reason + " | reviewAttempt=" + $0.evidencePacketDigest } ?? reason
            emitBuilderRunRecord(contractID: contract.id,
                                 missionInstanceID: planExecuteMissionID?.rawValue,
                                 launch: launch, outcome: "failed",
                                 detail: detail)
            return 1
        } catch {
            let reason = error.localizedDescription
            err("builder failed: \(reason)")
            if launch.adapter == .mission {
                let verificationPassed: Bool
                if let builderError = error as? BuilderRunError,
                   case .finalVerificationFailed = builderError { verificationPassed = false }
                else { verificationPassed = missionStageBox.get("execution")?.passed == true }
                func stageStatus(_ nodeID: String) -> String {
                    missionStageBox.get(nodeID)?.passed == true ? "passed" : "failed"
                }
                func stageEvidence(_ nodeID: String) -> String {
                    missionStageBox.get(nodeID)?.evidence ?? "stage was not reached: \(reason)"
                }
                emitAutonomyReceipt(prefix: "KIST_OBJECTIVE_RECEIPT:", payload: [
                    "receiptType": "kist.objective-stages", "schemaVersion": 1,
                    "stages": [
                        ["name": "research", "status": stageStatus("research"), "evidence": stageEvidence("research")],
                        ["name": "council", "status": stageStatus("research"), "evidence": stageEvidence("research")],
                        ["name": "simulation", "status": stageStatus("simulation"), "evidence": stageEvidence("simulation")],
                        ["name": "trial", "status": stageStatus("trial"), "evidence": stageEvidence("trial")],
                        ["name": "execute", "status": stageStatus("execution"), "evidence": stageEvidence("execution")],
                        ["name": "verify", "status": verificationPassed ? "passed" : "failed", "evidence": reason],
                        ["name": "review", "status": "failed", "evidence": reason],
                    ],
                ])
                emitAutonomyReceipt(prefix: "KIST_REVIEW_RECEIPT:", payload: [
                    "receiptType": "kist.independent-review", "schemaVersion": 1,
                    "builderIdentity": configuredBuilderIdentity, "reviewerIdentity": "unavailable",
                    "verification": "failed", "decision": "reject", "evidence": reason,
                ])
            }
            let reviewAttempt = (try? await runStore.load())?.reviewAttempt
            if let reviewAttempt {
                emitAutonomyReceipt(prefix: "KIST_REVIEW_ATTEMPT_RECEIPT:",
                                    payload: reviewAttemptPayload(reviewAttempt))
            }
            let detail = reviewAttempt.map { reason + " | reviewAttempt=" + $0.evidencePacketDigest } ?? reason
            emitBuilderRunRecord(contractID: contract.id,
                                 missionInstanceID: planExecuteMissionID?.rawValue,
                                 launch: launch, outcome: "failed",
                                 detail: detail)
            return 1
        }
    }
}
