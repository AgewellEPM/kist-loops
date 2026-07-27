import Foundation

/// Built-in professional identities the runtime can adopt before a task starts.
///
/// Saved specialists still live in `.kist/agents` / the user agents dir and are merged by
/// `TaskPersonaMatcher`; this catalog is the default human-side layer so a user can simply say
/// "review this mortgage clause" or "audit this SwiftUI app" without prompt-engineering a role first.
public enum BuiltinSpecialists {
    public static let all: [SpecialistDefinition] = catalog.map(\.definition)

    fileprivate struct Entry: Sendable {
        let definition: SpecialistDefinition
        let keywords: Set<String>
    }

    fileprivate static let catalog: [Entry] = [
        entry(
            name: "legal-research-analyst",
            description: "legal research analyst for statutes, regulations, court rules, case issues, deadlines, legal memos, and jurisdiction-specific research",
            tools: ["web_search", "fetch_url", "read_file", "tasks", "ask_user"],
            keywords: ["legal", "law", "statute", "regulation", "court", "case", "litigation", "jurisdiction", "attorney", "deadline", "plaintiff", "defendant", "memo", "remedy", "appeal"],
            prompt: """
            Act as a careful legal research analyst. This is research support, not legal advice. Identify jurisdiction, separate document facts from source-backed legal facts, prioritize official sources, cite material researched, flag deadlines and uncertainty, and produce questions for a licensed attorney before action.
            """
        ),
        entry(
            name: "real-estate-law-advisor",
            description: "real estate attorney for mortgage clauses, leases, deeds, escrow, title, property contracts, and closing documents",
            tools: ["web_search", "fetch_url", "read_file", "tasks", "ask_user"],
            keywords: ["mortgage", "lease", "deed", "escrow", "title", "closing", "property", "landlord", "tenant", "contract", "clause", "realtor", "hoa"],
            prompt: """
            Act as a careful real-estate law specialist. Explain risks in plain language, separate legal facts from assumptions, cite source material when researched, and recommend when a licensed attorney must review before action. Do not draft or sign binding documents as a final authority.
            """
        ),
        entry(
            name: "financial-advisor",
            description: "financial advisor for budgets, credit, loans, investments, pricing, unit economics, spreadsheets, and cost tradeoffs",
            tools: ["web_search", "fetch_url", "read_file", "read_spreadsheet", "query_data", "tasks", "ask_user"],
            keywords: ["finance", "financial", "budget", "loan", "credit", "investment", "pricing", "cost", "revenue", "spreadsheet", "money", "mortgage", "tax"],
            prompt: """
            Act as a financial analysis specialist. Quantify tradeoffs, state assumptions, avoid guarantees, and show the numbers needed for a decision. For regulated advice, provide educational analysis and recommend qualified review.
            """
        ),
        entry(
            name: "ip-prior-art-researcher",
            description: "intellectual-property and prior-art researcher for patents, trademarks, copyrights, claims, filings, and novelty checks",
            tools: ["web_search", "fetch_url", "read_file", "tasks", "ask_user"],
            keywords: ["patent", "trademark", "copyright", "prior", "art", "claim", "claims", "filing", "invention", "novelty", "license", "licensing"],
            prompt: """
            Act as an IP and prior-art researcher. Search broadly, cite sources, compare claims conservatively, and distinguish legal opinion from research evidence.
            """
        ),
        entry(
            name: "medical-researcher",
            description: "medical researcher for clinical studies, papers, evidence quality, symptoms, treatment literature, and health claims",
            tools: ["web_search", "fetch_url", "read_file", "tasks", "ask_user"],
            keywords: ["medical", "medicine", "clinical", "paper", "study", "trial", "symptom", "diagnosis", "treatment", "health", "doctor", "drug"],
            prompt: """
            Act as a medical research analyst. Summarize evidence quality, cite sources, explain uncertainty, and never present research as a diagnosis or substitute for a clinician.
            """
        ),
        entry(
            name: "security-auditor",
            description: "security auditor for vulnerabilities, secrets, injection, auth, permissions, SSRF, dependency risk, OWASP, and exploitability review",
            tools: ["security_audit", "search_code", "read_file", "glob_files", "web_search", "fetch_url", "tasks", "ask_user"],
            keywords: ["security", "audit", "vulnerability", "vulnerabilities", "exploit", "owasp", "secret", "secrets", "injection", "ssrf", "auth", "permission", "pentest", "cve"],
            prompt: """
            Act as a skeptical security auditor. Prefer reproducible evidence over speculation, identify attack surface and blast radius, avoid destructive exploitation, and turn findings into ranked fixes with verification.
            """
        ),
        entry(
            name: "bug-bounty-pentester",
            description: "authorized bug-bounty pentester for scoped reconnaissance, PoC validation, report drafting, deduplication, and remediation guidance",
            tools: ["security_audit", "browse", "web_search", "fetch_url", "read_file", "search_code", "tasks", "ask_user"],
            keywords: ["bug", "bounty", "pentest", "penetration", "recon", "scope", "poc", "exploit", "vulnerability", "hackerone", "bugcrowd"],
            prompt: """
            Act as an authorization-first bug-bounty specialist. Confirm scope before testing, avoid destructive actions, produce reproducible proof only for authorized targets, and separate confirmed findings from hypotheses.
            """
        ),
        entry(
            name: "swift-engineer",
            description: "senior Swift engineer for SwiftPM, Xcode, macOS, iOS, compiler errors, tests, concurrency, and app architecture",
            tools: ["search_code", "glob_files", "read_file", "write_file", "edit_file", "run_command", "tasks", "ask_user"],
            keywords: ["swift", "swiftui", "xcode", "ios", "macos", "compiler", "swiftpm", "package", "xctest", "concurrency", "actor"],
            prompt: """
            Act as a senior Swift engineer. Inspect before editing, keep patches scoped, respect Swift concurrency/sendability, and verify with focused SwiftPM or Xcode tests when available.
            """
        ),
        entry(
            name: "ux-reviewer",
            description: "UX/UI reviewer for terminal experience, screenshots, accessibility, information architecture, onboarding, clarity, and visual polish",
            tools: ["view_image", "browse", "fetch_url", "read_file", "tasks", "ask_user"],
            keywords: ["ux", "ui", "design", "terminal", "screenshot", "accessibility", "onboarding", "layout", "copy", "readability", "polish", "experience"],
            prompt: """
            Act as a product UX reviewer. Make the experience simple-first, reduce cognitive load, use evidence from screenshots or flows, and return concrete improvements with acceptance checks.
            """
        ),
        entry(
            name: "sre-diagnostics",
            description: "SRE diagnostics specialist for servers, logs, DNS, network, latency, ports, services, incidents, and safe remediation plans",
            tools: ["run_command", "fetch_url", "web_search", "read_file", "tasks", "ask_user"],
            keywords: ["server", "sre", "diagnose", "diagnostics", "logs", "dns", "latency", "port", "service", "incident", "outage", "network", "ssh"],
            prompt: """
            Act as an SRE diagnostics specialist. Prefer read-only checks first, correlate metrics/logs/reachability, cite the signal behind each hypothesis, and gate remediation behind approval and re-checks.
            """
        ),
        entry(
            name: "research-synthesizer",
            description: "research synthesizer for deep web research, source comparison, council summaries, decisions, next tasks, and test plans",
            tools: ["web_search", "fetch_url", "browse", "read_file", "tasks", "ask_user"],
            keywords: ["research", "deep", "dive", "latest", "sources", "citations", "compare", "landscape", "hacker", "news", "github", "roadmap", "future"],
            prompt: """
            Act as a research synthesizer. Search first, cite or name sources, compare disagreements, and end with Decision, Next 5 Tasks, and Test Plan instead of raw notes.
            """
        ),
    ]

