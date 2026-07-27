import Foundation

/// Capture web content via Playwright (screenshots and optional video)
final class PlaywrightCaptureTool: AgentTool {
    let name = "web_capture"
    let description = "Capture a webpage using Playwright. Params: url (string), script (string? JS to eval), screenshot (bool, default true), video (bool, default false), transcode_mp4 (bool, default true), transcribe (bool, default true), trim_seconds (int, optional), timeout (int sec, default 30), width/height (ints). Returns file paths in metadata (video_path, video_path_mp4, screenshot_path, transcript_path)."
    let parameters: [ToolParameter] = [
        ToolParameter(name: "url", type: "string", description: "Web URL to open", required: true),
        ToolParameter(name: "script", type: "string", description: "Optional JS to run in the page context", required: false),
        ToolParameter(name: "screenshot", type: "boolean", description: "Capture screenshot (default: true)", required: false),
        ToolParameter(name: "video", type: "boolean", description: "Record a short video (default: false)", required: false),
        ToolParameter(name: "transcode_mp4", type: "boolean", description: "If true, convert .webm to .mp4 with ffmpeg (default: false)", required: false),
        ToolParameter(name: "transcribe", type: "boolean", description: "If true, extract audio and transcribe with Whisper server (default: true)", required: false),
        ToolParameter(name: "trim_seconds", type: "integer", description: "Trim to the first N seconds before transcribing (optional)", required: false),
        ToolParameter(name: "timeout", type: "integer", description: "Timeout in seconds (default: 30)", required: false),
        ToolParameter(name: "width", type: "integer", description: "Viewport width", required: false),
        ToolParameter(name: "height", type: "integer", description: "Viewport height", required: false)
    ]

