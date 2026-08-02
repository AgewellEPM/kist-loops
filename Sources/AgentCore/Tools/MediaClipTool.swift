import Foundation

/// Agent tool: pull the actual moment out of a video — a still frame or a short clip at a timestamp
/// (the scene `analyze_media` flagged). Uses the local `ffmpeg` binary through the shell policy
/// (needs shell enabled, e.g. --allow-shell). Output is written inside the project root.
public struct MediaClipTool: AgentTool {
    public let name = "extract_clip"
    public let description = """
    Extract a still FRAME or a short CLIP from a video at a timestamp (MM:SS / HH:MM:SS / seconds), \
    e.g. the moment found by analyze_media. Writes a .jpg (frame) or .mp4 (clip) into the project. \
    Requires the ffmpeg binary and shell access.
    """
    public let parameters = [
        ToolParameter(name: "path", type: "string", description: "Project-relative path to the source video. Absolute paths under a session-armed read-only root (--allow-read) also work."),
        ToolParameter(name: "at", type: "string", description: "Timestamp: MM:SS, HH:MM:SS, or seconds."),
        ToolParameter(name: "kind", type: "string", description: "frame | clip (default frame)", required: false),
        ToolParameter(name: "seconds", type: "number", description: "Clip length in seconds (default 6, clip only).", required: false),
        ToolParameter(name: "out", type: "string", description: "Optional output path (project-relative).", required: false),
    ]

    private let resolveFFmpeg: @Sendable () -> String?
    private let runFFmpeg: @Sendable (_ launchPath: String, _ args: [String], _ cwd: String) async -> ToolResult

    public init() {
        self.resolveFFmpeg = {
            RunCommandTool.resolveExecutable("ffmpeg", env: ProcessInfo.processInfo.environment)
        }
        self.runFFmpeg = { launchPath, args, cwd in
            await RunCommandTool.spawnAndCollect(launchPath: launchPath, launchArgs: args,
                                                 cwd: cwd, timeout: 120)
        }
    }

    /// Deterministic process seam for tests; production always uses the public initializer above.
    init(resolveFFmpeg: @escaping @Sendable () -> String?,
         runFFmpeg: @escaping @Sendable (_ launchPath: String, _ args: [String], _ cwd: String) async -> ToolResult) {
        self.resolveFFmpeg = resolveFFmpeg
        self.runFFmpeg = runFFmpeg
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let path = try requireString("path", from: arguments)
        let at = try requireString("at", from: arguments)
        guard Self.isValidTimestamp(at) else { return .failure("'\(at)' isn't a valid timestamp (use MM:SS, HH:MM:SS, or seconds)") }
        let kind = (arguments["kind"] as? String ?? "frame").lowercased()
        guard kind == "frame" || kind == "clip" else { return .failure("kind must be 'frame' or 'clip'") }
        let seconds = min(max(optionalInt("seconds", from: arguments) ?? 6, 1), 60)
        // INPUT is read-only (ffmpeg -i) → armed external read roots also resolve.
        // The output path below stays project-confined via resolvedPath — never widen it.
        let input = try context.resolvedPathForReading(path, mustExist: true)

        let stem = ((input as NSString).lastPathComponent as NSString).deletingPathExtension
        let safeAt = at.replacingOccurrences(of: ":", with: "-")
        let defaultName = kind == "clip" ? "\(stem)_\(safeAt).mp4" : "\(stem)_\(safeAt).jpg"
        let outArg = (arguments["out"] as? String) ?? defaultName
        let artifact = try ArtifactOutputEvidence.prepare(path: outArg, kind: .file, context: context)
        try artifact.ensureParentDirectory(context: context)
        let outPath = artifact.absolutePath

        guard let ffmpeg = resolveFFmpeg() else {
            return .failure("ffmpeg not found on PATH — install it (brew install ffmpeg) to extract frames/clips")
        }
        // -ss before -i = fast seek; -y overwrite. Frame: one image. Clip: stream-copy a window.
        let args: [String]
        if kind == "clip" {
            args = ["-ss", at, "-i", input, "-t", String(seconds), "-c", "copy", "-y", outPath]
        } else {
            args = ["-ss", at, "-i", input, "-frames:v", "1", "-q:v", "2", "-y", outPath]
        }
        if let reason = await context.shell.binaryRefusalReason(resolvedPath: ffmpeg, args: args) {
            return .failure("ffmpeg blocked by shell policy: \(reason) (try --allow-shell)")
        }
        let run = await runFFmpeg(ffmpeg, args, context.projectRoot)
        guard run.success else {
            return .failure("ffmpeg failed: \(run.error ?? run.output)")
        }
        guard FileManager.default.fileExists(atPath: outPath) else {
            return .failure("ffmpeg ran but produced no output: \(run.error ?? run.output)")
        }
        var metadata = ["path": artifact.relativePath]
        try metadata.mergeArtifactMetadata(artifact, context: context)
        return ToolResult(success: true,
                          output: "wrote \(kind) at \(at) → \(artifact.relativePath)",
                          metadata: metadata)
    }

    /// Accept MM:SS, HH:MM:SS, or a plain seconds value (int or decimal).
    static func isValidTimestamp(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        if let seconds = Double(t) { return seconds >= 0 }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return false }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count else { return false }
        if values.contains(where: { $0 < 0 }) { return false }
        guard let minutes = values.dropLast().last, let seconds = values.last else { return false }
        return minutes < 60 && seconds < 60
    }
}
