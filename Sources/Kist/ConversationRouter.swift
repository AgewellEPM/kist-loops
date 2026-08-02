import Foundation
import AgentCore

/// The INTENT ROUTER — the Claude-Code "just talk and it does the right thing" layer. Given a plain
/// message in the REPL, it decides whether the request is best served INLINE (an ordinary chat/build turn)
/// or by ESCALATING to a heavier capability (a typed plan-DAG, or a supervised parallel fleet). It never
/// spends big silently: it returns a PROPOSAL that the REPL confirms with the user before acting — so an
/// expensive fleet is never launched without a yes.
///
/// Cost-aware by design: a cheap heuristic skips the LLM for obvious chat (short messages, questions), so
/// the classifier call only fires for substantive build-shaped requests.
struct ConversationRouter {
    let providers: ProviderRegistry
    let binding: ProviderBinding      // a fast model for the one-word classification
    var defaultFleetAgents: Int = 3

    enum Route: Equatable {
        case fleet(agents: Int)
        case planExecute
        case council
        case research
    }
    struct Proposal { let route: Route; let prompt: String }

    /// Propose an escalation, or nil to just handle the message inline (chat/build).
    func propose(_ input: String, resolvedIntent: TaskBrief.Intent? = nil) async -> Proposal? {
        let intent = resolvedIntent ?? PromptCompiler.inferIntent(input)
        // Semantic intent belongs to PromptCompiler. This router chooses only a compatible execution
        // escalation; it may not reinterpret an answer/review request as a build or research run.
        guard Self.mayEscalate(intent) else { return nil }
        // Cheap pre-filter: obviously-chat → never escalate, and don't pay for a classifier call.
        if Self.isObviouslyChat(input) { return nil }
        guard let route = await classify(input) else { return nil }
        guard Self.compatible(route, with: intent) else { return nil }
        switch route {
        case .fleet:
            return Proposal(route: .fleet(agents: defaultFleetAgents),
                            prompt: "⇪ This looks like a large multi-part build that could split into a parallel fleet "
                                  + "(\(defaultFleetAgents) disjoint-lease agents, forge-proof signoff). Spawn the fleet? [y/N]")
        case .planExecute:
            return Proposal(route: .planExecute,
                            prompt: "⇪ This looks like a multi-step build. Run it as a typed plan-DAG (your planner→coder→critic team)? [y/N]")
        case .council:
            return Proposal(route: .council,
                            prompt: "⇪ This looks like strategy/roadmap work. Convene the council to produce a decision and task board? [y/N]")
        case .research:
            return Proposal(route: .research,
                            prompt: "⇪ This looks like source-backed research. Run the evidence-first research pipeline before council synthesis? [y/N]")
        }
    }

    static func mayEscalate(_ intent: TaskBrief.Intent) -> Bool {
        switch intent {
        case .build, .research, .review, .plan, .fleet: return true
        case .chat, .desktop: return false
        }
    }

    static func compatible(_ route: Route, with intent: TaskBrief.Intent) -> Bool {
        switch (intent, route) {
        case (.build, .planExecute), (.build, .fleet),
             (.fleet, .fleet), (.fleet, .planExecute),
             (.research, .research),
             (.review, .council), (.plan, .council):
            return true
        default:
            return false
        }
    }

    // MARK: - Classification

    /// True for messages that are clearly conversation (a question, a short ask, an explainer opener) —
    /// never an escalation, and not worth a classifier call.
    static func isObviouslyChat(_ input: String) -> Bool {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.count >= 40 && (hasBuildIntent(t) || hasResearchIntent(t)) { return false }
        return t.count < 40 || t.hasSuffix("?")
            || t.hasPrefix("what") || t.hasPrefix("why") || t.hasPrefix("how do")
            || t.hasPrefix("explain") || t.hasPrefix("tell me") || t.hasPrefix("can you explain")
    }

    private static func hasBuildIntent(_ text: String) -> Bool {
        ["add ", "build", "create", "implement", "refactor", "update", "wire", "spawn", "fleet", "plan-execute"]
            .contains { text.contains($0) }
    }

    private static func hasResearchIntent(_ text: String) -> Bool {
        ["research", "deep dive", "landscape", "roadmap", "compare", "cross compare", "look up", "investigate", "analyze the future"]
            .contains { text.contains($0) }
    }

    private func classify(_ input: String) async -> Route? {
        let messages = [
            ChatMessage(role: .system, content: Self.systemPrompt),
            ChatMessage(role: .user, content: "REQUEST:\n\(input)\n\nReply with ONE word."),
        ]
        guard let raw = try? await providers.complete(providerId: binding.providerId, model: binding.model, messages: messages)
        else { return nil }
        return Self.parseRoute(raw, defaultFleetAgents: defaultFleetAgents)
    }

    static func parseRoute(_ raw: String, defaultFleetAgents: Int) -> Route? {
        var word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if word.hasPrefix("```") {
            if let firstNL = word.firstIndex(of: "\n") { word = String(word[word.index(after: firstNL)...]) }
            if let fence = word.range(of: "```", options: .backwards) { word = String(word[..<fence.lowerBound]) }
        }
        word = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "`.,;:!\"'")))
        switch word {
        case "fleet": return .fleet(agents: defaultFleetAgents)
        case "plan": return .planExecute
        case "council": return .council
        case "research": return .research
        default: return nil   // chat | build | malformed/prose → handle inline
        }
    }

    static let systemPrompt = """
    You route a developer's request to the cheapest capability that fits. Reply with EXACTLY ONE word:
      chat   — a question, discussion, or tiny edit. Handle inline.
      build  — a single, focused coding task in one area. Handle inline.
      plan   — a multi-step build in one codebase area that benefits from an up-front typed plan.
      research — evidence-first fact finding, current-state research, or source-backed comparison.
      council — strategy analysis, roadmap work, or a decision that needs multiple minds to disagree
                before producing a task board.
      fleet  — a LARGE build that naturally splits into SEVERAL INDEPENDENT parts touching SEPARATE
               files/modules, where parallel agents would help.
    Bias toward the cheaper option when unsure (chat/build over plan/fleet). Reply with the single word only.
    """
}
