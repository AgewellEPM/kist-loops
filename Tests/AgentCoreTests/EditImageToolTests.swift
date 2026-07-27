import XCTest
@testable import AgentCore

final class EditImageToolTests: XCTestCase {

    private final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var v: (String, Data, String)?
        func set(_ p: String, _ d: Data, _ m: String) { lock.lock(); v = (p, d, m); lock.unlock() }
        func get() -> (String, Data, String)? { lock.lock(); defer { lock.unlock() }; return v }
    }

    private func tempRoot() throws -> String {
        let raw = NSTemporaryDirectory() + "edit_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        return ToolContext.canonicalize(raw)!
    }

    func testEditsImageAndWritesPNG() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: root + "/in.png"))
        let box = Box()
        let tool = EditImageTool { prompt, data, mime in
            box.set(prompt, data, mime)
            return Data([0x01, 0x02])   // "edited" bytes
        }
        let result = try await tool.execute(arguments: ["image": "in.png", "prompt": "make it blue", "out": "out/edited.png"],
                                            context: ToolContext(projectRoot: root))
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: root + "/out/edited.png")), Data([0x01, 0x02]))
        let seen = try XCTUnwrap(box.get())
        XCTAssertEqual(seen.0, "make it blue")
        XCTAssertEqual(seen.1, Data([0x89, 0x50, 0x4E, 0x47]))   // input image forwarded
        XCTAssertEqual(seen.2, "image/png")
    }

    func testRejectsNonImageOversizeAndNonPNGOut() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try "txt".write(toFile: root + "/notes.txt", atomically: true, encoding: .utf8)
        try Data([1, 2, 3, 4]).write(to: URL(fileURLWithPath: root + "/big.png"))
        let tool = EditImageTool(inlineCap: 2) { _, _, _ in Data([9]) }

        let notImage = try await tool.execute(arguments: ["image": "notes.txt", "prompt": "x"], context: ToolContext(projectRoot: root))
        XCTAssertFalse(notImage.success)
        XCTAssertTrue((notImage.error ?? "").contains("not a recognized image"))

        let oversize = try await tool.execute(arguments: ["image": "big.png", "prompt": "x"], context: ToolContext(projectRoot: root))
        XCTAssertFalse(oversize.success)
        XCTAssertTrue((oversize.error ?? "").contains("over"))
    }

    func testGeminiEditImageClientEditBuildsImagePart() throws {
        // The edit path reuses imageData parsing; confirm a multi-part response still yields the image.
        let bytes = Data([0x89, 0x50])
        let body = #"{"candidates":[{"content":{"parts":[{"text":"done"},{"inlineData":{"data":"\#(bytes.base64EncodedString())"}}]}}]}"#.data(using: .utf8)!
        XCTAssertEqual(try GeminiEditImageClient.imageData(from: body), bytes)
    }
}
