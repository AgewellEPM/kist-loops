import XCTest
@testable import FloatingChatApp

final class GeminiProviderTests: XCTestCase {

    func testMakeRequestBody_mapsRolesAndSystemInstruction() {
        let provider = GeminiProvider()
        var settings = ModelSettings()
        settings.temperature = 0.5
        settings.topP = 0.8
        settings.maxTokens = 1234
        settings.systemPrompt = "SYS-PROMPT"

        let body = provider.makeRequestBody(messages: [
            ChatMessage(role: .system, content: "extra-system"),
            ChatMessage(role: .user, content: "hi"),
            ChatMessage(role: .assistant, content: "hello back")
        ], settings: settings)

        let contents = body["contents"] as? [[String: Any]]
        XCTAssertEqual(contents?.count, 2, "system message must not become a content turn")
        XCTAssertEqual(contents?[0]["role"] as? String, "user")
        XCTAssertEqual(contents?[1]["role"] as? String, "model", "assistant maps to Gemini 'model'")

        let sys = (body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]]
        let sysText = sys?.first?["text"] as? String ?? ""
        XCTAssertTrue(sysText.contains("SYS-PROMPT"))
        XCTAssertTrue(sysText.contains("extra-system"), "system messages fold into systemInstruction")

        let gc = body["generationConfig"] as? [String: Any]
        XCTAssertEqual(gc?["temperature"] as? Double, 0.5)
        XCTAssertEqual(gc?["maxOutputTokens"] as? Int, 1234)
    }

    func testMakeRequestBody_coalescesConsecutiveModelTurns() {
        let provider = GeminiProvider()
        // The agent loop emits reply + thinking + tool_use as 3 assistant msgs.
        let body = provider.makeRequestBody(messages: [
            ChatMessage(role: .user, content: "go"),
            ChatMessage(role: .assistant, content: "thinking..."),
            ChatMessage(role: .assistant, content: "<tool_use>...</tool_use>"),
            ChatMessage(role: .assistant, content: "more")
        ], settings: ModelSettings())

        let contents = body["contents"] as? [[String: Any]]
        XCTAssertEqual(contents?.count, 2, "3 consecutive assistant turns must coalesce into 1 model turn")
        XCTAssertEqual(contents?[1]["role"] as? String, "model")
        let parts = contents?[1]["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.count, 3, "coalesced turn keeps all parts")
    }

    func testModelOverride_takesPrecedenceWithoutPersisting() {
        let provider = GeminiProvider()
        provider.modelOverride = "gemini-2.5-pro"
        XCTAssertEqual(provider.selectedModel?.id, "gemini-2.5-pro")
        // An arbitrary (non-curated) id is still honored.
        provider.modelOverride = "gemini-9.9-future"
        XCTAssertEqual(provider.selectedModel?.id, "gemini-9.9-future")
        // No global default was written.
        XCTAssertNotEqual(UserDefaults.standard.string(forKey: "gemini_model"), "gemini-9.9-future")
    }

    func testExtractTexts_usesOnlyFirstCandidate() {
        let chunk = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"primary\"}]}},{\"content\":{\"parts\":[{\"text\":\"ALT\"}]}}]}"
        XCTAssertEqual(GeminiProvider.extractTexts(fromChunk: chunk), ["primary"])
    }

    func testErrorMapping_distinguishesStatuses() {
        if case .invalidAPIKey = GeminiProvider.error(for: 401, body: "") {} else { XCTFail("401 -> invalidAPIKey") }
        if case .rateLimited = GeminiProvider.error(for: 429, body: "") {} else { XCTFail("429 -> rateLimited") }
        if case .unknown = GeminiProvider.error(for: 403, body: "denied") {} else { XCTFail("403 -> unknown (not invalidAPIKey)") }
    }

    func testExtractTexts_parsesCandidateParts() {
        let chunk = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hello \"},{\"text\":\"world\"}]}}]}"
        XCTAssertEqual(GeminiProvider.extractTexts(fromChunk: chunk), ["hello ", "world"])
    }

    func testExtractTexts_toleratesGarbage() {
        XCTAssertEqual(GeminiProvider.extractTexts(fromChunk: "not json at all"), [])
        XCTAssertEqual(GeminiProvider.extractTexts(fromChunk: "{\"candidates\":[]}"), [])
    }

    func testValidateAPIKey_checksPrefix() async {
        let provider = GeminiProvider()
        let good = await provider.validateAPIKey("AIzaSyABC123")
        let bad = await provider.validateAPIKey("sk-not-a-google-key")
        XCTAssertTrue(good)
        XCTAssertFalse(bad)
    }

    func testRegisteredInProviderManager() {
        XCTAssertTrue(
            ProviderManager.shared.availableProviders.contains { $0.id == "gemini" },
            "Gemini must be registered as a selectable provider"
        )
    }

    func testHasModels() {
        XCTAssertFalse(GeminiProvider().availableModels.isEmpty)
    }
}
