import Foundation

/// HUMAN-IN-THE-LOOP VIEW of the DGM archive. The evolution loop never auto-promotes — a human reviews the
/// kept candidate branches — so they need to SEE the archive: what passed, what the safety conscience
/// blocked, and (open-endedness made legible) exactly who the DGM would breed next and why. PURE render
/// from the archive records, so it is fully unit-testable.
public enum EvolutionStatusReport {

    public static func render(records: [EvolutionCandidateRecord], frontierLimit: Int = 8) -> String {
        guard !records.isEmpty else {
            return "No evolution candidates yet. Run  kist --evolve \"<objective>\"  to start a generation."
        }

        let passed = records.filter { $0.status == .passed }
        let failed = records.filter { $0.status == .failed }.count
        let blocked = records.filter { $0.status == .blocked }.count
        let noChange = records.filter { $0.status == .noChange }.count

        var out: [String] = []
        out.append("evolution archive · \(records.count) candidate(s)")
        out.append("passed \(passed.count) · failed \(failed) · blocked \(blocked) · no-change \(noChange)")
        out.append("")

        // Best realized improvement.
        if let best = passed.max(by: { lhs, rhs in
            lhs.score != rhs.score ? lhs.score < rhs.score : lhs.createdAtEpoch < rhs.createdAtEpoch }) {
            out.append("best · \(best.candidateID) · score \(best.score) · branch \(best.branch)")
            out.append("       \(best.summary)")
        } else {
            out.append("best · (nothing has passed benchmarks yet)")
        }

        // Safety signal: the conscience refused to breed from cheats. Surface it loudly.
        if blocked > 0 {
            out.append("")
            out.append("⚠ \(blocked) candidate(s) BLOCKED (gamed the verifier / touched the trust spine) — never bred from")
        }

        // The open-ended frontier: who the DGM would breed next, and why (fitness × exploration).
        let frontier = EvolutionParentSelector.frontier(records)
        let counts = EvolutionParentSelector.childCounts(records)
        if !frontier.isEmpty {
            out.append("")
            out.append("next to breed (fitness × under-explored):")
            for r in frontier.prefix(max(0, frontierLimit)) {
                let children = counts[r.candidateID] ?? 0
                let w = EvolutionParentSelector.weight(score: r.score, childCount: children, config: .default)
                out.append("  \(String(format: "%6.1f", w))  \(r.candidateID)  [\(r.status.rawValue) score \(r.score), \(children) child\(children == 1 ? "" : "ren")]  \(r.summary.prefix(60))")
            }
        } else {
            out.append("")
            out.append("frontier · empty (no eligible parents — next run starts from a fresh root)")
        }

        return out.joined(separator: "\n")
    }
}
