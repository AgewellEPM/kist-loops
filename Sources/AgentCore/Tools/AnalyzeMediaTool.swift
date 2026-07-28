import Foundation

/// Agent tool: deeply analyze a video/audio file into a navigable index — summary, scene timeline,
/// timestamped transcript, key moments — and answer "when does X happen". Inlines small files, uploads
/// big ones via the Gemini Files API, caches the result by content hash. Confined to the project root.
public struct AnalyzeMediaTool: AgentTool {
    public let name = "analyze_media"
    public let description = """
    Analyze a VIDEO or AUDIO file and return a structured index: summary, scene/chapter timeline with \
    MM:SS timestamps, a timestamped transcript (with speakers when known), and key moments worth \
    watching. Optionally search for when something happens. Use for .mp4/.mov/.webm/.mp3/.wav/etc.
    """
    public let parameters = [
        ToolParameter(name: "path", type: "string", description: "Project-relative path to the media file. Absolute paths under a session-armed read-only root (--allow-read) also work."),
        ToolParameter(name: "want", type: "string", description: "summary | scenes | transcript | all (default all)", required: false),
        ToolParameter(name: "query", type: "string", description: "Optional: find the moments matching this, e.g. 'when do they discuss pricing'.", required: false),
    ]

    private let analyzer: MediaAnalyzer
    private let filesClient: GeminiFilesClient
    private let inlineCap: Int

    public init(registry: ProviderRegistry, geminiKey: String, model: String = "gemini-2.5-flash",
                inlineCap: Int = 20 * 1024 * 1024) {
        self.analyzer = MediaAnalyzer(registry: registry, model: model)
        self.filesClient = GeminiFilesClient(apiKey: geminiKey)
        self.inlineCap = inlineCap
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let path = try requireString("path", from: arguments)
        // Read-only consumer: absolute paths under an armed external read root also resolve.
        let resolved = try context.resolvedPathForReading(path, mustExist: true)
        let ext = (resolved as NSString).pathExtension.lowercased()
        guard let (kind, mime) = MediaAttachment.kindAndMime(forExtension: ext), kind == .video || kind == .audio else {
            return .failure("analyze_media handles video/audio; '\(path)' isn't a recognized media file")
        }
        // TOCTOU-safe read on the openat/O_NOFOLLOW layer (never reopen-by-name).
        guard let data = try? context.readDataForReading(path) else {
            return .failure("couldn't read \(path)")
        }

        let cacheKey = MediaAnalyzer.cacheKey(forData: data)
        let attachment: MediaAttachment
        if data.count <= inlineCap {
            attachment = MediaAttachment(kind: kind, mimeType: mime, payload: .inline(data), sourcePath: resolved)
        } else {
            let uri = try await filesClient.upload(data: data, mimeType: mime,
                                                   displayName: (resolved as NSString).lastPathComponent)
            attachment = MediaAttachment(kind: kind, mimeType: mime, payload: .fileURI(uri), sourcePath: resolved)
        }

        let want = MediaAnalyzer.Want(rawValue: (arguments["want"] as? String ?? "all").lowercased()) ?? .all
        let index = try await analyzer.analyze(attachment: attachment, want: want, cacheKey: cacheKey)

        var out = Self.render(index, name: (resolved as NSString).lastPathComponent)
        if let q = (arguments["query"] as? String), !q.trimmingCharacters(in: .whitespaces).isEmpty {
            let hits = index.search(q)
            out += "\n\nMoments matching \"\(q)\":\n"
            out += hits.isEmpty ? "  (no matching moment found)" : hits.prefix(8).map { "  \($0.at)  \($0.label)" }.joined(separator: "\n")
        }
        return ToolResult(success: true, output: out, metadata: ["cacheKey": cacheKey])
    }

    static func render(_ index: MediaIndex, name: String) -> String {
        var s = "Media analysis · \(name)\(index.durationHint.map { " · ~\($0)" } ?? "")\n\n"
        s += "Summary: \(index.summary)\n"
        if !index.timeline.isEmpty {
            s += "\nTimeline:\n" + index.timeline.map { "  \($0.at)  \($0.label)" + ($0.detail.map { " — \($0)" } ?? "") }.joined(separator: "\n")
        }
        if !index.keyMoments.isEmpty {
            s += "\n\nKey moments to watch:\n" + index.keyMoments.map { "  \($0.at)  \($0.label)" }.joined(separator: "\n")
        }
        if !index.transcript.isEmpty {
            s += "\n\nTranscript:\n" + index.transcript.map { m in
                "  \(m.at)  " + (m.speaker.map { "\($0): " } ?? "") + m.label
            }.joined(separator: "\n")
        }
        return s
    }
}
