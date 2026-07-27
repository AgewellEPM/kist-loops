import XCTest
@testable import AgentCore

/// Opt-in live smoke for the real Gemini multimodal path.
///
/// Run manually with:
///   KIST_LIVE_GEMINI=1 swift test --disable-sandbox --filter LiveGeminiMultimodalSmokeTests
///
/// This is intentionally skipped in normal test runs. It spends tokens, uses the Gemini Files API,
/// and shells out to local media tools to generate deterministic fixtures.
final class LiveGeminiMultimodalSmokeTests: XCTestCase {

    func testGeminiReviewsOrchestratorCodeExcerpts() async throws {
        guard ProcessInfo.processInfo.environment["KIST_LIVE_GEMINI_REVIEW"] == "1" else {
            throw XCTSkip("Set KIST_LIVE_GEMINI_REVIEW=1 to run the live Gemini orchestrator review.")
        }
        let registry = ProviderRegistry()
        guard registry.apiKey(forProviderId: "gemini")?.isEmpty == false else {
            throw XCTSkip("Gemini key is not configured.")
        }
        let model = ProcessInfo.processInfo.environment["KIST_LIVE_GEMINI_MODEL"] ?? "gemini-2.5-flash"
        let prompt = try reviewPrompt(projectRoot: FileManager.default.currentDirectoryPath)
        let review = try await complete(
            registry: registry,
            model: model,
            message: ChatMessage(role: .user, content: prompt),
            systemPrompt: "You are a senior Swift agent-orchestration code reviewer. Return exactly the requested four lines.")

        print("\n--- GEMINI ORCHESTRATOR REVIEW ---\n\(review)\n--- END GEMINI ORCHESTRATOR REVIEW ---")
        XCTAssertContainsFolded(review, "Verdict")
        XCTAssertContainsFolded(review, "Findings")
        XCTAssertContainsFolded(review, "Next")
    }

    func testGeminiDeciphersInlineImageAndUploadedVideo() async throws {
        guard ProcessInfo.processInfo.environment["KIST_LIVE_GEMINI"] == "1" else {
            throw XCTSkip("Set KIST_LIVE_GEMINI=1 to run the live Gemini multimodal smoke.")
        }
        let registry = ProviderRegistry()
        guard let key = registry.apiKey(forProviderId: "gemini"), !key.isEmpty else {
            throw XCTSkip("Gemini key is not configured.")
        }
        let model = ProcessInfo.processInfo.environment["KIST_LIVE_GEMINI_MODEL"] ?? "gemini-2.5-flash"
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let magick = try requireExecutable("magick")
        let ffmpeg = try requireExecutable("ffmpeg")
        let imagePath = root + "/kist-smoke-image.png"
        let videoPath = root + "/kist-smoke-video.mp4"
        try makeImage(path: imagePath, magick: magick)
        try makeVideo(path: videoPath, root: root, magick: magick, ffmpeg: ffmpeg)

        let imageData = try Data(contentsOf: URL(fileURLWithPath: imagePath))
        let imageReply = try await complete(
            registry: registry,
            model: model,
            message: ChatMessage(role: .user,
                                 content: "Read the attached image. Answer in one short sentence and include the visible word and number.",
                                 attachments: [
                                    MediaAttachment(kind: .image, mimeType: "image/png",
                                                    payload: .inline(imageData), sourcePath: imagePath),
                                 ]))
        XCTAssertContainsFolded(imageReply, "KIST")
        XCTAssertContainsFolded(imageReply, "42")

        let videoData = try Data(contentsOf: URL(fileURLWithPath: videoPath))
        let files = GeminiFilesClient(apiKey: key, pollIntervalNanos: 500_000_000, maxPolls: 60)
        let fileURI = try await files.upload(data: videoData, mimeType: "video/mp4",
                                             displayName: "kist-smoke-video.mp4")
        let videoReply = try await complete(
            registry: registry,
            model: model,
            message: ChatMessage(role: .user,
                                 content: "Watch the uploaded video. Answer with the visible colors and numbers from the frames.",
                                 attachments: [
                                    MediaAttachment(kind: .video, mimeType: "video/mp4",
                                                    payload: .fileURI(fileURI), sourcePath: videoPath),
                                 ]))
        XCTAssertContainsFolded(videoReply, "RED")
        XCTAssertContainsFolded(videoReply, "7")
        XCTAssertContainsFolded(videoReply, "GREEN")
        XCTAssertContainsFolded(videoReply, "9")
    }

