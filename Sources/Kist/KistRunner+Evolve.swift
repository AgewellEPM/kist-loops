import Foundation
import AgentCore

extension KistRunner {
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
    /// verified lesson vs leaving the model to call `recall` itself. It can legitimately read FLAT (PLATEAUED:
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
        guard let embedder = Self.makeEmbedder(registry: registry) else {
            print(c("31", "recall-ablation · REFUSED — no embedder configured")
                  + c("2", " (set a Gemini key or KIST_EMBEDDER=ollama). Without it recall is inert; a +0% here would be a FALSE flat, not an honest one."))
            return 2
        }
        let semantic = SemanticMemoryService(embedder: embedder,
                                             store: FileBackedVectorStore(path: root + "/.kist/memory/vectors.json"))
        // PRECONDITION 2 — at least one case must ACTUALLY recall a verified auto-lesson (non-empty block).
        // If none do, the injection is inert for this corpus and the reading would be a FALSE flat. This also
        // proves the injection is live before we spend 2×N real turns.
        var injectableCase: String? = nil
        for cse in cases where injectableCase == nil {
            if !(await semantic.recallBlock(for: cse.prompt)).isEmpty { injectableCase = cse.name }
        }
        guard let proven = injectableCase else {
            print(c("31", "recall-ablation · REFUSED — no verified auto-lesson matches any recall-corpus case")
                  + c("2", " — accumulate a verified win first (its lesson is deposited as kind=auto-lesson), so recall has something real to surface. Injection would be inert here → a FALSE flat."))
            return 3
        }

        let corpusTag = "recall-ab-v\(EvalGoldenSuite.version)"
        print(c("36;1", "🔬 recall-ablation") + c("2", " · \(corpusTag) · injection-OFF vs injection-ON · toolset held constant · \(cases.count) case(s) · \(providerId)"))
        print(c("2", "│ live: case ‘\(proven)’ recalls a verified lesson (injection is not inert)"))
        let trace = TraceRecorder(traceId: TraceID.make())
        let inject: @Sendable (_ q: String) async -> String = { q in await semantic.recallBlock(for: q) }

        // advantage = warm(ON) − cold(OFF). Both arms full `tools`; ONLY `inject` differs.
        let result = await AblationRunner.run(
            heldOut: cases, accumulatedFrom: [], corpusHash: corpusTag,
            epoch: Date().timeIntervalSince1970,
            cold: ablationArm(registry: registry, context: context, providerId: providerId, model: model,
                              opts: opts, tools: tools, trace: trace, roleLabel: "recall-inject-off", inject: nil),
            warm: ablationArm(registry: registry, context: context, providerId: providerId, model: model,
                              opts: opts, tools: tools, trace: trace, roleLabel: "recall-inject-on", inject: inject),
            maxIterations: opts.maxIterations)

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
/// INDEPENDENT (different-provider) adversary try to break it by RUNNING a counterexample, and only on
/// surviving all of that does it activate the tool. It prints the ARTIFACTS at each step — the authored
/// script, the verdict, the activation smoke-test — because the whole point is you SEE the evidence, not a
/// "it passed". This is manual; the autonomous caller (standing autonomy) is separate and flag-gated OFF.
extension KistRunner {

