import XCTest
@testable import AgentCore

final class VisualGenerationAndWatchTests: XCTestCase {

    private func tempRoot() throws -> String {
        let raw = NSTemporaryDirectory() + "visual_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        return ToolContext.canonicalize(raw)!
    }

    func testOpenAIImageClientParsesBase64ImageResponse() async throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let body = #"{"data":[{"b64_json":"\#(bytes.base64EncodedString())"}]}"#.data(using: .utf8)!
        let parsed = try await OpenAIImageClient.imageData(from: body, transport: StubHTTPTransport())
        XCTAssertEqual(parsed, bytes)
    }

    func testGenerateImageWritesPNGInsideProject() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let capture = ImageCapture()
        let tool = GenerateImageTool { prompt, model, size in
            capture.record(prompt: prompt, model: model, size: size)
            return Data([0x89, 0x50, 0x4E, 0x47])
        }

        let result = try await tool.execute(arguments: [
            "prompt": "sleek terminal agent cockpit",
            "out": "art/cockpit.png",
            "size": "1024x1024",
        ], context: ToolContext(projectRoot: root))

        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: root + "/art/cockpit.png")),
                       Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(capture.prompt, "sleek terminal agent cockpit")
        XCTAssertEqual(capture.model, "gpt-image-1")
        XCTAssertEqual(capture.size, "1024x1024")
    }

    func testGeminiEditImageClientParsesInlineDataImage() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        // camelCase inlineData
        let camel = #"{"candidates":[{"content":{"parts":[{"text":"here"},{"inlineData":{"mimeType":"image/png","data":"\#(bytes.base64EncodedString())"}}]}}]}"#.data(using: .utf8)!
        XCTAssertEqual(try GeminiEditImageClient.imageData(from: camel), bytes)
        // snake_case inline_data
        let snake = #"{"candidates":[{"content":{"parts":[{"inline_data":{"data":"\#(bytes.base64EncodedString())"}}]}}]}"#.data(using: .utf8)!
        XCTAssertEqual(try GeminiEditImageClient.imageData(from: snake), bytes)
        // no image part → error, not garbage
        let none = #"{"candidates":[{"content":{"parts":[{"text":"sorry, no image"}]}}]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try GeminiEditImageClient.imageData(from: none))
    }

    func testGenerateImageGeminiInitDefaultsToNanoBanana() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let capture = ImageCapture()
        // Mirror the Gemini-backed init: default model is Nano Banana, size is ignored by Gemini.
        let tool = GenerateImageTool(defaultModel: GeminiEditImageClient.defaultModel) { prompt, model, size in
            capture.record(prompt: prompt, model: model, size: size)
            return Data([0x89, 0x50, 0x4E, 0x47])
        }
        let result = try await tool.execute(arguments: ["prompt": "a cat", "out": "art/cat.png"],
                                            context: ToolContext(projectRoot: root))
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(capture.model, "gemini-2.5-flash-image")
    }

    func testGenerateImageRejectsBadSizeAndNonPNGOutput() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let tool = GenerateImageTool { _, _, _ in Data() }

        let badSize = try await tool.execute(arguments: ["prompt": "x", "size": "999x999"], context: ToolContext(projectRoot: root))
        XCTAssertFalse(badSize.success)
        XCTAssertTrue((badSize.error ?? "").contains("unsupported size"))

        let badOut = try await tool.execute(arguments: ["prompt": "x", "out": "x.jpg"], context: ToolContext(projectRoot: root))
        XCTAssertFalse(badOut.success)
        XCTAssertTrue((badOut.error ?? "").contains(".png"))
    }

    func testWatchVideoSamplesFramesAndSendsOrderedVisionAttachments() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: root + "/movie.mp4"))
        let capture = FrameCapture()
        let tool = WatchVideoTool(
            capture: { _, outDir, every, maxFrames, _ in
                capture.every = every
                capture.maxFrames = maxFrames
                let a = outDir + "/frame_0001.jpg"
                let b = outDir + "/frame_0002.jpg"
                try Data([0xFF, 0xD8, 1]).write(to: URL(fileURLWithPath: a))
                try Data([0xFF, 0xD8, 2]).write(to: URL(fileURLWithPath: b))
                return [a, b]
            },
            analyze: { frames, prompt in
                capture.frameCount = frames.count
                capture.prompt = prompt
                return "scene map ready"
            }
        )

        let result = try await tool.execute(arguments: [
            "path": "movie.mp4",
            "every_seconds": 3,
            "max_frames": 2,
            "question": "what changed?"
        ], context: ToolContext(projectRoot: root))

        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(capture.every, 3)
        XCTAssertEqual(capture.maxFrames, 2)
        XCTAssertEqual(capture.frameCount, 2)
        XCTAssertTrue(capture.prompt.contains("sampled every 3 seconds"))
        XCTAssertTrue(result.output.contains("scene map ready"))
    }

    func testLiveScreenWatchCapturesAndComparesScreenshots() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let capture = FrameCapture()
        let tool = LiveScreenWatchTool(
            capture: { outDir, count, interval, _ in
                capture.maxFrames = count
                capture.every = interval
                let a = outDir + "/screen_0001.png"
                let b = outDir + "/screen_0002.png"
                try Data([0x89, 0x50, 1]).write(to: URL(fileURLWithPath: a))
                try Data([0x89, 0x50, 2]).write(to: URL(fileURLWithPath: b))
                return [a, b]
            },
            analyze: { frames, prompt in
                capture.frameCount = frames.count
                capture.prompt = prompt
                return "Safari appeared"
            }
        )

        let result = try await tool.execute(arguments: [
            "seconds": 4,
            "interval": 2,
            "question": "did Safari open?"
        ], context: ToolContext(projectRoot: root))

        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(capture.every, 2)
        XCTAssertEqual(capture.frameCount, 2)
        XCTAssertTrue(capture.prompt.contains("ordered captures"))
        XCTAssertTrue(result.output.contains("Safari appeared"))
    }
}

private struct StubHTTPTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(string: "https://example.com")!
        return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class ImageCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: (String, String, String) = ("", "", "")
    var prompt: String { lock.lock(); defer { lock.unlock() }; return values.0 }
    var model: String { lock.lock(); defer { lock.unlock() }; return values.1 }
    var size: String { lock.lock(); defer { lock.unlock() }; return values.2 }
    func record(prompt: String, model: String, size: String) {
        lock.lock(); values = (prompt, model, size); lock.unlock()
    }
}

private final class FrameCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: (every: Int, maxFrames: Int, frameCount: Int, prompt: String) = (0, 0, 0, "")
    var every: Int {
        get { lock.lock(); defer { lock.unlock() }; return values.every }
        set { lock.lock(); values.every = newValue; lock.unlock() }
    }
    var maxFrames: Int {
        get { lock.lock(); defer { lock.unlock() }; return values.maxFrames }
        set { lock.lock(); values.maxFrames = newValue; lock.unlock() }
    }
    var frameCount: Int {
        get { lock.lock(); defer { lock.unlock() }; return values.frameCount }
        set { lock.lock(); values.frameCount = newValue; lock.unlock() }
    }
    var prompt: String {
        get { lock.lock(); defer { lock.unlock() }; return values.prompt }
        set { lock.lock(); values.prompt = newValue; lock.unlock() }
    }
}
