import Foundation

/// R4 (2026-07-29): natural-language TEAM assignment. Lets Luke say, in plain words, "work as a team",
/// "gemini be the eyes for deepseek", or "deepseek codes and gemini reviews" instead of typing
/// `/copilot lead … / co … / on`. The parser is PURE (text → intent) so the role mapping is unit-tested
/// without a terminal; the REPL resolves the provider strings against its catalog and arms the copilot
/// (lead = coder, co = reviewer) + the review→fix loop.
///
/// Returns nil when the message carries no team directive — a normal turn is never reinterpreted.
struct TeamIntent: Equatable {
    /// Provider id/alias that WRITES the code (the lead / coder). nil ⇒ keep the current lead.
    var lead: String?
    /// Provider id/alias that REVIEWS (the co / eyes / critic). nil ⇒ keep the current co.
    var co: String?
    /// The residual task to actually run, with the team directive stripped ("" ⇒ pure setup, no task).
    var goal: String

    /// Known provider aliases the parser recognizes by name in free text (lowercased, whole-word).
    static let providerAliases: [String] = [
        "deepseek", "gemini", "mimo", "claude", "anthropic", "openai", "gpt", "chatgpt",
        "grok", "xai", "mistral", "perplexity", "ollama", "mlx", "groq", "qwen", "codex",
    ]

    /// Verbs that mark the CODER role (the lead who writes) and the REVIEWER role (the eyes/critic).
    static let codeVerbs: Set<String> = ["code", "codes", "coding", "build", "builds", "write", "writes",
                                         "implement", "implements", "develop", "develops", "author"]
    static let reviewWords: Set<String> = ["eyes", "review", "reviews", "reviewing", "reviewer", "check",
                                           "checks", "critique", "critiques", "verify", "verifies", "audit",
                                           "watch", "watches", "proofread", "qa"]

