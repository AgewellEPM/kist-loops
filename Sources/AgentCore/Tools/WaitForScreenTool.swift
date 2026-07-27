import Foundation

/// Block until something appears on screen — the missing piece for reliable GUI sequencing. Real apps and
/// games have loading screens, animations, and transitions; firing the next click before the target exists
/// is how automation desyncs. `wait_for_screen` polls the screen (fast vision model) until the described
/// thing is visible or a bounded timeout elapses, so the agent can say "click New Game, then WAIT for the
/// character screen, then continue."
///
/// Built on `StreamingPerception`. Session factory and sleep are injected so the poll loop is unit-tested
/// deterministically with scripted frames and no real waiting.
public struct WaitForScreenTool: AgentTool {
    public let name = "wait_for_screen"
    public var description: String {
        """
        Wait until something described in plain language appears on screen (e.g. "the character creation \
        screen", "the loading bar is gone"), up to a timeout. Use after an action that triggers a \
        transition, before the next action. Returns when it appears, or reports it didn't within the \
        timeout (with what was last seen). macOS main display; needs Screen Recording + a Moondream key/URL.
        """
    }

    public var parameters: [ToolParameter] {
        [
            ToolParameter(name: "condition", type: "string", description: "Plain-language description of what to wait for, e.g. 'the main menu'."),
            ToolParameter(name: "timeout_checks", type: "integer", description: "Max number of screen checks before giving up (default 15, max 120).", required: false),
        ]
    }
    public var capabilityNote: String? {
        "Polls the screen until the condition is visible or the check budget runs out; it does not click or type. Follow with tap/desktop_control once the condition is met."
    }
    public var usageExamples: [String] { ["{\"condition\":\"the character creation screen\",\"timeout_checks\":20}"] }

    public typealias MakeSession = @Sendable (_ condition: String) -> StreamingPerception
    public typealias Sleep = @Sendable () async -> Void

    static let defaultChecks = 15
    static let maxChecks = 120

    private let makeSession: MakeSession
    private let sleepBetweenChecks: Sleep

    public init(makeSession: @escaping MakeSession, sleepBetweenChecks: @escaping Sleep) {
        self.makeSession = makeSession
        self.sleepBetweenChecks = sleepBetweenChecks
    }

    /// Production wiring: real main-display capture + a Moondream yes/no visibility probe, ~1s between checks.
    public static func wired(client: MoondreamClient = MoondreamClient()) -> WaitForScreenTool {
        WaitForScreenTool(
            makeSession: { condition in
                StreamingPerception(
                    capture: {
                        #if canImport(CoreGraphics)
                        return DesktopControlTool.captureMainDisplayPNG()
                        #else
                        return nil
                        #endif
                    },
                    perceive: { data in
                        // A tight yes/no probe keeps perception cheap and the watch match unambiguous.
                        try await client.query(imageData: data, mime: "image/png",
                                               question: "Is \(condition) visible on the screen right now? Answer only 'yes' or 'no'.")
                    },
                    watches: ["yes"])
            },
            sleepBetweenChecks: { try? await Task.sleep(nanoseconds: 1_000_000_000) })
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let condition = try requireString("condition", from: arguments)
        guard !condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("condition must describe what to wait for (it was empty).")
        }
        let checks = min(max(1, optionalInt("timeout_checks", from: arguments) ?? Self.defaultChecks), Self.maxChecks)
        let session = makeSession(condition)

        for i in 1...checks {
            try Task.checkCancellation()   // honor interruption instead of polling to the end
            await session.tick()
            if await session.drainEvents().contains(where: { $0.kind == .appeared }) {
                // Report the loop INDEX, not frameCount(): dedup skips identical frames, so frameCount is
                // perceived-unique-frames, not checks performed (Codex).
                return ToolResult(success: true, output: "'\(condition)' appeared on screen (after \(i) check(s)).",
                                  metadata: ["appeared": "true", "checks": "\(i)"])
            }
            if i < checks { await sleepBetweenChecks() }   // no wasted sleep after the final check
        }
        let last = await session.latestObservation()?.text ?? "nothing perceived"
        return ToolResult(success: true,
                          output: "'\(condition)' did not appear within \(checks) checks. Last observation: \(last.prefix(200))",
                          metadata: ["appeared": "false", "checks": "\(checks)"])
    }
}
