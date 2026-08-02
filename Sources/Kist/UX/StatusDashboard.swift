import Foundation

/// The glanceable operating panel printed at the end of a turn — who's working, what's on the board, how
/// confident the last result is, and what's next. The point (Luke): in five seconds your eyes understand
/// the state of the system, without reading a paragraph. Terminal aesthetic (rules + a progress bar), not
/// a wall of prose. Pure → unit-tested; the REPL feeds it live data.
public struct StatusDashboard: Sendable, Equatable {
    public struct Mind: Sendable, Equatable {
        public let name: String     // "Claude", "Gemini", …
        public let role: String     // "Captain", "Research", "Review", …
        public let active: Bool
        public init(name: String, role: String, active: Bool = true) { self.name = name; self.role = role; self.active = active }
    }
    public struct Item: Sendable, Equatable {
        public enum State: Sendable, Equatable { case done, pending, blocked }
        public let title: String
        public let state: State
        public init(title: String, state: State) { self.title = title; self.state = state }
    }
    public struct ResearchItem: Sendable, Equatable {
        public enum Priority: String, Sendable, Equatable { case high, medium }
        public let title: String
        public let priority: Priority
        public let reason: String
        public let visit: String
        public let impact: Int
        public let estimatedLearning: String
        public let expectedBenefit: [String]
        public init(title: String, priority: Priority, reason: String, visit: String,
                    impact: Int = 3, estimatedLearning: String = "",
                    expectedBenefit: [String] = []) {
            self.title = title
            self.priority = priority
            self.reason = reason
            self.visit = visit
            self.impact = min(5, max(1, impact))
            self.estimatedLearning = estimatedLearning
            self.expectedBenefit = expectedBenefit
        }
    }
    public struct KnowledgeDebt: Sendable, Equatable {
        public let need: String
        public let topic: String
        public let impact: String
        public let severity: Int
        public init(need: String, topic: String, impact: String, severity: Int = 3) {
            self.need = need
            self.topic = topic
            self.impact = impact
            self.severity = min(5, max(1, severity))
        }
    }
    public struct Observation: Sendable, Equatable {
        public let message: String
        public let recommendedReading: [String]
        public let expectedROI: String
        public init(message: String, recommendedReading: [String] = [], expectedROI: String = "") {
            self.message = message
            self.recommendedReading = recommendedReading
            self.expectedROI = expectedROI
        }
    }
    public struct FutureEvolution: Sendable, Equatable {
        public let capability: String
        public let estimatedImpact: String
        public init(capability: String, estimatedImpact: String) {
            self.capability = capability
            self.estimatedImpact = estimatedImpact
        }
    }

    public let minds: [Mind]
    public let tasks: [Item]
    public let learned: [String]
    public let research: [ResearchItem]
    public let knowledgeDebt: [KnowledgeDebt]
    public let questions: [String]
    public let futureEvolution: FutureEvolution?
    public let observation: Observation?
    public let confidence: Double?   // 0…1, nil to hide
    /// The explainable confidence: keeps WHY the score is what it is (reliability/health/grounding),
    /// so the panel can show a battery gauge + the top drag, and `/confidence` can show the full
    /// breakdown. When present it drives the score; `confidence` remains for back-compat callers.
    public let confidenceReport: ConfidenceReport?
    public let next: String?
    public let width: Int

    public init(minds: [Mind] = [], tasks: [Item] = [], learned: [String] = [],
                research: [ResearchItem] = [], knowledgeDebt: [KnowledgeDebt] = [],
                questions: [String] = [], futureEvolution: FutureEvolution? = nil,
                observation: Observation? = nil, confidence: Double? = nil,
                confidenceReport: ConfidenceReport? = nil,
                next: String? = nil, width: Int = 72) {
        self.minds = minds; self.tasks = tasks; self.learned = learned; self.research = research
        self.knowledgeDebt = knowledgeDebt; self.questions = questions
        self.futureEvolution = futureEvolution; self.observation = observation
        self.confidenceReport = confidenceReport
        self.confidence = (confidenceReport?.score ?? confidence).map { min(1, max(0, $0)) }
        // Literal section labels such as "🔋 Confidence" and "/confidence for why" need a
        // usable minimum. Below 24 columns the dashboard cannot preserve those labels honestly.
        self.next = next; self.width = max(24, width)
    }

