import XCTest
@testable import AgentCore

final class GenerateVideoToolTests: XCTestCase {

    private func tempRoot() throws -> String {
        let raw = NSTemporaryDirectory() + "video_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        return ToolContext.canonicalize(raw)!
    }

    func testOperationNameParse() throws {
        let body = #"{"name":"models/veo-3.1/operations/abc123"}"#.data(using: .utf8)!
        XCTAssertEqual(try GeminiVideoClient.operationName(from: body), "models/veo-3.1/operations/abc123")
        XCTAssertThrowsError(try GeminiVideoClient.operationName(from: #"{}"#.data(using: .utf8)!))
    }

    func testIsDoneAndVideoURIParse() throws {
        let running = #"{"name":"op","done":false}"#.data(using: .utf8)!
        XCTAssertFalse(GeminiVideoClient.isDone(from: running))

        let done = #"{"done":true,"response":{"generateVideoResponse":{"generatedSamples":[{"video":{"uri":"https://gen.example/v.mp4"}}]}}}"#.data(using: .utf8)!
        XCTAssertTrue(GeminiVideoClient.isDone(from: done))
        XCTAssertEqual(try GeminiVideoClient.videoURI(from: done), "https://gen.example/v.mp4")

        // alternate predictions[] shape
        let alt = #"{"done":true,"response":{"predictions":[{"video":{"uri":"https://gen.example/alt.mp4"}}]}}"#.data(using: .utf8)!
        XCTAssertEqual(try GeminiVideoClient.videoURI(from: alt), "https://gen.example/alt.mp4")

        // done but no uri → error, not a silent empty
        let noURI = #"{"done":true,"response":{"generateVideoResponse":{"generatedSamples":[]}}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try GeminiVideoClient.videoURI(from: noURI))
    }

    func testGeneratesMP4InsideProject() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let tool = GenerateVideoTool { prompt, aspect in
            XCTAssertEqual(aspect, "16:9")
            return Data([0x00, 0x00, 0x00, 0x18])   // tiny stub "mp4"
        }
        let result = try await tool.execute(arguments: ["prompt": "a wave", "out": "v/wave.mp4"],
                                            context: ToolContext(projectRoot: root))
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: root + "/v/wave.mp4")), Data([0x00, 0x00, 0x00, 0x18]))
    }

    func testRejectsNonMP4Out() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let tool = GenerateVideoTool { _, _ in Data([1]) }
        let bad = try await tool.execute(arguments: ["prompt": "x", "out": "x.mov"], context: ToolContext(projectRoot: root))
        XCTAssertFalse(bad.success)
        XCTAssertTrue((bad.error ?? "").contains(".mp4"))
    }
}
