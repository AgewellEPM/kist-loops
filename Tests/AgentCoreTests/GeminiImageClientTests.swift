import XCTest
@testable import AgentCore

/// The image client's payload construction + response extraction + fail-soft behavior (no network).
final class GeminiImageClientTests: XCTestCase {

    var tmp: [String] = []
    override func tearDownWithError() throws { for p in tmp { try? FileManager.default.removeItem(atPath: p) }; tmp = [] }
    func pngFile() throws -> String {
        // a tiny valid-enough file; the client only base64s bytes, it doesn't decode the image
        let p = NSTemporaryDirectory() + "img-" + UUID().uuidString + ".png"
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: URL(fileURLWithPath: p))
        tmp.append(p); return p
    }

    func testPayloadCarriesBothImagesAndPrompt() throws {
        let a = try pngFile(); let b = try pngFile()
        let data = try GeminiImageClient.payload(model: "gemini-2.5-flash", prompt: "compare these",
                                                 referencePath: a, renderedPath: b)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "gemini-2.5-flash")
        let content = try XCTUnwrap((((obj["messages"] as? [[String: Any]])?.first)?["content"]) as? [[String: Any]])
        XCTAssertEqual(content.count, 3)   // text + 2 images
        XCTAssertEqual(content[0]["type"] as? String, "text")
        let img1 = try XCTUnwrap((content[1]["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertTrue(img1.hasPrefix("data:image/png;base64,"))
    }

    func testMissingImageMakesSendReturnNil() async throws {
        let client = GeminiImageClient(apiKey: "k") { _, _, _ in Data() }  // transport never reached
        let out = await client.send(referencePath: "/no/such.png", renderedPath: "/no/such2.png", prompt: "p")
        XCTAssertNil(out, "an unreadable image must fail-soft to nil (⇒ failed comparison, not a match)")
    }

    func testExtractsContentFromResponse() {
        let json = #"{"choices":[{"message":{"content":"SIMILARITY: 91"}}]}"#.data(using: .utf8)!
        XCTAssertEqual(GeminiImageClient.extractContent(json), "SIMILARITY: 91")
    }

    func testExtractContentFailsSoftOnGarbage() {
        XCTAssertNil(GeminiImageClient.extractContent(Data("not json".utf8)))
        XCTAssertNil(GeminiImageClient.extractContent(#"{"error":"quota"}"#.data(using: .utf8)!))
    }

    func testEndToEndThroughStubTransportAndComparator() async throws {
        let a = try pngFile(); let b = try pngFile()
        let client = GeminiImageClient(apiKey: "k") { _, _, _ in
            #"{"choices":[{"message":{"content":"SIMILARITY: 88\nDIFF|minor|button|slightly off"}}]}"#.data(using: .utf8)!
        }
        // wire the client into the real comparator — proves the whole node works together
        let comparator = GeminiVisualComparator(compareImages: client.compareImages)
        let cmp = await comparator.compare(reference: VisualReference(label: "r", source: a),
                                           rendered: RenderedView(imagePath: b, ok: true))
        XCTAssertTrue(cmp.ok)
        XCTAssertEqual(cmp.similarity, 0.88, accuracy: 0.001)
        XCTAssertEqual(cmp.diffs.count, 1)
    }

    func testTransportErrorFailsSoftThroughComparator() async throws {
        let a = try pngFile(); let b = try pngFile()
        struct Boom: Error {}
        let client = GeminiImageClient(apiKey: "k") { _, _, _ in throw Boom() }
        let comparator = GeminiVisualComparator(compareImages: client.compareImages)
        let cmp = await comparator.compare(reference: VisualReference(label: "r", source: a),
                                           rendered: RenderedView(imagePath: b, ok: true))
        XCTAssertFalse(cmp.ok, "a transport failure must read as a FAILED comparison, never a match")
    }
}
