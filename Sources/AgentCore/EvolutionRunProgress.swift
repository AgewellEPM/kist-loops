import Foundation

/// GENERATION PROGRESS for the open-ended DGM loop. A multi-generation `--evolve` run keeps breeding from
/// a growing archive; this decides whether each generation actually MOVED the frontier and when a bounded
/// run should stop early (stagnation) rather than burning budget on generations that aren't improving.
/// PURE + deterministic — the orchestrator owns the IO; this owns the arithmetic.
public enum EvolutionRunProgress {

    /// The DGM's realized fitness so far: the best score among PASSED candidates in the archive. A passing
    /// candidate is the only kind that represents a real, benchmarked improvement (stepping-stones can be
    /// bred from but are not "progress"). nil ⇒ nothing has passed yet.
    public static func bestPassingScore(_ records: [EvolutionCandidateRecord]) -> Int? {
        let readiness = EvolutionAutonomyReadinessAssessment.current
        guard !readiness.blockers.contains(where: {
            $0.gate == .parentRelativeCapabilityFitness || $0.gate == .externalRollbackWitness
        }) else { return nil }
        return bestPassingScoreForTesting(records)
    }

    /// Pure arithmetic seam for unit tests. Production callers cannot inject an optimistic readiness object.
    static func bestPassingScoreForTesting(_ records: [EvolutionCandidateRecord]) -> Int? {
        return records.filter { $0.hasValidArchiveAuthority && $0.status == .passed }.map(\.score).max()
    }

    /// Did the best passing score STRICTLY improve? A first pass (nil → some) counts as improvement.
    public static func improved(from before: Int?, to after: Int?) -> Bool {
        switch (before, after) {
        case (_, .none): return false
        case (.none, .some): return true
        case let (.some(b), .some(a)): return a > b
        }
    }

    /// Early-stop policy: with `patience > 0`, stop once `consecutiveStagnant` generations in a row failed
    /// to improve the best passing score. `patience <= 0` disables early stop (run every generation).
    public static func shouldStop(consecutiveStagnant: Int, patience: Int) -> Bool {
        patience > 0 && consecutiveStagnant >= patience
    }

    /// Fold one generation's result into the running stagnation counter: reset to 0 on improvement,
    /// otherwise increment. Returns the new counter.
    public static func updateStagnation(_ current: Int, improved: Bool) -> Int {
        improved ? 0 : current + 1
    }
}
