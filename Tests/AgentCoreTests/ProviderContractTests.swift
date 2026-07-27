import XCTest
@testable import AgentCore

/// CROSS-PROVIDER contract matrix — the line between "works on OpenAI" and "uses all AIs".
///
/// Every native adapter (OpenAI-compatible / Gemini / Anthropic) has a different wire shape, but
/// they must all satisfy the SAME invariants when encoding a tool round-trip. These tests run an
/// identical transcript through each adapter's `makeBodyTools` and assert — wire-shape-agnostically,
/// by serializing the body to JSON — that the universal contract holds. Per multi-site discipline,
/// each invariant is asserted PER ADAPTER with the adapter name in the failure message, so a
/// regression names the offending provider without re-deriving which one broke.
final class ProviderContractTests: XCTestCase {

    private let settings = ModelSettings(maxTokens: 256)

    /// (name, encode) for each native adapter. The closure normalizes the small signature
    /// differences (Gemini's makeBodyTools has no `stream:` param).
    private var adapters: [(name: String, encode: ([ChatMessage], [ToolSpec]) -> [String: Any])] {
        let openai = OpenAICompatibleProvider(
            id: "openai", name: "OpenAI", iconName: "circle", keyAccount: "k",
            endpoint: "https://example.com/v1/chat/completions", defaultModel: "gpt-4o",
            availableModels: [AIModel(id: "gpt-4o")])
        return [
            ("openai", { msgs, tools in openai.makeBodyTools(messages: msgs, model: "gpt-4o", settings: self.settings, tools: tools, stream: true) }),
            ("gemini", { msgs, tools in GeminiProvider().makeBodyTools(messages: msgs, model: "gemini-2.5-flash", settings: self.settings, tools: tools) }),
            ("anthropic", { msgs, tools in AnthropicProvider().makeBodyTools(messages: msgs, model: "claude-3-7-sonnet", settings: self.settings, tools: tools, stream: true) }),
        ]
    }

    private var twoTools: [ToolSpec] {
        [ToolSpec(name: "read_file", description: "Read a file.", parameters: [
            ToolParameter(name: "path", type: "string", description: "path", required: true)]),
         ToolSpec(name: "get_weather", description: "Weather.", parameters: [
            ToolParameter(name: "city", type: "string", description: "city", required: true)])]
    }

    /// A full multi-tool round-trip: the SAME tool called twice (distinct ids) + both results.
    private var roundTripTranscript: [ChatMessage] {
        [ChatMessage(role: .user, content: "read two files"),
         ChatMessage(role: .assistant, content: "", toolCalls: [
            ToolCallRef(id: "c1", name: "read_file", argumentsJSON: #"{"path":"a.txt"}"#),
            ToolCallRef(id: "c2", name: "read_file", argumentsJSON: #"{"path":"b.txt"}"#)]),
         ChatMessage.toolResult(callId: "c1", content: "RESULT_ONE"),
         ChatMessage.toolResult(callId: "c2", content: "RESULT_TWO")]
    }

    private func serialized(_ body: [String: Any], _ adapter: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let s = String(data: data, encoding: .utf8) else {
            XCTFail("[\(adapter)] body is not valid JSON-serializable"); return ""
        }
        return s
    }

    // MARK: - The contract, asserted on every adapter

    func testEveryAdapterEncodesValidJSON() {
        for (name, encode) in adapters {
            let body = encode(roundTripTranscript, twoTools)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(body), "[\(name)] body must be a valid JSON object")
            XCTAssertFalse(serialized(body, name).isEmpty, "[\(name)] body must serialize")
        }
    }

    func testEveryAdapterCarriesToolDefinitions() {
        for (name, encode) in adapters {
            let json = serialized(encode(roundTripTranscript, twoTools), name)
            XCTAssertTrue(json.contains("read_file"), "[\(name)] tool def 'read_file' missing from request")
            XCTAssertTrue(json.contains("get_weather"), "[\(name)] tool def 'get_weather' missing from request")
        }
    }

    func testEveryAdapterEncodesBothToolResults() {
        // The same-name-twice hazard: a broken adapter drops or merges the second result.
        for (name, encode) in adapters {
            let json = serialized(encode(roundTripTranscript, twoTools), name)
            XCTAssertTrue(json.contains("RESULT_ONE"), "[\(name)] first tool result lost")
            XCTAssertTrue(json.contains("RESULT_TWO"), "[\(name)] second tool result lost (same-name dedup bug?)")
        }
    }

    func testEveryAdapterEncodesTheAssistantCall() {
        for (name, encode) in adapters {
            let json = serialized(encode(roundTripTranscript, twoTools), name)
            // The argument payloads of BOTH calls must survive (proves both calls encoded).
            XCTAssertTrue(json.contains("a.txt"), "[\(name)] first tool call args lost")
            XCTAssertTrue(json.contains("b.txt"), "[\(name)] second tool call args lost")
        }
    }

    func testEveryAdapterOmitsToolsBlockWhenNoneProvided() {
        // No tools → no tool/function-declaration scaffolding leaks in (each adapter's own key).
        let plain = [ChatMessage(role: .user, content: "hi")]
        for (name, encode) in adapters {
            let json = serialized(encode(plain, []), name)
            XCTAssertFalse(json.contains("read_file"), "[\(name)] leaked a tool when none were passed")
        }
    }

    func testEveryAdapterTreatsArrayParamsWithItems() {
        // Gemini (and strict OpenAI) reject an array schema with no `items`; all adapters must emit it.
        let arrayTool = [ToolSpec(name: "run", description: "run", parameters: [
            ToolParameter(name: "args", type: "array", description: "argv", required: false)])]
        for (name, encode) in adapters {
            let json = serialized(encode([ChatMessage(role: .user, content: "x")], arrayTool), name)
            XCTAssertTrue(json.contains("items"), "[\(name)] array param must carry an 'items' schema")
        }
    }
}
