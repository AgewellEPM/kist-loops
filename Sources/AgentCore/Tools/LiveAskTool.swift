import Foundation

/// Agent tool: ask a question over the Gemini Live API (realtime bidirectional WebSocket) and return
/// the text answer. PROTOTYPE — the live session is the foundation for voice; a terminal can't capture
/// audio, so this exposes the text round-trip that proves the transport.
public struct LiveAskTool: AgentTool {
    public let name = "live_ask"
    public let description = """
    Ask a question over the Gemini Live API (low-latency realtime session) and return the text answer. \
    PROTOTYPE — foundation for future voice; today it does a text round-trip over the live socket.
    """
    public let parameters = [
        ToolParameter(name: "text", type: "string", description: "The question to ask over the live session.", required: true),
    ]

    private let ask: @Sendable (_ text: String) async throws -> String

    public init(geminiKey: String) {
        let client = GeminiLiveClient(apiKey: geminiKey)
        self.ask = { text in try await client.ask(text) }
    }

    public init(ask: @escaping @Sendable (_ text: String) async throws -> String) {
        self.ask = ask
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let text = try requireString("text", from: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure("nothing to ask") }
        let answer = try await ask(text)
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("live session returned no answer")
        }
        return ToolResult(success: true, output: answer.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
