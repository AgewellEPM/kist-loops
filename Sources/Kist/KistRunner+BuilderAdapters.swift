import Foundation
import AgentCore

// Execute the selected adapter inside its sealed workspace.
extension KistRunner {
    struct BuilderAdapterExecutionContext: Sendable {
        let opts: KistOptions
        let goal: String
        let registry: ProviderRegistry
        let projectRoot: String
        let routeTools: ToolRegistry
        let toolContext: ToolContext
        let checkpoints: LoopCheckpointStore?
        let toolMode: ToolMode
        let providerID: String
        let model: String?
        let roles: RoleBindings
        let launch: BuilderCompatibilityLaunch
        let dossierBox: BuilderCompatibilityDossierBox
        let missionStageBox: BuilderCompatibilityMissionStageBox
        let artifactStore: BuilderCompositionArtifactStore
        let finalizedContract: BuilderContract
        let contractProvider: (any BuilderNodeExecutionContractProvider)?
        let graph: BuilderGraph
        let preflightEnvelope: BuilderPreflightEnvelope?
        let plannedVerificationStore: BuilderPlannedVerificationStore
        let coboloIdentityPlan: CoboloIdentityPlan?
        let executionGoal: String
        let sharedBudget: BudgetLedger?
        let durableStateRoot: URL
        let coboloEvidenceBox: BuilderCompatibilityCoboloEvidenceBox
        let planExecuteLaunchMode: PlanExecuteLaunchMode
        let planExecuteMissionID: PlanExecuteMissionID?
        let riskObjective: String?
        let functionalExecutionGoal: String
        let canonicalFunctionalExecutionGoal: String
        let planOutcomeBox: BuilderCompatibilityPlanOutcomeBox
        let builderBinding: ProviderBinding
        let statusBox: BuilderCompatibilityStatusBox
        let baselineDigest: String
        let completionMode: BuilderCompletionMode
        let objectiveFingerprint: String
        let configuredProducerIdentities: Set<String>
        let selectedIndependentReviewer: IndependentReviewerSelection
        let missionReasoningStore: AtomicReasoningControlStore
        let missionReasoningRunID: String
        let builderModel: String
    }

