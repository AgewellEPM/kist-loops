import Foundation

/// Transcribe a local media file (video/audio) using ffmpeg + Whisper server
final class TranscribeMediaTool: AgentTool {
    let name = "transcribe_media"
    let description = "Transcribe a media file via Whisper server. Params: path (string), trim_seconds (int, optional). Saves transcript.txt next to the input and returns its path."
    let parameters: [ToolParameter] = [
        ToolParameter(name: "path", type: "string", description: "Path to video or audio file", required: true),
        ToolParameter(name: "trim_seconds", type: "integer", description: "Trim to first N seconds before transcription", required: false)
    ]

    func execute(arguments: [String : Any], projectPath: String) async throws -> ToolResult {
        guard let path = arguments["path"] as? String, !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            return ToolResult(success: false, output: "", error: "File not found")
        }
        let trim = (arguments["trim_seconds"] as? Int) ?? 0

        // Ensure WAV 16k mono
        let workDir = (path as NSString).deletingLastPathComponent
        let input: String
        if trim > 0, let trimmed = try? trimMedia(path: path, seconds: trim, workDir: workDir) {
            input = trimmed
        } else {
            input = path
        }
        guard let wav = try? extractAudioWav(from: input, workDir: workDir) else {
            return ToolResult(success: false, output: "", error: "Failed to extract audio")
        }

        guard let text = await transcribeWav(path: wav) else {
            return ToolResult(success: false, output: "", error: "Transcription failed")
        }
        let transcriptPath = (workDir as NSString).appendingPathComponent("transcript.txt")
        try? text.write(toFile: transcriptPath, atomically: true, encoding: .utf8)

        await MainActor.run {
            RecentCaptureStore.shared.lastTranscriptPath = transcriptPath
        }

        return ToolResult(success: true, output: text.prefix(1000) + (text.count > 1000 ? "..." : ""), metadata: [
            "transcript_path": transcriptPath
        ])
    }

    // MARK: - Helpers
    private func findFFmpeg() -> String? {
        let paths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for p in paths where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    private func trimMedia(path: String, seconds: Int, workDir: String) throws -> String {
        guard let ffmpeg = findFFmpeg() else { throw NSError(domain: "TranscribeMedia", code: 1, userInfo: [NSLocalizedDescriptionKey: "ffmpeg not found"]) }
        let out = (workDir as NSString).appendingPathComponent("trimmed.mov")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = ["-y", "-t", String(seconds), "-i", path, "-c", "copy", out]
        let (ok, _, err, _) = try runProcess(proc)
        guard ok && FileManager.default.fileExists(atPath: out) else { throw NSError(domain: "TranscribeMedia", code: 2, userInfo: [NSLocalizedDescriptionKey: "ffmpeg trim failed: \(err)"]) }
        return out
    }

    private func extractAudioWav(from input: String, workDir: String) throws -> String {
        guard let ffmpeg = findFFmpeg() else { throw NSError(domain: "TranscribeMedia", code: 3, userInfo: [NSLocalizedDescriptionKey: "ffmpeg not found"]) }
        let out = (workDir as NSString).appendingPathComponent("audio.wav")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = ["-y", "-i", input, "-vn", "-ac", "1", "-ar", "16000", "-f", "wav", out]
        let (ok, _, err, _) = try runProcess(proc)
        guard ok && FileManager.default.fileExists(atPath: out) else { throw NSError(domain: "TranscribeMedia", code: 4, userInfo: [NSLocalizedDescriptionKey: "ffmpeg audio extract failed: \(err)"]) }
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
            if let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let text = json["text"] as? String { return text }
            if let txt = String(data: d, encoding: .utf8) { return txt }
        } catch { return nil }
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

