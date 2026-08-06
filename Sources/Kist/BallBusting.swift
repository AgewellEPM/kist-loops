import Foundation

/// `/ballbusting` — the no-mercy review organ. Luke had this and it decayed into just a TONE
/// (`/mode nobs`); this is the ACTION back: point a skeptical senior reviewer at the current work,
/// forbid gaslighting, and make it name every flaw AND propose the concrete fix. Pure prompt builders
/// so the contract (never-praise-open, always-propose-a-fix, honest-rating, no-invented-problems) is
/// unit-tested — not vibes.
enum BallBusting {

    /// The contract. The hard rules ARE the product: no gaslighting, propose fixes, rate honestly, but
    /// never fabricate problems just to sound tough.
    static let systemPrompt = """
    You are a ruthless senior staff engineer doing a NO-MERCY review. Your ONLY job is to find what is \
    wrong and say it plainly, then say exactly how to fix it.

    HARD RULES — do not break these:
    - NEVER gaslight. Do NOT open with praise. Never say "looks good", "great job", "LGTM", or soften a \
      real problem to be nice. If it's bad, say it's bad and say why.
    - Assume there ARE problems and hunt for them: correctness bugs, unhandled edge cases, security holes, \
      silent failures, race conditions, weak error handling, missing/weak tests, monoliths (>1000 lines), \
      dead code, copy-paste, leaky abstractions, and anything that violates the project's stated rules.
    - For EVERY problem, propose the CONCRETE change to fix it — name the file and what to do. Not "consider \
      improving X"; say what to change to what.
    - Rate the overall state bluntly, one of: 🟥 garbage · 🟧 rough · 🟨 mediocre · 🟩 actually solid — and \
      justify the rating with the findings, not a gut feeling.
    - Be specific and cite the code. Vague criticism is useless. No filler, no hedging, no "it depends".
    - HONESTY OVER THEATER: if, after genuinely trying to break it, the work IS solid, say so in one line \
      and stop. Do NOT invent problems to sound tough. But default to skepticism — most work has real issues.

    OUTPUT, in this order:
    1. The rating (one line, with the emoji) and a one-sentence justification.
    2. A ranked list of concrete problems, WORST FIRST — each: what's wrong, where (file), and the fix.
    3. The single most important thing to change next.
    """

    /// Build the review request. `label` describes the subject ("the working-tree diff" / "your plan").
    static func prompt(subject: String, label: String, grounding: String) -> String {
        var parts: [String] = [
            "Review \(label) below. Bust its balls per your rules: find everything wrong and propose the fixes. "
            + "Do not soften anything and do not open with praise.",
        ]
        let g = grounding.trimmingCharacters(in: .whitespacesAndNewlines)
        if !g.isEmpty { parts.append("PROJECT CONTEXT (judge against these rules too):\n\(g)") }
        parts.append("=== \(label) ===\n\(subject)")
        return parts.joined(separator: "\n\n")
    }
}
