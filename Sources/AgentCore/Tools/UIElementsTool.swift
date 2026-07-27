import Foundation

/// Read the focused app's interactive UI elements from the macOS Accessibility tree — role, label, state,
/// and EXACT pixel center to click. This is the deterministic alternative to guessing a pixel from a
/// screenshot: instead of `locate("the Save button")` (a vision guess with ~20px error), the model reads
/// `button "Save" @ (640,400)` and clicks that exact center via desktop_control/tap. Prefer this for
/// standard apps/menus; fall back to look/locate for custom-rendered UIs (games) with no AX tree.
public struct UIElementsTool: AgentTool {
    public let name = "ui_elements"
    public var description: String {
        """
        List the focused app's clickable UI elements from the Accessibility tree — each with its role, \
        label, enabled state, and exact pixel center. Use this (not locate) for standard apps/menus: read \
        the element you want, then click its center with desktop_control(action="click", x, y) or tap. \
        Optionally filter with 'query' (matches role or label). Returns empty when the app exposes no AX \
        tree (e.g. a custom-rendered game) — use look/locate then. macOS; needs Accessibility permission.
        """
    }

    public var parameters: [ToolParameter] {
        [
            ToolParameter(name: "query", type: "string", description: "Optional filter — only elements whose role or label contains this, e.g. 'save'.", required: false),
            ToolParameter(name: "all", type: "boolean", description: "Include non-interactive elements too (default false = clickable controls only).", required: false),
            ToolParameter(name: "display", type: "integer", description: "0-based display index to read (default main). Use desktop_control screen_size to see what's attached.", required: false),
        ]
    }
    public var capabilityNote: String? {
        "Reads structured UI elements (deterministic, exact bounds) — the reliable alternative to guessing pixels. It does not click; use desktop_control/tap with the returned center x,y."
    }
    public var usageExamples: [String] { ["{}", "{\"query\":\"save\"}"] }

    /// Scan a LARGE raw tree (a target control can sit well past the first 200 geometric nodes), but
    /// return only the top matches after filtering (council: cap-before-filter would miss the target).
    static let maxRawScan = 2500
    static let maxReturned = 200

    private let provider: UIElementProvider

    public init(provider: UIElementProvider) {
        self.provider = provider
    }

    /// Production wiring over the real macOS Accessibility tree (no-op empty on non-macOS).
    public static func wired() -> UIElementsTool {
        #if canImport(ApplicationServices) && canImport(CoreGraphics)
        return UIElementsTool(provider: AXUIElementProvider())
        #else
        return UIElementsTool(provider: EmptyUIElementProvider())
        #endif
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let query = arguments["query"] as? String
        let interactiveOnly = !(optionalBool("all", from: arguments) ?? false)
        let (target, displayError) = resolveDisplay(from: arguments)
        if let displayError { return .failure(displayError) }
        let all = provider.snapshot(maxElements: Self.maxRawScan, on: target)
        let matched = UIElementRenderer.filter(all, query: query, interactiveOnly: interactiveOnly)
        guard !matched.isEmpty else {
            let why = all.isEmpty
                ? "No Accessibility tree available (the focused app exposes none, e.g. a custom-rendered game, or Accessibility permission isn't granted). Use look/locate instead."
                : "No elements matched\(query.map { " '\($0)'" } ?? ""). Try without a query, or use look to see the whole screen."
            return ToolResult(success: true, output: why, metadata: ["count": "0", "total": "\(all.count)"])
        }
        let capped = matched.count > Self.maxReturned ? Array(matched.prefix(Self.maxReturned)) : matched
        // If a non-main display was targeted, the returned coords are THAT display's pixels — tell the
        // model to pass the same display index to the click (else it defaults to main → wrong monitor).
        let displaySuffix = displayIndexIfExplicit(from: arguments).map { ", display=\($0)" } ?? ""
        return ToolResult(success: true,
                          output: "\(capped.count) element(s). Click one's center with desktop_control(action=\"click\"\(displaySuffix), x, y):\n" + UIElementRenderer.render(capped),
                          metadata: ["count": "\(capped.count)", "total": "\(all.count)"])
    }

    private func displayIndexIfExplicit(from arguments: [String: Any]) -> Int? {
        guard arguments["display"] != nil else { return nil }
        return strictInt(arguments["display"])
    }
}

/// Fallback provider on platforms without Accessibility (always empty).
public struct EmptyUIElementProvider: UIElementProvider {
    public init() {}
    public func snapshot(maxElements: Int, on display: DisplayInfo?) -> [UIElement] { [] }
}