    // MARK: - Neon category palette
    // Each section owns a distinct bright hue so the eye can jump straight to a section instead of
    // scanning a wall of white. Bright (9x) + bold so headers pop off the transcript.
    enum Cat {
        static let active   = "96;1"   // cyan   — who's working
        static let build    = "95;1"   // magenta— the build queue
        static let research = "94;1"   // blue   — research
        static let learned  = "92;1"   // green  — what we learned
        static let debt     = "93;1"   // yellow — knowledge debt
        static let question = "95;1"   // magenta— open questions
        static let evolve   = "93;1"   // yellow — future evolution
        static let observe  = "96;1"   // cyan   — captain observation
        static let next     = "96;1"   // cyan   — next
    }

    // ANSI
    private func c(_ code: String, _ s: String, _ on: Bool) -> String { on ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }
    /// A neon section header: `icon title` in the category hue.
    private func header(_ icon: String, _ title: String, _ code: String, _ on: Bool) -> String {
        c(code, "\(icon) \(title)", on)
    }
    private func stars(_ value: Int) -> String {
        String(repeating: "★", count: min(5, max(1, value))) + String(repeating: "☆", count: 5 - min(5, max(1, value)))
    }

    /// Render the panel. `color:false` for tests / dumb terminals.
    public func render(color: Bool = true) -> String {
        let rule = c("2", String(repeating: "━", count: width), color)
        var out = "\n" + rule + "\n"

        if !minds.isEmpty {
            out += "\n" + header("🧠", "Active Minds", Cat.active, color) + "\n"
            for m in minds {
                let plainMark = m.active ? "✓ " : "· "
                let renderedMark = c(m.active ? "32" : "2", m.active ? "✓" : "·", color) + " "
                out += wrappedLine("\(m.name) (\(m.role))",
                                   firstPrefix: plainMark,
                                   continuationPrefix: "  ",
                                   firstRenderedPrefix: renderedMark)
            }
            out += "\n" + rule + "\n"
        }

        if !tasks.isEmpty {
            out += "\n" + header("📋", "Build Queue", Cat.build, color) + "\n\n"
            for t in tasks {
                switch t.state {
                case .done:
                    out += wrappedLine(t.title, firstPrefix: "✓ ", continuationPrefix: "  ",
                                       firstRenderedPrefix: c("32", "✓", color) + " ")
                case .pending:
                    out += wrappedLine(t.title, firstPrefix: "⏳ ", continuationPrefix: "  ")
                case .blocked:
                    out += wrappedLine(t.title, firstPrefix: "⊘ ", continuationPrefix: "  ",
                                       firstRenderedPrefix: c("31", "⊘", color) + " ")
                }
            }
            out += "\n" + rule + "\n"
        }

        if !learned.isEmpty {
            out += "\n" + header("🧠", "What We Learned", Cat.learned, color) + "\n\n"
            for item in learned.prefix(5) {
                out += wrappedLine(item, firstPrefix: "• ", continuationPrefix: "  ")
            }
            out += "\n" + rule + "\n"
        }

        if !research.isEmpty {
            out += "\n" + header("🔬", "Research Queue", Cat.research, color) + "\n\n"
            for (label, priority) in [("High Priority", ResearchItem.Priority.high),
                                      ("Medium Priority", .medium)] {
                let items = research.filter { $0.priority == priority }
                guard !items.isEmpty else { continue }
                out += c(priority == .high ? "31;1" : "33;1", label, color) + "\n\n"
                for item in items {
                    out += wrappedLine(item.title, firstPrefix: "• ", continuationPrefix: "  ")
                    out += wrappedLine(item.reason, firstPrefix: "  Why: ", continuationPrefix: "       ",
                                       firstRenderedPrefix: c("2", "  Why: ", color))
                    if !item.visit.isEmpty {
                        out += wrappedLine(item.visit, firstPrefix: "  Visit: ", continuationPrefix: "         ",
                                           firstRenderedPrefix: c("2", "  Visit: ", color))
                    }
                    let impact = stars(item.impact)
                        + (item.estimatedLearning.isEmpty ? "" : " · learning: \(item.estimatedLearning)")
                    out += wrappedLine(impact,
                                       firstPrefix: "  Impact: ",
                                       continuationPrefix: "          ",
                                       firstRenderedPrefix: c("2", "  Impact: ", color))
                    if !item.expectedBenefit.isEmpty {
                        out += wrappedLine(item.expectedBenefit.joined(separator: "; "),
                                           firstPrefix: "  Expected benefit: ",
                                           continuationPrefix: "                    ",
                                           firstRenderedPrefix: c("2", "  Expected benefit: ", color))
                    }
                    out += "\n"
                }
            }
            out += rule + "\n"
        }

        if !knowledgeDebt.isEmpty {
            out += "\n" + header("📚", "Knowledge Debt", Cat.debt, color) + "\n\n"
            for item in knowledgeDebt {
                out += stars(item.severity) + "\n"
                out += wrappedLine(item.topic, firstPrefix: "\(item.need): ",
                                   continuationPrefix: String(repeating: " ", count: item.need.count + 2))
                out += wrappedLine(item.impact, firstPrefix: "Impact: ", continuationPrefix: "        ",
                                   firstRenderedPrefix: c("2", "Impact: ", color)) + "\n"
            }
            out += rule + "\n"
        }

        if !questions.isEmpty {
            out += "\n" + header("🧠", "Questions", Cat.question, color) + "\n\n"
            for question in questions {
                out += wrappedLine(question, firstPrefix: "? ", continuationPrefix: "  ")
            }
            out += "\n" + rule + "\n"
        }

        if let futureEvolution, !futureEvolution.capability.isEmpty {
            out += "\n" + header("💡", "Future Evolution", Cat.evolve, color) + "\n\n"
            out += c("2", "Next logical capability", color) + "\n"
            out += wrappedLine(futureEvolution.capability) + "\n"
            if !futureEvolution.estimatedImpact.isEmpty {
                out += c("2", "Estimated impact", color) + "\n"
                out += wrappedLine(futureEvolution.estimatedImpact)
            }
            out += "\n" + rule + "\n"
        }

        if let observation, !observation.message.isEmpty {
            out += "\n" + header("🧭", "Captain Observation", Cat.observe, color) + "\n"
            out += wrappedLine(observation.message)
            if !observation.recommendedReading.isEmpty {
                out += wrappedLine(observation.recommendedReading.joined(separator: ", "),
                                   firstPrefix: "Recommended reading: ",
                                   continuationPrefix: "                     ",
                                   firstRenderedPrefix: c("2", "Recommended reading: ", color))
            }
            if !observation.expectedROI.isEmpty {
                out += wrappedLine(observation.expectedROI, firstPrefix: "Expected ROI: ", continuationPrefix: "              ",
                                   firstRenderedPrefix: c("2", "Expected ROI: ", color))
            }
            out += "\n" + rule + "\n"
        }

        out += confidenceSection(color: color)

        if let next, !next.isEmpty {
            out += "\n" + header("→", "Next", Cat.next, color) + "\n"
            out += wrappedLine(next, firstPrefix: "→ ", continuationPrefix: "  ",
                               firstRenderedPrefix: c(Cat.next, "→ ", color))
            out += "\n" + rule + "\n"
        }
        return out
    }