    private static func entry(name: String, description: String, tools: [String],
                              keywords: [String], prompt: String) -> Entry {
        Entry(definition: SpecialistDefinition(name: name, description: description,
                                               systemPrompt: prompt, toolAllowlist: tools,
                                               source: "builtin"),
              keywords: Set(keywords.map(normalizeToken)))
    }
}

public struct PersonaMatch: Sendable, Equatable {
    public let specialist: SpecialistDefinition
    public let score: Int
    public let reasons: [String]

    public init(specialist: SpecialistDefinition, score: Int, reasons: [String]) {
        self.specialist = specialist
        self.score = score
        self.reasons = reasons
    }
}

/// Ranks task-appropriate specialists from the built-in catalog plus user/project-authored agents.
/// The matcher is deterministic and retrieval-only: it suggests an identity; it never certifies work.
public struct TaskPersonaMatcher: Sendable {
    private let registry: SpecialistRegistry?

    public init(projectRoot: String? = nil, userDir: String? = SpecialistRegistry.defaultUserDir()) {
        self.registry = projectRoot.map { SpecialistRegistry(projectRoot: $0, userDir: userDir) }
    }

    public init(registry: SpecialistRegistry?) {
        self.registry = registry
    }

    public func matches(for request: String, limit: Int = 3) -> [PersonaMatch] {
        let requestTokens = Self.tokens(request)
        guard !requestTokens.isEmpty else { return [] }

        var entries = BuiltinSpecialists.catalog
        if let registry {
            let saved = registry.load().map { def in
                BuiltinSpecialists.Entry(definition: def,
                                         keywords: Self.tokens(def.name + " " + def.description + " " + def.systemPrompt))
            }
            entries = merge(saved: saved, builtins: entries)
        }

        return entries.compactMap { entry -> PersonaMatch? in
            let hay = Self.tokens(entry.definition.name + " " + entry.definition.description)
                .union(entry.keywords)
            let overlap = requestTokens.intersection(hay)
            let phraseScore = Self.phraseScore(request.lowercased(), for: entry.definition.name)
            let score = overlap.count + phraseScore
            guard score > 0 else { return nil }
            let reasons = overlap.sorted().prefix(5).map { "matched '\($0)'" }
            return PersonaMatch(specialist: entry.definition, score: score,
                                reasons: reasons.isEmpty ? ["matched task phrasing"] : Array(reasons))
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.specialist.source != $1.specialist.source {
                return $0.specialist.source != "builtin"   // saved specialists win ties
            }
            return $0.specialist.name < $1.specialist.name
        }
        .prefix(max(0, limit))
        .map { $0 }
    }

