import Foundation

/// Agent tool: edit an existing image with a text instruction (Gemini "Nano Banana") and save the
/// result as a PNG in the project. Use to retouch, restyle, add/remove elements, or fix a mockup.
public struct EditImageTool: AgentTool {
    public let name = "edit_image"
    public let description = """
    Edit an existing image using a text instruction (Gemini native image editing) and save the result \
    as a PNG. Use to restyle, retouch, add/remove elements, change colors, or fix a screenshot/mockup.
    """
    public let parameters = [
        ToolParameter(name: "image", type: "string", description: "Project-relative path to the input image (png/jpg/webp).", required: true),
        ToolParameter(name: "prompt", type: "string", description: "What to change.", required: true),
        ToolParameter(name: "out", type: "string", description: "Project-relative .png output. Default edited-images/<slug>.png", required: false),
    ]

    private let inlineCap: Int
    private let edit: @Sendable (_ prompt: String, _ data: Data, _ mime: String) async throws -> Data

    public init(geminiKey: String, inlineCap: Int = 12 * 1024 * 1024) {
        let client = GeminiEditImageClient(apiKey: geminiKey)
        self.inlineCap = inlineCap
        self.edit = { prompt, data, mime in try await client.edit(prompt: prompt, imageData: data, mimeType: mime) }
    }

    public init(inlineCap: Int = 12 * 1024 * 1024,
                edit: @escaping @Sendable (_ prompt: String, _ data: Data, _ mime: String) async throws -> Data) {
        self.inlineCap = inlineCap
        self.edit = edit
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let prompt = try requireString("prompt", from: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return .failure("prompt is empty") }
        let imagePath = try requireString("image", from: arguments)
        let resolved = try context.resolvedPath(imagePath, mustExist: true)
        let ext = (resolved as NSString).pathExtension.lowercased()
        guard let (kind, mime) = MediaAttachment.kindAndMime(forExtension: ext), kind == .image else {
            return .failure("edit_image needs an image; '\(imagePath)' is not a recognized image file")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)) else {
            return .failure("couldn't read \(imagePath)")
        }
        guard data.count <= inlineCap else {
            return .failure("edit_image refuses input images over \(inlineCap / 1_048_576)MB; shrink '\(imagePath)' first")
        }

        let out = (arguments["out"] as? String) ?? "edited-images/\(Self.slug(prompt)).png"
        guard (out as NSString).pathExtension.lowercased() == "png" else { return .failure("out must end in .png") }
        let artifact = try ArtifactOutputEvidence.prepare(path: out, kind: .file, context: context)

        let edited = try await edit(prompt, data, mime)
        guard !edited.isEmpty else { return .failure("edit returned no image") }
        try context.confinedRoot().writeData(artifact.relativePath, edited, createParents: true)
        var metadata = ["path": artifact.relativePath, "bytes": String(edited.count)]
        try metadata.mergeArtifactMetadata(artifact, context: context)
        return ToolResult(success: true,
                          output: "edited \((resolved as NSString).lastPathComponent) → \(artifact.relativePath) (\(edited.count) bytes)",
                          metadata: metadata)
    }

    static func slug(_ prompt: String) -> String {
        let words = prompt.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(8)
        let joined = words.joined(separator: "-")
        return joined.isEmpty ? "edit" : String(joined.prefix(80))
    }
}
