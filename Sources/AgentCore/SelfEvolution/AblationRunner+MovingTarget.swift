import Foundation

/// Co-evolving (moving-target) ablation — the anti-Goodhart upgrade to the fixed held-out oracle.
///
/// The base `AblationRunner` measures a warm agent's advantage on a FIXED held-out corpus. That is a
/// strong, execution-grounded signal — but a static one: given enough rounds, a warm agent can learn
/// the corpus's surface and post an advantage it can't reproduce when the surface moves. This runner
/// closes that hole by making the evaluator co-evolve with the agent (2026 SkillAudit / SpecBench
/// lineage):
///   1. Perturb the held-out corpus this round (`SuiteMutator`, seed-driven, meaning-preserving).
///   2. Measure the cold-vs-warm advantage on the MUTATED corpus — a target whose surface the warm
///      arm has not seen. An advantage here is competence, not memorization.
///   3. Independently probe the warm arm for gaming: Δ = warm(fixed) − warm(mutated). Δ>0 means the
///      warm arm scores on the fixed surface but drops when it moves — the operational signature of
///      specification gaming, which a promote gate should veto on even if raw pass rate is high.
///
/// Arms are injected closures (same as `AblationRunner`), so this is testable without live models.
public struct MovingTargetAblation: Sendable, Equatable, Codable {
    /// Advantage measured on the MOVING target (nil if the mutated corpus was contaminated/malformed).
    public let onMovingTarget: AblationResult?
    /// Warm-arm gaming probe: fixed vs mutated pass-rate gap.
    public let warmGaming: SpecGamingResult?
    /// The seed that produced this round's perturbation (so it replays exactly).
    public let seed: UInt64

    /// The honest verdict a gate consumes: a real, non-gamed warm advantage on the moving target.
    public var advantageIsReal: Bool {
        guard let a = onMovingTarget, a.advantage > 1e-9 else { return false }
        if let g = warmGaming, g.gamed() { return false }   // advantage evaporates when the surface moves
        return true
    }

    public init(onMovingTarget: AblationResult?, warmGaming: SpecGamingResult?, seed: UInt64) {
        self.onMovingTarget = onMovingTarget; self.warmGaming = warmGaming; self.seed = seed
    }
}

public extension AblationRunner {
    /// Run one co-evolving ablation round. `seed` drives this round's suite perturbation (pass the
    /// epoch, a run counter, or any reproducible value — NOT a clock, so the round replays).
    static func runMovingTarget(
        base: [EvalCase],
        accumulatedFrom: Set<String>,
        epoch: Double,
        cold: EvalRunner.Agent,
        warm: EvalRunner.Agent,
        seed: UInt64,
        maxIterations: Int = 12,
        judge: EvalRunner.Judge? = nil
    ) async -> MovingTargetAblation? {
        guard !base.isEmpty else { return nil }
        let mutated = SuiteMutator.mutate(base, seed: seed)

        // Advantage on the moving target. Mutated case identities carry a per-seed suffix, so they are
        // disjoint from the accumulated (original-named) corpus by construction — but the base runner
        // re-checks disjointness itself and returns nil on contamination, which we surface honestly.
        let onMoving = await AblationRunner.run(
            heldOut: mutated,
            accumulatedFrom: accumulatedFrom,
            corpusHash: SuiteMutator.corpusHash(mutated),
            epoch: epoch,
            cold: cold, warm: warm,
            maxIterations: maxIterations, judge: judge
        )

        // Gaming probe (Δ = warm-on-fixed − warm-on-moving) WITHOUT re-running the expensive
        // warm-on-mutated pass: `run()` above already evaluated the warm arm on the mutated corpus, so
        // its `warmSuccess` IS the moving-target rate. We only need one more pass — warm on the fixed
        // base — to complete Δ. (When the corpus is contaminated `onMoving` is nil and the whole round
        // is invalid, so we skip the probe.)
        var gaming: SpecGamingResult?
        if let onMoving {
            let warmBase = await EvalRunner(maxIterations: maxIterations).run(base, agent: warm, judge: judge)
            let baseRate = warmBase.total == 0 ? 0 : Double(warmBase.passed) / Double(warmBase.total)
            gaming = SpecGamingResult(originalSuccess: baseRate, mutatedSuccess: onMoving.warmSuccess, n: base.count)
        }

        return MovingTargetAblation(onMovingTarget: onMoving, warmGaming: gaming, seed: seed)
    }
}

/// The operator-facing (and gate-consumable) verdict on one moving-target round, factored OUT of the live
/// `/ablation` command so the decision + presentation are testable without live models. `MovingTargetAblation`
/// already exposes the boolean `advantageIsReal`; this decomposes the NOT-real cases (GAMED vs EVAPORATED vs
/// INCONCLUSIVE) so the operator sees WHY and a promote gate can branch on it. Until this shipped, the whole
/// moving-target probe ran ONLY in unit tests (`runMovingTarget`/`advantageIsReal`/`.gamed()` had zero non-test
/// consumers), so the live `/ablation` reported a FIXED-corpus advantage with no gaming check — a memorized
/// (spec-gamed) advantage read as real in production. This is the live wire.
///
/// INVARIANT (pinned by test): for any non-nil round, `judge(mt).isReal == mt.advantageIsReal`.
public enum MovingTargetVerdict: Sendable, Equatable {
    /// The advantage SURVIVED the surface moving — competence, not memorization.
    case real(movingAdvantage: Double, delta: Double)
    /// The advantage EVAPORATES when the surface moves (Δ past the gaming threshold) — the spec-gaming signature
    /// a promote gate must veto on, over and above raw pass rate.
    case gamed(delta: Double)
    /// The moving-target advantage collapsed to ~0 WITHOUT tripping the gaming Δ — not reproducible either way.
    case evaporated
    /// No usable reading — the runner returned nil, or the mutated corpus was contaminated/malformed.
    case inconclusive(reason: String)

    public var isReal: Bool { if case .real = self { return true } else { return false } }

    /// Decide the verdict from a completed round. ORDER MATTERS and is safety-first: (1) no reading ⇒
    /// inconclusive before any advantage claim; (2) GAMING is checked BEFORE a positive-advantage claim, so a
    /// reading that both looks positive AND games is reported as GAMED (the veto-worthy reading), never `real`.
    public static func judge(_ mt: MovingTargetAblation?) -> MovingTargetVerdict {
        guard let mt else { return .inconclusive(reason: "moving-target produced no reading") }
        guard let onMoving = mt.onMovingTarget else {
            return .inconclusive(reason: "mutated corpus contaminated or malformed — no reading recorded")
        }
        if let g = mt.warmGaming, g.gamed() { return .gamed(delta: g.delta) }
        if onMoving.advantage > 1e-9 { return .real(movingAdvantage: onMoving.advantage, delta: mt.warmGaming?.delta ?? 0) }
        return .evaporated
    }
}
