import Foundation

/// EVOLUTIONARY ANCESTRY — makes the DGM's open-ended search legible as a TREE (who descended from whom)
/// plus the per-generation best-score TRAJECTORY (is the lineage actually climbing, or churning?). The
/// frontier view answers "who's bred next"; this answers "where did we come from and are we improving".
/// PURE render from the archive records; cycle-safe against a corrupt parentID chain.
public enum EvolutionLineage {

    /// Render the ancestry forest + a best-passing-score-per-generation trajectory. Roots are candidates
    /// whose parent is absent from the archive (first-of-lineage). Children indent under their parent.
    public static func render(records: [EvolutionCandidateRecord],
                              authoritativeRecords explicitAuthority: [EvolutionCandidateRecord]? = nil,
                              authorityState: EvolutionArchiveAuthorityState? = nil) -> String {
        if case .invalid(let reason) = authorityState, records.isEmpty {
            return "evolution lineage · INVALID / NON-AUTHORITATIVE\ntrajectory and parent selection refused: \(reason)"
        }
        guard !records.isEmpty else {
            return "No evolution lineage yet. Run  kist --evolve \"<objective>\"  to start a generation."
        }
        let authoritative = explicitAuthority ?? records.filter(\.hasValidArchiveAuthority)
        var out: [String] = ["evolution lineage · \(records.count) candidate(s)", ""]
        out.append("authority · \(authoritative.count) trusted · \(records.count - authoritative.count) display-only/untrusted")
        if case .invalid(let reason) = authorityState {
            out.append("⚠ ARCHIVE INVALID — trajectory and parent selection refused: \(reason)")
        }
        out.append(contentsOf: trajectoryLines(authoritative))
        out.append("")
        out.append("ancestry:")
        out.append(contentsOf: forestLines(records))
        return out.joined(separator: "\n")
    }

    /// Best PASSED score at each generation (parsed from candidateID "…-gN-vM"; ungrouped runs → one bucket),
    /// so you can see the fitness curve rise (or plateau) across generations.
    static func trajectoryLines(_ records: [EvolutionCandidateRecord]) -> [String] {
        var bestByGen: [Int: Int] = [:]
        for r in records where r.hasValidArchiveAuthority && r.status == .passed {
            let gen = generation(of: r.candidateID)
            bestByGen[gen] = max(bestByGen[gen] ?? Int.min, r.score)
        }
        guard !bestByGen.isEmpty else { return ["trajectory · nothing has passed benchmarks yet"] }
        var lines = ["trajectory (best passing score per generation):"]
        var prev: Int? = nil
        for gen in bestByGen.keys.sorted() {
            let score = bestByGen[gen]!
            let delta = prev.map { score > $0 ? "  ↑+\(score - $0)" : (score < $0 ? "  ↓\(score - $0)" : "  =") } ?? ""
            lines.append("  gen \(gen): \(score)\(delta)")
            prev = score
        }
        return lines
    }

    /// Extract the generation index from a candidateID. "runID-gN-vM" → N; "runID-vM" (single-gen) → 1.
    static func generation(of candidateID: String) -> Int {
        for part in candidateID.split(separator: "-") where part.hasPrefix("g") {
            if let n = Int(part.dropFirst()) { return n }
        }
        return 1
    }

    /// Indented ancestry forest. Cycle-safe: a candidate is emitted at most once even if parentID pointers
    /// form a loop (corrupt archive), so rendering can never infinite-recurse.
    static func forestLines(_ records: [EvolutionCandidateRecord]) -> [String] {
        let byID = Dictionary(records.map { ($0.candidateID, $0) }, uniquingKeysWith: { a, _ in a })
        var childrenOf: [String: [EvolutionCandidateRecord]] = [:]
        var roots: [EvolutionCandidateRecord] = []
        for r in records {
            if let p = r.parentID, byID[p] != nil { childrenOf[p, default: []].append(r) }
            else { roots.append(r) }   // parent absent (or nil) ⇒ root of a lineage
        }
        let ordered: ([EvolutionCandidateRecord]) -> [EvolutionCandidateRecord] = { list in
            list.sorted { $0.createdAtEpoch != $1.createdAtEpoch ? $0.createdAtEpoch < $1.createdAtEpoch : $0.candidateID < $1.candidateID }
        }
        var visited = Set<String>()
        var lines: [String] = []
        func walk(_ node: EvolutionCandidateRecord, depth: Int) {
            guard visited.insert(node.candidateID).inserted else { return }   // cycle / diamond guard
            let mark = statusMark(node.status)
            lines.append("\(String(repeating: "  ", count: depth))\(depth == 0 ? "" : "└ ")\(mark) \(node.candidateID) (score \(node.score))  \(node.summary.prefix(50))")
            for child in ordered(childrenOf[node.candidateID] ?? []) { walk(child, depth: depth + 1) }
        }
        for root in ordered(roots) { walk(root, depth: 0) }
        // Any record not reached (part of a pure cycle with no root) — surface rather than silently drop.
        for r in ordered(records) where !visited.contains(r.candidateID) {
            lines.append("• \(r.candidateID) (score \(r.score))  [unreachable — parentID cycle]")
        }
        return lines
    }

    private static func statusMark(_ s: EvolutionCandidateStatus) -> String {
        switch s { case .passed: return "✓"; case .failed: return "·"; case .blocked: return "⚠"; case .noChange: return "∅" }
    }
}
