import Foundation
import AgentCore

extension KistRunner {
    final class RecallAblationHealth: @unchecked Sendable {
        private let lock = NSLock()
        private var storedFailure: String?

        func recordFailure(_ detail: String) {
            lock.lock(); defer { lock.unlock() }
            guard storedFailure == nil else { return }
            storedFailure = String(detail.prefix(512))
        }

        var failure: String? {
            lock.lock(); defer { lock.unlock() }
            return storedFailure
        }
    }

    /// `/ablation` — RUN the ablation oracle: the golden held-out suite through a COLD arm (no accumulated
    /// self__ tools / recall) and a WARM arm (full), reporting the advantage WARM−COLD. This is the
    /// un-fakeable "is the flywheel compounding?" reading — and it can come back FLAT or NEGATIVE, which is
    /// the oracle telling the truth, not a failure. Costs real turns (2 arms × N cases).
    static func runAblation(_ opts: KistOptions, registry: ProviderRegistry, root: String,
                            tools: ToolRegistry, context: ToolContext,
                            providerId: String, model: String?, corpus: String = "golden") async -> Int32 {
        let color = KistREPL.stdoutColorEnabled(projectRoot: root)
        func c(_ code: String, _ s: String) -> String { color ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }
        // P0.5: the CAPABILITY corpus is where a WARM advantage can actually appear (the golden suite is
        // basic-behavior checks that both arms pass 100% → +0%). `/ablation capability` measures compounding.
        let isCapability = corpus.lowercased().hasPrefix("cap")
        let cases = isCapability ? EvalGoldenSuite.capabilityCases(projectRoot: root)
                                 : EvalGoldenSuite.cases(projectRoot: root)
        let corpusTag = isCapability ? "capability-v\(EvalGoldenSuite.version)" : "golden-v\(EvalGoldenSuite.version)"
        guard !cases.isEmpty else {
            print(c("31", "ablation · no \(isCapability ? "capability" : "golden") held-out cases")
                  + (isCapability ? c("2", " — seed .kist/eval/capability-suite.json with tasks that exercise accumulated capability") : ""))
            return 1
        }
        // The WARM accumulated state we toggle: self__ tools + the recall tool (semantic memory read-back).
        let warmOnly = tools.all().filter { $0.name.hasPrefix("self__") || $0.name == "recall" }.map { $0.name }
        print(c("36;1", "🔬 ablation") + c("2", " · \(corpusTag) · COLD (no \(warmOnly.isEmpty ? "accumulated state" : warmOnly.joined(separator: "/"))) vs WARM · \(cases.count) held-out case(s) · \(providerId)"))
        if warmOnly.isEmpty {
            print(c("33", "│ ⚠ WARM has no accumulated state yet (no self__ tools, no recall) — expect ≈0 advantage. That's honest: nothing has compounded yet."))
        }
        let trace = TraceRecorder(traceId: TraceID.make())

        // COLD arm strips the accumulated state (self__ tools + recall tool); WARM keeps everything. Neither
        // arm uses P1 injection here — this is the PROGRAM metric (is kist compounding overall), NOT the
        // per-wire metric. `/ablation recall` isolates the injection A/B (see runRecallAblation).
        func armAgent(cold: Bool) -> EvalRunner.Agent {
            let armTools: ToolRegistry = cold
                ? ToolRegistry(tools.all().filter { !$0.name.hasPrefix("self__") && $0.name != "recall" })
                : tools
            return ablationArm(registry: registry, context: context, providerId: providerId, model: model,
                               opts: opts, tools: armTools, trace: trace,
                               roleLabel: cold ? "ablation-cold" : "ablation-warm", inject: nil)
        }

        // accumulatedFrom = [] : the golden suite did NOT feed the warm state (memory/self__ came from real
        // use), so the held-out corpus is disjoint by construction. The guard still enforces it.
        let result = await AblationRunner.run(
            heldOut: cases, accumulatedFrom: [], corpusHash: corpusTag,
            epoch: Date().timeIntervalSince1970,
            cold: armAgent(cold: true), warm: armAgent(cold: false), maxIterations: opts.maxIterations)

        guard let r = result else {
            print(c("31", "└ ablation · REFUSED (contaminated corpus or malformed) — no reading recorded")); return 1
        }
        AblationHistoryStore(projectRoot: root).record(r)
        // Slope is only meaningful WITHIN one corpus — comparing a golden reading to a capability reading as
        // a "trend" is apples-to-oranges (a rising line that isn't real is the growth-hack we reject). Filter
        // to the SAME corpus before fitting.
        let sameCorpus = AblationHistoryStore(projectRoot: root).load().filter { $0.corpusHash == corpusTag }
        let slope = AblationHarness.advantageSlope(sameCorpus)
        func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
        let advColor = r.advantage > 1e-9 ? "32" : (r.negativeTransfer ? "31" : "33")
        print(c("36", "│ COLD ") + pct(r.coldSuccess) + c("2", "  vs  ") + c("36", "WARM ") + pct(r.warmSuccess) + c("2", "  (n=\(r.n))"))
        print(c(advColor, "│ advantage · \(r.advantage >= 0 ? "+" : "")\(pct(r.advantage))") + c("2", r.negativeTransfer ? " · ⚠ NEGATIVE TRANSFER (warm did worse — the state hurt here)" : (r.advantage <= 1e-9 ? " · flat (nothing compounded on this corpus yet)" : " · warm state helped on unseen work")))

        // P1 — ANTI-GOODHART TEETH (live). A positive fixed-corpus advantage is only trustworthy if it SURVIVES
        // the surface moving. Until now `runMovingTarget`/`advantageIsReal` ran ONLY in unit tests, so a
        // memorized (spec-gamed) advantage read as real in production. Probe ONLY when there's a positive
        // advantage to validate (a flat/negative reading has nothing to game). The perturbation seed is
        // reproducible (derived from the corpus, NOT a clock), so the round replays exactly.
        if r.advantage > 1e-9 {
            print(c("2", "│ probing whether that advantage is REAL — perturbing the corpus surface (co-evolving moving target) and re-measuring…"))
            let seed = FNV1a.seed("ablation-moving-target", corpusTag, String(cases.count))
            let mt = await AblationRunner.runMovingTarget(
                base: cases, accumulatedFrom: [], epoch: r.epoch,
                cold: armAgent(cold: true), warm: armAgent(cold: false),
                seed: seed, maxIterations: opts.maxIterations)
            switch MovingTargetVerdict.judge(mt) {
            case .real(let mAdv, let d):
                print(c("32", "│ ✅ advantage is REAL · +\(pct(mAdv)) on the MOVED surface (gaming Δ \(pct(d))) — competence, not memorization"))
            case .gamed(let d):
                print(c("31", "│ ⛔ advantage is GAMED · it EVAPORATES when the surface moves (Δ \(pct(d))) — spec-gaming signature; a promote gate must VETO this, don't trust the +\(pct(r.advantage))"))
            case .evaporated:
                print(c("33", "│ ⚠ advantage does NOT hold on the moved surface (drops to ~0) — not reproducible; treat as no real compounding"))
            case .inconclusive(let why):
                print(c("33", "│ ⚠ moving-target inconclusive · \(why) — advantage unvalidated"))
            }
        }

        if sameCorpus.count >= 2 {
            print(c("2", "│ flywheel slope over \(sameCorpus.count) \(corpusTag) readings: \(slope > 1e-6 ? "↑ accelerating" : (slope < -1e-6 ? "↓ decaying" : "→ flat"))"))
        }
        print(c("2", "└ recorded · .kist/self-evolution/ablation.jsonl · the honest curve (it can go down)"))
        return 0
    }

