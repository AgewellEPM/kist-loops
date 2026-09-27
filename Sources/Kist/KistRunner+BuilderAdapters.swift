import Foundation
import AgentCore

/// Builder route selection, compatibility adapter contracts, and Cobolo bindings.
extension KistRunner {
    static func builderPreflightBinding(
        roles: RoleBindings,
        registry: ProviderRegistry
    ) -> ProviderBinding? {
        let configured = roles.binding(for: .planner)
        guard let provider = registry.provider(id: configured.providerId) else { return nil }
        return ProviderBinding(
            providerId: provider.id,
            model: provider.resolvedModel(configured.model))
    }

    enum BuilderCompatibilityAdapter: String, Sendable, Equatable {
        case headless
        case greatLoop
        case planExecute
        case fleet
        case mission
        case cobolo

        var compatibleRoute: BuilderRoute {
            switch self {
            case .headless: return .direct
            case .planExecute: return .planned
            case .fleet: return .fleet
            case .greatLoop, .mission, .cobolo: return .highAssurance
            }
        }
    }

    struct BuilderCompatibilityLaunch: Sendable, Equatable {
        let routeHint: BuilderRouteHint
        let adapter: BuilderCompatibilityAdapter
        let routerDecision: TaskRouter.Decision
        let effort: EffortController.Assessment
        /// Host-derived from the canonical request and explicit route flags before any provider
        /// produces a preflight. A model-authored plan can narrow this authority, never create it.
        let mutationIntent: Bool
        let leanHeadless: Bool
        /// Host-minted route capability. Completion mode alone is descriptive and never grants it.
        let allowsVerifiedReadOnlyPromotion: Bool
        /// Effect risk is separate from `routeHint.risk`, whose medium value can mean only prompt
        /// complexity. This host-owned capability is the first gate for the narrow disposable-temp
        /// same-model review exception; root and sealed-preflight checks run later.
        let effectSafetyRisk: BuilderRisk
        let allowsFreshContextSameModelReviewCandidate: Bool
    }

    struct BuilderCaptainDecisionReceipt: Sendable, Equatable {
        static let schemaVersion = 1
        let builderContractID: String
        let objectiveDigest: String
        let adapter: String
        let route: String
        let risk: String
        let requiresResearch: Bool
        let requiresSimulation: Bool

        var digest: String {
            BuilderEvidenceDigest.sha256([
                "kist.captain-builder-decision.v\(Self.schemaVersion)", builderContractID,
                objectiveDigest, adapter, route, risk,
                String(requiresResearch), String(requiresSimulation),
            ].joined(separator: "\u{1f}"))
        }
    }

    static func builderCaptainDecisionReceipt(
        contractID: String, goal: String, launch: BuilderCompatibilityLaunch
    ) -> BuilderCaptainDecisionReceipt {
        BuilderCaptainDecisionReceipt(
            builderContractID: contractID,
            objectiveDigest: BuilderEvidenceDigest.sha256(goal),
            adapter: launch.adapter.rawValue,
            route: String(describing: launch.routeHint.resolve()),
            risk: String(describing: launch.routeHint.risk),
            requiresResearch: launch.routeHint.requiresResearch,
            requiresSimulation: launch.routeHint.requiresSimulation)
    }

    static func coboloBuilderGraph(root: String, goal: String, target: String) throws -> BuilderGraph {
        guard try BuilderMutationOperation(kind: .create, path: target).path == target else {
            throw BuilderRunError.invalidConfiguration(
                "Cobolo target authority must be canonical and project-relative")
        }
        return try BuilderGraph(nodes: [
            BuilderNode(
                id: "research", objective: "Produce an exact-run research dossier for: \(goal)",
                resources: [BuilderResourceClaim(path: ".", access: .read)],
                isolation: .sandbox, role: .planner, retryLimit: 0),
            BuilderNode(
                id: "symbolic-peel", objective: "Bind the research dossier to symbolic PEEL evidence",
                dependencies: ["research"],
                resources: [BuilderResourceClaim(path: ".", access: .read)],
                isolation: .sandbox, role: .verifier, retryLimit: 0),
            BuilderNode(
                id: "council", objective: "Produce a Kist council decision from the PEEL-gated dossier",
                dependencies: ["symbolic-peel"],
                resources: [BuilderResourceClaim(path: ".", access: .read)],
                isolation: .sandbox, role: .planner, retryLimit: 0),
            BuilderNode(
                id: "task-board-projection", objective: "Project the council plan onto the shared board",
                dependencies: ["council"],
                resources: [BuilderResourceClaim(path: ".", access: .read)],
                isolation: .sandbox, role: .planner, retryLimit: 0),
            BuilderNode(
                id: "cobolo-execution", objective: goal,
                dependencies: ["task-board-projection"],
                resources: [BuilderResourceClaim(path: target, access: .write)],
                isolation: .sandbox, role: .builder, retryLimit: 0),
        ])
    }

