import Foundation
import Crypto

/// Asks a vision model (Gemini) for a structured `MediaIndex` of a video/audio clip, and caches it on
/// disk keyed by file content — so "summarize this / transcribe it / which scenes / when does X" is a
/// one-time API cost and every follow-up is a local search. Gemini natively does timestamped Q&A,
/// transcripts, and scene detection; we just pin it to a strict JSON shape.
public struct MediaAnalyzer: Sendable {
    private let registry: ProviderRegistry
    private let model: String
    private let cacheDir: String

    public init(registry: ProviderRegistry,
                model: String = "gemini-2.5-flash",
                cacheDir: String = NSHomeDirectory() + "/.mythos/media-cache") {
        self.registry = registry
        self.model = model
        self.cacheDir = cacheDir
    }

    public enum Want: String, Sendable { case summary, scenes, transcript, all }

    /// Analyze an already-built attachment (inline bytes or a Gemini fileUri). Uses the cache key when
    /// provided (a content hash) so repeat calls are free.
    public func analyze(attachment: MediaAttachment, want: Want, cacheKey: String?) async throws -> MediaIndex {
        if let cacheKey, let cached = readCache(cacheKey) { return cached }

        let msg = ChatMessage(role: .user, content: Self.prompt(want: want), attachments: [attachment])
        let settings = ModelSettings(temperature: 0.1, maxTokens: 8192,
                                     systemPrompt: "You are a precise media analyst. Output ONLY the requested JSON.")
        var text = ""
        let stream = try await registry.stream(providerId: "gemini", model: model, messages: [msg], settings: settings)
        for try await event in stream { if case .delta(let d) = event { text += d } }

        guard let index = MediaIndex.parse(text) else {
            throw AIProviderError.invalidResponse("media analysis returned no parseable JSON")
        }
        if let cacheKey { writeCache(cacheKey, index) }
        return index
    }

    /// SHA-256 of bytes → a stable cache key.
    public static func cacheKey(forData data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func prompt(want: Want) -> String {
        let focus: String
        switch want {
        case .summary:    focus = "Focus on a tight summary + a short timeline of the main scenes."
        case .scenes:     focus = "Focus on the timeline of scenes and the keyMoments worth watching, with accurate MM:SS."
        case .transcript: focus = "Focus on a COMPLETE timestamped transcript of all speech, with speaker labels when distinguishable."
        case .all:        focus = "Fill in ALL sections fully: summary, timeline, complete transcript, and keyMoments."
        }
        return """
        Analyze this media. \(focus)
        Return ONLY a single JSON object matching this shape (no markdown, no prose around it):
        \(MediaIndex.jsonSchemaHint)
        Use real MM:SS (or HH:MM:SS) timestamps from the media. If a section doesn't apply, return an empty array.
        """
    }

    // MARK: cache

    private func cachePath(_ key: String) -> String { cacheDir + "/" + key + ".json" }

    private func readCache(_ key: String) -> MediaIndex? {
        guard let data = FileManager.default.contents(atPath: cachePath(key)) else { return nil }
        return try? JSONDecoder().decode(MediaIndex.self, from: data)
    }

    private func writeCache(_ key: String, _ index: MediaIndex) {
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: URL(fileURLWithPath: cachePath(key)))
        }
    }
}
