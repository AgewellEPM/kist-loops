import XCTest
@testable import AgentCore

final class WatsonXProviderTests: XCTestCase {
    private let p = WatsonXProvider()

    // MARK: - Registration & identity

    func testRegisteredInCatalogAsBYOKProvider() {
        let watson = ProviderCatalog.all.first { $0.id == "watsonx" }
        XCTAssertNotNil(watson, "watsonx is a built-in provider")
        XCTAssertTrue(watson!.requiresAPIKey)
        XCTAssertEqual(watson!.keyAccount, "watsonx_api_key")   // → env WATSONX_API_KEY
        XCTAssertFalse(watson!.supportsNativeTools, "routes through the universal text protocol")
    }

    // MARK: - Config resolution from the environment

    func testBaseURLDefaultsToUSSouthAndTrimsOverride() {
        XCTAssertEqual(WatsonXProvider.baseURL(env: [:]), "https://us-south.ml.cloud.ibm.com")
        XCTAssertEqual(WatsonXProvider.baseURL(env: ["WATSONX_URL": "https://eu-de.ml.cloud.ibm.com/"]),
                       "https://eu-de.ml.cloud.ibm.com")
    }

    func testScopePrefersProjectThenSpaceElseNil() {
        XCTAssertNil(WatsonXProvider.scope(env: [:]), "no project/space id → nil (caller fails fast)")
        let proj = WatsonXProvider.scope(env: ["WATSONX_PROJECT_ID": "pid-1"])
        XCTAssertEqual(proj?.key, "project_id"); XCTAssertEqual(proj?.value, "pid-1")
        // project wins over space when both are present
        let both = WatsonXProvider.scope(env: ["WATSONX_PROJECT_ID": "pid-1", "WATSONX_SPACE_ID": "sid-1"])
        XCTAssertEqual(both?.key, "project_id")
        let space = WatsonXProvider.scope(env: ["WATSONX_SPACE_ID": "sid-1"])
        XCTAssertEqual(space?.key, "space_id"); XCTAssertEqual(space?.value, "sid-1")
    }

    // MARK: - Request body (pure)

    func testMakeBodyCarriesModelScopeAndMessages() {
        let msgs = [ChatMessage(role: .system, content: "be terse"),
                    ChatMessage(role: .user, content: "hi")]
        let body = WatsonXProvider.makeBody(messages: msgs, model: "ibm/granite-3-8b-instruct",
                                            scope: ("project_id", "pid-9"),
                                            settings: ModelSettings(maxTokens: 1000))
        XCTAssertEqual(body["model_id"] as? String, "ibm/granite-3-8b-instruct")
        XCTAssertEqual(body["project_id"] as? String, "pid-9")
        let wire = body["messages"] as? [[String: Any]]
        XCTAssertEqual(wire?.count, 2)
        XCTAssertEqual(wire?.first?["role"] as? String, "system")
        XCTAssertEqual(wire?.last?["content"] as? String, "hi")
    }

    func testToolMessageFoldsIntoUserRole() {
        let wire = WatsonXProvider.wireMessages([ChatMessage.toolResult(callId: "c1", content: "result text")])
        XCTAssertEqual(wire.first?["role"] as? String, "user", "tool results ride as user text in the text protocol")
        XCTAssertEqual(wire.first?["content"] as? String, "result text")
    }

    func testReasoningModelGetsTokenFloor() {
        // A big/reasoning model with a tiny caller budget is floored so thinking + answer both fit.
        XCTAssertEqual(WatsonXProvider.effectiveMaxTokens(model: "meta-llama/llama-3-3-70b-instruct",
                                                          settings: ModelSettings(maxTokens: 600)),
                       WatsonXProvider.reasoningTokenFloor)
        // A caller that explicitly disabled thinking keeps its small budget.
        XCTAssertEqual(WatsonXProvider.effectiveMaxTokens(model: "meta-llama/llama-3-3-70b-instruct",
                                                          settings: ModelSettings(maxTokens: 600, disableThinking: true)),
                       600)
        // A small model with a big budget is untouched.
        XCTAssertEqual(WatsonXProvider.effectiveMaxTokens(model: "small-8b",
                                                          settings: ModelSettings(maxTokens: 4096)),
                       4096)
    }

    // MARK: - SSE parsing (pure)

    func testEventsParsesDeltaContent() {
        let events = WatsonXProvider.events(fromSSE: #"{"choices":[{"delta":{"content":"Hello"}}]}"#)
        XCTAssertEqual(events, [.delta("Hello")])
    }

    func testEventsParsesFinishAndUsage() {
        let payload = #"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":5}}"#
        let events = WatsonXProvider.events(fromSSE: payload)
        XCTAssertTrue(events.contains(.finish(reason: "stop")))
        XCTAssertTrue(events.contains(.usage(promptTokens: 12, completionTokens: 5)))
    }

    func testEventsIgnoresDoneAndEmptyAndGarbage() {
        XCTAssertTrue(WatsonXProvider.events(fromSSE: "[DONE]").isEmpty)
        XCTAssertTrue(WatsonXProvider.events(fromSSE: "   ").isEmpty)
        XCTAssertTrue(WatsonXProvider.events(fromSSE: "not json").isEmpty)
        XCTAssertTrue(WatsonXProvider.events(fromSSE: #"{"choices":[{"delta":{"content":""}}]}"#).isEmpty,
                      "an empty content chunk yields no delta")
    }

    // MARK: - Capabilities

    func testCapabilitiesReasoningAndVisionByModel() {
        XCTAssertTrue(p.capabilities(forModel: "meta-llama/llama-3-3-70b-instruct").reasoning)
        XCTAssertTrue(p.capabilities(forModel: "meta-llama/llama-3-2-90b-vision-instruct").vision)
        XCTAssertFalse(p.capabilities(forModel: "ibm/granite-3-8b-instruct").nativeTools)
    }

    // MARK: - Fail-fast guidance

    func testStreamWithoutScopeFailsWithGuidance() async throws {
        // No WATSONX_PROJECT_ID/SPACE_ID in the process env for tests → configuration error.
        // (Guard against a machine that happens to have them set.)
        guard WatsonXProvider.scope() == nil else {
            throw XCTSkip("host has WATSONX_PROJECT_ID/SPACE_ID set; skipping the missing-scope path")
        }
        do {
            _ = try await p.stream(messages: [ChatMessage(role: .user, content: "hi")],
                                   model: p.defaultModel, settings: ModelSettings(), apiKey: "fake-key")
            XCTFail("expected a configuration error for the missing project id")
        } catch let AIProviderError.configuration(msg) {
            XCTAssertTrue(msg.contains("WATSONX_PROJECT_ID"), "the error tells the user exactly what to set")
        } catch {
            XCTFail("expected .configuration, got \(error)")
        }
    }

    func testStreamWithoutKeyFailsMissingKey() async {
        do {
            _ = try await p.stream(messages: [ChatMessage(role: .user, content: "hi")],
                                   model: p.defaultModel, settings: ModelSettings(), apiKey: nil)
            XCTFail("expected missingAPIKey")
        } catch AIProviderError.missingAPIKey(let provider) {
            XCTAssertEqual(provider, "watsonx")
        } catch {
            XCTFail("expected .missingAPIKey, got \(error)")
        }
    }
}
