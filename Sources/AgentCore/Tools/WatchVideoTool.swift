import Foundation

/// Agent tool: sample frames from a video, send them to a vision model, and return a scene/change map.
/// This is bounded "watching" for files, not live playback: defaults sample a small number of frames.
public struct WatchVideoTool: AgentTool {
    public let name = "watch_video"
    public let description = """
    Sample frames from a video/movie and ask a vision model to build a scene map, visual timeline, \
    changes, UI states, and notable moments. Bounded by every_seconds/max_frames; use analyze_media \
    for transcript/audio and watch_video for visual frame understanding.
    """
    public let parameters = [
        ToolParameter(name: "path", type: "string", description: "Project-relative video path. Absolute paths under a session-armed read-only root (--allow-read) also work.", required: true),
        ToolParameter(name: "every_seconds", type: "integer", description: "Sample one frame every N seconds (default 5, min 1, max 60).", required: false),
        ToolParameter(name: "max_frames", type: "integer", description: "Maximum frames to inspect (default 12, max 40).", required: false),
        ToolParameter(name: "question", type: "string", description: "Optional focused question, e.g. 'what UI changed?'.", required: false),
        ToolParameter(name: "out_dir", type: "string", description: "Project-relative folder to store sampled frames.", required: false),
    ]

    private let capture: @Sendable (_ input: String, _ outDir: String, _ everySeconds: Int, _ maxFrames: Int, _ context: ToolContext) async throws -> [String]
    private let analyze: @Sendable (_ frames: [MediaAttachment], _ prompt: String) async throws -> String

    public init(registry: ProviderRegistry, binding: ProviderBinding) {
        self.capture = { input, outDir, everySeconds, maxFrames, context in
            try await Self.sampleFrames(input: input, outDir: outDir, everySeconds: everySeconds,
                                        maxFrames: maxFrames, context: context)
        }
        self.analyze = { frames, prompt in
            try await registry.complete(providerId: binding.providerId, model: binding.model,
                                        messages: [
                                            ChatMessage(role: .system, content: "You are a precise visual video analyst. Use only the sampled frames and call out uncertainty."),
                                            ChatMessage(role: .user, content: prompt, attachments: frames),
                                        ],
                                        settings: ModelSettings(temperature: 0.0, maxTokens: 2400))
        }
    }

    public init(capture: @escaping @Sendable (_ input: String, _ outDir: String, _ everySeconds: Int, _ maxFrames: Int, _ context: ToolContext) async throws -> [String],
                analyze: @escaping @Sendable (_ frames: [MediaAttachment], _ prompt: String) async throws -> String) {
        self.capture = capture
        self.analyze = analyze
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let path = try requireString("path", from: arguments)
        // INPUT is read-only (ffmpeg -i) → armed external read roots also resolve.
        // The output dir below stays project-confined via resolvedPath — never widen it.
        let input = try context.resolvedPathForReading(path, mustExist: true)
        let ext = (input as NSString).pathExtension.lowercased()
        guard let (kind, _) = MediaAttachment.kindAndMime(forExtension: ext), kind == .video else {
            return .failure("watch_video handles video files; '\(path)' is not recognized as video")
        }
        let every = min(max(optionalInt("every_seconds", from: arguments) ?? 5, 1), 60)
        let maxFrames = min(max(optionalInt("max_frames", from: arguments) ?? 12, 1), 40)
        let outDirArg = (arguments["out_dir"] as? String) ?? ".mythos/video-frames/\(Self.slug((input as NSString).lastPathComponent))-\(Int(Date().timeIntervalSince1970))"
        let outDir = try context.resolvedPath(outDirArg, mustExist: false)
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let sampled = try await capture(input, outDir, every, maxFrames, context)
        guard !sampled.isEmpty else { return .failure("ffmpeg produced no sampled frames") }

        let attachments = try sampled.map { frame -> MediaAttachment in
            let data = try Data(contentsOf: URL(fileURLWithPath: frame))
            return MediaAttachment(kind: .image, mimeType: "image/jpeg", payload: .inline(data), sourcePath: frame)
        }
        let question = (arguments["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = Self.prompt(everySeconds: every, frameCount: attachments.count, question: question)
        let report = try await analyze(attachments, prompt)
        let relFrames = sampled.map { Self.relativePath($0, root: context.projectRoot) }
        return ToolResult(success: true,
                          output: "Video watch · sampled \(attachments.count) frame(s) every \(every)s\nFrames:\n" +
                                  relFrames.map { "  \($0)" }.joined(separator: "\n") +
                                  "\n\n" + report.trimmingCharacters(in: .whitespacesAndNewlines),
                          metadata: ["frames": String(attachments.count), "out_dir": outDirArg])
    }

    static func sampleFrames(input: String, outDir: String, everySeconds: Int, maxFrames: Int,
                             context: ToolContext) async throws -> [String] {
        guard let ffmpeg = RunCommandTool.resolveExecutable("ffmpeg", env: ProcessInfo.processInfo.environment) else {
            throw ToolError.configuration("ffmpeg not found on PATH — install it (brew install ffmpeg) to sample videos")
        }
        let pattern = outDir + "/frame_%04d.jpg"
        let args = ["-i", input, "-vf", "fps=1/\(everySeconds)", "-frames:v", String(maxFrames),
                    "-q:v", "2", "-y", pattern]
        if let reason = await context.shell.binaryRefusalReason(resolvedPath: ffmpeg, args: args) {
            throw ToolError.shellDenied("ffmpeg blocked by shell policy: \(reason) (try --allow-shell)")
        }
        let run = await RunCommandTool.spawnAndCollect(launchPath: ffmpeg, launchArgs: args,
                                                       cwd: context.projectRoot, timeout: 180)
        guard run.success else { throw ToolError.execution(run.error ?? run.output) }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: outDir)) ?? []
        return files.filter { $0.hasSuffix(".jpg") }.sorted().map { outDir + "/" + $0 }
    }

    static func prompt(everySeconds: Int, frameCount: Int, question: String) -> String {
        var p = """
        The attached images are ordered video frames sampled every \(everySeconds) seconds (\(frameCount) frame(s)).
        Build a concise scene map:
        - approximate time range for each visible scene/state
        - what changed between frames
        - UI/text/errors/objects visible
        - notable moments to inspect more closely
        - uncertainty caused by sparse sampling
        """
        if !question.isEmpty { p += "\nFocus question: \(question)" }
        return p
    }

    static func slug(_ s: String) -> String {
        let base = ((s as NSString).deletingPathExtension).lowercased()
        let parts = base.split { !$0.isLetter && !$0.isNumber }.prefix(6)
        return parts.joined(separator: "-").prefix(60).description.isEmpty ? "video" : parts.joined(separator: "-")
    }

    static func relativePath(_ path: String, root: String) -> String {
        let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(rootWithSlash) ? String(path.dropFirst(rootWithSlash.count)) : path
    }
}
