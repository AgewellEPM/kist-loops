import Foundation

/// Agent tool: answer a question with LIVE Google Search grounding via Gemini, returning a synthesized
/// answer plus source citations. This is how grounding reaches the agent at all: Gemini's built-in
/// tools CANNOT be sent alongside our function declarations (the API 400s), and the agent loop always
/// carries functions — so grounding is unreachable inline. This tool makes a separate TOOL-LESS Gemini
/// call (where the built-ins are allowed) and hands the grounded result back.
public struct GroundedAnswerTool: AgentTool {
    public let name = "grounded_answer"
    public let description = """
    Answer a question using LIVE Google Search grounding (Gemini) — returns a synthesized answer with \
    source citations. Use for current events, recent facts, prices, releases, or anything needing \
    up-to-date web information that your training data may not have.
    """
    public let parameters = [
        ToolParameter(name: "question", type: "string", description: "The question to answer with live web grounding.", required: true),
    ]

    /// (question) -> grounded answer text (includes the model's "Sources:" citations). Injectable for tests.
    private let answer: @Sendable (_ question: String) async throws -> String

    public init(geminiKey: String, model: String = "gemini-2.5-flash") {
        self.answer = { question in
            // Tool-less call → makeBodyTools adds google_search/url_context/code_execution (built-ins
            // are only valid without functionDeclarations). geminiBuiltins defaults ON.
            let stream = try await GeminiProvider().streamTools(
                messages: [
                    ChatMessage(role: .system, content: "Answer the question concisely using live web search. Cite the sources you used."),
                    ChatMessage(role: .user, content: question),
                ],
                model: model, settings: ModelSettings(), apiKey: geminiKey, tools: [])
            var text = ""
            for try await event in stream { if case .delta(let d) = event { text += d } }
            return text
        }
    }

    public init(answer: @escaping @Sendable (_ question: String) async throws -> String) {
        self.answer = answer
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let question = try requireString("question", from: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return .failure("empty question") }
        let result = try await answer(question).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return .failure("grounded answer came back empty") }
        return ToolResult(success: true, output: result)
    }
}
