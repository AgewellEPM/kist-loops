import Foundation

/// Phase 1 — turn a finished great-loop cycle into a durable, structured LESSON (Reflexion done right,
/// gated by verification). The research is clear: verbal reflection is a rich learning signal for a
/// frozen-weights model — but UNVERIFIED memory degrades (vague "be careful" advice, or a confident-wrong
/// lesson reinforced forever). So: a PROVEN lesson is written ONLY when the cycle was genuinely
/// done+verified (Phase-0 gate); otherwise an OBSTACLE that names the concrete wall (the verifier's
/// rejection, the review gist, or a failure spike) so the next run avoids it. Pure → unit-tested.
public enum CycleReflection {
    /// Build the lesson. `done` MUST already reflect the anti-Goodhart verdict (done ⇒ verified).
    public static func lesson(goal: String, done: Bool, verdictReason: String, reviewGist: String?,
                              summary: String, failureRate: Double, at: Double) -> Lesson {
        let g = clip(goal, 100)
        let kws = keywords(from: goal)
        if done {
            // `done` already means the Phase-0 anti-Goodhart gate passed (real build/test, tests not
            // weakened) — that verification IS the proof source the honesty invariant requires for `.proven`.
            return Lesson(kind: .proven,
                          text: "GOAL: \(g) — SOLVED and verified (real build/test passed, tests not weakened). Approach that worked: \(clip(summary, 240)).",
                          source: "greatloop-verified@\(Int(at))", at: at, keywords: kws)
        }
        // OBSTACLE — name the concrete blocker, most specific first.
        var blocker: String
        if verdictReason != "verified", !verdictReason.isEmpty {
            blocker = "the 'done' was REJECTED — \(clip(verdictReason, 180))"
        } else if let r = reviewGist, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocker = "team review flagged — \(clip(r, 180))"
        } else if failureRate > 0.4 {
            blocker = "a high tool-failure rate (\(Int(failureRate * 100))%) — the approach was fighting the environment"
        } else {
            blocker = "the cycle ended without a verified finish"
        }
        return Lesson(kind: .obstacle,
                      text: "GOAL: \(g) — BLOCKED: \(blocker). Next time: make a real build/test pass, never weaken/skip tests, and address the review before claiming done.",
                      source: nil, at: at, keywords: kws)
    }

    /// A few salient keywords from the goal for the lesson store's keyword ranking.
    static func keywords(from goal: String) -> [String] {
        let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "into", "from", "then", "make",
                                 "add", "run", "its", "your", "you", "them", "have", "will", "should", "must",
                                 "each", "all", "both", "before", "after", "when", "what", "how", "a", "an", "to", "of", "in", "it"]
        var seen = Set<String>(), out: [String] = []
        for raw in goal.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let w = String(raw)
            guard w.count >= 4, !stop.contains(w), seen.insert(w).inserted else { continue }
            out.append(w)
            if out.count >= 8 { break }
        }
        return out
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }
}