    private func complete(registry: ProviderRegistry, model: String, message: ChatMessage,
                          systemPrompt: String = "You are a precise multimodal QA smoke tester. Be literal.") async throws -> String {
        let settings = ModelSettings(temperature: 0.0, maxTokens: 3000,
                                     systemPrompt: systemPrompt)
        let stream = try await registry.stream(providerId: "gemini", model: model,
                                               messages: [message], settings: settings)
        var text = ""
        for try await event in stream {
            if case .delta(let chunk) = event { text += chunk }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidResponse("Gemini returned an empty multimodal response")
        }
        return text
    }

    private func reviewPrompt(projectRoot: String) throws -> String {
        var sections: [String] = [
            """
            You are Gemini reviewing Kist's orchestrator and multimodal implementation.
            Return EXACTLY four short lines:
            Verdict: whether Gemini can handle inline images and uploaded videos in this system.
            Findings: the top 1-2 P0/P1/P2 bugs or reliability gaps with file references, or "none".
            Coverage: what is proven by the live smoke and what remains unproven.
            Next: concrete actions.

            Review only the excerpts below.
            """,
        ]
        let excerpts: [(String, ClosedRange<Int>?)] = [
            ("Sources/AgentCore/Providers/GeminiProvider.swift", 55...180),
            ("Sources/AgentCore/GeminiFilesClient.swift", 55...120),
            ("Sources/Kist/MediaResolver.swift", nil),
            ("Sources/Kist/KistRunner.swift", 85...110),
            ("Sources/Kist/KistRunner.swift", 240...275),
            ("Sources/Kist/KistREPL.swift", 230...250),
            ("Sources/Kist/KistREPL.swift", 703...725),
            ("Sources/AgentCore/Tools/VisualVerifyTool.swift", 75...215),
            ("Sources/Kist/UX/RunReplayStore.swift", nil),
            ("Tests/AgentCoreTests/LiveGeminiMultimodalSmokeTests.swift", 10...85),
        ]
        for (path, range) in excerpts {
            let full = projectRoot + "/" + path
            let text = try String(contentsOfFile: full, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let body: String
            if let range {
                let selected = range.compactMap { idx -> String? in
                    guard idx >= 1 && idx <= lines.count else { return nil }
                    return "\(idx): \(lines[idx - 1])"
                }
                body = selected.joined(separator: "\n")
            } else {
                body = lines.enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
            }
            sections.append("\n===== \(path)\(range.map { " lines \($0.lowerBound)-\($0.upperBound)" } ?? "") =====\n\(body)")
        }
        return sections.joined(separator: "\n")
    }

    private func makeRoot() throws -> String {
        let raw = NSTemporaryDirectory() + "kist-gemini-live-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        return ToolContext.canonicalize(raw)!
    }

    private func makeImage(path: String, magick: String) throws {
        try run(magick, [
            "-size", "640x360", "xc:white",
            "-fill", "#2563eb", "-draw", "rectangle 45,70 255,275",
            "-fill", "#dc2626", "-gravity", "center",
            "-pointsize", "72", "-annotate", "+0-55", "KIST",
            "-pointsize", "88", "-annotate", "+0+65", "42",
            path,
        ])
    }

    private func makeVideo(path: String, root: String, magick: String, ffmpeg: String) throws {
        let frame1 = root + "/frame-01.png"
        let frame2 = root + "/frame-02.png"
        try run(magick, [
            "-size", "640x360", "xc:#7f1d1d",
            "-fill", "white", "-gravity", "center", "-pointsize", "72",
            "-annotate", "+0+0", "RED 7",
            frame1,
        ])
        try run(magick, [
            "-size", "640x360", "xc:#14532d",
            "-fill", "white", "-gravity", "center", "-pointsize", "72",
            "-annotate", "+0+0", "GREEN 9",
            frame2,
        ])
        try run(ffmpeg, [
            "-y", "-loglevel", "error",
            "-framerate", "1",
            "-i", root + "/frame-%02d.png",
            "-c:v", "libx264",
            "-pix_fmt", "yuv420p",
            "-movflags", "+faststart",
            path,
        ])
    }

    private func requireExecutable(_ name: String) throws -> String {
        let result = try capture("/usr/bin/env", ["bash", "-lc", "command -v \(name)"])
        let path = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw XCTSkip("\(name) is not installed.") }
        return path
    }

    private func run(_ executable: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw AIProviderError.transport("\((executable as NSString).lastPathComponent) failed: \(message)")
        }
    }

    private func capture(_ executable: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw AIProviderError.transport("\((executable as NSString).lastPathComponent) failed: \(message)")
        }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func XCTAssertContainsFolded(_ haystack: String, _ needle: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
                      "Expected '\(needle)' in Gemini reply:\n\(haystack)", file: file, line: line)
    }
}