    /// The confidence block: a battery gauge in its charge color + the top factor dragging it down +
    /// a `/confidence` pointer to the full breakdown. Shared by full + compact renders so the bar is
    /// green-when-good everywhere (the compact panel used to print it with NO color at all).
    private func confidenceSection(color: Bool) -> String {
        let rule = c("2", String(repeating: "━", count: width), color)
        if let report = confidenceReport {
            var out = "\n" + header("🔋", "Confidence", report.batteryCode, color) + "\n"
            out += report.bar(width: 10, color: color) + "\n"
            if let top = report.pending.max(by: { $0.penalty < $1.penalty }) {
                out += wrappedLine(top.label.lowercased() + " · ↑ " + top.raise,
                                   firstPrefix: "drag: ",
                                   continuationPrefix: "      ",
                                   firstRenderedPrefix: c("2", "drag: ", color))
            }
            out += wrappedLine("/confidence for why")
            out += "\n" + rule + "\n"
            return out
        }
        guard let confidence else { return "" }
        let filled = Int((confidence * 10).rounded())
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 10 - filled)
        let col = confidence >= 0.75 ? "92;1" : (confidence >= 0.5 ? "93;1" : "91;1")
        var out = "\n" + header("🔋", "Confidence", col, color) + "\n"
        out += c(col, bar, color) + " " + c(col, "\(Int((confidence * 100).rounded()))%", color) + "\n"
        out += "\n" + rule + "\n"
        return out
    }

    /// Compact end-of-turn panel for read-only, interrupted, or no-progress turns. It keeps the operating
    /// signal visible without dumping the full research/knowledge-debt board every time.
    public func renderCompact(color: Bool = true) -> String {
        let rule = c("2", String(repeating: "━", count: width), color)
        var out = "\n" + rule + "\n"
        if !minds.isEmpty {
            out += "\n" + header("🧠", "Active", Cat.active, color) + "\n"
            let activeLine = minds.prefix(3)
                .map { "\($0.active ? "✓" : "·") \($0.name) \($0.role)" }
                .joined(separator: " · ")
            out += wrappedLine(activeLine)
            out += rule + "\n"
        }
        if !tasks.isEmpty {
            out += "\n" + header("📋", "Build Queue", Cat.build, color) + "\n"
            for task in tasks.prefix(3) {
                let mark: String
                switch task.state {
                case .done: mark = c("92;1", "✓", color)
                case .pending: mark = c("93;1", "⏳", color)
                case .blocked: mark = c("91;1", "⊘", color)
                }
                out += wrappedLine(task.title, firstPrefix: "· ", continuationPrefix: "  ",
                                   firstRenderedPrefix: mark + " ")
            }
            if tasks.count > 3 { out += c("2", "… +\(tasks.count - 3) more · /tasks", color) + "\n" }
            out += rule + "\n"
        }
        if !research.isEmpty {
            out += "\n" + header("🔬", "Research", Cat.research, color) + "\n"
            for item in research.prefix(3) {
                let title = item.title + (item.impact >= 5 ? " · high ROI" : "")
                out += wrappedLine(title, firstPrefix: "• ", continuationPrefix: "  ",
                                   firstRenderedPrefix: c(Cat.research, "•", color) + " ")
            }
            out += c("2", "details: /summary", color) + "\n"
            out += rule + "\n"
        }
        out += confidenceSection(color: color)
        if let next, !next.isEmpty {
            out += "\n" + header("→", "Next", Cat.next, color) + "\n"
            out += wrappedLine(next, firstPrefix: "→ ", continuationPrefix: "  ",
                               firstRenderedPrefix: c(Cat.next, "→ ", color))
            out += "\n" + rule + "\n"
        }
        return out
    }

    private func wrappedLine(_ text: String,
                             firstPrefix: String = "",
                             continuationPrefix: String? = nil,
                             firstRenderedPrefix: String? = nil) -> String {
        let restPrefix = continuationPrefix ?? String(repeating: " ", count: firstPrefix.count)
        let renderedFirst = firstRenderedPrefix ?? firstPrefix
        var out = ""
        for paragraph in text.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let lines = wrapParagraph(String(paragraph), firstPrefix: firstPrefix, continuationPrefix: restPrefix)
            for (index, line) in lines.enumerated() {
                out += (index == 0 ? renderedFirst : restPrefix) + line + "\n"
            }
        }
        return out
    }

    private func wrapParagraph(_ text: String, firstPrefix: String, continuationPrefix: String) -> [String] {
        let words = text.split { $0.isWhitespace }.map(String.init)
        guard !words.isEmpty else { return [""] }

        var lines: [String] = []
        var current = ""
        var capacity = max(1, width - firstPrefix.count)
        let continuationCapacity = max(1, width - continuationPrefix.count)

        func pushCurrent() {
            lines.append(current)
            current = ""
            capacity = continuationCapacity
        }

        for word in words {
            var remaining = word
            while !remaining.isEmpty {
                if current.isEmpty {
                    if remaining.count <= capacity {
                        current = remaining
                        remaining = ""
                    } else {
                        let splitIndex = remaining.index(remaining.startIndex, offsetBy: capacity)
                        lines.append(String(remaining[..<splitIndex]))
                        remaining = String(remaining[splitIndex...])
                        capacity = continuationCapacity
                    }
                } else if current.count + 1 + remaining.count <= capacity {
                    current += " " + remaining
                    remaining = ""
                } else {
                    pushCurrent()
                }
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
