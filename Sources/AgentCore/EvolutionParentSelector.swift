import Foundation

/// OPEN-ENDED PARENT SELECTION — the defining move of a Sakana-style Darwin-Gödel Machine, and the piece
/// the EvolutionLab was missing. Greedy hill-climbing (always mutate the single best) gets stuck in local
/// optima; a DGM keeps an ARCHIVE and samples parents from ALL viable prior candidates, deliberately
/// favouring UNDER-EXPLORED stepping-stones so a mediocre-but-novel candidate can become the parent of a
/// breakthrough. This selector makes that choice — PURE and deterministic (seeded), so it is fully
/// unit-testable and reproducible (no wall-clock, no system RNG).
public enum EvolutionParentSelector {

    public struct Config: Sendable, Equatable {
        /// How strongly to favour under-explored candidates (few children). 0 = pure greedy exploitation
        /// by score; higher = more open-ended exploration of the frontier.
        public var explorationWeight: Double
        /// Experimental inspection mode for changed-but-`failed` candidates.
        /// Autonomous/default selection is passed-only because a candidate can
        /// suppress a sandbox denial and surface an ordinary assertion exit.
        public var includeFailedSteppingStones: Bool
        public init(explorationWeight: Double = 1.0, includeFailedSteppingStones: Bool = false) {
            // Clamp exploration ≥ 0: a negative value could drive selection weights to zero/negative and
            // silently degenerate the probabilistic pick to "first eligible" (GPT review).
            self.explorationWeight = max(0, explorationWeight)
            self.includeFailedSteppingStones = includeFailedSteppingStones
        }
        public static let `default` = Config()
    }

    /// Candidates eligible to be a parent. A `blocked` candidate (it gamed the verifier / touched the
    /// trust spine) is NEVER eligible — breeding from a cheat would let the reward-hack propagate. A
    /// `noChange` candidate has nothing to build on. `passed` always qualifies;
    /// failed records require an explicit non-default experimental opt-in.
    public static func eligibleParents(_ archive: [EvolutionCandidateRecord], config: Config = .default,
                                       allowedCandidateIDs: Set<String>? = nil) -> [EvolutionCandidateRecord] {
        archive.filter { record in
            guard record.hasValidArchiveAuthority,
                  EvolutionRecordAuthority.parentEligible(
                    record, includeFailed: config.includeFailedSteppingStones),
                  allowedCandidateIDs?.contains(record.candidateID) ?? true else { return false }
            return true
        }
    }

    /// Count of archived children per candidate (records whose parentID == that candidate's id).
    public static func childCounts(_ archive: [EvolutionCandidateRecord]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for r in archive where r.hasValidArchiveAuthority && r.hasValidEvolutionEvidence {
            if let p = r.parentID { counts[p, default: 0] += 1 }
        }
        return counts
    }

    /// Selection weight for a candidate: fitness (its score, floored at 1 so a 0-score stepping-stone can
    /// still be picked) scaled by an EXPLORATION bonus that decays with the number of children it already
    /// has — so the loop keeps reaching for the under-explored frontier instead of re-mutating one winner.
    /// Upper bound on the fitness input. Real evaluator scores are ~1–200; this only guards against an
    /// extreme score blowing the Double dynamic range so a low-weight stepping-stone gets lost in the
    /// cumulative sum and is starved to 0% selection (Gemini review). Insurance, not a live scenario.
    static let maxFitness = 10_000_000

    static func weight(score: Int, childCount: Int, config: Config) -> Double {
        let fitness = Double(min(max(1, score), maxFitness))
        // 1 child-free ⇒ full bonus; grows-explored ⇒ bonus → 1. explorationWeight (already clamped ≥ 0
        // in Config) tunes the spread; guard the bonus ≥ 0 too so weights can never go negative.
        let explorationBonus = max(0, 1.0 + config.explorationWeight / Double(1 + max(0, childCount)))
        return fitness * explorationBonus
    }

    /// Deterministically sample a parent from the archive by weight. `seed` makes it reproducible (same
    /// archive + seed ⇒ same parent), which the DGM orchestrator advances each generation. Returns nil
    /// when no candidate is eligible (the caller then seeds a fresh root candidate).
    public static func selectParent(from archive: [EvolutionCandidateRecord], seed: UInt64,
                                    config: Config = .default,
                                    allowedCandidateIDs: Set<String>? = nil) -> EvolutionCandidateRecord? {
        let eligible = eligibleParents(archive, config: config, allowedCandidateIDs: allowedCandidateIDs)
        guard !eligible.isEmpty else { return nil }
        let counts = childCounts(archive)
        let weights = eligible.map { weight(score: $0.score, childCount: counts[$0.candidateID] ?? 0, config: config) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return eligible.first }

        var rng = SplitMix64(seed: seed)
        let pick = rng.nextUnitDouble() * total
        var running = 0.0
        for (idx, w) in weights.enumerated() {
            running += w
            if pick < running { return eligible[idx] }
        }
        return eligible.last
    }

    /// Stable, process-independent seed from string tokens (FNV-1a 64). Tokens are length-prefixed so
    /// boundaries remain unambiguous even when a token contains a separator-like character.
    public static func seed(_ tokens: String...) -> UInt64 {
        FNV1a.seed(tokens)   // canonical length-prefixed FNV-1a (constants were inlined here)
    }

    /// Stable per-candidate seed for evolution parent selection. Deliberately excludes runID/candidateID:
    /// those contain UUID entropy for branch uniqueness, while parent selection should replay for the same
    /// archive, repo base, objective, generation, and candidate slot. `generation` varies the seed across
    /// generations so gen-2's slot 1 explores a different parent than gen-1's slot 1.
    public static func selectionSeed(baseSHA: String, objective: String, variantIndex: Int,
                                     variantCount: Int, generation: Int = 1) -> UInt64 {
        if generation <= 1 {
            return seed("evolve-parent", baseSHA, objective, String(variantIndex), String(variantCount))
        }
        return seed("evolve-parent", baseSHA, objective, String(generation), String(variantIndex), String(variantCount))
    }

    /// The exploration FRONTIER — eligible parents ranked by selection weight (best exploration targets
    /// first). Useful for surfacing "who the DGM would breed next" and for tests.
    public static func frontier(_ archive: [EvolutionCandidateRecord], config: Config = .default,
                                allowedCandidateIDs: Set<String>? = nil) -> [EvolutionCandidateRecord] {
        let eligible = eligibleParents(archive, config: config, allowedCandidateIDs: allowedCandidateIDs)
        let counts = childCounts(archive)
        return eligible.sorted { a, b in
            let wa = weight(score: a.score, childCount: counts[a.candidateID] ?? 0, config: config)
            let wb = weight(score: b.score, childCount: counts[b.candidateID] ?? 0, config: config)
            if wa != wb { return wa > wb }
            return a.createdAtEpoch > b.createdAtEpoch   // stable tie-break: newer first
        }
    }
}

/// Small, fast, deterministic PRNG (SplitMix64) — reproducible seeded selection without the system RNG
/// (which would make evolution runs non-replayable).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// A double in [0, 1).
    mutating func nextUnitDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)   // 53-bit mantissa
    }
}
