import Foundation

/// P2 — task-targeted self__ tool surfacing. A PURE, deterministic function of (goal, self__ manifests) that
/// decides which self-authored tools are worth ADVERTISING for a turn, so the tool schema doesn't bloat as the
/// self__ population grows. Deterministic by construction (no I/O, no network, no embedder) — required because
/// a native→text protocol downgrade re-drives the same goal and must re-derive the SAME surface mid-run.
///
/// FAIL-OPEN is the whole safety story: this can only ever reduce advertisement from "all self__" toward
/// "relevant self__", and it returns nil (= surface everything) whenever it's unsure. It NEVER hides a tool on
/// absence of a positive match. Only self__ names are ever in scope; the loop keeps every non-self__ tool.
public enum SelfToolRelevance {

    /// High-frequency English + manifest-boilerplate words that would otherwise make EVERY tool match (a
    /// contract reads "Given --a and --b, prints the sum" — "and"/"the"/"given"/"prints" are noise). Dropping
    /// them only sharpens the trim; a false KEEP was already harmless, but a stopword match keeps EVERYTHING.
    static let stopwords: Set<String> = [
        "the", "and", "for", "are", "with", "this", "that", "your", "you", "its", "but", "not", "all", "any",
        "can", "has", "have", "will", "from", "into", "out", "off", "use", "using", "given", "prints", "print",
        "writes", "write", "return", "returns", "their", "them", "then", "when", "what", "which", "onto", "via",
        "each", "one", "two", "arg", "args", "argument", "arguments", "value", "output", "input", "string",
    ]

    /// Lowercased alnum/underscore tokens of length >= 3 (short enough to catch tool verbs like `add`/`sum`/`zip`),
    /// minus stopwords. False KEEP is harmless (fail-open direction), false DROP is neutralized by fail-open.
    public static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "_") }
            .map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    /// The set of self__ tool NAMES to KEEP for `goal`, or nil meaning "don't filter — surface all".
    ///
    /// Fail-open policy (honest — review #2/#3): returns nil (surface all) when the population is small
    /// (`<= surfaceAllBelow`), the goal has no usable tokens, or NO tool lexically matched. When SOME tool
    /// matched, returns the keep-set = matched tools PLUS every tool whose haystack is EMPTY (a token-less
    /// tool can never be positively matched, so hiding it would be pure loss — it is always surfaced).
    ///
    /// The honest limit this does NOT paper over: matching is LEXICAL. A tool whose words don't overlap the
    /// goal's words (e.g. goal "make an id" vs a tool described only as "generate a unique identifier") CAN be
    /// trimmed from advertisement. That is why this is ADVERTISEMENT-ONLY (execution, steering, `toolNames`,
    /// and the P1 recall wire all still see the tool) and OFF by default until the ablation proves the trim
    /// helps more than it costs. It is not a claim that the right tool is always advertised.
    public static func relevant(goal: String,
                                manifests: [SelfAuthoredManifest],
                                surfaceAllBelow: Int = 3) -> Set<String>? {
        guard manifests.count > surfaceAllBelow else { return nil }   // too few to bother — surface all
        let g = tokens(goal)
        guard !g.isEmpty else { return nil }                          // unknown/empty goal — surface all
        var kept = Set<String>()
        var anyMatched = false
        for m in manifests {
            let hay = haystack(m)
            if hay.isEmpty {
                kept.insert(m.name)                                   // #2: token-less tool — always surface
            } else if !g.isDisjoint(with: hay) {
                kept.insert(m.name); anyMatched = true
            }
        }
        // No POSITIVE match ⇒ fail open entirely (surfacing only the degenerate tools would wrongly hide the
        // non-matching ones). Only trim when at least one tool actually matched the goal.
        return anyMatched ? kept : nil
    }

    /// The searchable token set for one tool: its name (self__ prefix dropped AND snake_case split so
    /// `self__do_thing` yields `thing`, not the glued `do_thing` — review #4), description, contract, and
    /// every parameter name + description.
    static func haystack(_ m: SelfAuthoredManifest) -> Set<String> {
        let name = m.name.replacingOccurrences(of: "self__", with: " ").replacingOccurrences(of: "_", with: " ")
        var parts = [name, m.description, m.contract]
        for p in m.parameters { parts.append(p.name); parts.append(p.description) }
        return tokens(parts.joined(separator: " "))
    }
}