    /// One ablation arm: a fresh loop over `tools`, optionally with P1 recall injection (`inject`). The
    /// injection hook is the ONLY thing that differs between the two arms of the recall A/B, so the
    /// advantage it produces is causally the injection (not the toolset).
    private static func ablationArm(registry: ProviderRegistry, context: ToolContext,
                                    providerId: String, model: String?, opts: KistOptions,
                                    tools: ToolRegistry, trace: TraceRecorder, roleLabel: String,
                                    inject: (@Sendable (_ q: String) async -> String)?) -> EvalRunner.Agent {
        return { prompt in
            let trajectory = TrajectoryRecorder()
            var loop = makeLoop(registry: registry, providerId: providerId, model: model, context: context,
                                tools: tools, checkpoints: LoopCheckpointStore(), maxIterations: opts.maxIterations,
                                budget: opts.makeBudget(), interactor: AutoApproveInteractor(), approvalTools: [],
                                planMode: opts.planMode, extendedThinking: opts.extendedThinking,
                                toolMode: ToolMode(rawValue: opts.toolMode) ?? .auto,
                                roles: RoleBindings(default: ProviderBinding(providerId: providerId, model: model)),
                                delegationDepth: 0, sinkOverride: TerminalEventSink(),
                                recorder: trajectory, traceRecorder: trace, traceRole: roleLabel)
            loop.recallLessons = inject   // P1: injection-ON arm sets this; injection-OFF arm leaves it nil
            let outcome = await loop.run(goal: prompt)
            return EvalRunner.RunOutcome(output: outcome.summary, trajectory: trajectory.snapshot())
        }
    }

