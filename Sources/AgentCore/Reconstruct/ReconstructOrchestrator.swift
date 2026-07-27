import Foundation

/// Drives the reconstruct→render→compare loop: rebuild the candidate, screenshot it, visually compare it to
/// the real reference, and on a miss feed the concrete DIFFERENCES back into the next reconstruction (fix,
/// don't rebuild blind) until the measured similarity reaches the fidelity threshold or the budget runs out.
///
/// FAIL-CLOSED ON FIDELITY: a match is declared ONLY when the comparison completed (`ok`) AND
/// `similarity >= threshold`. A failed comparison, a failed render, or a below-threshold score is never a
/// match — the result carries the BEST similarity actually measured, so we never claim a clone we didn't earn.
public struct ReconstructOrchestrator: Sendable {
    public let stages: ReconstructStages
    public let threshold: Double   // similarity required to accept a match (e.g. 0.95)
    public let maxRounds: Int

    public init(stages: ReconstructStages, threshold: Double = 0.95, maxRounds: Int = 4) {
        self.stages = stages
        self.threshold = min(1, max(0, threshold))
        self.maxRounds = max(1, maxRounds)
    }

    public func run(goal: String, reference: VisualReference) async -> ReconstructResult {
        var openDiffs: [VisualDiff] = []
        var rounds: [ReconstructRound] = []
        var best = 0.0

        for round in 1...maxRounds {
            let build = await stages.reconstruct(goal: goal, reference: reference, feedback: openDiffs)
            guard build.ok else {
                rounds.append(ReconstructRound(round: round, build: build, rendered: nil, comparison: nil))
                // a failed build is a "major" diff to fix next round; keep prior visual diffs too.
                openDiffs = mergeDiffs([VisualDiff(area: "build", description: build.note.isEmpty ? "reconstruction build failed" : build.note, severity: "major")], into: openDiffs)
                continue
            }
            let rendered = await stages.render(build)
            guard rendered.ok else {
                rounds.append(ReconstructRound(round: round, build: build, rendered: rendered, comparison: nil))
                openDiffs = mergeDiffs([VisualDiff(area: "render", description: rendered.note.isEmpty ? "could not screenshot the reconstruction" : rendered.note, severity: "major")], into: openDiffs)
                continue
            }
            let cmp = await stages.compare(reference: reference, rendered: rendered)
            rounds.append(ReconstructRound(round: round, build: build, rendered: rendered, comparison: cmp))

            // A comparison that didn't complete is NOT a match — treat it as a major diff, don't trust the score.
            if cmp.ok { best = max(best, cmp.similarity) }
            if cmp.ok && cmp.similarity >= threshold {
                return .matched(branch: build.branch, similarity: cmp.similarity, rounds: rounds)
            }
            let newDiffs = cmp.ok ? cmp.diffs
                                  : [VisualDiff(area: "compare", description: cmp.note.isEmpty ? "visual comparison failed" : cmp.note, severity: "major")]
            openDiffs = mergeDiffs(newDiffs, into: openDiffs)
        }

        return .unmatched(bestSimilarity: best, rounds: rounds,
                          reason: "did not reach \(pct(threshold)) similarity within \(maxRounds) round(s) (best \(pct(best)))")
    }

    /// Accumulate diffs (latest first), deduped by area+description, so a build/render failure in a later
    /// round doesn't drop the concrete visual diffs still to fix.
    func mergeDiffs(_ new: [VisualDiff], into prior: [VisualDiff]) -> [VisualDiff] {
        let carried = prior.filter { p in !new.contains { $0.area == p.area && $0.description == p.description } }
        return new + carried
    }

    private func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
}