    static func coboloIssueExecutionContract(
        builderContractID: String,
        builderNodeID: String,
        target: String,
        root: String,
        lineage: BuilderLineageEnvelope,
        identityPlan: CoboloIdentityPlan,
        maxRevisions: Int,
        maxTokens: Int?
    ) throws -> SealedBuilderExecutionContract {
        let confined = try ConfinedRoot(root: root)
        let mutation: BuilderMutationOperation
        do {
            let type = try confined.fileType(target)
            guard !type.isDir else {
                throw CoboloLoopError.configuration("COBOL target is a directory")
            }
            if type.exists {
                let digest = try confined.fileSHA256(target)
                    .map { String(format: "%02x", $0) }.joined()
                mutation = try BuilderMutationOperation(
                    kind: .modify, path: target, preimageSHA256: digest)
            } else {
                mutation = try BuilderMutationOperation(kind: .create, path: target)
            }
        } catch ToolError.notFound {
            mutation = try BuilderMutationOperation(kind: .create, path: target)
        }
        guard mutation.path == target else {
            throw CoboloLoopError.configuration(
                "--cobol-target is not already in canonical normalized form")
        }

        func identity(_ binding: ProviderBinding) throws -> BuilderModelIdentity {
            guard let model = binding.model else {
                throw CoboloLoopError.configuration("Cobolo identity is not concrete")
            }
            return try BuilderModelIdentity(providerID: binding.providerId, modelID: model)
        }
        let identities = try BuilderIdentityPlan(
            producers: [identityPlan.driver, identityPlan.coder, identityPlan.cobol].map(identity),
            reviewers: [identityPlan.critic, identityPlan.promotion].map(identity))
        let revisions = max(1, maxRevisions)
        let tokenLimit = max(8_000, maxTokens ?? 200_000)
        let total = try BuilderResourceBudget(
            maxToolCalls: 16 + revisions * 10,
            maxTokens: tokenLimit,
            maxWallTimeSeconds: 900 + revisions * 600)
        let stages: [BuilderExecutionStage] = [.planning, .build, .verification, .review, .promotion]
        let perStage = try BuilderResourceBudget(
            maxToolCalls: total.maxToolCalls,
            maxTokens: total.maxTokens,
            maxWallTimeSeconds: total.maxWallTimeSeconds)
        let budgets = try BuilderBudgetPolicy(
            total: total, stages: stages.map { BuilderStageBudget(stage: $0, limit: perStage) })
        let criteria = try [
            BuilderStageCriterion(
                id: "cobolo-lineage", stage: .planning, kind: .lineageReceipt,
                statement: "Captain, research, symbolic PEEL, and council lineage is complete; task-board projection is advisory"),
            BuilderStageCriterion(
                id: "cobolo-target", stage: .build, kind: .artifactDigest,
                statement: "Only the normalized COBOL target is created or modified"),
            BuilderStageCriterion(
                id: "cobolo-compile", stage: .verification, kind: .deterministicCommand,
                statement: "The promoted COBOL target compiles with a sandboxed exit-zero receipt"),
            BuilderStageCriterion(
                id: "cobolo-runtime", stage: .verification, kind: .deterministicCommand,
                statement: "The promoted COBOL binary exits zero and satisfies required stdout"),
            BuilderStageCriterion(
                id: "cobolo-semantic-review", stage: .review, kind: .modelJudgment,
                statement: "A model independent of every producer approves semantic correctness"),
            BuilderStageCriterion(
                id: "cobolo-promotion-review", stage: .promotion, kind: .modelJudgment,
                statement: "A second independent model approves promotion from bound evidence"),
        ]
        return try SealedBuilderExecutionContract.issue(BuilderExecutionContract(
            builderContractID: builderContractID, builderNodeID: builderNodeID,
            mutations: [mutation], criteria: criteria, budgets: budgets,
            identities: identities, lineage: lineage))
    }

