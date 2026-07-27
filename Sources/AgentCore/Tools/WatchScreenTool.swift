import Foundation

/// Always-on screen watching: start a background perception loop, then query its state or stop it — so the
/// agent can keep working while "keeping an eye" on the screen and react when something appears or changes.
/// Complements `wait_for_screen` (which BLOCKS until one thing appears): `watch_screen` runs in the
/// background and is polled.
///
/// Backends (session factory + the background launcher) are injected, so start/state/stop dispatch is
/// unit-tested deterministically without real timers. Shares one `PerceptionMonitor` across calls.
public struct WatchScreenTool: AgentTool {
    public let name = "watch_screen"
    public var description: String {
        """
        Watch the screen in the BACKGROUND (unlike wait_for_screen which blocks). action=start begins a \
        bounded background watch (optionally for named things via watch_for); action=state reports what's \
        on screen now and what appeared/changed since your last check; action=stop ends it. Use start, keep \
        doing other work, then poll state. macOS main display; needs Screen Recording + a Moondream key/URL.
        """
    }

    public var parameters: [ToolParameter] {
        [
            ToolParameter(name: "action", type: "string", description: "start | state | stop."),
            ToolParameter(name: "watch_for", type: "string", description: "(start) comma-separated things to watch for, e.g. 'enemy, game over'. Optional.", required: false),
            ToolParameter(name: "interval_seconds", type: "integer", description: "(start) seconds between checks (default 1, 1..30).", required: false),
        ]
    }
    public var supportedActions: [String] { ["start", "state", "stop"] }
    public var capabilityNote: String? {
        "Background watcher (poll it with action=state). For a blocking wait on one thing use wait_for_screen; for a one-shot read use look. It does not click/type."
    }
    public var usageExamples: [String] { ["{\"action\":\"start\",\"watch_for\":\"enemy, game over\"}", "{\"action\":\"state\"}", "{\"action\":\"stop\"}"] }

    public typealias MakeSession = @Sendable (_ watches: [String]) -> StreamingPerception

    static let defaultInterval = 1
    static let maxInterval = 30

    private let monitor: PerceptionMonitor
    private let makeSession: MakeSession
    private let spawn: PerceptionMonitor.Spawn

    public init(monitor: PerceptionMonitor, makeSession: @escaping MakeSession,
                spawn: @escaping PerceptionMonitor.Spawn) {
        self.monitor = monitor
        self.makeSession = makeSession
        self.spawn = spawn
    }

    /// Production wiring: real capture + Moondream caption, one shared monitor, background via Task.detached.
    public static func wired(monitor: PerceptionMonitor, client: MoondreamClient = MoondreamClient()) -> WatchScreenTool {
        WatchScreenTool(
            monitor: monitor,
            makeSession: { watches in
                StreamingPerception(
                    capture: {
                        #if canImport(CoreGraphics)
                        return DesktopControlTool.captureMainDisplayPNG()
                        #else
                        return nil
                        #endif
                    },
                    perceive: { data in try await client.caption(imageData: data, mime: "image/png") },
                    watches: watches)
            },
            spawn: { Task.detached(operation: $0) })
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let action = (try requireString("action", from: arguments)).lowercased()
        switch action {
        case "start":
            let watches = ((arguments["watch_for"] as? String) ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let seconds = min(max(1, optionalInt("interval_seconds", from: arguments) ?? Self.defaultInterval), Self.maxInterval)
            let interval = UInt64(seconds) * 1_000_000_000
            let session = makeSession(watches)
            // begin owns the single background loop (cancels any prior watch); no racing loops.
            await monitor.begin(session: session, intervalNanos: interval, spawn: spawn)
            let forNote = watches.isEmpty ? "" : " watching for: \(watches.joined(separator: ", "))."
            return ToolResult(success: true, output: "Background screen watch started (every \(seconds)s).\(forNote) Poll it with watch_screen(action=\"state\").",
                              metadata: ["running": "true", "watch_for": "\(watches.count)"])

        case "state":
            let s = await monitor.snapshot()
            var out = s.running ? "Watching (checked \(s.ticks) frame(s))." : "Not watching (start one with action=start)."
            if let latest = s.latest { out += " On screen: \(latest.prefix(240))" }
            let appeared = s.events.filter { $0.kind == .appeared }.map(\.detail)
            if !appeared.isEmpty { out += " ⚡ APPEARED: \(Set(appeared).sorted().joined(separator: ", "))." }
            if s.events.contains(where: { $0.kind == .changed }) { out += " (screen changed since last check)." }
            return ToolResult(success: true, output: out,
                              metadata: ["running": "\(s.running)", "ticks": "\(s.ticks)", "appeared": "\(appeared.count)"])

        case "stop":
            await monitor.stop()
            return ToolResult(success: true, output: "Background screen watch stopped.", metadata: ["running": "false"])

        default:
            return .failure("unknown watch_screen action '\(action)'. Valid: start, state, stop.")
        }
    }
}
