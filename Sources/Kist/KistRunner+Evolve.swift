import Foundation
import AgentCore

extension KistRunner {
    /// `/ablation` — RUN the ablation oracle: the golden held-out suite through a COLD arm (no accumulated
    /// self__ tools / recall) and a WARM arm (full), reporting the advantage WARM−COLD. This is the
    /// un-fakeable "is the flywheel compounding?" reading — and it can come back FLAT or NEGATIVE, which is
    /// the oracle telling the truth, not a failure. Costs real turns (2 arms × N cases).
    static func runAblation(_ opts: KistOptions, registry: ProviderRegistry, root: String,
                            tools: ToolRegistry, context: ToolContext,
                            providerId: String, model: String?) async -> Int32 {
        let color = KistREPL.stdoutColorEnabled(projectRoot: root)
        func c(_ code: String, _ s: String) -> String { color ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }
        let cases = EvalGoldenSuite.cases(projectRoot: root)
        guard !cases.isEmpty else { print(c("31", "ablation · no golden held-out cases")); return 1 }
        // The WARM accumulated state we toggle: self__ tools + the recall tool (semantic memory read-back).
        let warmOnly = tools.all().filter { $0.name.hasPrefix("self__") || $0.name == "recall" }.map { $0.name }
        print(c("36;1", "🔬 ablation") + c("2", " · COLD (no \(warmOnly.isEmpty ? "accumulated state" : warmOnly.joined(separator: "/"))) vs WARM · \(cases.count) held-out case(s) · \(providerId)"))
        if warmOnly.isEmpty {
            print(c("33", "│ ⚠ WARM has no accumulated state yet (no self__ tools, no recall) — expect ≈0 advantage. That's honest: nothing has compounded yet."))
        }
        let trace = TraceRecorder(traceId: TraceID.make())

        func armAgent(cold: Bool) -> EvalRunner.Agent {
            let armTools: ToolRegistry = cold
                ? ToolRegistry(tools.all().filter { !$0.name.hasPrefix("self__") && $0.name != "recall" })
                : tools
            return { prompt in
                let trajectory = TrajectoryRecorder()
                let loop = makeLoop(registry: registry, providerId: providerId, model: model, context: context,
                                    tools: armTools, checkpoints: LoopCheckpointStore(), maxIterations: opts.maxIterations,
                                    budget: opts.makeBudget(), interactor: AutoApproveInteractor(), approvalTools: [],
                                    planMode: opts.planMode, extendedThinking: opts.extendedThinking,
                                    toolMode: ToolMode(rawValue: opts.toolMode) ?? .auto,
                                    roles: RoleBindings(default: ProviderBinding(providerId: providerId, model: model)),
                                    delegationDepth: 0, sinkOverride: TerminalEventSink(),
                                    recorder: trajectory, traceRecorder: trace, traceRole: cold ? "ablation-cold" : "ablation-warm")
                let outcome = await loop.run(goal: prompt)
                return EvalRunner.RunOutcome(output: outcome.summary, trajectory: trajectory.snapshot())
            }
        }

        // accumulatedFrom = [] : the golden suite did NOT feed the warm state (memory/self__ came from real
        // use), so the held-out corpus is disjoint by construction. The guard still enforces it.
        let result = await AblationRunner.run(
            heldOut: cases, accumulatedFrom: [], corpusHash: "golden-v\(EvalGoldenSuite.version)",
            epoch: Date().timeIntervalSince1970,
            cold: armAgent(cold: true), warm: armAgent(cold: false), maxIterations: opts.maxIterations)

        guard let r = result else {
            print(c("31", "└ ablation · REFUSED (contaminated corpus or malformed) — no reading recorded")); return 1
        }
        AblationHistoryStore(projectRoot: root).record(r)
        let history = AblationHistoryStore(projectRoot: root).load()
        let slope = AblationHarness.advantageSlope(history)
        func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
        let advColor = r.advantage > 1e-9 ? "32" : (r.negativeTransfer ? "31" : "33")
        print(c("36", "│ COLD ") + pct(r.coldSuccess) + c("2", "  vs  ") + c("36", "WARM ") + pct(r.warmSuccess) + c("2", "  (n=\(r.n))"))
        print(c(advColor, "│ advantage · \(r.advantage >= 0 ? "+" : "")\(pct(r.advantage))") + c("2", r.negativeTransfer ? " · ⚠ NEGATIVE TRANSFER (warm did worse — the state hurt here)" : (r.advantage <= 1e-9 ? " · flat (nothing compounded on this corpus yet)" : " · warm state helped on unseen work")))
        if history.count >= 2 {
            print(c("2", "│ flywheel slope over \(history.count) readings: \(slope > 1e-6 ? "↑ accelerating" : (slope < -1e-6 ? "↓ decaying" : "→ flat"))"))
        }
        print(c("2", "└ recorded · .kist/self-evolution/ablation.jsonl · the honest curve (it can go down)"))
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
                          providerId: String, model: String?) async -> Int32 {
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

        line(c("2", "│ ✍️  authoring candidate…"))
        let result = await ClosedEvolutionLoop.run(decision: decision, author: author, gate: gate, veto: veto, adversary: adversary)

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
            line(c("32", "└ ACTIVATED ") + tool + c("2", " → \(home)"))
            line(c("2", "  smoke: \(manifest.testArgs) ⇒ ") + (smoke.output.contains(manifest.testExpectSubstring)
                 ? c("32", "‘\(smoke.output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).prefix(80))’ ✓ (sandboxed)")
                 : c("31", "‘\(smoke.output.prefix(80))’ ✗ expected \(manifest.testExpectSubstring)")))
            line(c("2", "  callable next session as \(tool); relaunch to pick it up."))
            return 0
        } catch {
            line(c("31", "└ activation write failed: \(error)"))
            return 1
        }
    }
}