    static func coboloBoundExecutionContract(
        builderContractID: String,
        builderNodeID: String,
        target: String,
        root: String,
        lineage: BuilderLineageEnvelope,
        identityPlan: CoboloIdentityPlan,
        maxRevisions: Int,
        maxTokens: Int?
    ) throws -> SealedBuilderExecutionContract {
        let directory = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(".kist", isDirectory: true)
            .appendingPathComponent("builder-runs", isDirectory: true)
        let url = directory.appendingPathComponent(
            "\(builderContractID)-\(builderNodeID)-execution-contract.json")
        if let data = FileManager.default.contents(atPath: url.path) {
            let persisted = try JSONDecoder().decode(
                SealedBuilderExecutionContract.self, from: data)
            try coboloValidateExecutionContract(
                persisted, builderContractID: builderContractID,
                builderNodeID: builderNodeID, target: target,
                identityPlan: identityPlan)
            guard persisted.contract.lineage == lineage else {
                throw CoboloLoopError.rejected(
                    "Builder planning lineage drifted from the durable Cobolo execution contract")
            }
            return persisted
        }
        let issued = try coboloIssueExecutionContract(
            builderContractID: builderContractID, builderNodeID: builderNodeID,
            target: target, root: root, lineage: lineage,
            identityPlan: identityPlan, maxRevisions: maxRevisions,
            maxTokens: maxTokens)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(issued).write(to: url, options: .atomic)
        return issued
    }

    /// Back-compatible pure seam for existing tests/callers that already put the goal on KistOptions.
    static func builderCompatibilityLaunch(for opts: KistOptions) -> BuilderCompatibilityLaunch {
        builderCompatibilityLaunch(for: opts, goal: opts.goal ?? "")
    }

