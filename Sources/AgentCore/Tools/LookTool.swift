import Foundation

/// Fast, cheap "what am I looking at?" — captures the screen and describes it (or answers a question about
/// it) with a small vision model (Moondream), so the decision model can reason about game/app state every
/// turn without paying for a full big-model `view_image`. Completes the perception trio: `look` (what's
/// there) · `locate` (where is X) · `wait_for_screen` (has X appeared).
///
/// Capture + perception injected so it's unit-tested without a real screen or model.
public struct LookTool: AgentTool {
    public let name = "look"
    public var description: String {
        """
        Take a quick look at the screen and get a plain-language description, or answer a specific \
        question about what's visible (pass 'question'). Cheap/fast — use it to understand current state \
        before deciding, instead of the heavier view_image. macOS main display; needs Screen Recording + a \
        Moondream key/URL.
        """
    }

    public var parameters: [ToolParameter] {
        [
            ToolParameter(name: "question", type: "string", description: "Optional question about the screen, e.g. 'whose turn is it?'. Omit for a general description.", required: false),
        ]
    }
    public var capabilityNote: String? {
        "Describes/answers about the CURRENT screen (main display). It does not click or type — follow with tap/desktop_control. For pixel coordinates of a target use locate."
    }
    public var usageExamples: [String] { ["{}", "{\"question\":\"is it my turn?\"}"] }

    public typealias Capture = @Sendable () async -> (data: Data, width: Int, height: Int)?
    /// Perceive a frame; `question` nil ⇒ caption the whole screen, non-nil ⇒ answer that question.
    public typealias Perceive = @Sendable (_ pngData: Data, _ question: String?) async throws -> String

    private let capture: Capture
    private let perceive: Perceive

    public init(capture: @escaping Capture, perceive: @escaping Perceive) {
        self.capture = capture
        self.perceive = perceive
    }

    /// Production wiring: real main-display capture + Moondream caption (no question) or query (question).
    public static func wired(client: MoondreamClient = MoondreamClient()) -> LookTool {
        LookTool(
            capture: {
                #if canImport(CoreGraphics)
                return DesktopControlTool.captureMainDisplayPNG()
                #else
                return nil
                #endif
            },
            perceive: { data, question in
                if let question, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return try await client.query(imageData: data, mime: "image/png", question: question)
                }
                return try await client.caption(imageData: data, mime: "image/png")
            })
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let question = (arguments["question"] as? String).flatMap { q -> String? in
            let t = q.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t
        }
        guard let shot = await capture() else {
            return .failure("could not capture the screen — grant Screen Recording permission to this process.")
        }
        let text = try await perceive(shot.data, question)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure("the vision model returned an empty description.")
        }
        let label = question.map { "Q: \($0)\nA: " } ?? "On screen: "
        return ToolResult(success: true, output: label + trimmed,
                          metadata: ["chars": "\(trimmed.count)", "mode": question == nil ? "caption" : "query"])
    }
}
