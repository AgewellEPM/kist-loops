import Foundation

/// Phase 2.2 — the SAFE, GATED bridge from the great-loop's learning to self-improvement (DGM). The great
/// loop evolves policy hints per task-signature (PolicyEvolver); when a hint proves itself — enough
/// verified-done wins at a high rate — it becomes a CANDIDATE for promotion into Mythos's own prompts/policy.
///
/// CRITICAL: this NEVER auto-applies anything. It appends to a reviewable queue that a human (or a gated DGM
/// pass) inspects and promotes deliberately. Per the standing rule + the research (DGM AND shipping
/// Claude-Code/Codex all reward-hacked live), a self-modifying loop must not close its own promotion loop.
/// Fail-closed: below threshold ⇒ not a candidate.
public struct PromotionCandidate: Codable, Sendable, Equatable {
    public let signature: String
    public let hint: String
    public let wins: Int
    public let trials: Int
    public let at: Double
    public init(signature: String, hint: String, wins: Int, trials: Int, at: Double) {
        self.signature = signature; self.hint = hint; self.wins = wins; self.trials = trials; self.at = at
    }
    public var rate: Double { trials == 0 ? 0 : Double(wins) / Double(trials) }
}

public enum PromotionGate {
    /// A hint qualifies for REVIEW (never auto-apply) once it has real evidence: enough verified-done wins
    /// AND a high verified-done rate. Grounded in the Phase-0 gate, so a gamed policy can't qualify.
    public static func qualifies(wins: Int, trials: Int, minWins: Int = 3, minRate: Double = 0.75) -> Bool {
        wins >= minWins && trials >= wins && (Double(wins) / Double(max(1, trials))) >= minRate
    }
}

/// Durable, deduped queue of promotion candidates at `<root>/.kist/promotion-candidates.jsonl`. Append-only
/// review queue; nothing here is ever applied automatically. Fail-soft.
public final class PromotionCandidateStore {
    private let path: String
    public init(projectRoot: String) { self.path = projectRoot + "/.kist/promotion-candidates.jsonl" }

    public func load() -> [PromotionCandidate] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            line.data(using: .utf8).flatMap { try? JSONDecoder().decode(PromotionCandidate.self, from: $0) }
        }
    }

    /// Append the candidate if this (signature, hint) isn't already queued. Returns true if newly queued.
    @discardableResult
    public func export(_ c: PromotionCandidate) -> Bool {
        var all = load()
        guard !all.contains(where: { $0.signature == c.signature && $0.hint == c.hint }) else { return false }
        all.append(c)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let text = all.compactMap { (try? JSONEncoder().encode($0)).flatMap { String(data: $0, encoding: .utf8) } }
            .joined(separator: "\n")
        try? (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return true
    }
}