    /// TaskRouter is the sole front-door selector for unforced builds. Explicit modes remain overrides,
    /// except that rigor-sensitive/council work escalates to high assurance rather than honoring an unsafe
    /// downgrade. EffortController.planning then maps one-to-one onto its executor adapter.
    static func builderCompatibilityLaunch(for opts: KistOptions, goal: String) -> BuilderCompatibilityLaunch {
        let mutationIntent = builderDeterministicMutationIntent(for: opts, goal: goal)
        let effort = EffortController.assess(goal: goal)
        let highRisk = opts.cobolo || opts.mission || opts.greatLoop
            || EffortController.requiresRigor(goal: goal)
        let structuralComplexity = min(
            100,
            max(10, goal.split(whereSeparator: { $0.isWhitespace }).count * 4)
        )
        let explicitReasoningRoute: ReasoningRoute?
        if opts.headless {
            explicitReasoningRoute = .direct
        } else if opts.fleet {
            explicitReasoningRoute = .fleet
        } else if opts.cobolo || opts.mission || opts.planExecute || opts.greatLoop {
            explicitReasoningRoute = .planned
        } else {
            explicitReasoningRoute = nil
        }
        let requestedEffort: ProviderReasoningEffort
        switch effort.thinking {
        case .none: requestedEffort = .none
        case .light: requestedEffort = .light
        case .deep: requestedEffort = .deep
        }
        let captainControl = CaptainController.control(CaptainControlRequest(
            routeRequest: ReasoningRouteRequest(
                explicitRoute: explicitReasoningRoute,
                complexity: structuralComplexity,
                risk: highRisk ? .high : .low,
                requiresMutation: mutationIntent,
                independentWorkstreams: opts.fleet ? 2 : 1,
                expectedToolCalls: max(1, structuralComplexity / 15)
            ),
            requestedEffort: requestedEffort,
            requiresResearch: highRisk,
            requiresSimulation: highRisk
        ))
        let reasoningDecision = captainControl.routeDecision
        // The legacy decision remains only as a compatibility record. Its route is
        // forced from the typed Sol policy, so objective text is no longer routed a
        // second time by the lexical router.
        let routerDecision: TaskRouter.Decision
        switch reasoningDecision.route {
        case .direct:
            routerDecision = TaskRouter.route(goal: goal, userForced: .fast)
        case .planned:
            routerDecision = TaskRouter.route(goal: goal, userForced: .standard)
        case .fleet:
            routerDecision = TaskRouter.route(goal: goal, userForced: .pipeline)
        }
        let route: BuilderRoute
        let adapter: BuilderCompatibilityAdapter
        let lean: Bool
        if opts.cobolo {
            route = .highAssurance; adapter = .cobolo; lean = false
        } else if opts.headless {
            // This is a host-derived route capability. Goal text and provider prose cannot
            // redirect an explicitly selected direct Builder run to a different adapter.
            route = .direct; adapter = .headless; lean = true
        } else if opts.mission {
            route = .highAssurance; adapter = .mission; lean = false
        } else if opts.fleet {
            route = .fleet; adapter = .fleet; lean = false
        } else if opts.planExecute {
            route = .planned; adapter = .planExecute; lean = false
        } else if opts.greatLoop {
            route = .highAssurance; adapter = .greatLoop; lean = false
        } else if highRisk {
            route = .highAssurance; adapter = .mission; lean = false
        } else {
            switch routerDecision.route {
            case .fast:
                route = .direct; adapter = .headless; lean = true
            case .standard:
                switch effort.planning {
                case .direct:
                    route = .direct; adapter = .headless; lean = false
                case .plan:
                    route = .planned; adapter = .planExecute; lean = false
                case .decompose:
                    route = .fleet; adapter = .fleet; lean = false
                }
            case .pipeline:
                switch effort.planning {
                case .direct, .plan:
                    route = .planned; adapter = .planExecute; lean = false
                case .decompose:
                    route = .fleet; adapter = .fleet; lean = false
                }
            }
        }

        let builderRisk: BuilderRisk = opts.mission ? .critical
            : (route == .highAssurance ? .high
                : (effort.complexity >= 40 ? .medium : .low))
        let effectSafetyRisk: BuilderRisk = opts.mission ? .critical : (highRisk ? .high : .low)
        let sameModelCandidate = adapter == .headless
            && route == .direct
            && mutationIntent
            && effectSafetyRisk == .low
            && builderRisk != .high && builderRisk != .critical
            && !opts.ship && !opts.mission && !opts.fleet && !opts.planExecute
            && !opts.greatLoop && !opts.cobolo && !opts.enableComputerUse
            && opts.auto && opts.sandbox
            && !captainControl.requiresResearch && !captainControl.requiresSimulation
        let estimatedFiles = effort.planning == .direct ? 1 : max(2, opts.agents)
        return BuilderCompatibilityLaunch(
            routeHint: .init(preferred: route,
                             estimatedFiles: estimatedFiles,
                             independentWorkstreams: route == .fleet ? max(2, opts.agents) : 1,
                             risk: builderRisk,
                             requiresResearch: captainControl.requiresResearch || route == .highAssurance,
                             requiresSimulation: captainControl.requiresSimulation || route == .highAssurance),
            adapter: adapter,
            routerDecision: routerDecision,
            effort: effort,
            mutationIntent: mutationIntent,
            leanHeadless: lean,
            allowsVerifiedReadOnlyPromotion: verifiedReadOnlyPromotionCapability(
                adapter: adapter, leanHeadless: lean,
                completionMode: builderCompletionMode(for: goal)),
            effectSafetyRisk: effectSafetyRisk,
            allowsFreshContextSameModelReviewCandidate: sameModelCandidate
        )
    }

    /// Resolve write authority exactly once from host-owned CLI mode plus PromptCompiler's canonical
    /// request classification. Explicit read-only wording wins inside PromptCompiler; provider output,
    /// retrieved memory, council prose, and the generated preflight never participate in this decision.
    static func builderDeterministicMutationIntent(for opts: KistOptions, goal: String) -> Bool {
        let intent = PromptCompiler.inferIntent(goal, mode: .inline)
        if intent == .delegate { return false }
        if opts.cobolo { return true }
        guard !opts.planMode, builderCompletionMode(for: goal) == .build else { return false }
        if opts.headless || opts.mission || opts.fleet || opts.planExecute || opts.greatLoop || opts.ship
            || opts.resumeId != nil || opts.resumeLast || opts.planExecuteResumeID != nil {
            return true
        }
        return intent.expectsMutation
    }

