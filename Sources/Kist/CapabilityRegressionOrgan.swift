import Foundation
import AgentCore

/// P3 — the concrete `RegressionInvariant` for the `/evolve` promote gate. Until this existed, the loop's
/// monotonic held-out check (`ClosedEvolutionLoop.run`, the HARD anti-gaming reject) was dead on the live
/// path: `runEvolve` passed no regression organ, so a candidate that made its OWN acceptance test pass while
/// quietly breaking a previously-passing capability case shipped unchallenged.
///
/// GROUNDING vs NON-DETERMINISM. The pass/fail signal is the deterministic EvalRunner verdict over real runs
/// on the frozen CAPABILITY corpus — but the AGENT is a live model, so a single run per arm is a NOISY
/// sample. A naive `before ⊆ after` HARD reject over two single samples manufactures FALSE rejects: any case
/// that flakes to failing in the candidate arm (a transient tool/timeout/rate-limit, or plain sampling
/// variance — the capability assertions include `.noToolFailures`/`.maxSteps`/`.trajectoryHealthy`) drops from
/// `after` and is blamed on the candidate. So this organ makes the two operands TRUSTWORTHY before the loop
/// compares them (adversarial review 2026-08-15, Codex + a 5-lens panel):
///   1. BASELINE IS MEASURED ONCE and cached — every consumer (the ⊆ operand and the missing-artifact
///      fallback) reuses that exact set, so `before ⊆ after` can never be broken by re-measuring baseline.
///   2. A drop is confirmed by a TWO-SIDED MAJORITY RATE TEST, not a single sample and NOT a one-pass pardon.
///      Each suspected case is sampled `confirmRetries+1` times in BOTH arms; it is a real regression only if it
///      fails a STRICT MAJORITY of candidate samples AND passes a strict majority of baseline samples. This is
///      symmetric against noise: a pure candidate flake (no candidate majority) is exonerated, an environmental
///      baseline flake (baseline not majority-healthy, so the drop can't be pinned on the candidate) is
///      exonerated, but a reproducible-PARTIAL break — the agent stumbling into a pass on a MINORITY of runs —
///      is still REFUSED. A one-sided "pardon on the first candidate pass" would launder exactly that
///      partial-break class: at the wired retry count a real reproducible break shipped ~40–66% of the time
///      (adversarial review 2026-08-15, Codex + 5-lens panel, skeptic-reproduced). This preserves the loop's
///      HARD-reject semantics (a confirmed, candidate-caused, reproducible regression is refused, no adversary
///      override) while removing the false-reject landmine; fail-safe DIRECTION on every tie/ambiguity is
///      "don't reject" — a strict majority (count*2 > total) means ties resolve toward promoting.
///
/// HONEST LIMIT (do not overclaim): this only has teeth on capability cases the model ACTUALLY exercises with
/// the candidate tool. A brand-new `self__` tool that no held-out case invokes yields `before == after`
/// (vacuous pass) — that regression class is the ADVERSARY's job, which already runs. The organ is a safety
/// net for "adding/altering a tool reproducibly breaks work that used to pass," not a completeness guarantee.
/// RESIDUAL after the two-sided fix: a break tuned to fail right at ~50% (no strict majority either way) rides
/// the tie into promotion. The majority test collapses the practical escape band (from "pass once in N" to
/// "pass the majority of N"); closing the near-tie residual is a follow-up — a run-to-run stability check on the
/// candidate's OWN acceptance test, refusing a nondeterministic-by-design tool as ungrounded at the GATE (a
/// different code path, not this organ).
///
/// Actor because baseline is cached across the two protocol calls; the loop invokes `baselinePassing()` then
/// `passingWith()` strictly sequentially (verified), so isolation here is belt-and-suspenders, not a hot path.
public actor CapabilityRegressionOrgan: RegressionInvariant {
    /// The FROZEN held-out corpus for this /evolve invocation (captured once, so both arms score the same
    /// cases at the same difficulty — the invariant's whole premise).
    public let cases: [EvalCase]
    /// Extra independent samples taken of EACH arm beyond the initial pair when a drop is suspected — total
    /// samples per arm = `confirmRetries + 1`. A case counts as a regression only if it fails a STRICT MAJORITY
    /// of candidate samples while the baseline passes a strict majority of its own. Higher ⇒ more flake-robust
    /// and more discriminating, at more cost — but only ever on suspicious candidates.
    let confirmRetries: Int
    /// Runs a subset of `cases` through an eval agent built on the warm toolset OPTIONALLY plus one extra
    /// candidate tool, and returns the set of case names that PASSED. `nil` extra ⇒ the baseline (no candidate)
    /// arm. Injected so this type is decoupled from the provider/registry/context wiring and testable without
    /// live models.
    let run: @Sendable (_ cases: [EvalCase], _ extra: ScriptTool?) async -> Set<String>

    /// Measured once in `baselinePassing()`, reused everywhere (the anti-false-reject cache).
    private var cachedBaseline: Set<String>?

    public init(cases: [EvalCase], confirmRetries: Int = 2,
                run: @escaping @Sendable (_ cases: [EvalCase], _ extra: ScriptTool?) async -> Set<String>) {
        self.cases = cases
        self.confirmRetries = confirmRetries
        self.run = run
    }

    public func baselinePassing() async -> Set<String> {
        guard !cases.isEmpty else { return [] }        // fail-safe: nothing to protect ⇒ empty set
        let baseline = await run(cases, nil)
        cachedBaseline = baseline
        return baseline
    }

    public func passingWith(_ candidate: CapabilityCandidate) async -> Set<String> {
        guard !cases.isEmpty else { return [] }        // fail-safe: matches baseline ⇒ never a false reject
        // Reuse the ONE measured baseline. Defensive: if the loop ever calls us before baselinePassing(),
        // measure it now (still cached for internal reuse). This is the exact set the loop uses as `before`.
        let before: Set<String>
        if let cached = cachedBaseline {
            before = cached
        } else {
            before = await run(cases, nil)
            cachedBaseline = before
        }

        // The candidate's home dir holds the manifest + script the author just wrote. Load it exactly as the
        // runtime store would, and add it as one more tool to the warm arm.
        guard let (manifest, _) = SelfAuthoredManifest.loadFrom(workdir: candidate.workdir) else {
            // The gate already loaded this candidate, so a miss here means the artifact vanished — anomalous,
            // NOT a candidate regression. Return the EXACT cached baseline so `before ⊆ after` holds by
            // identity (never a re-measured, drift-prone second baseline). Fail-safe: do not reject.
            return before
        }
        let tool = ScriptTool(manifest: manifest, homeDir: candidate.workdir)

        let afterRaw = await run(cases, tool)
        let apparent = before.subtracting(afterRaw)   // passed baseline, failed THIS candidate sample
        guard !apparent.isEmpty else { return before } // fast path: no drops ⇒ no extra cost, no reject

        // TWO-SIDED MAJORITY RATE TEST. Confirming a drop by a single sample manufactures FALSE rejects (a
        // candidate-arm flake is blamed on the candidate); the inverse — exonerating the instant the candidate
        // passes the case once on retry — manufactures FALSE NEGATIVES: a genuinely-but-partially broken
        // capability (the agent stumbles into a pass on a fraction of runs) is laundered, softening the very HARD
        // reject P3 exists to be (adversarial review 2026-08-15: at the wired retry count a real reproducible
        // break shipped ~40–66% of the time). So sample BOTH arms `confirmRetries+1` times per suspected case and
        // confirm a regression ONLY when the candidate fails a strict majority AND the baseline passes a strict
        // majority. Refuses a reproducible-partial break; exonerates a pure candidate flake (no candidate
        // majority) and an environmental baseline flake (baseline not majority-healthy ⇒ drop not attributable
        // to the candidate). Fail-safe direction unchanged: a tie confirms nothing ⇒ resolves toward PROMOTE.
        let apparentCases = cases.filter { apparent.contains($0.name) }
        // Seed each arm's tally with the samples already in hand: the initial candidate run (`afterRaw`) FAILED
        // every apparent case by definition, and every apparent case PASSED the cached baseline (`before`).
        var candFails: [String: Int] = [:], candTotal: [String: Int] = [:]
        var basePasses: [String: Int] = [:], baseTotal: [String: Int] = [:]
        for name in apparent {
            candFails[name] = 1; candTotal[name] = 1        // afterRaw failed it
            basePasses[name] = 1; baseTotal[name] = 1       // it was in `before`
        }
        // Additional independent samples of BOTH arms over only the suspected cases (bounded, suspicious-path
        // only). Sampling baseline too is what lets an environmental baseline flake exonerate rather than reject.
        for _ in 0..<max(1, confirmRetries) {
            let candAgain = await run(apparentCases, tool)
            let baseAgain = await run(apparentCases, nil)
            for c in apparentCases {
                candTotal[c.name, default: 0] += 1
                if !candAgain.contains(c.name) { candFails[c.name, default: 0] += 1 }
                baseTotal[c.name, default: 0] += 1
                if baseAgain.contains(c.name) { basePasses[c.name, default: 0] += 1 }
            }
        }
        // Strict majority both sides (count*2 > total). Only a reproducibly candidate-broken case drops.
        var confirmed: Set<String> = []
        for name in apparent {
            let cf = candFails[name] ?? 0, ct = candTotal[name] ?? 1
            let bp = basePasses[name] ?? 0, bt = baseTotal[name] ?? 1
            if cf * 2 > ct && bp * 2 > bt { confirmed.insert(name) }
        }
        return before.subtracting(confirmed)
    }
}
