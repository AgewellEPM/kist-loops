import Foundation

/// THE AIM. Bridges perception to the hands: given a screenshot and a plain-language target ("the attack
/// button", "the red door", "the OK button"), it returns PIXEL coordinates the big model can hand
/// straight to `desktop_control` — instead of the model guessing pixels off an image, which is the weak
/// link in vision-driven control. Backed by Moondream's pointing (fast + cheap, local or cloud).
///
/// Flow: desktop_control(screenshot) -> locate(image=path, target="…") -> desktop_control(click, x, y).
///
/// Perception is injected so tests never require a running model or spend on the cloud API. Coordinates
/// are in the SAME pixel space as the screenshot, so they drop directly into desktop_control.
public struct LocateTool: AgentTool {
    public let name = "locate"
    public var description: String {
        """
        Find a named thing on a screenshot and get its pixel coordinates for clicking. Take a screenshot \
        with desktop_control first, then locate(image=<that path>, target="the button/thing you want"). \
        Returns x,y in screenshot pixels — hand them straight to desktop_control click. Returns "not \
        found" (not an error) when the target isn't visible.
        """
    }

    public var parameters: [ToolParameter] {
        [
            ToolParameter(name: "image", type: "string", description: "Project-relative path to a PNG screenshot (from desktop_control screenshot)."),
            ToolParameter(name: "target", type: "string", description: "Plain-language description of what to find, e.g. 'the attack button'."),
        ]
    }
    public var capabilityNote: String? {
        "Locates a target IN an existing screenshot; it does not capture the screen (use desktop_control screenshot) or click (use desktop_control click with the returned x,y). PNG images only."
    }
    public var usageExamples: [String] {
        ["{\"image\":\".kist/desktop/shot-...png\",\"target\":\"the OK button\"}"]
    }

    private let locate: @Sendable (_ pngData: Data, _ target: String) async throws -> [MoondreamClient.NormPoint]

    /// Inject the pointing backend (mockable). See `LocateTool.moondream()` for the production wiring.
    public init(locate: @escaping @Sendable (_ pngData: Data, _ target: String) async throws -> [MoondreamClient.NormPoint]) {
        self.locate = locate
    }

    /// Production wiring over the Moondream client (cloud key or local MOONDREAM_BASE_URL).
    public static func moondream(client: MoondreamClient = MoondreamClient()) -> LocateTool {
        LocateTool { data, target in try await client.point(imageData: data, mime: "image/png", object: target) }
    }

    static let maxImageBytes = 25_000_000

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let path = try requireString("image", from: arguments)
        let target = try requireString("target", from: arguments)
        // TOCTOU-safe read via ConfinedRoot (openat/O_NOFOLLOW) — never a resolve-then-reopen-by-path
        // window that a symlink swap could use to feed an out-of-root image to the vision API.
        let data = try context.confinedRoot().readData(path)
        guard data.count <= Self.maxImageBytes else {
            return .failure("image is too large (\(data.count) bytes > \(Self.maxImageBytes)) to send to the vision model.")
        }
        guard let dims = Self.pngDimensions(data) else {
            return .failure("locate needs a PNG screenshot (from desktop_control screenshot); '\(path)' is not a readable PNG.")
        }
        let points = try await locate(data, target)
        guard !points.isEmpty else {
            return ToolResult(success: true, output: "'\(target)' was not found in \(path). Try a fresh screenshot or a different description.",
                              metadata: ["found": "0"])
        }
        let px = MoondreamClient.pixels(from: points, width: dims.width, height: dims.height)
        let first = px[0]
        let list = px.map { "(\($0.x),\($0.y))" }.joined(separator: ", ")
        return ToolResult(success: true,
                          output: "found '\(target)' at \(first.x),\(first.y) px (\(px.count) match(es): \(list)). Click it with desktop_control(action=\"click\", x=\(first.x), y=\(first.y)).",
                          metadata: ["x": "\(first.x)", "y": "\(first.y)", "found": "\(px.count)"])
    }

    /// Read a PNG's pixel dimensions from its IHDR header — pure, cross-platform, no ImageIO. Returns nil
    /// if the bytes aren't a PNG (screenshots from desktop_control are always PNG).
    static func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 24 else { return nil }
        // 8-byte PNG signature, then the first chunk MUST be IHDR (length 13, type "IHDR") — so an
        // arbitrary blob with a spoofed signature and junk at offsets 16/20 isn't accepted as a PNG.
        let prefix: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,   // signature
                               0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52]   // IHDR length + "IHDR"
        let base = data.startIndex
        for i in 0..<16 where data[base + i] != prefix[i] { return nil }
        func be32(_ off: Int) -> Int {
            let b = base + off
            return (Int(data[b]) << 24) | (Int(data[b + 1]) << 16) | (Int(data[b + 2]) << 8) | Int(data[b + 3])
        }
        let w = be32(16), h = be32(20)
        guard w > 0, h > 0, w <= 100_000, h <= 100_000 else { return nil }   // sane bounds
        return (w, h)
    }
}
