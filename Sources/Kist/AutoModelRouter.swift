import Foundation
import AgentCore

/// Picks the best (provider, model) for ONE request with a cheap, deterministic heuristic — no extra
/// LLM call. This is kist's default behaviour when the user hasn't pinned a model with `/model`:
///
///   1. media in the turn                      → a vision-capable model (vision engine first)
///   2. architecture / algorithm / math / build → the strongest reasoning model available
///   3. everything else                        → STAY on the current/Captain model (the `fallback`)
///
/// Rule 3 deliberately does NOT flip to whatever fast model is first: constant auto-switching to
/// gemini-flash was jarring while dogfooding ("everything flips to gemini"), and a silent flash model
/// also killed the streamed "thinking" display. Only a real reason (vision / reasoning) switches models;
/// ordinary turns stay put. The `fallback` is the session's current binding, so a one-provider setup
/// always works and never routes to something unconfigured.
struct AutoModelRouter: Equatable {
    struct Candidate: Equatable {
        var binding: ProviderBinding
        var vision: Bool
        var reasoning: Bool
        var contextTokens: Int
        var fast: Bool            // flash/mini/small-tier model (by name or small context)
    }

    enum Tier: String, Equatable { case vision, reasoning, fast }
    struct Decision: Equatable { var binding: ProviderBinding; var tier: Tier; var reason: String }

    /// Runner orders candidates by preference within a tier (e.g. the vision engine first).
    var candidates: [Candidate]
    var fallback: ProviderBinding

    /// `current` is the model in use RIGHT NOW; on a STAY decision the router must return the current model,
    /// not the STARTUP fallback — else toggling `/model auto` after a `/model` switch route-flips back to the
    /// launch provider on the next no-signal turn (Codex MED, 2026-07-03). Defaults to the startup fallback,
    /// so existing callers and behaviour are unchanged.
    func route(_ text: String, hasMedia: Bool, current: ProviderBinding? = nil) -> Decision {
        let stayTarget = current ?? fallback
        if hasMedia, let v = candidates.first(where: { $0.vision }) {
            return Decision(binding: v.binding, tier: .vision, reason: "vision")
        }
        if Self.looksLikeReasoning(text), let r = bestReasoning() {
            return Decision(binding: r.binding, tier: .reasoning, reason: "reasoning")
        }
        // Ordinary turns STAY on the current/Captain model (the stay target) rather than flipping to
        // whatever fast candidate is first — the constant auto-switch to gemini-flash was jarring while
        // dogfooding ("everything flips to gemini"). Vision (media) and reasoning above are the ONLY
        // reasons to switch models; everything else stays put. It also keeps a model that streams
        // reasoning (so the "thinking" display keeps working) instead of a silent flash model.
        return Decision(binding: stayTarget, tier: .fast, reason: "staying on current model")
    }

    /// Strongest = explicit reasoning flag first, then the largest context window; else widest context.
    private func bestReasoning() -> Candidate? {
        let reasoners = candidates.filter { $0.reasoning }
        if let best = reasoners.max(by: { $0.contextTokens < $1.contextTokens }) { return best }
        // No declared reasoner: prefer a clearly NON-fast model, by widest context.
        let heavy = candidates.filter { !$0.fast }
        return heavy.max(by: { $0.contextTokens < $1.contextTokens })
    }

    /// Architecture / algorithm / systems / math language → wants the strongest model. Curated to
    /// match intent, NOT to fire on plain "explain"/"what is" chatter (those stay on the fast tier).
    static func looksLikeReasoning(_ text: String) -> Bool {
        let t = text.lowercased()
        let kws = [
            "architect", "design ", "system design", "data model", "schema design",
            "fault-toler", "fault toler", "distributed", "concurren", "consensus", "throughput",
            "algorithm", "optimi", "complexity", "scalab", "big-o", "big o",
            "proof", "prove ", "prove that", "theorem", "derive", "derivation", "math",
            "trade-off", "tradeoff", "refactor", "race condition", "deadlock",
            "plan a", "plan the", "strategy for", "step-by-step plan"
        ]
        return kws.contains { t.contains($0) }
    }

    /// Stability policy for a Captain interactive assignment (C4): switch off the current model ONLY when
    /// the turn carries a real capability signal (explicit coding / reasoning / research) AND the Captain
    /// picked a confident, DIFFERENT model. Otherwise STAY on the current model — no churn on ordinary
    /// turns, and the streamed "thinking" display is preserved. Pure/deterministic so the policy is tested
    /// directly (the empty-tags default 'coding' is NOT a signal — `wantsCoding` is the explicit keyword).
    static func captainDecision(_ a: InteractiveAssignment, fallback: ProviderBinding) -> Decision {
        let signal = a.wantsReasoning || a.prefersResearch || a.wantsCoding
        if signal, a.binding != fallback, a.confidence >= 0.5 {
            return Decision(binding: a.binding, tier: .reasoning, reason: "captain · \(a.reason)")
        }
        return Decision(binding: fallback, tier: .fast, reason: "staying on current model")
    }

    /// Name/context heuristic the runner uses to tag a candidate as "fast" tier.
    static func isFastModel(_ modelId: String, contextTokens: Int) -> Bool {
        let m = modelId.lowercased()
        let fastNames = ["flash", "mini", "lite", "small", "fast", "haiku", "nano", "turbo",
                         "-3b", "-7b", "-8b", "1.5b", "3b-", "phi"]
        if fastNames.contains(where: { m.contains($0) }) { return true }
        return contextTokens > 0 && contextTokens < 32_000
    }
}
