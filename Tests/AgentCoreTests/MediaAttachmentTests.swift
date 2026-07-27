import XCTest
@testable import AgentCore

final class MediaAttachmentTests: XCTestCase {

    // MARK: ChatMessage Codable back-compat (persisted checkpoints predate `attachments`)

    func testDecodesLegacyMessageWithoutAttachments() throws {
        // A checkpoint written before `attachments` existed — the key is simply absent.
        let legacy = #"{"role":"user","content":"hi"}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(ChatMessage.self, from: legacy)
        XCTAssertEqual(msg.content, "hi")
        XCTAssertTrue(msg.attachments.isEmpty)
        XCTAssertFalse(msg.hasImage)
    }

    func testAttachmentsRoundTrip() throws {
        let att = MediaAttachment(kind: .video, mimeType: "video/mp4",
                                 payload: .fileURI("files/abc123"), sourcePath: "/tmp/clip.mp4")
        let msg = ChatMessage(role: .user, content: "watch this", attachments: [att])
        let data = try JSONEncoder().encode(msg)
        let back = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(back.attachments, [att])
        XCTAssertEqual(back.attachments.first?.fileURI, "files/abc123")
    }

    func testAllAttachmentsFoldsLegacyImage() {
        let img = Data([0x1, 0x2, 0x3])
        let msg = ChatMessage(role: .user, content: "see", imageData: img, imageMimeType: "image/png")
        let all = msg.allAttachments
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.kind, .image)
        XCTAssertEqual(all.first?.inlineData, img)
        XCTAssertTrue(msg.hasImage)
    }

    // MARK: Gemini encoding — BOTH encode sites go through `mediaParts` (multi-site invariant)

    func testGeminiMediaPartsInlineAndFileURI() {
        let inlineImg = MediaAttachment(kind: .image, mimeType: "image/png", payload: .inline(Data([0xFF])))
        let videoRef  = MediaAttachment(kind: .video, mimeType: "video/mp4", payload: .fileURI("files/v1"))
        let msg = ChatMessage(role: .user, content: "q", attachments: [inlineImg, videoRef])

        let parts = GeminiProvider.mediaParts(for: msg)
        XCTAssertEqual(parts.count, 2)

        let inlineData = parts[0]["inline_data"] as? [String: Any]
        XCTAssertEqual(inlineData?["mime_type"] as? String, "image/png")
        XCTAssertEqual(inlineData?["data"] as? String, Data([0xFF]).base64EncodedString())

        let fileData = parts[1]["file_data"] as? [String: Any]
        XCTAssertEqual(fileData?["mime_type"] as? String, "video/mp4")
        XCTAssertEqual(fileData?["file_uri"] as? String, "files/v1")
    }

    func testGeminiMediaPartsFoldsLegacyImageData() {
        let msg = ChatMessage(role: .user, content: "q", imageData: Data([0x10]), imageMimeType: "image/jpeg")
        let parts = GeminiProvider.mediaParts(for: msg)
        XCTAssertEqual(parts.count, 1)
        let inlineData = parts[0]["inline_data"] as? [String: Any]
        XCTAssertEqual(inlineData?["mime_type"] as? String, "image/jpeg")
    }
}