    /// Lean direct builds never inherit the broad runtime registry. Read-only capabilities remain
    /// available, while the sealed plan adds only the smallest file primitive for each operation kind.
    /// Every retained mutator is wrapped with exact path + operation-kind authority before execution.
    static func builderScopedHeadlessTools(
        from tools: ToolRegistry,
        sealedPlan: BuilderPreflightPlan?
    ) -> ToolRegistry {
        guard let sealedPlan, !sealedPlan.operations.isEmpty else {
            return tools.scoped(to: Array(HeadlessAgentLoop.readOnlyTools))
        }
        let authority = Dictionary(uniqueKeysWithValues: sealedPlan.operations.map {
            ($0.path, $0.kind)
        })
        var mutationTools = Set<String>()
        for operation in sealedPlan.operations {
            switch operation.kind {
            case .create: mutationTools.formUnion(["write_file", "edit_file"])
            case .modify: mutationTools.insert("edit_file")
            case .delete: mutationTools.insert("apply_patch")
            }
        }
        var scopedTools = mutationTools
        if !sealedPlan.verificationCommands.isEmpty { scopedTools.insert("run_command") }
        let allowed = HeadlessAgentLoop.readOnlyTools.union(scopedTools)
        let createdFiles = BuilderCreatedFileAuthority()
        let selected: [any AgentTool] = tools.all().compactMap { tool in
            guard allowed.contains(tool.name) else { return nil }
            guard scopedTools.contains(tool.name) else { return tool }
            return BuilderContractScopedMutationTool(
                base: tool, authority: authority,
                verificationCommands: sealedPlan.verificationCommands,
                createdFiles: createdFiles)
        }
        return ToolRegistry(selected)
    }

    /// PlanExecute retains its established mutation-tool semantics, but verification commands must
    /// still carry the same frozen-contract authority as lean-headless execution. Wrapping only the
    /// command tool keeps that distinction explicit: file mutations remain governed by PlanExecute's
    /// own pipeline while a successful exact verifier can mint the non-model-visible verification seal.
    static func builderScopedPlanExecuteTools(
        from tools: ToolRegistry,
        sealedPlan: BuilderPreflightPlan?
    ) -> ToolRegistry {
        guard let sealedPlan, !sealedPlan.verificationCommands.isEmpty else { return tools }
        let selected: [any AgentTool] = tools.all().map { tool -> any AgentTool in
            guard tool.name == "run_command" else { return tool }
            return BuilderContractScopedMutationTool(
                base: tool, authority: [:],
                verificationCommands: sealedPlan.verificationCommands,
                substitutesNearMisses: true)
        }
        return ToolRegistry(selected)
    }

    /// The driver chooses the route, but the configured coder performs the mutation. Keep the
    /// concrete loop/replay identity aligned with the worker identity recorded in Builder receipts.
    static func builderHeadlessExecutionBinding(
        builder: ProviderBinding,
        resolvedModel: String
    ) -> ProviderBinding {
        ProviderBinding(
            providerId: builder.providerId,
            model: builder.model ?? resolvedModel)
    }

    struct BuilderFleetWorkerRoute: Sendable, Equatable {
        let providerID: String
        let modelID: String
    }

    static func builderFleetWorkerRoute(
        builder: ProviderBinding,
        resolvedModel: String
    ) -> BuilderFleetWorkerRoute {
        let binding = builderHeadlessExecutionBinding(
            builder: builder, resolvedModel: resolvedModel)
        return BuilderFleetWorkerRoute(
            providerID: binding.providerId,
            modelID: binding.model ?? resolvedModel)
    }

    /// Generic headless deliberately fails a changed-but-unverified run. A sealed Builder execution
    /// may advance only that typed terminal state, and only when exact mutation authority and a
    /// host-owned deterministic verifier are both present. BuilderRun still decides acceptance after
    /// node verification, final verification, and independent review.
    static func builderHeadlessCanHandOffToDeterministicVerification(
        outcome: HeadlessAgentLoop.Outcome,
        sealedPlan: BuilderPreflightPlan?
    ) -> Bool {
        guard outcome.terminalStatus == .stoppedUnverified,
              let sealedPlan,
              sealedPlan.adapter == BuilderCompatibilityAdapter.headless.rawValue,
              !sealedPlan.operations.isEmpty,
              !sealedPlan.verificationCommands.isEmpty else {
            return false
        }
        return true
    }

    /// Nested headless adapter learning (global "task failed" lessons + paused journal entries) must be
    /// deferred until the FINAL Builder receipt is accepted. A sealed headless mutation that stops at
    /// `.stoppedUnverified` is the EXPECTED handoff: `outcome.success` is still false, but the outer
    /// BuilderRun continues to node verification, final verification, and independent review before it
    /// decides acceptance. Recording a failure lesson or a paused journal line at that handoff would
    /// poison future retrieval for runs that go on to be accepted. So skip nested learning whenever the
    /// deterministic-verification handoff fires; a genuinely-final headless failure (no handoff) still
    /// records, so real failures are never swallowed.
    static func builderShouldRecordNestedAdapterLearning(
        headlessVerificationHandoff: Bool
    ) -> Bool {
        !headlessVerificationHandoff
    }

