import Foundation

/// Agent tool: text -> speech (Gemini native TTS) -> a playable WAV file in the project. Use when the
/// user asks to narrate, voice, read aloud, or produce audio from text. Confined to the project root.
public struct GenerateAudioTool: AgentTool {
    public let name = "generate_audio"
    public let description = """
    Convert text to spoken audio using Gemini text-to-speech and save it as a playable WAV in the \
    project. Use for narration, voiceover, "read this aloud", or generating spoken clips. Pick a voice \
    by name (e.g. Kore, Puck, Charon, Aoede) or use the default.
    """
    public let parameters = [
        ToolParameter(name: "text", type: "string", description: "The text to speak.", required: true),
        ToolParameter(name: "voice", type: "string", description: "Prebuilt voice name (default Kore).", required: false),
        ToolParameter(name: "out", type: "string", description: "Project-relative .wav output path. Default audio/<slug>.wav", required: false),
    ]

    /// (text, voice) -> raw PCM + sample rate. Injectable so tests never spend.
    private let synth: @Sendable (_ text: String, _ voice: String) async throws -> GeminiTTSClient.PCM

    public init(geminiKey: String) {
        let client = GeminiTTSClient(apiKey: geminiKey)
        self.synth = { text, voice in try await client.synthesize(text: text, voice: voice) }
    }

    public init(synth: @escaping @Sendable (_ text: String, _ voice: String) async throws -> GeminiTTSClient.PCM) {
        self.synth = synth
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let text = try requireString("text", from: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure("text is empty") }
        let voice = (arguments["voice"] as? String)?.trimmingCharacters(in: .whitespaces).nonEmpty ?? GeminiTTSClient.defaultVoice
        let out = (arguments["out"] as? String) ?? "audio/\(Self.slug(text)).wav"
        guard (out as NSString).pathExtension.lowercased() == "wav" else { return .failure("out must end in .wav") }
        let artifact = try ArtifactOutputEvidence.prepare(path: out, kind: .file, context: context)

        let pcm = try await synth(text, voice)
        guard !pcm.data.isEmpty else { return .failure("TTS returned no audio") }
        let wav = GeminiTTSClient.wav(pcm: pcm.data, sampleRate: pcm.sampleRate)
        // Symlink-safe atomic write inside the project root.
        try context.confinedRoot().writeData(artifact.relativePath, wav, createParents: true)
        let seconds = Double(pcm.data.count) / Double(pcm.sampleRate * 2)   // 16-bit mono
        var metadata = ["path": artifact.relativePath, "voice": voice, "bytes": String(wav.count)]
        try metadata.mergeArtifactMetadata(artifact, context: context)
        return ToolResult(success: true,
                          output: "spoke \(text.count) chars → \(artifact.relativePath) (voice \(voice), ~\(String(format: "%.1f", seconds))s, \(wav.count) bytes)",
                          metadata: metadata)
    }

    static func slug(_ text: String) -> String {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(8)
        let joined = words.joined(separator: "-")
        return joined.isEmpty ? "speech" : String(joined.prefix(80))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