    func execute(arguments: [String : Any], projectPath: String) async throws -> ToolResult {
        guard let url = arguments["url"] as? String, !url.isEmpty else {
            return ToolResult(success: false, output: "", error: "Missing url")
        }
        let script = (arguments["script"] as? String) ?? ""
        let doScreenshot = (arguments["screenshot"] as? Bool) ?? true
        let doVideo = (arguments["video"] as? Bool) ?? false
        let transcodeMp4 = (arguments["transcode_mp4"] as? Bool) ?? true
        let doTranscribe = (arguments["transcribe"] as? Bool) ?? true
        let trimSeconds = (arguments["trim_seconds"] as? Int) ?? 0
        let timeoutSec = (arguments["timeout"] as? Int) ?? 30
        let width = (arguments["width"] as? Int) ?? 1280
        let height = (arguments["height"] as? Int) ?? 800

        // Prepare temp working dir
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("playwright_\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true) } catch {}

        // Write runner script
        let runner = tmpDir.appendingPathComponent("run.js")
        let outScreenshot = tmpDir.appendingPathComponent("capture.png").path
        let outVideoDir = tmpDir.appendingPathComponent("videos").path
        let outLog = tmpDir.appendingPathComponent("log.txt").path
        let js = makeRunnerJS(url: url, script: script, screenshotPath: outScreenshot, videoDir: outVideoDir, doScreenshot: doScreenshot, doVideo: doVideo, width: width, height: height, timeoutSec: timeoutSec)
        try js.write(to: runner, atomically: true, encoding: .utf8)

        // Ensure browser installed
        let envPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        let install = Process()
        install.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        install.arguments = ["npx", "--yes", "playwright@latest", "install", "chromium"]
        install.environment = ["PATH": envPath, "PLAYWRIGHT_BROWSERS_PATH": "0"]
        let _ = try? runProcess(install)

        // Run capture
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        run.arguments = ["node", runner.path]
        run.environment = ["PATH": envPath, "NODE_NO_WARNINGS": "1"]
        let (ok, stdout, stderr, _) = try runProcess(run)

        // Determine outputs
        var meta: [String: String] = ["work_dir": tmpDir.path]
        var summary = stdout
        if doScreenshot, FileManager.default.fileExists(atPath: outScreenshot) {
            meta["screenshot_path"] = outScreenshot
            summary += "\nScreenshot: \(outScreenshot)"
        }
        if doVideo {
            if let vid = try? latestVideo(in: outVideoDir) {
                meta["video_path"] = vid
                summary += "\nVideo: \(vid)"

                // Optional: transcode to MP4 for inline AVKit playback
                if transcodeMp4, let mp4 = try? transcodeToMP4(input: vid, workDir: outVideoDir) {
                    meta["video_path_mp4"] = mp4
                    summary += "\nMP4: \(mp4)"
                }

                // Optional: transcribe via Whisper server (auto-enabled by default)
                if doTranscribe {
                    let sourceForAudio = meta["video_path_mp4"] ?? vid
                    let inputForAudio: String
                    if trimSeconds > 0, let trimmed = try? trimMedia(input: sourceForAudio, seconds: trimSeconds, workDir: outVideoDir) {
                        inputForAudio = trimmed
                    } else {
                        inputForAudio = sourceForAudio
                    }
                    if let wav = try? extractAudioWav(from: inputForAudio, workDir: outVideoDir) {
                        if let text = await transcribeWav(path: wav) {
                            let transcriptPath = (outVideoDir as NSString).appendingPathComponent("transcript.txt")
                            try? text.write(toFile: transcriptPath, atomically: true, encoding: .utf8)
                            meta["transcript_path"] = transcriptPath
                            let preview = text.prefix(300)
                            summary += "\nTranscript: \(preview)\(text.count > 300 ? "..." : "")"
                        }
                    }
                }
            }
        }
        if !stderr.isEmpty { summary += "\n\nSTDERR:\n" + stderr }

        // If we recorded video, auto-extract key frames
        if doVideo, let videoPath = meta["video_path"], FileManager.default.fileExists(atPath: videoPath) {
            let extractor = ExtractVideoFramesTool()
            let frameResult = try await extractor.execute(arguments: [
                "video_path": videoPath,
                "max_frames": 4,
                "scene_threshold": 0.4
            ], projectPath: projectPath)

            if let joined = frameResult.metadata?["frame_paths"], !joined.isEmpty {
                meta["frame_paths"] = joined
                if let outDir = frameResult.metadata?["output_dir"] { meta["frames_dir"] = outDir }

                let paths = joined.components(separatedBy: "\n").filter { !$0.isEmpty }
                await MainActor.run {
                    RecentCaptureStore.shared.setLastCapture(screenshot: doScreenshot ? outScreenshot : nil,
                                                             video: videoPath,
                                                             frames: paths,
                                                             mp4: meta["video_path_mp4"],
                                                             transcript: meta["transcript_path"])
                    // Auto-attach the top frame to next user message
                    RecentCaptureStore.shared.nextAutoAttachPath = paths.first
                }
            }
        } else {
            // Update recent capture store for UI quick actions
            await MainActor.run {
                RecentCaptureStore.shared.setLastCapture(screenshot: doScreenshot ? outScreenshot : nil,
                                                         video: meta["video_path"],
                                                         frames: [],
                                                         mp4: meta["video_path_mp4"],
                                                         transcript: meta["transcript_path"])
            }
        }

        return ToolResult(success: ok, output: summary, error: ok ? nil : "Playwright run failed", metadata: meta)
    }

    private func latestVideo(in dir: String) throws -> String {
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir)
        let vids = contents.filter { $0.hasSuffix(".webm") || $0.hasSuffix(".mp4") }
        if let name = vids.sorted().last { return (dir as NSString).appendingPathComponent(name) }
        return dir
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

    private func makeRunnerJS(url: String, script: String, screenshotPath: String, videoDir: String, doScreenshot: Bool, doVideo: Bool, width: Int, height: Int, timeoutSec: Int) -> String {
        let safeScript = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`")
        return """
        const { chromium } = require('playwright');

        (async () => {
          const opts = { headless: true };
          const contextOpts = { viewport: { width: \(width), height: \(height) } };
          if (\(doVideo ? "true" : "false")) {
            contextOpts['recordVideo'] = { dir: '\(videoDir)' };
          }
          const browser = await chromium.launch(opts);
          const context = await browser.newContext(contextOpts);
          const page = await context.newPage();
          page.setDefaultTimeout(\(timeoutSec * 1000));
          await page.goto('\(url)', { waitUntil: 'load' });
          if (`\(safeScript)`.trim().length > 0) {
            await page.evaluate(`(async () => { \(safeScript) })()`);
          }
          if (\(doScreenshot ? "true" : "false")) {
            await page.screenshot({ path: '\(screenshotPath)', fullPage: true });
          }
          await browser.close();
          console.log('OK');
        })().catch(err => {
          console.error(err && err.stack || String(err));
          process.exit(1);
        });
        """
    }

    // MARK: - ffmpeg helpers

    private func findFFmpeg() -> String? {
        let paths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for p in paths where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    private func transcodeToMP4(input: String, workDir: String) throws -> String {
        guard let ffmpeg = findFFmpeg() else { throw NSError(domain: "PlaywrightCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "ffmpeg not found"]) }
        let out = (workDir as NSString).appendingPathComponent("capture.mp4")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = ["-y", "-i", input, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart", out]
        let (ok, _, err, _) = try runProcess(proc)
        guard ok && FileManager.default.fileExists(atPath: out) else { throw NSError(domain: "PlaywrightCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "ffmpeg transcode failed: \(err)"]) }
        return out
    }

    private func trimMedia(input: String, seconds: Int, workDir: String) throws -> String {
        guard let ffmpeg = findFFmpeg() else { throw NSError(domain: "PlaywrightCapture", code: 5, userInfo: [NSLocalizedDescriptionKey: "ffmpeg not found"]) }
        let out = (workDir as NSString).appendingPathComponent("trimmed.mp4")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = ["-y", "-t", String(seconds), "-i", input, "-c", "copy", out]
        let (ok, _, err, _) = try runProcess(proc)
        guard ok && FileManager.default.fileExists(atPath: out) else { throw NSError(domain: "PlaywrightCapture", code: 6, userInfo: [NSLocalizedDescriptionKey: "ffmpeg trim failed: \(err)"]) }
        return out
    }

    private func extractAudioWav(from input: String, workDir: String) throws -> String {
        guard let ffmpeg = findFFmpeg() else { throw NSError(domain: "PlaywrightCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "ffmpeg not found"]) }
        let out = (workDir as NSString).appendingPathComponent("audio.wav")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = ["-y", "-i", input, "-vn", "-ac", "1", "-ar", "16000", "-f", "wav", out]
        let (ok, _, err, _) = try runProcess(proc)
        guard ok && FileManager.default.fileExists(atPath: out) else { throw NSError(domain: "PlaywrightCapture", code: 4, userInfo: [NSLocalizedDescriptionKey: "ffmpeg audio extract failed: \(err)"]) }
        return out
    }

    private func transcribeWav(path: String) async -> String? {
        let serverURL = UserDefaults.standard.string(forKey: "mlx_whisper_url") ?? "http://localhost:8081"
        guard let endpoint = URL(string: serverURL + "/transcribe") else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue((path as NSString).lastPathComponent, forHTTPHeaderField: "X-Filename")
        req.httpBody = data
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            if let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let text = json["text"] as? String {
                return text
            } else if let txt = String(data: d, encoding: .utf8) { return txt }
        } catch {
            return nil
        }
        return nil
    }
}