    static func runEvolve(_ opts: KistOptions, brief: String,
                          registry: ProviderRegistry, root: String,
                          tools: ToolRegistry, context: ToolContext,
                          providerId: String, model: String?,
                          semantic: SemanticMemoryService? = nil) async -> Int32 {
        func line(_ s: String) { print(s) }
        let color = KistREPL.stdoutColorEnabled(projectRoot: root)
        func c(_ code: String, _ s: String) -> String { color ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }

        // Two DISTINCT keyed providers — author + an INDEPENDENT adversary (never self-certify). The
        // adversary must be CAPABLE: it has to find edge cases and emit valid JSON, so we rank it by
        // strength and never fall to a weak model (e.g. mimo) when a stronger one is keyed — a weak
        // adversary can't vouch, and the gate then holds forever ("couldn't attack" ⇒ no promotion).
        let keyed = registry.providers.filter { registry.hasKey(for: $0) }.map { $0.id }
        let authorProvider = keyed.contains(providerId) ? providerId : (keyed.first ?? providerId)
        let strongOrder = ["claude-cli", "codex-cli", "anthropic", "gemini", "deepseek", "grok", "openai"]
        let adversaryProvider = strongOrder.first(where: { $0 != authorProvider && keyed.contains($0) })
            ?? keyed.first(where: { $0 != authorProvider })
        guard let adversaryProvider else {
            line(c("31", "evolve · needs ≥2 keyed providers (an author AND an independent adversary) — only ‘\(authorProvider)’ is keyed. Add a second provider key so the adversary can't be the author."))
            return 2
        }

        line(c("36;1", "🧬 evolve") + c("2", " · author=\(authorProvider) · independent adversary=\(adversaryProvider) · target=self__ (contained)"))
        line(c("2", "   \(brief)"))

        let sandboxRoot = (root as NSString).appendingPathComponent(".kist/self-tools/candidates")
        try? FileManager.default.createDirectory(atPath: sandboxRoot, withIntermediateDirectories: true)

        let decision = SelfEvolutionDecision(
            category: .toolLimit, kind: .extendTool,
            brief: brief + "\n\nAuthor a NEW self__ script tool that provides this capability.",
            culpritTool: "self__(manual-evolve)", discovery: nil,
            ownership: .selfAuthored, foreignServer: nil,
            signature: SelfEvolutionLedger.signature(tool: "self__evolve", evidence: brief), skipped: nil)

        let author = LiveCapabilityAuthor(registry: registry, providerId: authorProvider, model: model, sandboxRoot: sandboxRoot)
        let gate = ScriptCandidateGate()
        let veto = JeevesFloorVeto()
        let adversary = LiveCapabilityAdversary(registry: registry, provider: adversaryProvider, model: model)

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

        // Record the resolved outcome so the loop-guard dedup fires next time (P5).
        if let outcome = ClosedEvolutionLoop.ledgerOutcome(for: result.outcome), let sig = decision.signature {
            SelfEvolutionLedger(projectRoot: root).record(SelfEvolutionAttempt(
                tool: result.toolName ?? "self__?", category: "toolLimit", signature: sig,
                outcome: outcome, atEpoch: Date().timeIntervalSince1970))
        }

        guard result.promoted, let tool = result.toolName else {
            line(c("33", "└ not promoted — nothing activated (this is the loop refusing to ship an unproven tool)"))
            return 1
        }

        // ── ACTIVATE (into the self__ store) + SMOKE-TEST (prove it's really callable) ───────────────────
        let candidateDir = (sandboxRoot as NSString).appendingPathComponent(tool)
        guard let (manifest, scriptPath) = SelfAuthoredManifest.loadFrom(workdir: candidateDir),
              let script = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
            line(c("31", "└ promoted but candidate artifacts vanished — not activating")); return 1
        }
        let store = SelfAuthoredToolStore(projectRoot: root)
        do {
            let home = try store.save(manifest: manifest, scriptBody: script)
            // Smoke test through the SAME contained runner it'll serve from.
            let cli = ScriptTool.cliArgs(from: manifest.testArgs, manifest: manifest)
            let smoke = await ScriptTool.runContained(interpreter: manifest.interpreter,
                                                      scriptPath: (home as NSString).appendingPathComponent(manifest.scriptFile),
                                                      args: cli)
            // GROUNDED gate: the smoke run must actually produce the expected output. `expect` must be
            // NON-EMPTY — `contains("")` is vacuously true, so an empty-expect tool is UNGROUNDED and refused
            // (review #1). This one boolean now governs BOTH activation and the lesson deposit.
            let smokeOk = Self.groundedSmokePass(output: smoke.output, expect: manifest.testExpectSubstring)
            if !smokeOk {
                // review #7: a promoted-but-smoke-FAILED (or ungrounded empty-expect) tool must NOT be left on
                // disk to load + advertise next session. Roll the activation back and fail.
                try? FileManager.default.removeItem(atPath: home)
                let why = manifest.testExpectSubstring.isEmpty
                    ? "empty expect — ungrounded, refused" : "did not produce ‘\(manifest.testExpectSubstring)’"
                line(c("31", "└ ACTIVATION ROLLED BACK ") + tool + c("2", " — smoke \(why): ‘\(smoke.output.prefix(80))’"))
                return 1
            }
            line(c("32", "└ ACTIVATED ") + tool + c("2", " → \(home)"))
            line(c("2", "  smoke: \(manifest.testArgs) ⇒ ")
                 + c("32", "‘\(smoke.output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).prefix(80))’ ✓ (sandboxed)"))
            // P2 triangle close: on a GROUNDED promotion deposit a recallable "winning approach" auto-lesson so
            // the P1 recall→plan wire surfaces "you grew self__X for exactly this" on a future similar task.
            // kind MUST be "auto-lesson" (SemanticMemory.formatLessonBlock filters on it). Deterministic text ⇒
            // SHA256 upsert dedup. Fail-soft (try?) + embedder-gated (nil semantic ⇒ no-op), like rememberLesson.
            if let semantic {
                let lesson = Self.promotionLesson(tool: tool, brief: brief, description: manifest.description)
                try? await semantic.remember(lesson, metadata: ["kind": "auto-lesson", "tool": tool])
            }
            line(c("2", "  callable next session as \(tool); relaunch to pick it up."))
            return 0
        } catch {
            line(c("31", "└ activation write failed: \(error)"))
            return 1
        }
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
        let goal = brief.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
        return "SOLVED: \(goal) — authored + adversary-proven `\(tool)` (\(desc)). Callable next session as \(tool)."
    }
}