    /// Parse a team directive. Recognizes:
    ///   • "work as a team [to] <goal>"            → enable team (defaults filled by the REPL)
    ///   • "<A> as the eyes for <B> [to] <goal>"   → co = A (eyes), lead = B (coder)
    ///   • "<A> code(s) … <B> review(s) …"         → lead = A, co = B (by verb association)
    ///   • "bring in <A> to review …"              → co = A
    ///   • "have <A> and <B> work as a team …"     → lead = A, co = B (first-mentioned leads)
    /// Returns nil when no team phrasing is present.
    static func parse(_ text: String) -> TeamIntent? {
        let lower = text.lowercased()
        let mentions = orderedProviderMentions(lower)
        let saysTeam = lower.contains("as a team") || lower.contains("work together")
            || lower.contains("as a partner") || lower.contains("tag team") || lower.contains("tag-team")
        let saysEyes = lower.contains("eyes for") || lower.contains("eyes on") || lower.contains("be the eyes")
        let saysBring = lower.range(of: #"\bbring in\b"#, options: .regularExpression) != nil
        // "<A> codes … <B> reviews …" — an explicit role split. REQUIRES TWO DISTINCT models named
        // (plus a code-verb and a review-word): a single incidental provider name in an ordinary coding
        // request ("write the deepseek client and add a check for nil") must NOT arm team mode — that
        // false-positive silently rebound the coding model + forced auto-fix on (review catch, critical).
        let codeReviewSplit = mentions.count >= 2 && hasAny(lower, codeVerbs) && hasAny(lower, reviewWords)

        guard saysTeam || saysEyes || saysBring || codeReviewSplit else { return nil }

        var lead: String?
        var co: String?

        if saysEyes, let eyesRange = lower.range(of: #"(\w+)\s+(?:acts?\s+as\s+|be\s+|is\s+|as\s+)?the\s+eyes\s+for\s+(\w+)"#,
                                                 options: .regularExpression) {
            // "<A> [as] the eyes for <B>": A reviews, B codes.
            let names = orderedProviderMentions(String(lower[eyesRange]))
            if names.count >= 2 { co = names[0]; lead = names[1] }
            else if let a = names.first { co = a }
        } else if codeReviewSplit {
            // Verb association: the provider nearest a code-verb leads; nearest a review-word is co.
            (lead, co) = assignByVerbProximity(lower, mentions: mentions)
        } else if saysBring {
            co = mentions.first                                                 // "bring in X" ⇒ reviewer
        }

        // Fill the unset role from mention order: first-mentioned leads, next distinct reviews.
        if lead == nil && co == nil {
            if mentions.count >= 2 { lead = mentions[0]; co = mentions[1] }
            else { lead = mentions.first }        // 0 or 1 model — a bare team frame; REPL fills defaults
        } else if co == nil, !saysBring, let extra = mentions.first(where: { $0 != lead }) {
            co = extra
        } else if lead == nil, let extra = mentions.first(where: { $0 != co }) {
            lead = extra
        }

        return TeamIntent(lead: lead, co: co, goal: residualGoal(text))
    }

    /// Whole-word membership of any of `words` in the lowercased text.
    static func hasAny(_ lower: String, _ words: Set<String>) -> Bool {
        let tokens = Set(lower.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return !tokens.isDisjoint(with: words)
    }

    /// Provider aliases in first-appearance order, de-duplicated (whole-word matches only).
    static func orderedProviderMentions(_ lower: String) -> [String] {
        var hits: [(Int, String)] = []
        for alias in providerAliases {
            if let r = lower.range(of: "\\b\(alias)\\b", options: .regularExpression) {
                hits.append((lower.distance(from: lower.startIndex, to: r.lowerBound), canonical(alias)))
            }
        }
        var seen = Set<String>()
        return hits.sorted { $0.0 < $1.0 }.compactMap { seen.insert($0.1).inserted ? $0.1 : nil }
    }

    /// Map an alias to the canonical provider id the REPL catalog resolves.
    static func canonical(_ alias: String) -> String {
        switch alias {
        case "anthropic": return "claude"
        case "gpt", "chatgpt": return "openai"
        case "xai": return "grok"
        default: return alias
        }
    }

    /// Assign lead/co by which provider name sits closest (in word distance) to a code-verb vs a
    /// review-word. Returns (nil, nil) when neither role verb is near a distinct provider.
    private static func assignByVerbProximity(_ lower: String, mentions: [String]) -> (String?, String?) {
        guard !mentions.isEmpty else { return (nil, nil) }
        let tokens = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        func nearestProvider(toAnyOf words: Set<String>) -> String? {
            var best: (dist: Int, provider: String)? = nil
            for (i, tok) in tokens.enumerated() where words.contains(tok) {
                for (j, t2) in tokens.enumerated() {
                    let cano = canonical(t2)
                    guard providerAliases.contains(t2) else { continue }
                    let d = abs(i - j)
                    if best == nil || d < best!.dist { best = (d, cano) }
                }
            }
            return best?.provider
        }
        let lead = nearestProvider(toAnyOf: codeVerbs)
        var co = nearestProvider(toAnyOf: reviewWords)
        if let l = lead, co == l { co = mentions.first { $0 != l } }   // don't bind one model to both
        return (lead, co)
    }

    /// Strip the team directive so what's left is the actual task. Best-effort: drops the framing
    /// clause ("work as a team to", "<A> as the eyes for <B> to", "bring in X to review and") and any
    /// leading provider-role scaffolding, keeping the imperative that follows.
    static func residualGoal(_ text: String) -> String {
        var s = text
        // Only strip UNAMBIGUOUS leading team-framing clauses. Deliberately NO greedy "A codes … B
        // reviews …" span strip — it ate the real task ("code the parser …" → "after and fix it",
        // review catch). For the code/review-split shape the whole message stays the goal; the coder
        // reads the role sentence and does the sensible thing.
        let patterns = [
            #"(?i)\bhave\s+\w+\s+and\s+\w+\s+work\s+(?:together|as\s+a\s+team)\s+(?:to|and)?\s*"#,
            #"(?i)\bwork\s+(?:together\s+)?as\s+a\s+team\s+(?:to|and|on)?\s*"#,
            #"(?i)\b\w+\s+(?:acts?\s+as\s+|be\s+|is\s+|as\s+)?the\s+eyes\s+for\s+\w+\s+(?:to|and|while)?\s*"#,
            #"(?i)\bbring\s+in\s+\w+\s+(?:to\s+\w+\s+)?(?:and|to)?\s*"#,
        ]
        for p in patterns {
            if let r = s.range(of: p, options: .regularExpression) { s.removeSubrange(r) }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
