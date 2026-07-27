import XCTest
@testable import AgentCore

/// Pins that the THREE vision-capable provider shapes each encode an inline image — the multi-site
/// invariant (Gemini parts, OpenAI image_url, Anthropic image block). A dragged image must reach
/// whichever model is active, not just Gemini.
final class ProviderVisionEncodingTests: XCTestCase {

    private let img = Data([0xDE, 0xAD, 0xBE, 0xEF])
    private func imageMessage() -> ChatMessage {
        ChatMessage(role: .user, content: "what is this",
                    attachments: [MediaAttachment(kind: .image, mimeType: "image/png", payload: .inline(Data([0xDE, 0xAD, 0xBE, 0xEF])))])
    }

    // MARK: OpenAI-compatible (gpt-4o and friends)

    func testOpenAIUserContentPlainWhenNoImage() {
        let content = OpenAICompatibleProvider.userContent(for: ChatMessage(role: .user, content: "hi"))
        XCTAssertEqual(content as? String, "hi")
    }

    func testOpenAIUserContentEmbedsImageURL() throws {
        let parts = try XCTUnwrap(OpenAICompatibleProvider.userContent(for: imageMessage()) as? [[String: Any]])
        XCTAssertEqual(parts.first?["type"] as? String, "text")
        let imagePart = try XCTUnwrap(parts.first { $0["type"] as? String == "image_url" })
        let url = try XCTUnwrap((imagePart["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertEqual(url, "data:image/png;base64,\(img.base64EncodedString())")
    }

    func testOpenAIBothEncodeSitesUseArrayContentForImages() {
        let p = OpenAICompatibleProvider(id: "openai", name: "OpenAI", iconName: "", keyAccount: "openai_api_key",
                                         endpoint: "https://x", defaultModel: "gpt-4o",
                                         availableModels: [AIModel(id: "gpt-4o", isVision: true)])
        let body = p.makeBody(messages: [imageMessage()], model: "gpt-4o", settings: ModelSettings(), stream: false)
        let msgs = body["messages"] as? [[String: Any]]
        XCTAssertNotNil(msgs?.first(where: { $0["content"] is [[String: Any]] }), "makeBody must use array content")

        let toolsBody = p.makeBodyTools(messages: [imageMessage()], model: "gpt-4o", settings: ModelSettings(), tools: [], stream: false)
        let toolMsgs = toolsBody["messages"] as? [[String: Any]]
        XCTAssertNotNil(toolMsgs?.first(where: { $0["content"] is [[String: Any]] }), "makeBodyTools must use array content")
    }

    func testOpenAICompatibleTextOnlyModelDropsImagePayloadsFromRequestHistory() throws {
        let p = OpenAICompatibleProvider(id: "mimo", name: "MiMo", iconName: "", keyAccount: "mimo_api_key",
                                         endpoint: "https://x", defaultModel: "mimo-v2.5-pro",
                                         availableModels: [AIModel(id: "mimo-v2.5-pro")],
                                         nativeToolsSupported: false)

        let body = p.makeBody(messages: [imageMessage(), ChatMessage(role: .user, content: "make this a PDF")],
                              model: "mimo-v2.5-pro", settings: ModelSettings(), stream: false)
        let data = try JSONSerialization.data(withJSONObject: body)
        let json = String(data: data, encoding: .utf8) ?? ""
        let msgs = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let firstContent = try XCTUnwrap(msgs.first?["content"] as? String)

        XCTAssertTrue(firstContent.contains("what is this"))
        XCTAssertTrue(firstContent.contains("1 image attachment omitted for this text-only model"))
        XCTAssertFalse(json.contains("image_url"))
        XCTAssertFalse(json.contains(img.base64EncodedString()))
    }

    func testOpenAICompatibleTextOnlyNativeBodyAlsoDropsImagePayloads() throws {
        let p = OpenAICompatibleProvider(id: "mimo", name: "MiMo", iconName: "", keyAccount: "mimo_api_key",
                                         endpoint: "https://x", defaultModel: "mimo-v2.5-pro",
                                         availableModels: [AIModel(id: "mimo-v2.5-pro")],
                                         nativeToolsSupported: false)

        let body = p.makeBodyTools(messages: [imageMessage()],
                                   model: "mimo-v2.5-pro", settings: ModelSettings(), tools: [], stream: false)
        let data = try JSONSerialization.data(withJSONObject: body)
        let json = String(data: data, encoding: .utf8) ?? ""
        let msgs = try XCTUnwrap(body["messages"] as? [[String: Any]])

        XCTAssertTrue((msgs.first?["content"] as? String)?.contains("1 image attachment omitted for this text-only model") == true)
        XCTAssertFalse(json.contains("image_url"))
        XCTAssertFalse(json.contains(img.base64EncodedString()))
    }

    // MARK: Anthropic (Claude)

    func testAnthropicUserContentPlainWhenNoImage() {
        let content = AnthropicProvider.userContent(for: ChatMessage(role: .user, content: "hi"))
        XCTAssertEqual(content as? String, "hi")
    }

    func testAnthropicUserContentEmbedsImageBlock() throws {
        let blocks = try XCTUnwrap(AnthropicProvider.userContent(for: imageMessage()) as? [[String: Any]])
        let imageBlock = try XCTUnwrap(blocks.first { $0["type"] as? String == "image" })
        let source = try XCTUnwrap(imageBlock["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, img.base64EncodedString())
    }

    func testAnthropicBothEncodeSitesUseBlocksForImages() {
        let p = AnthropicProvider()
        let body = p.makeBody(messages: [imageMessage()], model: "claude", settings: ModelSettings(), stream: false)
        let msgs = body["messages"] as? [[String: Any]]
        XCTAssertNotNil(msgs?.first(where: { $0["content"] is [[String: Any]] }), "makeBody must use image blocks")

        let toolsBody = p.makeBodyTools(messages: [imageMessage()], model: "claude", settings: ModelSettings(), tools: [], stream: false)
        let toolMsgs = toolsBody["messages"] as? [[String: Any]]
        XCTAssertNotNil(toolMsgs?.first(where: { $0["content"] is [[String: Any]] }), "makeBodyTools must use image blocks")
    }

    // Since the Anthropic image encoder is wired + tested, the Claude models now ADVERTISE vision — so the
    // REPL auto-routes an image to Claude instead of only ever encoding it on a direct call (audit fix).
    func testAnthropicAdvertisesVisionSoAutoRoutingPicksClaude() {
        let p = AnthropicProvider()
        for m in p.availableModels {
            XCTAssertTrue(p.capabilities(forModel: m.id).vision, "\(m.id) should advertise vision (encoder is wired)")
        }
    }
}
