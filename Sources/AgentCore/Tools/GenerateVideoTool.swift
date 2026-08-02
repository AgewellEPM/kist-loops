import Foundation

/// Agent tool: generate a short video from a text prompt (Gemini Veo) and save it as an MP4 in the
/// project. PROTOTYPE — Veo is a slow preview API; a call can take minutes (long-running operation).
public struct GenerateVideoTool: AgentTool {
    public let name = "generate_video"
    public let description = """
    Generate a short video from a text prompt using Gemini Veo and save it as an MP4. Note: this is \
    slow (can take minutes). Use for motion concepts, b-roll, or animated illustrations.
    """
    public let parameters = [
        ToolParameter(name: "prompt", type: "string", description: "What the video should show.", required: true),
        ToolParameter(name: "out", type: "string", description: "Project-relative .mp4 output. Default generated-videos/<slug>.mp4", required: false),
        ToolParameter(name: "aspect", type: "string", description: "Aspect ratio, 16:9 (default) or 9:16.", required: false),
    ]

    private let generate: @Sendable (_ prompt: String, _ aspect: String) async throws -> Data

    public init(geminiKey: String) {
        let client = GeminiVideoClient(apiKey: geminiKey)
        self.generate = { prompt, aspect in try await client.generate(prompt: prompt, aspectRatio: aspect) }
    }

    public init(generate: @escaping @Sendable (_ prompt: String, _ aspect: String) async throws -> Data) {
        self.generate = generate
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let prompt = try requireString("prompt", from: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return .failure("prompt is empty") }
        let aspect = (arguments["aspect"] as? String).flatMap { ["16:9", "9:16"].contains($0) ? $0 : nil } ?? "16:9"
        let out = (arguments["out"] as? String) ?? "generated-videos/\(Self.slug(prompt)).mp4"
        guard (out as NSString).pathExtension.lowercased() == "mp4" else { return .failure("out must end in .mp4") }
        let artifact = try ArtifactOutputEvidence.prepare(path: out, kind: .file, context: context)

        let bytes = try await generate(prompt, aspect)
        guard !bytes.isEmpty else { return .failure("video generation returned no data") }
        try context.confinedRoot().writeData(artifact.relativePath, bytes, createParents: true)
        var metadata = ["path": artifact.relativePath, "bytes": String(bytes.count), "aspect": aspect]
        try metadata.mergeArtifactMetadata(artifact, context: context)
        return ToolResult(success: true,
                          output: "generated video → \(artifact.relativePath) (\(bytes.count) bytes, \(aspect))",
                          metadata: metadata)
    }

    static func slug(_ prompt: String) -> String {
        let words = prompt.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(8)
        let joined = words.joined(separator: "-")
        return joined.isEmpty ? "video" : String(joined.prefix(80))
    }
}