    public static func promptContext(matches: [PersonaMatch]) -> String? {
        guard !matches.isEmpty else { return nil }
        var lines = ["ACTIVE SPECIALIST MATCHES (advisory identity; tool permissions still enforce the ceiling):"]
        for match in matches {
            let tools = match.specialist.toolAllowlist?.joined(separator: ", ") ?? "inherit available tools"
            lines += [
                "- \(match.specialist.name): \(match.specialist.description)",
                "  Why: \(match.reasons.joined(separator: "; "))",
                "  Tools requested: \(tools)",
                "  Instructions: \(match.specialist.systemPrompt)",
            ]
        }
        return lines.joined(separator: "\n")
    }

    public static func display(matches: [PersonaMatch]) -> String? {
        guard let first = matches.first else { return nil }
        let extra = matches.dropFirst().map(\.specialist.name)
        if extra.isEmpty { return "acting as: \(first.specialist.name)" }
        return "acting as: \(first.specialist.name) · consulting: " + extra.joined(separator: ", ")
    }

    // MARK: - Internals

    private func merge(saved: [BuiltinSpecialists.Entry],
                       builtins: [BuiltinSpecialists.Entry]) -> [BuiltinSpecialists.Entry] {
        var byName: [String: BuiltinSpecialists.Entry] = [:]
        for entry in builtins { byName[entry.definition.name] = entry }
        for entry in saved { byName[entry.definition.name] = entry }  // user/project wins
        return byName.values.sorted { $0.definition.name < $1.definition.name }
    }

    private static func phraseScore(_ lower: String, for name: String) -> Int {
        switch name {
        case "legal-research-analyst":
            return containsAny(lower, ["legal research", "legal memo", "court rule", "case law", "licensed attorney"]) ? 3 : 0
        case "real-estate-law-advisor":
            return containsAny(lower, ["real estate", "closing document", "mortgage clause"]) ? 3 : 0
        case "ip-prior-art-researcher":
            return containsAny(lower, ["prior art", "patent filing", "license review"]) ? 3 : 0
        case "bug-bounty-pentester":
            return containsAny(lower, ["bug bounty", "penetration test", "security program"]) ? 3 : 0
        case "sre-diagnostics":
            return containsAny(lower, ["server down", "why is my server", "network issue"]) ? 3 : 0
        case "research-synthesizer":
            return containsAny(lower, ["deep research", "landscape analysis", "hacker news", "github trends"]) ? 3 : 0
        default:
            return 0
        }
    }

    fileprivate static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }
            .map { normalizeToken(String($0)) }
            .filter { $0.count > 2 })
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}

private func normalizeToken(_ token: String) -> String {
    var t = token.lowercased()
    for suffix in ["ing", "ers", "ies", "ed", "es", "s"] where t.count > suffix.count + 3 && t.hasSuffix(suffix) {
        t.removeLast(suffix.count)
        if suffix == "ies" { t += "y" }
        break
    }
    return t
}
