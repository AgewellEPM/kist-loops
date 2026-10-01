import Foundation
import AgentCore

// Pure route selection and compatibility contracts.
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
        // Reuse the assessed task complexity. Word count made a one-file request with a
        // quoted payload look maximally complex and contradicted its direct effort plan.
        let structuralComplexity = min(100, max(10, effort.complexity))
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

}
