import Foundation

/// How Kist TALKS this session — an interaction mode + a reading/vocabulary level + an optional custom
/// persona. Set with `/mode`. The rendered `directive()` is injected into each turn's prompt so the
/// model actually adopts the requested voice. Persisted per project so it survives relaunches.
struct ReplStyle: Codable, Equatable, Sendable {

    /// The interaction voice.
    enum Mode: String, Codable, Sendable, CaseIterable {
        case normal            // default balance
        case conversation      // long, exploratory conversations
        case science           // deep study / deep research — rigorous, cited
        case build             // quick build — minimal talk, minimal planning, just do it
        case friend            // warm, hype best-friend voice
        case nobs              // blunt skeptical partner, finds faults, no flattery

        /// Accept the messy aliases a human types.
        static func parse(_ raw: String) -> Mode? {
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "normal", "default", "off", "balanced": return .normal
            case "conversation", "convo", "long", "chat", "talk": return .conversation
            case "science", "scientific", "deep", "study", "deep study", "research", "deepresearch",
                 "deep-research", "deep research": return .science
            case "build", "quick", "quickbuild", "quick-build", "fast", "ship": return .build
            case "friend", "bestfriend", "best-friend", "buddy", "hype", "warm": return .friend
            case "nobs", "no-bs", "no-bull", "critic", "brutal", "cynic", "cynical", "sceptic", "skeptic": return .nobs
            default: return nil
            }
        }

        var directive: String {
            switch self {
            case .normal:
                return ""
            case .conversation:
                return "CONVERSATION MODE: have a thorough, exploratory conversation — take your time, "
                    + "surface context, tradeoffs, and options; think out loud with me."
            case .science:
                return "SCIENTIFIC / DEEP-STUDY MODE: be rigorous and evidence-first. Cite sources, quantify "
                    + "claims, examine assumptions, separate fact from inference, and note uncertainty. No hand-waving."
            case .build:
                return "QUICK-BUILD MODE: minimal explanation, minimal planning — just do the work and show the "
                    + "result. Skip preamble, caveats, and restating the request. Lead with the change/answer."
            case .friend:
                return "FRIEND MODE: talk to me like my sharp, supportive best friend — warm, casual, encouraging, "
                    + "a bit of hype. Keep it short and human. Still honest, never fake."
            case .nobs:
                return "NO-BS MODE: be a blunt, skeptical partner. Hunt for the flaws in what I'm doing, challenge "
                    + "weak reasoning, and call out risks. Zero flattery, zero filler. If something's wrong, say so plainly."
            }
        }
    }

    /// Reading/vocabulary level — the "slider" from 1st grade to college.
    enum ReadingLevel: Int, Codable, Sendable, CaseIterable {
        case grade1 = 1, grade2, grade3, grade4, grade5, grade6, grade7, grade8
        case highSchool = 9, college = 10

        static func parse(_ raw: String) -> ReadingLevel? {
            let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
            switch s {
            case "college", "grad", "graduate", "phd", "expert", "advanced": return .college
            case "highschool", "high-school", "high school", "hs": return .highSchool
            default: break
            }
            // "1", "1st", "grade 3", "3rd grade", "5", …
            let digits = s.filter { $0.isNumber }
            if let n = Int(digits), (1...12).contains(n) {
                if n >= 11 { return .college }
                if n == 9 || n == 10 { return .highSchool }
                return ReadingLevel(rawValue: n)
            }
            return nil
        }

        var label: String {
            switch self {
            case .highSchool: return "high-school"
            case .college: return "college"
            default: return "grade \(rawValue)"
            }
        }

        var directive: String {
            switch self {
            case .grade1, .grade2, .grade3:
                return "READING LEVEL \(label): use very simple, everyday words and short sentences. "
                    + "Explain like I'm a young kid. Avoid jargon; if you must use a hard word, define it."
            case .grade4, .grade5, .grade6:
                return "READING LEVEL \(label): use plain, simple language and short paragraphs. Minimal jargon; "
                    + "explain any technical term in one line."
            case .grade7, .grade8:
                return "READING LEVEL \(label): clear everyday language; some technical terms are fine if explained."
            case .highSchool:
                return "READING LEVEL high-school: normal clear prose; technical terms allowed with brief context."
            case .college:
                return "READING LEVEL college: use precise, advanced vocabulary and domain-specific terminology; "
                    + "assume an expert reader — don't over-explain basics."
            }
        }
    }

    var mode: Mode = .normal
    var readingLevel: ReadingLevel? = nil       // nil = don't constrain vocabulary
    var persona: String? = nil                  // custom personality, injected verbatim, overrides mode voice

    var isDefault: Bool { mode == .normal && readingLevel == nil && (persona?.isEmpty ?? true) }

    /// The style block injected into each turn's prompt. nil when nothing is set.
    func directive() -> String? {
        var parts: [String] = []
        if let persona, !persona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("PERSONA — adopt this voice for your whole reply: \(persona)")
        } else if mode != .normal {
            parts.append(mode.directive)
        }
        if let readingLevel { parts.append(readingLevel.directive) }
        guard !parts.isEmpty else { return nil }
        return "[STYLE]\n" + parts.joined(separator: "\n")
    }

    /// One-line human status for `/mode`.
    var summary: String {
        if let persona, !persona.isEmpty {
            let level = readingLevel.map { " · \($0.label)" } ?? ""
            return "persona: \"\(persona.prefix(60))\"\(level)"
        }
        let level = readingLevel.map { " · \($0.label)" } ?? ""
        return "\(mode.rawValue)\(level)"
    }

    // MARK: - Persistence (per project)

    private static func path(_ projectRoot: String) -> String { projectRoot + "/.kist/repl-style.json" }

    static func load(projectRoot: String) -> ReplStyle {
        guard let data = FileManager.default.contents(atPath: path(projectRoot)),
              let s = try? JSONDecoder().decode(ReplStyle.self, from: data) else { return ReplStyle() }
        return s
    }

    func save(projectRoot: String) {
        let dir = projectRoot + "/.kist"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: URL(fileURLWithPath: Self.path(projectRoot)))
        }
    }
}