    static func builderEffortContext(_ effort: EffortController.Assessment) -> String {
        "BUILDER EFFORT CONTRACT (provider-neutral): planning=\(effort.planning.rawValue); "
            + "thinking=\(effort.thinking.rawValue); team=\(effort.team.rawValue); "
            + "tier=\(effort.modelTier.rawValue); iterationBudget=\(effort.iterationBudget); "
            + "searchWidth=\(effort.searchWidth). Apply this amount of planning and collaboration; "
            + "do not substitute vendor-specific behavior for the requested effort."
    }

    static func builderCompletionMode(for goal: String) -> BuilderCompletionMode {
        let lower = goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let firstWord = lower.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        let verificationLead = ["verify", "audit", "validate", "check", "test", "inspect"]
            .contains(firstWord)
        let explicitLabel = lower.contains("verification-only")
            || lower.contains("verification only") || lower.contains("audit-only")
        let forbidsEdits = [
            "without editing", "without changing", "do not edit", "do not change",
            "must not edit", "must not modify", "no edits", "no changes", "read-only", "read only",
        ].contains(where: lower.contains)
        return (explicitLabel || (verificationLead && forbidsEdits)) ? .verificationOnly : .build
    }

    /// Authority is minted only by a trusted audit-capable launch route AND an explicit no-mutation
    /// contract. Neither lexical completion mode nor a broad build adapter can authorize promotion alone.
    static func verifiedReadOnlyPromotionCapability(
        adapter: BuilderCompatibilityAdapter,
        leanHeadless: Bool,
        completionMode: BuilderCompletionMode
    ) -> Bool {
        guard completionMode == .verificationOnly else { return false }
        return leanHeadless || adapter == .planExecute
    }

    static func configuredProducerIdentities(
        roles: RoleBindings,
        registry: ProviderRegistry
    ) -> Set<String>? {
        var identities = Set<String>()
        // Inner critics are advisory gates, not artifact producers. Their verdicts never satisfy the
        // authoritative outer review, but counting them as producers would unnecessarily require a
        // third provider in the common Claude-produces/Gemini-reviews configuration.
        for role in [AgentRole.planner, .worker, .coder] {
            let binding = roles.binding(for: role)
            guard let provider = registry.provider(id: binding.providerId),
                  let identity = providerModelIdentity(
                    provider: provider.id, model: provider.resolvedModel(binding.model)) else { return nil }
            identities.insert(identity)
        }
        return identities.isEmpty ? nil : identities
    }

    static func independentReviewRoles(_ selection: IndependentReviewerSelection) -> RoleBindings {
        // The outer review is the authoritative provenance-bearing gate. Planned grounded_answer output
        // is evidence only: that tool has no provider:model receipt and cannot satisfy this contract.
        RoleBindings(default: selection.binding)
    }

    static func builderObjectiveFingerprint(contractID: String, goal: String) -> String {
        BuilderEvidenceDigest.sha256(contractID + "\u{0}" + goal)
    }

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
                            maxIterations: launch.leanHeadless
                                ? min(opts.maxIterations, launch.effort.iterationBudget)
                                : max(opts.maxIterations, launch.effort.iterationBudget),
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

/// Execution-time half of the lean-headless capability contract. The surrounding isolated workspace
/// transaction still verifies the complete tree and rolls back undeclared effects; this wrapper denies
/// an out-of-contract file operation before it can touch even that staged workspace.
struct BuilderContractScopedMutationTool: AgentTool, ToolArgumentCanonicalizing {
    let base: any AgentTool
    let authority: [String: BuilderMutationKind]
    let verificationCommands: [KistRunner.BuilderPreflightCommand]
    var createdFiles: BuilderCreatedFileAuthority? = nil
    /// Plan-execute only: its coordinated actions get no in-step repair, so a same-executable near
    /// miss on the sealed verifier canonicalizes to the sealed command. The lean headless lane keeps
    /// exact-match denial — its own repair loop reads the denial and retries.
    var substitutesNearMisses: Bool = false

