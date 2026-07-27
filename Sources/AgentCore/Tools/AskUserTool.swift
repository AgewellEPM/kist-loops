import Foundation

/// CLARIFYING QUESTIONS as a first-class tool — the conversational mechanism most-noticed missing vs
/// Claude Code. Instead of guessing on an ambiguous request or dumping a wall of prose, the agent calls
/// `ask_user` to ask ONE short, specific question and gets the answer back as the observation. This wires
/// the runtime's `RuntimeInteractor.requestInput`, which previously existed but was never reachable.
///
/// In a non-interactive context (one-shot/fleet/--auto, where the interactor auto-answers empty) it returns
/// a "proceed with best judgment" note rather than blocking — autopilot can't stop to ask a human.
public struct AskUserTool: AgentTool {
    private let interactor: RuntimeInteractor
    public init(interactor: RuntimeInteractor) { self.interactor = interactor }

    public var name: String { "ask_user" }
    public var description: String {
        "Ask the user ONE short, specific clarifying question when intent is genuinely ambiguous or a "
        + "choice has real consequences you can't resolve yourself. Returns their answer. Use sparingly — "
        + "prefer a sensible default and proceeding; only ask when you truly cannot."
    }
    public var parameters: [ToolParameter] {
        [
            ToolParameter(name: "question", type: "string",
                          description: "the single, specific question to ask the user", required: true),
            ToolParameter(name: "options", type: "string",
                          description: "optional comma-separated choices to offer", required: false),
        ]
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let q = (arguments["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .failure("ask_user requires a non-empty 'question'") }
        let opts = (arguments["options"] as? String).flatMap { s -> String? in
            let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : "  (options: \(t))"
        } ?? ""
        let answer = await interactor.requestInput(question: q + opts).trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isEmpty {
            return ToolResult(success: true, output: "(no answer — running non-interactively; proceed with "
                              + "your best judgment and state the assumption you made)")
        }
        return ToolResult(success: true, output: "The user answered: \(answer)")
    }
}
