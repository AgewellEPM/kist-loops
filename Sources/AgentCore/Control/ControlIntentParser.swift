import Foundation

/// Detects plain-English directives that should mutate the RUNTIME (model/role bindings), not just be
/// understood by the model — so "use DeepSeek as builder and Gemini as critic" actually rebinds roles,
/// and "switch to gemini" actually changes the model. Deterministic + conservative: it only fires on an
/// explicit agent-introduction structure ("X as ROLE", "have/use/make X VERB", "switch to X"), so a
/// normal request like "build a login page" or "research the gemini api" never changes a binding.
public enum ControlIntentParser {

    public struct RoleAssignment: Equatable { public let role: AgentRole; public let binding: ProviderBinding }
    public enum Setting: Equatable { case planMode(Bool); case reasoning(Bool) }
    public enum Action: Equatable {
        case setModel(ProviderBinding)          // single provider → switch the conversational model
        case setRoles([RoleAssignment])         // a team → rebind roles for fleet/plan-execute/spawn
        case setting(Setting)                   // plan mode / reasoning toggle, by talking
    }
    public struct Intent: Equatable {
        public let action: Action
        public let residualTask: String         // task left after the control clause ("" = control-only)
        public var isControlOnly: Bool { residualTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func role(forKeyword w: String) -> AgentRole? {
        switch w {
        case "planner", "plan", "architect": return .planner
        case "researcher", "research", "worker", "analyst", "investigator": return .worker
        case "builder", "coder", "developer", "dev", "implementer", "programmer": return .coder
        case "critic", "reviewer", "review", "verifier", "judge", "qa", "tester": return .critic
        default: return nil
        }
    }
    static func role(forVerb w: String) -> AgentRole? {
        switch w {
        case "build", "code", "implement", "write", "develop", "create", "make", "builds", "codes": return .coder
        case "review", "critique", "criticize", "check", "verify", "audit", "critiques", "reviews", "checks": return .critic
        case "research", "investigate", "find", "gather", "explore", "analyze", "study", "researches": return .worker
        case "plan", "design", "decompose", "architect", "plans": return .planner
        case "run", "execute", "test", "runs": return .coder
        default: return nil
        }
    }
    static let articles: Set<String> = ["the", "a", "an", "this", "that", "your", "my", "its", "their", "of"]
    static let switchVerbs: Set<String> = ["use", "switch", "try", "with", "via", "have", "make", "let", "get", "set", "using",
                                           "bring", "ask", "call"]
    /// STRONG switch-intent verbs that alone make a bare provider mention a model-switch DIRECTIVE.
    /// Deliberately excludes the weaker/conversational "with/have/make/let/get" so "built with gemini"
    /// or "my own claude" never silently switch the model.
    static let bareSwitchVerbs: Set<String> = ["use", "switch", "try", "using"]
    /// Verbs that introduce an AGENT directive ("have/make/use Gemini review…"). Excludes "with" —
    /// "compare with claude code" / "built with gemini" are descriptions, not commands.
    static let directiveLeadVerbs: Set<String> = ["use", "have", "make", "let", "get", "via", "using",
                                                  "bring", "ask", "call"]
    // residual made only of these ⇒ no real task (just a control directive).
    static let glue: Set<String> = ["and", "then", "to", "for", "with", "please", "now", "next", "task",
                                    "this", "it", "the", "a", "from", "on", "as", "instead", ""]

    /// Standalone settings directives (no provider needed) — checked first.
    static func detectSetting(_ message: String) -> Setting? {
        let m = " " + message.lowercased() + " "
        func has(_ phrases: [String]) -> Bool { phrases.contains { m.contains($0) } }
        // OFF/negation phrases FIRST — "exit plan mode" contains "plan mode", so the ON check must not win.
        if has(["exit plan mode", "execute mode", "you can edit", "stop planning", "make changes now",
                "turn off plan", "leave plan mode"]) { return .planMode(false) }
        if has(["plan mode", "read-only", "read only", "just propose", "don't edit", "do not edit",
                "dry run", "plan only", "propose a plan", "don't make changes", "do not make changes"]) { return .planMode(true) }
        if has(["hide reasoning", "stop showing reasoning", "hide thinking", "hide your reasoning"]) { return .reasoning(false) }
        if has(["show your reasoning", "show reasoning", "show thinking", "show your thinking",
                "think out loud", "show your thoughts"]) { return .reasoning(true) }
        return nil
    }

    public static func parse(_ message: String, knownProviders: [String: String]) -> Intent? {
        if let setting = detectSetting(message) { return Intent(action: .setting(setting), residualTask: "") }
        guard !knownProviders.isEmpty else { return nil }
        let tokens = tokenize(message)
        let words = tokens.map { $0.lowercased() }
        func wd(_ i: Int) -> String { (i >= 0 && i < words.count) ? words[i] : "" }
        func providerAt(_ i: Int) -> String? {
            guard i >= 0, i < words.count, let canon = knownProviders[words[i]] else { return nil }
            if i > 0, articles.contains(words[i - 1]) { return nil }   // object position ("the gemini api")
            return canon
        }

        var explicit: [RoleAssignment] = []          // "X as/for ROLE"
        var verbed: [RoleAssignment] = []            // "X [to] VERB …"  (verb stays in residual)
        var bare: ProviderBinding? = nil             // "use X" / "switch to X"
        var consumed = Set<Int>()
        var sawProvider = false

        var i = 0
        while i < words.count {
            guard let pid = providerAt(i) else { i += 1; continue }
            sawProvider = true
            let binding = ProviderBinding(providerId: pid)
            let prev = wd(i - 1)
            func consumeProviderAndLeadVerb() {
                consumed.insert(i)
                if switchVerbs.contains(prev) { consumed.insert(i - 1) }
                if ["in", "on"].contains(prev), Self.directiveLeadVerbs.contains(wd(i - 2)) {
                    consumed.insert(i - 1)
                    consumed.insert(i - 2)
                }
                if wd(i - 2) == "switch" { consumed.insert(i - 2) }   // "switch to X"
            }

            // (a) "X as/for [the] ROLE"
            if wd(i + 1) == "as" || wd(i + 1) == "for" {
                var j = i + 2
                if articles.contains(wd(j)) { j += 1 }
                if let r = role(forKeyword: wd(j)) {
                    explicit.append(.init(role: r, binding: binding))
                    consumeProviderAndLeadVerb()
                    consumed.insert(i + 1); consumed.insert(j); if j != i + 2 { consumed.insert(i + 2) }
                    i = j + 1; continue
                }
            }
            // (b) DIRECTIVE verb-role: "<cmd-verb> X [to] VERB" or "X to VERB". A casual mention like
            // "claude code terminal" (no command verb before X, no "to" before the verb) is NOT a
            // directive — the product name "Claude Code" must never be read as "make anthropic the coder".
            let controlLead = Self.directiveLeadVerbs.contains(prev)
                || (["in", "on"].contains(prev) && Self.directiveLeadVerbs.contains(wd(i - 2)))
                || wd(i - 2) == "switch"
            let toIntroduced = wd(i + 1) == "to"
            var vj = i + 1
            if toIntroduced { vj += 1 }
            if let r = role(forVerb: wd(vj)), controlLead || toIntroduced {
                verbed.append(.init(role: r, binding: binding))
                consumeProviderAndLeadVerb()
                if toIntroduced { consumed.insert(i + 1) }
                i += 1; continue
            }
            // (c) bare provider → a model switch, but ONLY with an explicit switch verb
            // ("use/switch to/try X"). A bare mention ("my own claude code") is never a directive.
            if Self.bareSwitchVerbs.contains(prev) || wd(i - 2) == "switch" {
                bare = binding
                consumeProviderAndLeadVerb()
            }
            i += 1
        }

        guard sawProvider else { return nil }
        let residual = residualText(tokens, consumed: consumed)

        // ROLE/THE TEAM: any explicit role OR role-bearing verb rebinds the runtime role(s), even
        // when there is only one provider: "have Gemini review this" means critic=gemini, not a
        // generic model switch. Bare provider directives ("switch to Gemini") still switch the model.
        if !explicit.isEmpty || !verbed.isEmpty {
            var byRole: [AgentRole: ProviderBinding] = [:]
            for a in explicit + verbed { byRole[a.role] = a.binding }   // last wins per role
            let final = AgentRole.allCases.compactMap { r in byRole[r].map { RoleAssignment(role: r, binding: $0) } }
            return Intent(action: .setRoles(final), residualTask: residual)
        }
        // Bare switch ("use Gemini", "switch to Claude") → model switch.
        if let model = bare {
            return Intent(action: .setModel(model), residualTask: residual)
        }
        return nil
    }

    static func tokenize(_ s: String) -> [String] {
        s.split { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "," || $0 == ";" }.map { String($0) }
    }

    static func residualText(_ tokens: [String], consumed: Set<Int>) -> String {
        var words = tokens.enumerated().filter { !consumed.contains($0.offset) }.map { $0.element }
        let lead: Set<String> = ["and", "then", "to", "for", "with", "please", "now", "next", "the", "a", "so", "ok"]
        while let f = words.first, lead.contains(f.lowercased()) { words.removeFirst() }
        let joined = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        // If what's left is only glue/control words, treat it as control-only (empty residual).
        let meaningful = joined.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !glue.contains($0) }
        return meaningful.isEmpty ? "" : joined
    }
}