    /// `/ablation recall` — P1's ISOLATED oracle. Cold-vs-warm confounds three variables (self__ tools, the
    /// recall TOOL, the P1 injection); this instead holds the toolset CONSTANT (both arms full) and toggles
    /// ONLY the injection. advantage = injection-ON − injection-OFF = the marginal value of auto-surfacing a
    /// locally checked advisory lesson vs leaving the model to call `recall` itself. It can read FLAT (PLATEAUED:
    /// the model already gets the lesson via the tool, or doesn't need it) — that's an honest per-wire result,
    /// not a failure. REFUSES up-front on the conditions that would make the reading a FALSE flat.
    static func runRecallAblation(_ opts: KistOptions, registry: ProviderRegistry, root: String,
                                  tools: ToolRegistry, context: ToolContext,
                                  providerId: String, model: String?) async -> Int32 {
        let color = KistREPL.stdoutColorEnabled(projectRoot: root)
        func c(_ code: String, _ s: String) -> String { color ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }

        let cases = EvalGoldenSuite.recallCases(projectRoot: root)
        guard !cases.isEmpty else {
            print(c("31", "recall-ablation · no recall-corpus cases")
                  + c("2", " — seed .kist/eval/recall-suite.json with memory-dependent tasks (answerable only from a recalled lesson)"))
            return 1
        }
        // PRECONDITION 1 — an embedder must be configured, else recallBlock is inert (→) "" for every case and
        // the A/B reads a FALSE flat. Refuse rather than report a meaningless +0%.
        guard !opts.noMemory else {
            print(c("31", "recall-ablation · REFUSED — memory is disabled")
                  + c("2", " (--no-memory applies to Cortex and semantic recall)"))
            return 2
        }
        guard let semantic = Self.makeSemanticMemory(root: root, opts: opts, registry: registry) else {
            print(c("31", "recall-ablation · REFUSED — no embedder configured")
                  + c("2", " (set a Gemini key or KIST_EMBEDDER=ollama). Without it recall is inert; a +0% here would be a FALSE flat, not an honest one."))
            return 2
        }
        // PRECONDITION 2 — at least one case must recall a locally checked advisory lesson (non-empty block).
        // If none do, the injection is inert for this corpus and the reading would be a FALSE flat. This also
        // proves the injection is live before we spend 2×N real turns.
        var injectableCase: String? = nil
        for cse in cases where injectableCase == nil {
            do {
                let block = try await semantic.recallBlockChecked(for: cse.prompt)
                if let degradation = semantic.lastFailure {
                    print(c("31", "recall-ablation · REFUSED — semantic memory is degraded")
                          + c("2", " (\(degradation))"))
                    return 4
                }
                if !block.isEmpty {
                    injectableCase = cse.name
                }
            } catch {
                print(c("31", "recall-ablation · REFUSED — semantic memory unavailable")
                      + c("2", " (\(error))"))
                return 4
            }
        }
        guard let proven = injectableCase else {
            print(c("31", "recall-ablation · REFUSED — no locally checked advisory lesson matches any recall-corpus case")
                  + c("2", " — accumulate a locally checked successful run first (its unsigned advisory lesson is deposited as kind=auto-lesson), so recall has something real to surface. Injection would be inert here → a FALSE flat."))
            return 3
        }

        let corpusTag = "recall-ab-v\(EvalGoldenSuite.version)"
        print(c("36;1", "🔬 recall-ablation") + c("2", " · \(corpusTag) · injection-OFF vs injection-ON · toolset held constant · \(cases.count) case(s) · \(providerId)"))
        print(c("2", "│ live: case ‘\(proven)’ recalls a locally checked advisory lesson (injection is not inert)"))
        let trace = TraceRecorder(traceId: TraceID.make())
        let recallHealth = RecallAblationHealth()
        let inject: @Sendable (_ q: String) async -> String = { q in
            do {
                let block = try await semantic.recallBlockChecked(for: q)
                if let degradation = semantic.lastFailure {
                    recallHealth.recordFailure(degradation)
                    Self.err("semantic recall degraded during ablation: \(degradation)")
                }
                return block
            }
            catch {
                let detail = String(describing: error)
                recallHealth.recordFailure(detail)
                Self.err("semantic recall unavailable during ablation: \(detail)")
                return ""
            }
        }

        // advantage = warm(ON) − cold(OFF). Both arms full `tools`; ONLY `inject` differs.
        let result = await AblationRunner.run(
            heldOut: cases, accumulatedFrom: [], corpusHash: corpusTag,
            epoch: Date().timeIntervalSince1970,
            cold: ablationArm(registry: registry, context: context, providerId: providerId, model: model,
                              opts: opts, tools: tools, trace: trace, roleLabel: "recall-inject-off", inject: nil),
            warm: ablationArm(registry: registry, context: context, providerId: providerId, model: model,
                              opts: opts, tools: tools, trace: trace, roleLabel: "recall-inject-on", inject: inject),
            maxIterations: opts.maxIterations)

        if let failure = recallHealth.failure {
            print(c("31", "└ recall-ablation · REFUSED — semantic memory failed during measurement")
                  + c("2", " (\(failure)); no reading recorded"))
            return 4
        }
        guard let r = result else {
            print(c("31", "└ recall-ablation · REFUSED (contaminated corpus or malformed) — no reading recorded")); return 1
        }
        AblationHistoryStore(projectRoot: root).record(r)
        let sameCorpus = AblationHistoryStore(projectRoot: root).load().filter { $0.corpusHash == corpusTag }
        let slope = AblationHarness.advantageSlope(sameCorpus)
        func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
        let advColor = r.advantage > 1e-9 ? "32" : (r.negativeTransfer ? "31" : "33")
        print(c("36", "│ OFF ") + pct(r.coldSuccess) + c("2", "  vs  ") + c("36", "ON ") + pct(r.warmSuccess) + c("2", "  (n=\(r.n))"))
        let verdict = r.advantage > 1e-9
            ? " · injection helped (auto-surfacing the lesson beat leaving it to the recall tool)"
            : (r.negativeTransfer ? " · ⚠ NEGATIVE (the injected block hurt here)"
                                  : " · PLATEAUED (the model already gets the lesson via the recall tool, or doesn’t need it) — honest, not a failure")
        print(c(advColor, "│ P1 advantage · \(r.advantage >= 0 ? "+" : "")\(pct(r.advantage))") + c("2", verdict))
        if sameCorpus.count >= 2 {
            print(c("2", "│ slope over \(sameCorpus.count) \(corpusTag) readings: \(slope > 1e-6 ? "↑" : (slope < -1e-6 ? "↓" : "→ flat"))"))
        }
        print(c("2", "└ recorded · .kist/self-evolution/ablation.jsonl · P1 isolated (injection-ON − injection-OFF)"))
        return 0
    }
}

