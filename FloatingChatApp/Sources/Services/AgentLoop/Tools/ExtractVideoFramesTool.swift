import Foundation

/// Extract key frames from a video using ffmpeg and expose paths for the chat UI
final class ExtractVideoFramesTool: AgentTool {
    let name = "extract_video_frames"
    let description = "Extract key frames from a video (ffmpeg). Params: video_path (string), max_frames (int, default 4), scene_threshold (double, default 0.4). Returns frame paths in metadata as frame_paths[]."
    let parameters: [ToolParameter] = [
        ToolParameter(name: "video_path", type: "string", description: "Path to a .webm/.mp4 created by Playwright", required: true),
        ToolParameter(name: "max_frames", type: "integer", description: "Max frames to keep (default 4)", required: false),
        ToolParameter(name: "scene_threshold", type: "number", description: "Scene change threshold (0.1-1.0, default 0.4)", required: false)
    ]

    func execute(arguments: [String : Any], projectPath: String) async throws -> ToolResult {
        guard let video = arguments["video_path"] as? String, !video.isEmpty else {
            return ToolResult(success: false, output: "", error: "Missing video_path")
        }
        let maxFrames = (arguments["max_frames"] as? Int) ?? 4
        let threshold = (arguments["scene_threshold"] as? Double) ?? 0.4

        // Prepare output directory
        let outDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("frames_\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) } catch {}
        let pattern = outDir.appendingPathComponent("frame_%03d.png").path

        // Locate ffmpeg
        guard let ffmpeg = findFFmpeg() else {
            return ToolResult(success: false, output: "", error: "ffmpeg not found (install via Homebrew)")
        }

        // Run ffmpeg: extract key/scene frames
        // Using select filter to pick I-frames or scene changes
        let filter = "select='eq(pict_type,\\\"I\\\")+gt(scene,\(threshold))',metadata=print"
        let args = ["-y", "-i", video, "-vf", filter, "-vsync", "vfr", pattern]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args
        let (ok, out, err, _) = try runProcess(proc)
        var output = out
        if !err.isEmpty { output += "\n" + err }

        // Gather frames
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []
        let frames = contents.filter { $0.hasPrefix("frame_") }.sorted().map { (outDir.path as NSString).appendingPathComponent($0) }
        let limited = Array(frames.prefix(maxFrames))

        // Update recent store for UI to attach
        await MainActor.run {
            RecentCaptureStore.shared.setLastCapture(screenshot: RecentCaptureStore.shared.lastScreenshotPath,
                                                     video: video,
                                                     frames: limited)
        }

        let summary = (limited.isEmpty ? "No frames extracted" : "Extracted \(limited.count) frame(s)") + "\nOutput dir: \(outDir.path)"
        return ToolResult(success: ok && !limited.isEmpty, output: summary, error: ok ? nil : "ffmpeg extraction failed", metadata: [
            "frame_paths": limited.joined(separator: "\n"),
            "output_dir": outDir.path
        ])
    }

    private func findFFmpeg() -> String? {
        let paths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for p in paths where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    private func runProcess(_ process: Process) throws -> (success: Bool, stdout: String, stderr: String, code: Int32) {
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus == 0, o, e, process.terminationStatus)
    }
}