    var name: String { base.name }
    var description: String {
        if name == "run_command" {
            return "Run a sealed verification command in the staged project root. "
                + "Use one of these exact structured argument objects: "
                + sealedCommandExamples.joined(separator: "; ")
                + ". Omit cwd (or use a single dot). Omit timeout to use its sealed value. "
                + "Shell commands, input redirection and background execution are unavailable in this contract."
        }
        return base.description + " Builder contract paths: "
            + authority.keys.sorted().joined(separator: ", ")
            + (name == "write_file" ? ". After creating a file, revise it with edit_file or replace its full contents with write_file; then rerun the sealed verifier." : "")
            + (name == "edit_file" ? ". A create path can be edited only after this worker successfully wrote its current contents." : "")
    }
    var parameters: [ToolParameter] {
        guard name == "run_command" else { return base.parameters }
        return [
            ToolParameter(name: "executable", type: "string", description: "Exact executable from the sealed argument objects above"),
            ToolParameter(name: "args", type: "array", description: "Exact string argument array from the sealed command"),
            ToolParameter(name: "cwd", type: "string", description: "Omit for the staged project root; only the root is permitted", required: false),
            ToolParameter(name: "timeout", type: "number", description: "Omit to use the sealed command timeout; an explicit value must match exactly", required: false),
            ToolParameter(name: "allowed_exit_codes", type: "array", description: "Omit, or use [0]", required: false),
        ]
    }
    var supportedActions: [String] { base.supportedActions }
    var unsupportedActions: [String] { base.unsupportedActions }
    var capabilityNote: String? { base.capabilityNote }
    var usageExamples: [String] { name == "run_command" ? sealedCommandExamples : base.usageExamples }

