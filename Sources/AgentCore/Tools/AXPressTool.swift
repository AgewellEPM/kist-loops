import Foundation

/// Press a UI control BY IDENTITY via the Accessibility API — the most reliable action for AX-exposed
/// apps. Unlike clicking a pixel (which can miss, be occluded, or hit the wrong element), this performs
/// the element's own press action directly, resolved fresh at press time. Use after `ui_elements` shows
/// the control; fall back to tap/desktop_control for custom-rendered UIs (games) with no AX tree.
public struct AXPressTool: AgentTool {
    public let name = "ax_press"
    public var description: String {
        """
        Press a named button/control directly through the Accessibility API (more reliable than clicking \
        a pixel — it can't miss). Give the element's label (as shown by ui_elements), optionally its role. \
        Use for standard apps/menus; if it returns not-found (e.g. a custom-rendered game), use ui_elements \
        to see labels, or fall back to tap/desktop_control. macOS; needs Accessibility permission.
        """
    }

    public var parameters: [ToolParameter] {
        [
            ToolParameter(name: "label", type: "string", description: "The control's label to press, e.g. 'New Game' (as shown by ui_elements)."),
            ToolParameter(name: "role", type: "string", description: "Optional role filter, e.g. 'button', to disambiguate.", required: false),
            ToolParameter(name: "display", type: "integer", description: "0-based display index (default main). Use desktop_control screen_size to see what's attached.", required: false),
        ]
    }
    public var capabilityNote: String? {
        "Presses an Accessibility control by label — the reliable alternative to clicking coordinates. Returns not-found when no AX match; then use ui_elements or tap."
    }
    public var usageExamples: [String] { ["{\"label\":\"New Game\"}", "{\"label\":\"Save\",\"role\":\"button\"}"] }

    private let provider: UIActionProvider

    public init(provider: UIActionProvider) { self.provider = provider }

    /// Production wiring over the real macOS Accessibility tree (no-op unavailable on non-macOS).
    public static func wired() -> AXPressTool {
        #if canImport(ApplicationServices) && canImport(CoreGraphics)
        return AXPressTool(provider: AXUIElementProvider())
        #else
        return AXPressTool(provider: EmptyUIActionProvider())
        #endif
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let label = try requireString("label", from: arguments)
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("label must name the control to press (it was empty).")
        }
        let role = arguments["role"] as? String
        let (target, displayError) = resolveDisplay(from: arguments)
        if let displayError { return .failure(displayError) }
        let shownLabel = Self.safeText(label, maxLength: 80)
        switch provider.press(labelQuery: label, role: role, on: target) {
        case .pressed(let r, let l):
            let shownRole = Self.safeText(UIElementRenderer.short(r), maxLength: 40)
            let actualLabel = Self.safeText(l ?? label, maxLength: 80)
            return ToolResult(success: true, output: "pressed \(shownRole) \"\(actualLabel)\".",
                              metadata: ["pressed": "true"])
        case .ambiguous(let n):
            return ToolResult(success: true,
                              output: "\(n) controls match '\(shownLabel)' — too ambiguous to press safely. Use ui_elements to see them, then click the one you want with desktop_control(action=\"click\", x, y), or pass a more specific label/role.",
                              metadata: ["pressed": "false", "reason": "ambiguous", "matches": "\(n)"])
        case .indeterminate:
            return ToolResult(success: true,
                              output: "'\(shownLabel)' may or may not have been pressed (the app didn't confirm). VERIFY with wait_for_screen/look before doing anything — do NOT blindly press again.",
                              metadata: ["pressed": "unknown", "reason": "indeterminate"])
        case .notFound:
            let shownRole = role.flatMap { UIElementRenderer.clean($0, maxLength: 40) }
            return ToolResult(success: true,
                              output: "no Accessibility control matching '\(shownLabel)'\(shownRole.map { " (role \($0))" } ?? ""). Use ui_elements to see exact labels, or tap/desktop_control for a custom-rendered UI.",
                              metadata: ["pressed": "false", "reason": "not_found"])
        case .unavailable:
            return .failure("Accessibility isn't available (permission not granted, or the app exposes no AX tree). Use tap/look/locate instead.")
        case .failed(let m):
            return .failure("found '\(shownLabel)' but the press failed: \(m)")
        }
    }

    private static func safeText(_ raw: String, maxLength: Int) -> String {
        UIElementRenderer.clean(raw, maxLength: maxLength) ?? "(empty)"
    }
}

/// Fallback action provider on platforms without Accessibility (always unavailable).
public struct EmptyUIActionProvider: UIActionProvider {
    public init() {}
    public func press(labelQuery: String, role: String?, on display: DisplayInfo?) -> AXPressResult { .unavailable }
}