/// `/evolve <capability brief>` — the ON-DEMAND, TRANSPARENT proof path for the closed evolution loop.
/// It authors a `self__` tool (neural), gates it (contained acceptance test), symbolic-vetoes it, has an
/// adversarial critic try to break it by RUNNING a counterexample, and only on surviving all of that does it
/// activate the tool. Review is provider-independent by default; the explicit fresh-context same-model grade
/// is weaker and is labeled `independent=false`. It prints the ARTIFACTS at each step — the authored
/// script, the verdict, the activation smoke-test — because the whole point is you SEE the evidence, not a
/// "it passed". This is manual; the autonomous caller (standing autonomy) is separate and flag-gated OFF.
extension KistRunner {

    struct EvolutionProviderPlan: Equatable {
        let author: ProviderBinding
        let adversary: ProviderBinding
        let authorIdentity: String
        let adversaryIdentity: String
        let reviewGrade: EvolutionReviewGrade
        let independent: Bool
    }

    enum EvolutionCriticSelection: Equatable {
        case automatic
        case explicit(ProviderBinding)
        case invalidExplicit
    }

    /// Keep "no critic was requested" distinct from "the requested critic could not be
    /// resolved." Collapsing both to nil would let the independent path silently substitute an
    /// automatic reviewer after an invalid `--critic`/`--roles` selection.
    static func evolutionCriticSelection(explicitRequested: Bool,
                                          resolvedRoles: RoleBindings?) -> EvolutionCriticSelection {
        guard explicitRequested else { return .automatic }
        guard let resolvedRoles else { return .invalidExplicit }
        return .explicit(resolvedRoles.binding(for: .critic))
    }