    private var sealedCommandExamples: [String] {
        verificationCommands.compactMap { command in
            let object: [String: Any] = ["executable": command.executable, "args": command.arguments,
                                         "timeout": command.timeoutSeconds]
            return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) }
        }
    }

    func canonicalizeToolArguments(_ arguments: [String: Any]) -> [String: Any] {
        contractBoundArguments(arguments)
    }

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let effectiveArguments = canonicalizeToolArguments(arguments)
        var sealedSubstitutionNote: String?
        if name == "run_command", let substitute = sealedSubstitutionApplied(raw: arguments) {
            sealedSubstitutionNote = "[sealed verifier substituted for the requested arguments: "
                + substitute.canonicalStatement + "]\n"
        }
        let path = effectiveArguments["path"] as? String
        let revisingCreatedFile: Bool
        if name == "edit_file", let path, authority[path] == .create, let createdFiles {
            revisingCreatedFile = await createdFiles.matches(path: path, context: context)
        } else {
            revisingCreatedFile = false
        }
        guard authorized(effectiveArguments) || revisingCreatedFile else {
            if name == "run_command" {
                return .failure("The command arguments did not match the sealed verifier. "
                    + "Use exactly one of these argument objects: " + sealedCommandExamples.joined(separator: "; ")
                    + ". Omit cwd; do not switch to shell/command mode.")
            }
            return .failure("builder execution contract denied an undeclared mutation. "
                + "Use the advertised file tool for a sealed path; run_command permits only the exact sealed verifier, including during repair.")
        }
        var result = try await base.execute(arguments: effectiveArguments, context: context)
        if let sealedSubstitutionNote {
            result = result.prefixingOutput(sealedSubstitutionNote)
        }
        if result.success, let path, authority[path] == .create,
           name == "write_file" || name == "edit_file" {
            await createdFiles?.record(path: path, context: context)
        }
        guard name == "run_command", result.success else { return result }
        return result.authorizingBuilderContractVerification(arguments: effectiveArguments)
    }

    /// The sealed command a raw request canonicalizes to, or nil when the request is already exact
    /// (no substitution) or is not a repairable near miss.
    func sealedSubstitutionApplied(raw arguments: [String: Any]) -> KistRunner.BuilderPreflightCommand? {
        guard substitutesNearMisses, name == "run_command", !authorized(arguments) else { return nil }
        return sealedSubstitute(for: arguments)
    }

    /// The one sealed command this request can only have meant: same executable, no shell/stdin/
    /// background/cwd escape, default exit codes — and exactly ONE sealed command for that
    /// executable, so the substitution is unambiguous. Nil keeps the exact-match refusal.
    func sealedSubstitute(for arguments: [String: Any]) -> KistRunner.BuilderPreflightCommand? {
        guard name == "run_command",
              let executable = arguments["executable"] as? String,
              arguments["command"] == nil, arguments["shell"] == nil,
              arguments["stdin"] == nil, arguments["stdin_path"] == nil,
              arguments["background"] == nil,
              arguments["cwd"] == nil || (arguments["cwd"] as? String) == ".",
              exactZeroExitCodes(arguments["allowed_exit_codes"]) else { return nil }
        let candidates = verificationCommands.filter { $0.executable == executable }
        guard candidates.count == 1, let sealed = candidates.first else { return nil }
        // Explicit timeouts are never repaired (same rule as contractBoundArguments): only an omitted
        // timeout, or exactly the sealed one, may ride along with substituted arguments.
        if arguments["timeout"] != nil, exactInteger(arguments["timeout"]) != sealed.timeoutSeconds {
            return nil
        }
        return sealed
    }

    /// `run_command` defaults an omitted timeout to 120 seconds, which could exceed the frozen
    /// verifier's ceiling. For one unambiguous executable+argv match, bind the actual invocation to
    /// the contract's timeout before the command is authorized, audited, executed, and sealed.
    /// Explicit timeouts are never repaired. An empty cwd is the base tool's spelling of the project
    /// root, so canonicalize it to omission before authorization, audit and execution.
    private func contractBoundArguments(_ arguments: [String: Any]) -> [String: Any] {
        var arguments = arguments
        if name == "run_command", arguments["cwd"] as? String == "" {
            arguments.removeValue(forKey: "cwd")
        }
        // A same-executable near miss on the sealed verifier canonicalizes TO the sealed command
        // (different test selection, an extra -v, a discover subcommand): the contract permits only
        // that command, so this is what will actually run. Doing it here, not in execute, means the
        // executor records, durable receipts, replay recipes, and the gate digest all describe the
        // sealed invocation (2026-09-27: substituting at execution time left the recipe holding the
        // near miss and no final receipt could ever be minted).
        if let substitute = sealedSubstitutionApplied(raw: arguments) {
            return ["executable": substitute.executable, "args": substitute.arguments,
                    "timeout": substitute.timeoutSeconds]
        }
        guard name == "run_command", arguments["timeout"] == nil,
              let executable = arguments["executable"] as? String else { return arguments }
        let suppliedArguments = (arguments["args"] as? [String]) ?? []
        let matches = verificationCommands.filter {
            $0.executable == executable && $0.arguments == suppliedArguments
        }
        guard matches.count == 1, let command = matches.first else { return arguments }
        var bound = arguments
        bound["timeout"] = command.timeoutSeconds
        return bound
    }

    private func authorized(_ arguments: [String: Any]) -> Bool {
        switch name {
        case "write_file":
            guard let path = arguments["path"] as? String else { return false }
            return authority[path] == .create
        case "edit_file":
            guard let path = arguments["path"] as? String else { return false }
            return authority[path] == .modify
        case "apply_patch":
            guard let patch = arguments["patch"] as? String,
                  let operations = try? ApplyPatch.parse(patch), !operations.isEmpty else { return false }
            return operations.allSatisfy { operation in
                switch operation {
                case .add(let path, _): return authority[path] == .create
                case .delete(let path): return authority[path] == .delete
                case .update(let path, let moveTo, _):
                    return moveTo == nil && authority[path] == .modify
                }
            }
        case "run_command":
            let allowedKeys: Set<String> = [
                "executable", "args", "cwd", "timeout", "allowed_exit_codes",
            ]
            guard Set(arguments.keys).isSubset(of: allowedKeys),
                  let executable = arguments["executable"] as? String,
                  arguments["command"] == nil, arguments["shell"] == nil,
                  arguments["stdin"] == nil, arguments["stdin_path"] == nil,
                  arguments["background"] == nil else { return false }
            let suppliedArguments: [String]
            if let raw = arguments["args"] {
                guard let values = raw as? [String] else { return false }
                suppliedArguments = values
            } else {
                suppliedArguments = []
            }
            let cwd = arguments["cwd"] as? String
            guard arguments["cwd"] == nil || cwd == ".",
                  exactZeroExitCodes(arguments["allowed_exit_codes"]) else { return false }
            return verificationCommands.contains { command in
                executable == command.executable
                    && suppliedArguments == command.arguments
                    && exactInteger(arguments["timeout"]) == command.timeoutSeconds
            }
        default:
            return false
        }
    }

    private func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let encoding = String(cString: number.objCType)
        guard encoding != "c", encoding != "B" else { return nil }
        let numeric = number.doubleValue
        guard numeric.isFinite, numeric.rounded() == numeric,
              numeric >= Double(Int.min), numeric <= Double(Int.max) else { return nil }
        return Int(numeric)
    }

    private func exactZeroExitCodes(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let values = value as? [Any], values.count == 1 else { return false }
        return exactInteger(values[0]) == 0
    }
}
