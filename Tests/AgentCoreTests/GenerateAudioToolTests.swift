import XCTest
@testable import AgentCore

final class GenerateAudioToolTests: XCTestCase {

    private func tempRoot() throws -> String {
        let raw = NSTemporaryDirectory() + "audio_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        return ToolContext.canonicalize(raw)!
    }

    func testParsesInlinePCMAndSampleRate() throws {
        let pcmBytes = Data([0x01, 0x02, 0x03, 0x04])
        let body = #"{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"audio/L16;codec=pcm;rate=24000","data":"\#(pcmBytes.base64EncodedString())"}}]}}]}"#.data(using: .utf8)!
        let pcm = try GeminiTTSClient.pcm(from: body)
        XCTAssertEqual(pcm.data, pcmBytes)
        XCTAssertEqual(pcm.sampleRate, 24000)
        // no audio part → error
        let none = #"{"candidates":[{"content":{"parts":[{"text":"nope"}]}}]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try GeminiTTSClient.pcm(from: none))
    }

    func testSampleRateFallsBackTo24kWhenMissing() {
        XCTAssertEqual(GeminiTTSClient.sampleRate(fromMime: "audio/L16;codec=pcm"), 24000)
        XCTAssertEqual(GeminiTTSClient.sampleRate(fromMime: "audio/L16;rate=16000"), 16000)
    }

    func testWavHeaderIsWellFormed() {
        let pcm = Data(repeating: 0xAB, count: 100)
        let wav = GeminiTTSClient.wav(pcm: pcm, sampleRate: 24000)
        XCTAssertEqual(wav.count, 44 + 100)                         // header + data
        XCTAssertEqual(Array(wav.prefix(4)), Array("RIFF".utf8))
        XCTAssertEqual(Array(wav[8..<12]), Array("WAVE".utf8))
        XCTAssertEqual(Array(wav[36..<40]), Array("data".utf8))
        // sample rate at offset 24 (little-endian) == 24000
        let rate = Int(wav[24]) | Int(wav[25]) << 8 | Int(wav[26]) << 16 | Int(wav[27]) << 24
        XCTAssertEqual(rate, 24000)
    }

    func testGeneratesWavFileInsideProject() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let tool = GenerateAudioTool { text, voice in
            XCTAssertEqual(voice, "Kore")                          // default voice
            return .init(data: Data(repeating: 0x00, count: 48000), sampleRate: 24000)
        }
        let result = try await tool.execute(arguments: ["text": "hello there", "out": "out/hi.wav"],
                                            context: ToolContext(projectRoot: root))
        XCTAssertTrue(result.success, result.error ?? "")
        let wav = try Data(contentsOf: URL(fileURLWithPath: root + "/out/hi.wav"))
        XCTAssertEqual(Array(wav.prefix(4)), Array("RIFF".utf8))
        XCTAssertEqual(wav.count, 44 + 48000)
        XCTAssertTrue(result.output.contains("voice Kore"))
    }

    func testRejectsEmptyTextAndNonWavOutput() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let tool = GenerateAudioTool { _, _ in .init(data: Data([1]), sampleRate: 24000) }
        let empty = try await tool.execute(arguments: ["text": "   "], context: ToolContext(projectRoot: root))
        XCTAssertFalse(empty.success)
        let badOut = try await tool.execute(arguments: ["text": "hi", "out": "x.mp3"], context: ToolContext(projectRoot: root))
        XCTAssertFalse(badOut.success)
        XCTAssertTrue((badOut.error ?? "").contains(".wav"))
    }
}
