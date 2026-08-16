import XCTest
@testable import AgentCore

/// Structured-output routing for OpenAI-compatible providers. The invariant is asserted on BOTH
/// request-body sites (text path `makeBody` AND native-tool path `makeBodyTools`) — a fix that only
/// covered one would silently leave the other emitting free text.
final class ProviderStructuredOutputTests: XCTestCase {

    private func provider(nativeTools: Bool = true) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(id: "openai", name: "OpenAI", iconName: "", keyAccount: "openai_api_key",
                                 endpoint: "https://x", defaultModel: "gpt-4o",
                                 availableModels: [AIModel(id: "gpt-4o")],
                                 nativeToolsSupported: nativeTools)
    }

    /// Both body builders, so every assertion below runs against each site by name.
    private func bodies(_ p: OpenAICompatibleProvider, _ settings: ModelSettings) -> [(String, [String: Any])] {
        [
            ("makeBody", p.makeBody(messages: [ChatMessage(role: .user, content: "hi")],
                                    model: "gpt-4o", settings: settings, stream: false)),
            ("makeBodyTools", p.makeBodyTools(messages: [ChatMessage(role: .user, content: "hi")],
                                              model: "gpt-4o", settings: settings, tools: [], stream: false)),
        ]
    }

    func testJSONSchemaEmitsStrictJSONSchemaResponseFormat_bothSites() {
        let settings = ModelSettings(jsonSchema: #"{"type":"object","properties":{"n":{"type":"integer"}}}"#)
        for (site, body) in bodies(provider(), settings) {
            let rf = body["response_format"] as? [String: Any]
            XCTAssertEqual(rf?["type"] as? String, "json_schema", "\(site) must request json_schema")
            let js = rf?["json_schema"] as? [String: Any]
            XCTAssertEqual(js?["name"] as? String, "response", "\(site) json_schema.name")
            XCTAssertEqual(js?["strict"] as? Bool, true, "\(site) json_schema.strict")
            let schema = js?["schema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object", "\(site) must carry the parsed schema")
        }
    }

    func testJSONOutputWithoutSchemaEmitsJSONObject_bothSites() {
        let settings = ModelSettings(jsonOutput: true)
        for (site, body) in bodies(provider(), settings) {
            let rf = body["response_format"] as? [String: Any]
            XCTAssertEqual(rf?["type"] as? String, "json_object", "\(site) must request json_object")
        }
    }

    func testNormalCallHasNoResponseFormat_bothSites() {
        // The default (prose / normal tool loop) must be byte-for-byte unchanged: NO response_format.
        for (site, body) in bodies(provider(), ModelSettings()) {
            XCTAssertNil(body["response_format"], "\(site) must not add response_format unless requested")
        }
    }

    func testMalformedSchemaFallsBackToNothing() {
        // A schema string that isn't valid JSON must not crash or emit a broken field — with no
        // jsonOutput fallback requested, it stays absent (fail-safe, not fail-broken).
        let settings = ModelSettings(jsonSchema: "not json {{{")
        for (site, body) in bodies(provider(), settings) {
            XCTAssertNil(body["response_format"], "\(site) must not emit a response_format from unparseable schema")
        }
    }

    func testCapabilityAdvertisedOnlyForHostedToolCapableModels() {
        XCTAssertTrue(provider(nativeTools: true).capabilities(forModel: "gpt-4o").structuredOutput,
                      "hosted tool-capable model advertises structured output")
        XCTAssertFalse(provider(nativeTools: false).capabilities(forModel: "gpt-4o").structuredOutput,
                       "a model we don't trust for native tools must not claim structured output")
    }

    func testLocalModelOmitsResponseFormatEvenWhenSchemaRequested_bothSites() {
        // Fail-safe: a model that does NOT advertise structured output must NEVER receive response_format,
        // even if a caller mistakenly sets a schema — otherwise a local llama.cpp/MLX endpoint 400s. The
        // capability flag is load-bearing here, asserted on BOTH body sites.
        let settings = ModelSettings(jsonSchema: #"{"type":"object"}"#)
        for (site, body) in bodies(provider(nativeTools: false), settings) {
            XCTAssertNil(body["response_format"], "\(site) must not send response_format to a non-structured-output model")
        }
    }
}