    static func builderExecuteNode(
        _ request: BuilderExecutionRequest,
        context configuration: BuilderAdapterExecutionContext
    ) async throws -> BuilderWorkerReceipt {
        let opts = configuration.opts
        let goal = configuration.goal
        let registry = configuration.registry
        let root = configuration.projectRoot
        let routeTools = configuration.routeTools
        let context = configuration.toolContext
        let checkpoints = configuration.checkpoints
        let toolMode = configuration.toolMode
        let providerId = configuration.providerID
        let model = configuration.model
        let roles = configuration.roles
        let launch = configuration.launch
        let dossierBox = configuration.dossierBox
        let missionStageBox = configuration.missionStageBox
        let artifactStore = configuration.artifactStore
        let finalizedContract = configuration.finalizedContract
        let contractProvider = configuration.contractProvider
        let graph = configuration.graph
        let preflightEnvelope = configuration.preflightEnvelope
        let plannedVerificationStore = configuration.plannedVerificationStore
        let coboloIdentityPlan = configuration.coboloIdentityPlan
        let executionGoal = configuration.executionGoal
        let sharedBudget = configuration.sharedBudget
        let durableStateRoot = configuration.durableStateRoot
        let coboloEvidenceBox = configuration.coboloEvidenceBox
        let planExecuteLaunchMode = configuration.planExecuteLaunchMode
        let planExecuteMissionID = configuration.planExecuteMissionID
        let riskObjective = configuration.riskObjective
        let functionalExecutionGoal = configuration.functionalExecutionGoal
        let canonicalFunctionalExecutionGoal = configuration.canonicalFunctionalExecutionGoal
        let planOutcomeBox = configuration.planOutcomeBox
        let builderBinding = configuration.builderBinding
        let statusBox = configuration.statusBox
        let baselineDigest = configuration.baselineDigest
        let completionMode = configuration.completionMode
        let objectiveFingerprint = configuration.objectiveFingerprint
        let configuredProducerIdentities = configuration.configuredProducerIdentities
        let selectedIndependentReviewer = configuration.selectedIndependentReviewer
        let missionReasoningStore = configuration.missionReasoningStore
        let missionReasoningRunID = configuration.missionReasoningRunID
        let builderModel = configuration.builderModel
                    if ((launch.adapter == .mission || launch.adapter == .greatLoop)
                            && request.node.id != "execution")
                        || (launch.adapter == .cobolo && request.node.id != "cobolo-execution") {
                        let result: AutonomyMissionStageResult
                        var durableDossier: AutonomyMissionDossier?
                        var advisoryTaskBoard: BuilderTaskBoardLineage?
                        switch request.node.id {
                        case "research":
                            let output = await runAutonomyResearchStage(
                                opts, goal: goal, registry: registry, root: root,
                                tools: routeTools, context: context,
                                providerId: providerId, model: model, roles: roles
                            )
                            result = output.0
                            if let dossier = output.1 {
                                dossierBox.set(dossier)
                                durableDossier = dossier
                            }
                        case "council":
                            let dependencyDossier: AutonomyMissionDossier?
                            if let dependency = request.acceptedDependencies.first {
                                dependencyDossier = try await artifactStore
                                    .loadDependency(dependency).payload.dossier.value
                            } else {
                                dependencyDossier = nil
                            }
                            guard let dossier = dependencyDossier ?? dossierBox.get() else {
                                result = autonomyMissionFailureStage(
                                    "council", evidence: "research produced no exact dossier handoff"
                                )
                                break
                            }
                            let output = await runAutonomyCouncilStage(
                                opts, goal: goal, dossier: dossier, registry: registry,
                                root: root, tools: routeTools, context: context,
                                providerId: providerId, model: model, roles: roles
                            )
                            result = output.0
                            if let updated = output.1 {
                                dossierBox.set(updated)
                                durableDossier = updated
                            }
                        case "symbolic-peel":
                            let dependencyDossier: AutonomyMissionDossier?
                            if let dependency = request.acceptedDependencies.first {
                                dependencyDossier = try await artifactStore
                                    .loadDependency(dependency).payload.dossier.value
                            } else {
                                dependencyDossier = nil
                            }
                            guard let dossier = dependencyDossier ?? dossierBox.get() else {
                                result = autonomyMissionFailureStage(
                                    "symbolic-peel", evidence: "research produced no exact dossier handoff")
                                break
                            }
                            result = runAutonomySymbolicPEELStage(dossier: dossier)
                            durableDossier = dossier
                        case "task-board-projection":
                            let dependencyDossier: AutonomyMissionDossier?
                            if let dependency = request.acceptedDependencies.first {
                                dependencyDossier = try await artifactStore
                                    .loadDependency(dependency).payload.dossier.value
                            } else {
                                dependencyDossier = nil
                            }
                            guard let dossier = dependencyDossier ?? dossierBox.get() else {
                                result = autonomyMissionFailureStage(
                                    "task-board-projection",
                                    evidence: "council produced no durable dossier")
                                break
                            }
                            durableDossier = dossier
                            if let projection = runAutonomyTaskBoardProjectionStage(
                                    goal: goal, dossier: dossier,
                                    builderContractID: finalizedContract.id,
                                    root: durableStateRoot.path) {
                                advisoryTaskBoard = projection.lineage
                                result = projection.stage
                            } else {
                                result = AutonomyMissionStageResult(
                                    name: "task-board-projection", passed: true,
                                    evidence: "advisory task-board projection unavailable; no acceptance authority was granted",
                                    provider: "kist", model: "deterministic",
                                    artifacts: [], changedPaths: [],
                                    checks: [.init(
                                        name: "advisory task board", passed: true,
                                        details: "projection is advisory and may be absent")],
                                    risks: [], usage: .init(aggregateTokens: 0))
                            }
                        case "independent-review":
                            guard request.acceptedDependencies.count == 1,
                                  let dependency = request.acceptedDependencies.first,
                                  dependency.nodeID == "execution",
                                  let sharedBudget else {
                                result = autonomyMissionFailureStage(
                                    "independent-review",
                                    evidence: "review lacks one accepted execution receipt or finite budget")
                                break
                            }
                            let dependencyArtifact = try await artifactStore.loadDependency(dependency)
                            let dossier = dependencyArtifact.payload.dossier.value
                            durableDossier = dossier
                            let evidence = (dependency.worker.checks
                                + dependency.verification.checks)
                                .map { "\($0.name): \($0.details)" }
                                .joined(separator: "\n")
                            let review = await runBudgetedBuilderShipReview(
                                goal: autonomyMissionGoal(goal, dossier: dossier),
                                registry: registry, roles: roles, root: root,
                                budget: sharedBudget,
                                reviewerProviderID: selectedIndependentReviewer.binding.providerId,
                                verifiedExecution: dependency.verification.passed,
                                evidenceOverride: evidence,
                                verificationSubject: dependency.verification.verificationSubject,
                                verificationDigest: dependency.verification.subjectDigest,
                                confirmDeployment: false)
                            let accepted = review.decision?.canDeploy == true
                            let detail = review.decision?.reason
                                ?? review.denialReason
                                ?? "independent reviewer returned no decision"
                            result = AutonomyMissionStageResult(
                                name: "independent-review", passed: accepted,
                                evidence: detail,
                                provider: selectedIndependentReviewer.binding.providerId,
                                model: selectedIndependentReviewer.binding.model ?? "",
                                artifacts: [], changedPaths: [],
                                checks: [.init(
                                    name: "independent execution review",
                                    passed: accepted, details: detail)],
                                risks: accepted ? [] : [detail], usage: review.usage)
                        case "simulation":
                            guard let dossier = dossierBox.get() else {
                                result = autonomyMissionFailureStage(
                                    "simulation", evidence: "research produced no dossier handoff"
                                )
                                break
                            }
                            result = runAutonomySimulationStage(
                                opts, goal: goal, dossier: dossier, root: root
                            )
                        case "trial":
                            guard let dossier = dossierBox.get() else {
                                result = autonomyMissionFailureStage(
                                    "trial", evidence: "research produced no dossier handoff"
                                )
                                break
                            }
                            result = runAutonomyTrialStage(dossier: dossier)
                        case "execution":
                            guard let checkpoints else {
                                throw BuilderRunError.invalidConfiguration(
                                    "autonomy mission requires a checkpoint store"
                                )
                            }
                            guard let dossier = dossierBox.get() else {
                                result = autonomyMissionFailureStage(
                                    "execute", evidence: "execution received no dossier handoff"
                                )
                                break
                            }
                            result = await runAutonomyExecutionStage(
                                opts, goal: goal, dossier: dossier,
                                registry: registry, root: root, tools: routeTools,
                                context: context, checkpoints: checkpoints,
                                toolMode: toolMode, roles: roles,
                                providerId: providerId, model: model,
                                builder: builderBinding, budget: sharedBudget
                            )
                        default:
                            throw BuilderRunError.invalidConfiguration(
                                "unknown mission stage \(request.node.id)"
                            )
                        }
                        do {
                            _ = try await missionReasoningStore.update(
                                runID: missionReasoningRunID,
                                create: ReasoningControlState(
                                    id: missionReasoningRunID, route: .planned,
                                    goalFingerprint: finalizedContract.id
                                )
                            ) { state in
                                state.addEvidence(result.reasoningEvidence)
                                let evidenceID = result.reasoningEvidence.first?.id
                                _ = MonotonicProgressReducer.apply(
                                    ReasoningProgressReceipt(
                                        nodeID: request.node.id,
                                        evidence: .checkTransition(ReasoningCheckReceipt(
                                            id: "mission-stage:\(request.node.id)",
                                            name: "mission \(request.node.id)",
                                            state: result.passed ? .passed : .failed,
                                            evidenceID: evidenceID, nodeID: request.node.id
                                        ))
                                    ),
                                    to: &state.progress
                                )
                            }
                        } catch {
                            throw BuilderRunError.invalidConfiguration(
                                "mission reasoning evidence persistence failed: \(error.localizedDescription)"
                            )
                        }
                        missionStageBox.set(result, for: request.node.id)
                        statusBox.set(result.passed ? 0 : 1)
                        var worker = result.workerReceipt(nodeID: request.node.id)
                        if launch.adapter == .cobolo || launch.adapter == .mission
                            || launch.adapter == .greatLoop {
                            guard let dossier = durableDossier else {
                                throw BuilderRunError.persistedStateInvalid(
                                    "\(request.node.id) produced no durable dossier artifact")
                            }
                            let artifact = try await artifactStore.saveStage(
                                nodeID: request.node.id, attempt: request.attempt,
                                dependencies: request.acceptedDependencies,
                                dossier: dossier,
                                advisoryTaskBoard: advisoryTaskBoard)
                            worker = builderWorker(worker, adding: artifact)
                        }
                        return request.node.id == "execution"
                            ? bindBuilderWorkspaceEvidence(
                                worker, mode: completionMode, root: root,
                                baselineDigest: baselineDigest,
                                commandEvidence: [])
                            : worker
                    }
                    let started = Date()
                    let tokensBefore = await sharedBudget?.spentTokens() ?? 0
                    let adapterWorkspace = launch.adapter == .cobolo
                        ? nil : request.executionWorkspace
                    if preflightEnvelope != nil {
                        guard let workspace = adapterWorkspace,
                              let provider = contractProvider else {
                            throw BuilderRunError.invalidConfiguration(
                                "planned execution is missing its isolated workspace or contract provider")
                        }
                        let selected = try await artifactStore.loadContract(
                            providerFingerprint: provider.identity.implementationFingerprint,
                            nodeID: request.node.id, attempt: request.attempt,
                            graphNodeIDs: graph.nodes.map(\.id))
                        guard selected.fingerprint == workspace.attestation.contractFingerprint else {
                            throw BuilderRunError.persistedStateInvalid(
                                "planned workspace attestation drifted from its selected contract")
                        }
                        try await plannedVerificationStore.save(
                            BuilderPlannedVerificationRecord(
                                builderContractID: finalizedContract.id,
                                nodeID: request.node.id,
                                stage: .executionWorkspace,
                                workspace: workspace,
                                contractFingerprint: selected.fingerprint))
                    }
                    let adapterRoot = adapterWorkspace?.rootPath ?? root
                    let boundedExecutionGoal = builderBoundedMutationAttemptGoal(
                        executionGoal, attempt: request.attempt)
                    let adapterContext = adapterWorkspace.map {
                        builderRebasedToolContext(
                            context, projectRoot: $0.rootPath,
                            governedExecutionWorkspace: true)
                    } ?? context
                    let adapterCheckpoints = adapterWorkspace.map { _ in
                        LoopCheckpointStore(directory: durableStateRoot
                            .appendingPathComponent("adapter-checkpoints", isDirectory: true)
                            .appendingPathComponent(request.node.id, isDirectory: true).path)
                    } ?? checkpoints
                    let highAssuranceDossier: AutonomyMissionDossier?
                    if launch.adapter == .mission || launch.adapter == .greatLoop {
                        guard request.acceptedDependencies.count == 1,
                              let dependency = request.acceptedDependencies.first else {
                            throw BuilderRunError.persistedStateInvalid(
                                "high-assurance execution has no accepted task-board dependency")
                        }
                        highAssuranceDossier = try await artifactStore
                            .loadDependency(dependency).payload.dossier.value
                    } else {
                        highAssuranceDossier = nil
                    }
                    let fleetWorkerRoute = launch.adapter == .fleet
                        ? builderFleetWorkerRoute(
                            builder: builderBinding, resolvedModel: builderModel)
                        : nil
                    let status: Int32
                    var headlessVerificationHandoff = false
                    switch launch.adapter {
                    case .cobolo:
                        guard let dependency = request.acceptedDependencies.first else {
                            throw BuilderRunError.persistedStateInvalid(
                                "Cobolo execution has no sealed planning dependency")
                        }
                        let dependencyArtifact = try await artifactStore.loadDependency(dependency)
                        let dossier = dependencyArtifact.payload.dossier.value
                        guard
                              let runID = dossier.researchRunID,
                              let dossierDigest = dossier.reportDigest,
                              let peel = dossier.peelReceipt,
                              let council = dossier.council,
                              let target = opts.cobolTarget,
                              let identityPlan = coboloIdentityPlan,
                              let workspace = request.executionWorkspace else {
                            throw BuilderRunError.invalidConfiguration(
                                "Cobolo execution is missing durable lineage or its isolated workspace")
                        }
                        _ = runID; _ = dossierDigest; _ = peel; _ = council; _ = target
                        let executionContract = try await artifactStore.loadContract(
                            providerFingerprint: contractProvider!.identity.implementationFingerprint,
                            nodeID: request.node.id, attempt: request.attempt,
                            graphNodeIDs: graph.nodes.map(\.id))
                        guard executionContract.fingerprint
                                == workspace.attestation.contractFingerprint else {
                            throw BuilderRunError.persistedStateInvalid(
                                "Cobolo workspace attestation drifted from its selected contract")
                        }
                        let workspaceContext = builderRebasedToolContext(
                            context, projectRoot: workspace.rootPath,
                            governedExecutionWorkspace: true)
                        // BuilderExecutionGovernance owns the one-use sandbox scope around this
                        // callback. Re-activating the same attestation here is a replay, not added
                        // isolation; every subprocess remains confined by the inherited scope.
                        status = await runCobolo(
                            opts, goal: autonomyMissionGoal(boundedExecutionGoal, dossier: dossier),
                            registry: registry, root: workspace.rootPath,
                            tools: routeTools, context: workspaceContext, roles: roles,
                            providerId: providerId, model: model, budget: sharedBudget,
                            executionContract: executionContract,
                            durableStateRoot: durableStateRoot
                                .appendingPathComponent("cobolo-state", isDirectory: true).path,
                            dependencies: CoboloDependencies(identityPlan: identityPlan),
                            outcomeCapture: { coboloEvidenceBox.set($0) })
                    case .greatLoop:
                        guard let adapterCheckpoints else {
                            throw BuilderRunError.invalidConfiguration("GreatLoop requires a checkpoint store")
                        }
                        let greatLoopGoal = highAssuranceDossier.map {
                            autonomyMissionGoal(boundedExecutionGoal, dossier: $0)
                        } ?? boundedExecutionGoal
                        let invokeGreatLoop: @Sendable () async -> Int32 = {
                            await runGreatLoop(
                                opts, goal: greatLoopGoal, registry: registry,
                                root: adapterRoot, tools: routeTools,
                                context: adapterContext, checkpoints: adapterCheckpoints,
                                toolMode: toolMode, roles: roles,
                                providerId: providerId, model: model,
                                budgetOverride: sharedBudget)
                        }
                        status = await invokeGreatLoop()
                    case .planExecute:
                        let planExecuteTools = builderScopedPlanExecuteTools(
                            from: routeTools, sealedPlan: preflightEnvelope?.plan)
                        // The worker sees the host-frozen contract (allowed paths + exact verifier)
                        // instead of discovering it from failures (KistRunner+SealedContractPrompt).
                        let sealedGoal = builderGoalWithSealedContract(
                            boundedExecutionGoal, plan: preflightEnvelope?.plan)
                        let invokePlanExecute: @Sendable () async -> Int32 = {
                            await runPlanExecute(
                                opts, goal: sealedGoal, registry: registry,
                                root: adapterRoot, tools: planExecuteTools, context: adapterContext,
                                providerId: providerId, model: model,
                                rolesOverride: roles, budgetOverride: sharedBudget,
                                launchMode: planExecuteLaunchMode,
                                freshMissionInstanceID: planExecuteMissionID,
                                riskObjective: riskObjective ?? goal,
                                checkpointGoal: goal, hostOwnedFinalReview: true,
                                // The planner's first message IS the functional objective (not the
                                // goal), so the sealed contract rides here; the canonical objective
                                // and its fingerprint stay untouched.
                                functionalObjective: builderGoalWithSealedContract(
                                    functionalExecutionGoal, plan: preflightEnvelope?.plan),
                                canonicalFunctionalObjective: canonicalFunctionalExecutionGoal,
                                hostContractID: finalizedContract.id,
                                memoryRoot: root, auditRoot: root,
                                persistMemoryEpisode: false,
                                outcomeCapture: { planOutcomeBox.set($0) })
                        }
                        status = await invokePlanExecute()
                    case .fleet:
                        guard let adapterCheckpoints,
                              let fleetWorkerRoute,
                              let plan = preflightEnvelope?.plan,
                              let partition = plan.partitions.first(where: {
                                  builderFleetNodeID($0.id) == request.node.id
                              }) else {
                            throw BuilderRunError.persistedStateInvalid(
                                "fleet node is not bound to one sealed partition")
                        }
                        let partitionGoal = """
                        Execute exactly one sealed fleet partition. Do not create or delegate another fleet.
                        Parent objective: \(goal)
                        Attempt objective: \(boundedExecutionGoal)
                        Partition: \(partition.id)
                        Allowed mutation paths: \(partition.paths.joined(separator: ", "))
                        Deterministic acceptance commands are host-owned and run after this worker exits.
                        Stop after completing only this partition.
                        """
                        let recorder = TrajectoryRecorder()
                        let traceRecorder = TraceRecorder(traceId: TraceID.make())
                        let loop = makeLoop(
                            registry: registry,
                            providerId: fleetWorkerRoute.providerID,
                            model: fleetWorkerRoute.modelID,
                            context: adapterContext, tools: routeTools,
                            checkpoints: adapterCheckpoints,
                            maxIterations: max(1, min(
                                opts.maxIterations, launch.effort.iterationBudget)),
                            budget: sharedBudget, planMode: false,
                            extendedThinking: opts.extendedThinking
                                || launch.effort.thinking != .none,
                            toolMode: toolMode, roles: roles,
                            delegationDepth: 0,
                            showReasoning: opts.extendedThinking
                                || launch.effort.thinking == .deep,
                            sinkOverride: TerminalEventSink(
                                showReasoning: opts.extendedThinking
                                    || launch.effort.thinking == .deep,
                                style: .calm),
                            recorder: recorder, traceRecorder: traceRecorder)
                        let invokePartition: @Sendable () async -> HeadlessAgentLoop.Outcome = {
                            await loop.run(goal: partitionGoal, rawRequest: goal,
                                           resolvedIntent: .build)
                        }
                        let outcome = await invokePartition()
                        status = outcome.success ? 0 : 1
                    case .mission:
                        guard let adapterCheckpoints, let highAssuranceDossier else {
                            throw BuilderRunError.invalidConfiguration(
                                "mission execution requires durable lineage and a checkpoint store")
                        }
                        let invokeMission: @Sendable () async -> AutonomyMissionStageResult = {
                            await runAutonomyExecutionStage(
                                opts, goal: boundedExecutionGoal, dossier: highAssuranceDossier,
                                registry: registry, root: adapterRoot, tools: routeTools,
                                context: adapterContext, checkpoints: adapterCheckpoints,
                                toolMode: toolMode, roles: roles,
                                providerId: providerId, model: model,
                                builder: builderBinding, budget: sharedBudget)
                        }
                        let missionResult = await invokeMission()
                        missionStageBox.set(missionResult, for: request.node.id)
                        status = missionResult.passed ? 0 : 1
                    case .headless:
                        guard let adapterCheckpoints else {
                            throw BuilderRunError.invalidConfiguration("headless execution requires a checkpoint store")
                        }
                        let executionBinding = builderHeadlessExecutionBinding(
                            builder: builderBinding, resolvedModel: builderModel)
                        let recorder = TrajectoryRecorder()
                        let runReplay = RunReplayStore(
                            projectRoot: root,
                            provider: executionBinding.providerId,
                            model: executionBinding.model,
                            executionRoot: adapterRoot,
                            parentContractID: finalizedContract.id)
                        let traceRecorder = TraceRecorder(traceId: runReplay.manifest.runID)
                        let proofStore = TurnProofStore(replayStore: runReplay)
                        let lessonStore = opts.noMemory ? nil : LessonStore()
                        proofStore.startTurn(goal: goal)
                        let loop = makeLoop(
                            registry: registry,
                            providerId: executionBinding.providerId,
                            model: executionBinding.model,
                            context: adapterContext,
                            tools: routeTools, checkpoints: adapterCheckpoints,
                            maxIterations: max(1, min(opts.maxIterations, launch.effort.iterationBudget)),
                            budget: sharedBudget, planMode: opts.planMode,
                            extendedThinking: opts.extendedThinking || launch.effort.thinking != .none,
                            toolMode: toolMode, roles: roles,
                            delegationDepth: launch.effort.team == .solo ? 0 : opts.delegationDepth,
                            showReasoning: opts.extendedThinking || launch.effort.thinking == .deep,
                            sinkOverride: TerminalEventSink(
                                                            showReasoning: opts.extendedThinking || launch.effort.thinking == .deep,
                                                            style: .calm, proofStore: proofStore),
                            recorder: recorder, traceRecorder: traceRecorder
                        )
                        let memoryContext = Self.sessionMemory(root: adapterRoot, opts: opts)
                        let personaContext = opts.fast ? nil : TaskPersonaMatcher.promptContext(
                            matches: TaskPersonaMatcher(projectRoot: adapterRoot).matches(for: goal, limit: 3))
                        let reviewContext = opts.fast ? nil
                            : ReviewContext.renderIfNeeded(request: goal, projectRoot: adapterRoot)
                        let executionIntent: TaskBrief.Intent = completionMode == .build
                            ? .build : .review
                        let boundedUserGoal = builderBoundedMutationAttemptGoal(
                            goal, attempt: request.attempt)
                        let baseProjectContext = briefContext(
                            memoryContext: memoryContext,
                            roles: roles,
                            lessons: opts.fast ? nil : lessonStore?.primer(forGoal: goal),
                            specialists: personaContext,
                            reviewTargets: reviewContext
                        ) ?? ""
                        let compiledGoal = PromptCompiler.compiledPrompt(
                            boundedUserGoal,
                            mode: opts.planMode ? .plan : .inline,
                            projectContext: builderEffortContext(launch.effort)
                                + "\n\n" + baseProjectContext,
                            resolvedIntent: executionIntent
                        )
                        // Builder already performed the host-owned mutation-intent and preflight gates.
                        // Do not let generated effort/project context reclassify that sealed contract.
                        let outcome = await loop.run(
                            goal: compiledGoal, rawRequest: goal,
                            resolvedIntent: executionIntent)
                        headlessVerificationHandoff = builderHeadlessCanHandOffToDeterministicVerification(
                            outcome: outcome, sealedPlan: preflightEnvelope?.plan)
                        let executionStagePassed = outcome.success || headlessVerificationHandoff
                        // Defer nested adapter learning until the final Builder receipt is accepted. On the
                        // sealed-headless-mutation handoff (`.stoppedUnverified` + verification handoff) the
                        // outer BuilderRun is still running its authoritative verifier + independent review,
                        // so `outcome.success == false` here is the EXPECTED intermediate state, not a
                        // failure. Writing a global "task failed" lesson or a paused journal entry now would
                        // poison retrieval for builds that go on to be accepted. Genuinely-final headless
                        // failures (no handoff) still record, so real failures are never swallowed.
                        if builderShouldRecordNestedAdapterLearning(
                            headlessVerificationHandoff: headlessVerificationHandoff) {
                            recordRuntimeLessons(goal: goal, success: outcome.success, recorder: recorder,
                                                 lessonStore: lessonStore,
                                                 maxIterations: opts.maxIterations,
                                                 mode: opts.planMode ? .plan : .inline)
                            Self.autoJournalRun(goal: goal, success: outcome.success, root: adapterRoot,
                                                enabled: !opts.noMemory)
                        }
                        print(KistREPL.renderSimpleSummary(projectRoot: adapterRoot,
                                                           spans: await traceRecorder.all(),
                                                           trajectory: recorder.snapshot()))
                        let grounding = GroundedReviewValidator.audit(outcome.summary, projectRoot: adapterRoot)
                        if !grounding.isGrounded {
                            print(grounding.render(color: TerminalCapabilities.stdoutIsInteractive))
                        }
                        printUsageDelta(from: [], to: await traceRecorder.all(), label: "usage",
                                        projectRoot: root)
                        note("replay · kist --replay \(runReplay.manifest.runID)")
                        if !executionStagePassed {
                            note("paused — resume with: kist --resume \(outcome.checkpointId)")
                        }
                        status = executionStagePassed ? 0 : 1
                    }
                    statusBox.set(status)
                    let tokensAfter = await sharedBudget?.spentTokens() ?? tokensBefore
                    let unmeteredStages: [String]
                    switch launch.adapter {
                    case .mission:
                        // runResearch returns only an exit status, so its council/model usage cannot be
                        // reconciled into the shared ledger without inventing a number.
                        unmeteredStages = ["mission.research"]
                    default:
                        unmeteredStages = []
                    }
                    let adapterPassed = status == 0
                    let observedPlanOutcome = launch.adapter == .planExecute
                        ? planOutcomeBox.get() : nil
                    let observedPlanMission = observedPlanOutcome?.missionInstanceID
                    let subjectDigest = PlanExecuteLoop.governedWorkspaceDigest(
                        projectRoot: adapterRoot)
                    let planFinalReplay = launch.adapter == .planExecute
                        ? builderFinalReplayEvidence(
                            receipt: observedPlanOutcome?.finalVerificationReceipt,
                            missionInstanceID: planExecuteMissionID?.rawValue ?? "",
                            contractID: finalizedContract.id,
                            contractFingerprint: objectiveFingerprint,
                            subjectDigest: subjectDigest)
                        : nil
                    if launch.adapter == .planExecute, planFinalReplay == nil {
                        // Name the reason (0.17.63): a minted receipt that fails admission here used to
                        // surface only as "final command receipt is missing".
                        note("build lane · final replay receipt not admitted: "
                             + builderFinalReplayRejectionReasons(
                                 receipt: observedPlanOutcome?.finalVerificationReceipt,
                                 missionInstanceID: planExecuteMissionID?.rawValue ?? "",
                                 contractID: finalizedContract.id,
                                 subjectDigest: subjectDigest).joined(separator: ", "))
                    }
                    let planMissionBound = launch.adapter != .planExecute
                        || (observedPlanMission != nil
                            && observedPlanMission == finalizedContract.checkpointIdentity)
                    // PlanExecute's host-owned final review promises one exact post-mutation replay.
                    // Make that promise part of worker admission for both build and verification-only
                    // modes, so a successful adapter exit cannot later become an accepted Builder final
                    // with nil/unbound typed evidence.
                    let planFinalReplayBound = launch.adapter != .planExecute
                        || planFinalReplay != nil
                    let passed = launch.adapter == .planExecute
                        ? builderPlanExecuteCompletionGatePassed(
                            adapterPassed: adapterPassed,
                            observedMissionID: observedPlanMission,
                            expectedMissionID: finalizedContract.checkpointIdentity,
                            finalReplay: planFinalReplay)
                        : adapterPassed
                    if launch.adapter == .cobolo, passed {
                        guard let evidence = coboloEvidenceBox.get() else {
                            throw BuilderRunError.finalVerificationFailed(
                                "Cobolo exited successfully without captured acceptance evidence")
                        }
                        let expectedExecutionContract = try await artifactStore.loadContract(
                            providerFingerprint: contractProvider!.identity.implementationFingerprint,
                            nodeID: request.node.id, attempt: request.attempt,
                            graphNodeIDs: graph.nodes.map(\.id))
                        let actualProducers = evidence.producerIdentities.map {
                            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        }
                        guard Set(actualProducers).count == evidence.producerIdentities.count,
                              actualProducers.allSatisfy({ $0.contains(":") }),
                              Set(actualProducers) == configuredProducerIdentities else {
                            throw BuilderRunError.finalVerificationFailed(
                                "Cobolo actual producer identities do not match the immutable Builder contract")
                        }
                        let supportingReviewer = evidence.reviewerIdentity
                            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        guard supportingReviewer.contains(":"),
                              !actualProducers.contains(where: {
                                coboloIdentitiesConflict($0, supportingReviewer)
                              }) else {
                            throw BuilderRunError.reviewerNotIndependent(
                                "Cobolo supporting reviewer identity is missing or conflicts with a producer")
                        }
                        let validated = try builderValidatedCoboloEvidence(
                            evidence, root: request.executionWorkspace?.rootPath ?? root,
                            contractFingerprint: objectiveFingerprint,
                            builderContractID: finalizedContract.id,
                            builderNodeID: request.node.id,
                            expectedExecutionContract: expectedExecutionContract)
                        let acceptanceCheck = BuilderCheckReceipt(
                            name: "cobolo promoted acceptance",
                            passed: true,
                            details: "target=\(evidence.target); source=\(evidence.promotedSHA256); "
                                + "workspace=\(validated.subjectDigest); "
                                + "supportingReviewer=\(supportingReviewer)")
                        let worker = BuilderWorkerReceipt(
                            nodeID: request.node.id,
                            provider: builderBinding.providerId,
                            model: builderModel,
                            artifacts: [BuilderArtifact(
                                path: evidence.target, kind: "cobolo-promoted-source",
                                digest: evidence.promotedSHA256)],
                            changedPaths: [evidence.target],
                            checks: [acceptanceCheck],
                            usage: .init(
                                wallTimeSeconds: Date().timeIntervalSince(started),
                                aggregateTokens: max(0, tokensAfter - tokensBefore)))
                        return bindBuilderWorkspaceEvidence(
                            worker, mode: completionMode, root: root,
                            baselineDigest: baselineDigest,
                            commandEvidence: validated.commandEvidence)
                    }
                    let check = BuilderCheckReceipt(
                        name: "\(launch.adapter.rawValue) completion gate",
                        passed: passed,
                        details: passed
                            ? (headlessVerificationHandoff
                                ? "sealed mutation execution stopped for mandatory Builder node verification"
                                : "adapter exit 0; its internal deterministic gate passed")
                            : (!planMissionBound
                                ? "plan mission identity missing or mismatched host contract"
                                : (!planFinalReplayBound
                                    ? "PlanExecute final replay receipt missing or unbound"
                                : "adapter exited \(status)")
                            )
                    )
                    let workerProvider = fleetWorkerRoute?.providerID
                        ?? builderBinding.providerId
                    let workerModel = fleetWorkerRoute?.modelID ?? builderModel
                    var worker = BuilderWorkerReceipt(
                        nodeID: request.node.id,
                        provider: workerProvider,
                        model: workerModel,
                        checks: [check],
                        unresolvedRisks: passed ? [] : [check.details],
                        usage: .init(
                            wallTimeSeconds: Date().timeIntervalSince(started),
                            aggregateTokens: unmeteredStages.isEmpty
                                ? max(0, tokensAfter - tokensBefore) : nil,
                            unmeteredStages: unmeteredStages.isEmpty ? nil : unmeteredStages
                        ),
                        missionInstanceID: observedPlanMission
                    )
                    if let highAssuranceDossier {
                        let artifact = try await artifactStore.saveStage(
                            nodeID: request.node.id, attempt: request.attempt,
                            dependencies: request.acceptedDependencies,
                            dossier: highAssuranceDossier,
                            advisoryTaskBoard: nil)
                        worker = builderWorker(worker, adding: artifact)
                    }
                    let commandEvidence: [BuilderCommandEvidenceReceipt]
                    let requiredSupportingObligations: [PlanSupportingObligation]?
                    let supportingCommandReceipts: [PlanSupportingCommandReceipt]?
                    let planFinalVerificationReceipt: PlanFinalVerificationReceipt?
                    if launch.adapter == .planExecute {
                        let outcome = observedPlanOutcome
                        let replay = planFinalReplay
                        if completionMode == .verificationOnly {
                            commandEvidence = replay.map { [$0] } ?? []
                            requiredSupportingObligations = outcome?.requiredSupportingObligations
                            let unchanged = baselineDigest == subjectDigest
                            supportingCommandReceipts = unchanged && replay != nil
                                ? outcome?.supportingCommandReceipts : []
                            planFinalVerificationReceipt = unchanged && replay != nil
                                ? outcome?.finalVerificationReceipt : nil
                        } else {
                            var evidence = builderCommandEvidence(
                                execution: outcome?.execution,
                                contractFingerprint: objectiveFingerprint,
                                subjectDigest: subjectDigest)
                            if let replay { evidence.append(replay) }
                            commandEvidence = evidence
                            requiredSupportingObligations = nil
                            supportingCommandReceipts = nil
                            // Preserve the same typed post-mutation replay receipt already admitted
                            // into command evidence. Accepted dashboard authority later requires this
                            // exact mission/contract/workspace lineage; dropping it here made a real
                            // PlanExecute build indistinguishable from a generic planned adapter.
                            planFinalVerificationReceipt = replay != nil
                                ? outcome?.finalVerificationReceipt : nil
                        }
                    } else {
                        // Generic adapters expose only an aggregate exit/check string, not one exact
                        // registered launcher invocation. Never fabricate deterministic command proof.
                        commandEvidence = []
                        requiredSupportingObligations = nil
                        supportingCommandReceipts = nil
                        planFinalVerificationReceipt = nil
                    }
                    return bindBuilderWorkspaceEvidence(
                        worker, mode: completionMode, root: adapterRoot,
                        baselineDigest: baselineDigest, commandEvidence: commandEvidence,
                        requiredSupportingObligations: requiredSupportingObligations,
                        supportingCommandReceipts: supportingCommandReceipts,
                        planFinalVerificationReceipt: planFinalVerificationReceipt)
    }
}
