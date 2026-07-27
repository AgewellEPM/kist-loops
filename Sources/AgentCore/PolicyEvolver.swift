import Foundation

/// Phase 2 — GEPA-style reflective policy evolution. GEPA (2507.19457) beats RL by ~10% at 35× fewer
/// rollouts by treating natural-language reflection as the learning signal and keeping a PARETO FRONTIER of
/// prompts (best-per-instance, not one global best) to dodge local optima. Our great-loop already produces
/// review critique every cycle and throws it away; this turns it into an evolving POLICY HINT — a compact
/// directive injected into future cycles of the SAME task-signature.
///
/// Mechanism: a failed cycle's review is REFLECTIVELY MUTATED into a candidate hint; fitness = the
/// verified-done rate of cycles run under it (grounded in the Phase-0 gate, so the policy can't evolve
/// toward fooling itself); selection keeps the best hint PER SIGNATURE. Pure logic here; durable in
/// `PolicyStore`. No LLM call — the mutation is a deterministic distillation, so it's unit-tested.
public struct PolicyCandidate: Codable, Sendable, Equatable {
    public let signature: String
    public let hint: String
    public var wins: Int
    public var trials: Int
    public var at: Double
    public init(signature: String, hint: String, wins: Int = 0, trials: Int = 0, at: Double) {
        self.signature = signature; self.hint = hint; self.wins = wins; self.trials = trials; self.at = at
    }
    /// Verified-done rate (grounded in the Phase-0 gate, so fitness can't be gamed). Untried ⇒ 0.
    public var score: Double { trials == 0 ? 0 : Double(wins) / Double(trials) }
}

public enum PolicyEvolver {
    /// Distill a review/rejection into a compact, actionable policy hint for this signature. Deterministic:
    /// takes the most actionable sentence of the critique, bounded. (The reflective "mutation" step.)
    public static func mutate(review: String, signature: String, maxChars: Int = 220) -> String? {
        let clean = review.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean.uppercased() != "LGTM — NO BLOCKING ISSUES" else { return nil }
        // Prefer the first sentence that reads like a directive (has a concrete verb/noun), else the head.
        let sentences = clean.split(whereSeparator: { $0 == "." || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }
        let pick = sentences.first(where: { $0.count > 15 }) ?? clean
        let body = pick.count > maxChars ? String(pick.prefix(maxChars)) + "…" : pick
        return "For tasks like this: \(body)"
    }

    /// Pick the best candidate for a signature: highest verified-done rate, ties broken by more trials
    /// (more evidence) then recency. Returns nil when there's no candidate yet.
    public static func best(_ candidates: [PolicyCandidate]) -> PolicyCandidate? {
        candidates.max { a, b in
            if a.score != b.score { return a.score < b.score }
            if a.trials != b.trials { return a.trials < b.trials }
            return a.at < b.at
        }
    }
}

/// Durable Pareto-frontier store of policy candidates at `<root>/.kist/policy-frontier.jsonl`. Keeps at most
/// `maxPerSignature` candidates per signature (prunes the weakest), so the frontier stays bounded. Fail-soft.
public final class PolicyStore {
    private let path: String
    private let maxPerSignature: Int
    public init(projectRoot: String, maxPerSignature: Int = 4) {
        self.path = projectRoot + "/.kist/policy-frontier.jsonl"
        self.maxPerSignature = max(1, maxPerSignature)
    }

    public func load() -> [PolicyCandidate] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            line.data(using: .utf8).flatMap { try? JSONDecoder().decode(PolicyCandidate.self, from: $0) }
        }
    }

    /// The best hint to inject for a goal's signature (nil ⇒ no evolved policy yet).
    public func bestHint(forSignature signature: String) -> String? {
        bestCandidate(forSignature: signature)?.hint
    }

    /// The full best candidate (with win/trial evidence) — for the promotion gate.
    public func bestCandidate(forSignature signature: String) -> PolicyCandidate? {
        PolicyEvolver.best(load().filter { $0.signature == signature })
    }

    /// Record a cycle's outcome under the hint it ran with (win = verified done). Creates the candidate if
    /// new. Then, if a review is present and no strong candidate exists, propose a mutated candidate.
    public func record(signature: String, activeHint: String?, won: Bool, review: String?, at: Double) {
        var all = load()
        var group = all.filter { $0.signature == signature }
        let others = all.filter { $0.signature != signature }

        if let hint = activeHint {
            if let idx = group.firstIndex(where: { $0.hint == hint }) {
                group[idx].trials += 1; if won { group[idx].wins += 1 }
            } else {
                group.append(PolicyCandidate(signature: signature, hint: hint, wins: won ? 1 : 0, trials: 1, at: at))
            }
        }
        // Reflective mutation: a failed cycle's review seeds a NEW candidate to try next time.
        if !won, let review, let mutated = PolicyEvolver.mutate(review: review, signature: signature),
           !group.contains(where: { $0.hint == mutated }) {
            group.append(PolicyCandidate(signature: signature, hint: mutated, wins: 0, trials: 0, at: at))
        }
        // Prune to the frontier: keep the strongest `maxPerSignature`.
        group.sort { ($0.score, $0.trials, $0.at) > ($1.score, $1.trials, $1.at) }
        group = Array(group.prefix(maxPerSignature))

        all = others + group
        persist(all)
    }

    private func persist(_ candidates: [PolicyCandidate]) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let text = candidates.compactMap { c -> String? in
            (try? JSONEncoder().encode(c)).flatMap { String(data: $0, encoding: .utf8) }
        }.joined(separator: "\n")
        try? (text + (text.isEmpty ? "" : "\n")).write(toFile: path, atomically: true, encoding: .utf8)
    }
}