    /// Resolve the two neural identities for a self-change without letting the author's model name leak
    /// into a different provider. An explicit critic wins; the default grade still requires it to be on a
    /// distinct provider. The automatic path keeps the prior strength order and remains independent-only.
    static func evolutionProviderPlan(
        primary: ProviderBinding,
        explicitCritic: ProviderBinding?,
        availableProviderIDs: [String],
        availableDefaultModels: [String: String] = [:],
        reviewGrade requestedGrade: EvolutionReviewGrade? = nil
    ) -> EvolutionProviderPlan? {
        let available = Set(availableProviderIDs)
        // The selected author is provenance, not a preference. If it is unavailable, fail closed instead
        // of silently letting a different provider become the brain that authors a self-modification.
        guard !available.isEmpty, available.contains(primary.providerId) else { return nil }
        let grade = requestedGrade ?? .independent

        func resolved(_ binding: ProviderBinding, requireConcreteModel: Bool) -> (ProviderBinding, String)? {
            guard available.contains(binding.providerId) else { return nil }
            let requestedModel = binding.model ?? availableDefaultModels[binding.providerId]
            if requireConcreteModel, requestedModel == nil { return nil }
            let concreteModel = requestedModel.flatMap {
                canonicalProviderModel(provider: binding.providerId, model: $0)
            }
            guard let identity = providerModelIdentity(
                provider: binding.providerId, model: concreteModel ?? "default") else { return nil }
            return (ProviderBinding(providerId: binding.providerId, model: concreteModel), identity)
        }
        guard let (author, authorIdentity) = resolved(
            primary, requireConcreteModel: grade == .freshContextSameModel) else { return nil }

        if let explicitCritic {
            guard let (critic, criticIdentity) = resolved(
                explicitCritic, requireConcreteModel: grade == .freshContextSameModel) else { return nil }
            switch grade {
            case .independent:
                guard critic.providerId != author.providerId else { return nil }
            case .freshContextSameModel:
                guard criticIdentity == authorIdentity else { return nil }
            }
            return EvolutionProviderPlan(
                author: author, adversary: critic,
                authorIdentity: authorIdentity, adversaryIdentity: criticIdentity,
                reviewGrade: grade, independent: grade.claimsIndependence)
        }

        // Same-model review is never inferred. It requires an explicit critic identity and explicit grade.
        guard grade == .independent else { return nil }

        let strongOrder = ["claude-cli", "codex-cli", "anthropic", "gemini", "deepseek", "grok", "openai"]
        let adversaryID = strongOrder.first(where: { $0 != author.providerId && available.contains($0) })
            ?? availableProviderIDs.first(where: { $0 != author.providerId })
        guard let adversaryID else { return nil }
        guard let (adversary, adversaryIdentity) = resolved(
            ProviderBinding(providerId: adversaryID), requireConcreteModel: false) else { return nil }
        return EvolutionProviderPlan(
            author: author, adversary: adversary,
            authorIdentity: authorIdentity, adversaryIdentity: adversaryIdentity,
            reviewGrade: .independent, independent: true
        )
    }

