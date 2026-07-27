import Foundation

/// THE TIGHT LOOP. Collapses "screenshot → locate → click" into ONE tool call: name a target and it
/// captures the screen, finds the target (Moondream point), and clicks it. Cuts three model round-trips
/// per action to one — the difference between painfully-slow and actually-playable GUI control.
///
/// All three backends are injected so the whole flow is unit-tested without a real screen, model, or
/// mouse. Production wiring (`PointClickTool.wired`) composes the real capture + Moondream + CGEvent click.
public struct PointClickTool: AgentTool {
    public let name = "tap"
    public var description: String {
        """
        Find a named on-screen target and click it in ONE step (captures the screen, locates the target, \
        clicks it). Prefer this over separate screenshot+locate+click for speed. Returns 'not found' (not \
        an error) when the target isn't visible so you can re-plan. macOS main display; needs Accessibility \
        + Screen Recording + a Moondream key/URL.
        """
    }

    public var parameters: [ToolParameter] {
        [
            ToolParameter(name: "target", type: "string", description: "Plain-language description of what to click, e.g. 'the New Game button'."),
            ToolParameter(name: "button", type: "string", description: "'left' (default) or 'right'.", required: false),
            ToolParameter(name: "double", type: "boolean", description: "Double-click when true (default false).", required: false),
        ]
    }
    public var capabilityNote: String? {
        "Captures + locates + clicks on the MAIN display in one call. For typing/keys use desktop_control. Returns 'not found' when the target isn't visible."
    }
    public var usageExamples: [String] { ["{\"target\":\"the New Game button\"}", "{\"target\":\"the red door\",\"double\":true}"] }

    public typealias Capture = @Sendable () async -> (data: Data, width: Int, height: Int)?
    public typealias Locate = @Sendable (_ pngData: Data, _ target: String) async throws -> [MoondreamClient.NormPoint]
    public typealias Click = @Sendable (_ x: Int, _ y: Int, _ right: Bool, _ clicks: Int) async -> DesktopControlTool.ClickOutcome

    private let capture: Capture
    private let locate: Locate
    private let click: Click

    public init(capture: @escaping Capture, locate: @escaping Locate, click: @escaping Click) {
        self.capture = capture
        self.locate = locate
        self.click = click
    }

    /// Production wiring: real main-display capture + Moondream pointing + real CGEvent click.
    public static func wired(client: MoondreamClient = MoondreamClient()) -> PointClickTool {
        PointClickTool(
            capture: {
                #if canImport(CoreGraphics)
                return DesktopControlTool.captureMainDisplayPNG()
                #else
                return nil
                #endif
            },
            locate: { data, target in try await client.point(imageData: data, mime: "image/png", object: target) },
            click: { x, y, right, clicks in
                #if canImport(CoreGraphics)
                return DesktopControlTool.clickMainDisplayPixel(x: x, y: y, right: right, clicks: clicks)
                #else
                return .failed("desktop control requires macOS")
                #endif
            })
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let target = try requireString("target", from: arguments)
        // button must be absent or a string; a present non-string is a malformed call, not a left-click.
        let right: Bool
        if let raw = arguments["button"] {
            guard let s = raw as? String else { return .failure("button must be a string ('left' or 'right')") }
            switch s.lowercased().trimmingCharacters(in: .whitespaces) {
            case "", "left": right = false
            case "right": right = true
            case let other: return .failure("unknown button '\(other)' — use 'left' or 'right'")
            }
        } else {
            right = false
        }
        let clicks = (optionalBool("double", from: arguments) ?? false) ? 2 : 1

        guard let shot = await capture() else {
            return .failure("could not capture the screen — grant Screen Recording permission to this process.")
        }
        let points = try await locate(shot.data, target)
        // Only act on a point that is a VALID normalized coordinate. `tap` auto-clicks, so — unlike the
        // read-only `locate` — a garbage/out-of-[0,1] result must be REFUSED, not clamped to an edge.
        guard let inRange = points.first(where: { $0.x.isFinite && $0.y.isFinite && (0.0...1.0).contains($0.x) && (0.0...1.0).contains($0.y) }),
              let first = MoondreamClient.pixels(from: [inRange], width: shot.width, height: shot.height).first else {
            return ToolResult(success: true, output: "'\(target)' was not found on screen — try a different description or check what's visible.",
                              metadata: ["found": "0"])
        }
        switch await click(first.x, first.y, right, clicks) {
        case .clicked(let x, let y):
            return ToolResult(success: true, output: "\(right ? "right-" : "")\(clicks == 2 ? "double-" : "")tapped '\(target)' at \(x),\(y) px",
                              metadata: ["x": "\(x)", "y": "\(y)", "found": "\(points.count)"])
        case .outOfBounds(let m):
            return .failure("located '\(target)' but \(m)")
        case .notTrusted:
            return .failure("Accessibility permission not granted — grant it in System Settings → Privacy & Security → Accessibility.")
        case .failed(let m):
            return .failure("located '\(target)' but the click failed: \(m)")
        }
    }
}