    static func evolutionReviewReceiptLine(_ receipt: EvolutionReviewReceipt) -> String? {
        let author = receipt.authorIdentity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let critic = receipt.criticIdentity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let authorSeparator = author.firstIndex(of: ":"),
              let criticSeparator = critic.firstIndex(of: ":"),
              authorSeparator != author.startIndex, criticSeparator != critic.startIndex,
              authorSeparator != author.index(before: author.endIndex),
              criticSeparator != critic.index(before: critic.endIndex),
              author[..<authorSeparator] != critic[..<criticSeparator] else { return nil }
        // Even this explicitly quarantined review line requires honest identity-distinct provenance. The
        // actual store has the stronger opaque authority gate; same-model evidence never gets rendered as
        // independent review, much less activation or promotion.
        guard receipt.grade == .independent, receipt.independent,
              receipt.freshConversation, receipt.separateInvocation,
              receipt.authorIdentity == author, receipt.criticIdentity == critic,
              !author.isEmpty, !critic.isEmpty, author != critic,
              !receipt.authorInvocationID.isEmpty, !receipt.criticInvocationID.isEmpty,
              receipt.authorInvocationID != receipt.criticInvocationID else { return nil }
        let payload: [String: Any] = [
            "activated": false,
            "authorIdentity": receipt.authorIdentity,
            "authorInvocationID": receipt.authorInvocationID,
            "criticIdentity": receipt.criticIdentity,
            "criticInvocationID": receipt.criticInvocationID,
            "freshConversation": receipt.freshConversation,
            "grade": receipt.grade.rawValue,
            "independent": receipt.independent,
            "outcome": EvolutionOutcome.quarantinedHardContainment.rawValue,
            "separateInvocation": receipt.separateInvocation,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "KIST_EVOLUTION_REVIEW_RECEIPT: " + json
    }

    /// `/grow` has no hard-contained execution implementation yet. A backend advertising availability is
    /// not a per-execution capability and must not let the command proceed to provider calls, candidate
    /// filesystem writes, or advisory script execution. This returns non-nil until a separately typed path
    /// is wired end-to-end with exact `ValidatedHardProcessContainment` authority; there is intentionally no
    /// optional/default-able receipt parameter on the current command.
    static func growHardContainmentExecutionBlocker() -> String? {
        let availability = HardProcessContainmentRuntime.currentAvailability
        if availability.available {
            return "a qualifying hard-containment backend is available, but /grow has no validated per-execution scope authority wired"
        }
        return availability.reason
    }

    static func runEvolve(_ opts: KistOptions, brief: String,
                          registry: ProviderRegistry, root: String,
                          tools: ToolRegistry, context: ToolContext,
                          providerId: String, model: String?,
                          semantic: SemanticMemoryService? = nil) async -> Int32 {
        // This is deliberately the first executable gate. Do not move provider resolution, model calls,
        // candidate-directory creation, ledger writes, or script execution above it.
        if let blocker = growHardContainmentExecutionBlocker() {
            print("evolve · refused · \(blocker). Nothing launched or written.")
            return 2
        }

        func line(_ s: String) { print(s) }
        let color = KistREPL.stdoutColorEnabled(projectRoot: root)
        func c(_ code: String, _ s: String) -> String { color ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }

        // The default remains two DISTINCT keyed providers. The sole explicit exception is an exact-identity
        // fresh-context same-model critic, recorded as independent=false. The critic must be CAPABLE: it has
        // to find edge cases and emit valid JSON, so the independent path ranks it by
        // strength and never fall to a weak model (e.g. mimo) when a stronger one is keyed — a weak
        // adversary can't vouch, and the gate then holds forever ("couldn't attack" ⇒ no promotion).
        let keyedProviders = registry.providers.filter { registry.hasKey(for: $0) }
        let keyed = keyedProviders.map { $0.id }
        let defaultModels = Dictionary(uniqueKeysWithValues: keyedProviders.map { ($0.id, $0.defaultModel) })
        let explicitRequested = opts.criticSpec != nil || opts.roleProfile != nil
        let resolvedExplicitRoles = explicitRequested
            ? resolveRoles(opts, registry, providerId: providerId, model: model)
            : nil
        let explicitCritic: ProviderBinding?
        switch evolutionCriticSelection(
            explicitRequested: explicitRequested, resolvedRoles: resolvedExplicitRoles) {
        case .automatic:
            explicitCritic = nil
        case .explicit(let binding):
            explicitCritic = binding
        case .invalidExplicit:
            line(c("31", "evolve · review refused · explicitly requested critic/roles could not be resolved"))
            return 2
        }
        guard let providerPlan = evolutionProviderPlan(
            primary: ProviderBinding(providerId: providerId, model: model),
            explicitCritic: explicitCritic,
            availableProviderIDs: keyed,
            availableDefaultModels: defaultModels,
            reviewGrade: opts.reviewGrade
        ) else {
            let requested = opts.reviewGrade == .freshContextSameModel
                ? "fresh_context_same_model requires an explicit critic with the same canonical provider:model identity"
                : "independent review requires an available critic on a provider distinct from the author"
            line(c("31", "evolve · review refused · \(requested)"))
            return 2
        }
        let authorProvider = providerPlan.author.providerId
        let adversaryProvider = providerPlan.adversary.providerId

        let authorLabel = authorProvider + (providerPlan.author.model.map { ":\($0)" } ?? "")
        let adversaryLabel = adversaryProvider + (providerPlan.adversary.model.map { ":\($0)" } ?? "")
        line(c("36;1", "🧬 evolve") + c("2", " · author=\(authorLabel) · critic=\(adversaryLabel) · reviewGrade=\(providerPlan.reviewGrade.rawValue) · independent=\(providerPlan.independent) · target=self__ (contained)"))
        line(c("2", "   \(brief)"))

        let sandboxRoot = (root as NSString).appendingPathComponent(".kist/self-tools/candidates")
        try? FileManager.default.createDirectory(atPath: sandboxRoot, withIntermediateDirectories: true)

        let decision = SelfEvolutionDecision(
            category: .toolLimit, kind: .extendTool,
            brief: brief + "\n\nAuthor a NEW self__ script tool that provides this capability.",
            culpritTool: "self__(manual-evolve)", discovery: nil,
            ownership: .selfAuthored, foreignServer: nil,
            signature: SelfEvolutionLedger.signature(tool: "self__evolve", evidence: brief), skipped: nil)

        let author = LiveCapabilityAuthor(
            registry: registry, providerId: authorProvider,
            model: providerPlan.author.model,
            canonicalIdentity: providerPlan.authorIdentity, sandboxRoot: sandboxRoot)
        let gate = ScriptCandidateGate()
        let veto = JeevesFloorVeto()
        let adversary = LiveCapabilityAdversary(
            registry: registry, provider: adversaryProvider,
            model: providerPlan.adversary.model,
            reviewGrade: providerPlan.reviewGrade,
            canonicalIdentity: providerPlan.adversaryIdentity)

        // P3 — arm the monotonic held-out regression guard. `ClosedEvolutionLoop` ALREADY enforces
        // HeldOutInvariant as a HARD reject (no adversary confidence overrides it); it was simply never handed
        // an organ on this path, so the strongest anti-gaming gate was dead here. We measure the CAPABILITY
        // corpus (the golden suite is 100%/100% — no signal) cold vs with-candidate. Empty corpus ⇒ nil ⇒
        // additive no-op (the guard can never manufacture a false reject when there's nothing to protect).
        let capabilityCases = EvalGoldenSuite.capabilityCases(projectRoot: root)
        let regressionTrace = TraceRecorder(traceId: TraceID.make())
        let regression: RegressionInvariant? = capabilityCases.isEmpty ? nil :
            CapabilityRegressionOrgan(cases: capabilityCases) { cases, extra in
                // Two IDENTICAL arms except for the candidate tool, so a dropped case is caused by the
                // candidate, not the surface. Baseline arm = warm toolset; candidate arm = warm + this self__ tool.
                let arm: ToolRegistry
                if let extra { arm = ToolRegistry(tools.all() + [extra as any AgentTool]) }
                else { arm = tools }
                let agent = Self.ablationArm(registry: registry, context: context, providerId: providerId,
                                             model: model, opts: opts, tools: arm, trace: regressionTrace,
                                             roleLabel: extra == nil ? "regress-base" : "regress-candidate", inject: nil)
                let report = await EvalRunner(maxIterations: opts.maxIterations).run(cases, agent: agent, judge: nil)
                return Set(report.results.filter { $0.passed }.map { $0.name })
            }
        if regression != nil {
            line(c("2", "│ 🛡️  held-out regression guard ARMED · \(capabilityCases.count) capability case(s) · rejects a REPRODUCIBLE candidate-caused break of a previously-passing case (a new tool no case exercises reads as no-signal — that class is the adversary's job)"))
        } else {
            line(c("2", "│ ⚠ held-out regression guard OFF · no capability cases (seed .kist/eval/capability-suite.json to arm P3)"))
        }

        line(c("2", "│ ✍️  authoring candidate…"))
        let result = await ClosedEvolutionLoop.run(decision: decision, author: author, gate: gate, veto: veto,
                                                   adversary: adversary, regression: regression)

        // ── ARTIFACTS: show what was actually produced + judged ─────────────────────────────────────────
        if let tool = result.toolName {
            let workdir = (sandboxRoot as NSString).appendingPathComponent(tool)
            if let (manifest, scriptPath) = SelfAuthoredManifest.loadFrom(workdir: workdir),
               let script = try? String(contentsOfFile: scriptPath, encoding: .utf8) {
                line(c("36", "│ authored tool: ") + tool + c("2", " — \(manifest.description)"))
                line(c("2", "│ contract: \(manifest.contract)"))
                line(c("2", "│ ── authored script ──"))
                for l in script.split(separator: "\n", omittingEmptySubsequences: false) { line(c("2", "│   ") + String(l)) }
                line(c("2", "│ acceptance test: \(manifest.testArgs) ⇒ expect ‘\(manifest.testExpectSubstring)’"))
            }
        }

        let verdictColor = result.promoted ? "32" : "33"
        line(c(verdictColor, "│ verdict · \(result.outcome.rawValue)") + c("2", " · \(result.reason)"))

        // Record terminal refusals now, but never record `promoted` before durable activation succeeds. A
        // candidate that cleared the model/gate loop but lacks hard-containment authority is quarantined and
        // may be retried after a real backend is wired; a premature promoted ledger row would falsely claim
        // activation and suppress that retry.
        if !result.promoted,
           let outcome = ClosedEvolutionLoop.ledgerOutcome(for: result.outcome),
           let sig = decision.signature {
            SelfEvolutionLedger(projectRoot: root).record(SelfEvolutionAttempt(
                tool: result.toolName ?? "self__?", category: "toolLimit", signature: sig,
                outcome: outcome, atEpoch: Date().timeIntervalSince1970))
        }

        guard result.promoted, let tool = result.toolName else {
            line(c("33", "└ not promoted — nothing activated (this is the loop refusing to ship an unproven tool)"))
            return 1
        }

        // Runtime activation requires a host-produced `ValidatedHardProcessContainment` bound to the exact
        // smoke execution. The current Seatbelt/Bubblewrap + process-group path is advisory: it cannot enforce
        // aggregate CPU/RAM/PID ceilings or prove every descendant is dead. It therefore cannot call
        // `SelfAuthoredToolStore.savePromoted`, regardless of how strong the model review was. Keeping the
        // candidate in the non-loadable candidates area is quarantine, not activation.
        let hardContainment = HardProcessContainmentRuntime.currentAvailability
        guard hardContainment.available else {
            line(c("31", "└ ACTIVATION REFUSED ") + tool
                 + c("2", " — \(hardContainment.reason); candidate remains quarantined and no activation receipt was written"))
            return 2
        }
        // Fail closed even after a future backend advertises availability until this command is explicitly
        // wired to receive its one-use validated scope result. Availability is not containment evidence.
        line(c("31", "└ ACTIVATION REFUSED ") + tool
             + c("2", " — hard-containment backend is available, but /grow has no validated smoke-scope authority wired"))
        return 2
    }

    /// The GROUNDED-promotion predicate (pure + directly testable — review #1/#14). A smoke run is grounded
    /// ONLY when `expect` is non-empty AND the output actually contains it. The non-empty check is the fix for
    /// `String.contains("")` being vacuously true — an empty-expect tool can never be "proven", so it's refused.
    static func groundedSmokePass(output: String, expect: String) -> Bool {
        !expect.isEmpty && output.contains(expect)
    }

    /// P2 triangle close: the deterministic "winning approach" lesson deposited on a GROUNDED promotion.
    /// Pure + testable. NO timestamps/smoke-snippets — same (tool, brief, description) ⇒ same text ⇒ same
    /// SHA256 id ⇒ upsert-dedup on re-promotion (never a duplicate). Names the tool IN the body (that's
    /// what the future model reads via recall) and states the callable-NEXT-session contract honestly.
    /// BOTH free-text fields are length-bounded (review #13): `description` is author-LLM text and otherwise
    /// unvalidated, so an unbounded blob would bloat every future recall injection.
    static func promotionLesson(tool: String, brief: String, description: String) -> String {
        let goal = boundedMemoryField(brief, limit: 160)
        let desc = boundedMemoryField(description, limit: 120)
        return "SOLVED: \(goal) — `\(tool)` passed the configured executed review and grounded smoke check (\(desc)). Advisory only; callable next session as \(tool)."
    }

    private static func boundedMemoryField(_ raw: String, limit: Int) -> String {
        String(raw.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ").prefix(limit))
    }
}
