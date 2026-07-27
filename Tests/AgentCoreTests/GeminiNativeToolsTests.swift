import XCTest
@testable import AgentCore

/// Pure-function tests for the Gemini NATIVE tool-calling path (no network).
/// They pin the wire contract documented in `GeminiProvider`:
///   • request body → `tools[].functionDeclarations` (minimal OpenAPI-subset schema);
///   • assistant `toolCalls` → a `model` `functionCall` part (args re-parsed to an object);
///   • a `.tool` result → a `user` `functionResponse` part whose NAME is looked up from the
///     immediately-preceding assistant turn's calls (matching `toolCallId` → `ToolCallRef.id`);
///   • a `candidates` SSE payload with a `functionCall` → `StreamEvent.toolCall` (synthesized id,
///     args serialized back to a JSON string).
final class GeminiNativeToolsTests: XCTestCase {

    private let provider = GeminiProvider()
    private let settings = ModelSettings()

    // A representative tool: one required string param + one optional integer.
    private var weatherTool: ToolSpec {
        ToolSpec(name: "get_weather", description: "Look up the weather for a city.", parameters: [
            ToolParameter(name: "city", type: "string", description: "City name", required: true),
            ToolParameter(name: "days", type: "integer", description: "Forecast horizon", required: false)
        ])
    }

    // MARK: - (0) provider advertises native tools

    func testSupportsNativeTools() {
        XCTAssertTrue(provider.supportsNativeTools)
    }

    // MARK: - (a) request body carries functionDeclarations with the right names/params

    func testBodyContainsFunctionDeclarations() {
        let messages = [ChatMessage(role: .user, content: "weather in Hartford?")]
        // Isolate function declarations from the server-side built-ins (tested separately).
        let s = ModelSettings(geminiBuiltins: false)
        let body = provider.makeBodyTools(messages: messages, model: "gemini-2.5-flash", settings: s, tools: [weatherTool])

        // tools → [{ functionDeclarations: [ {name, description, parameters} ] }]
        let tools = body["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        let decls = tools?.first?["functionDeclarations"] as? [[String: Any]]
        XCTAssertEqual(decls?.count, 1)
        let decl = decls?.first
        XCTAssertEqual(decl?["name"] as? String, "get_weather")
        XCTAssertEqual(decl?["description"] as? String, "Look up the weather for a city.")

        // parameters = minimal object schema; required reflects ToolParameter.required.
        let params = decl?["parameters"] as? [String: Any]
        XCTAssertEqual(params?["type"] as? String, "object")
        let props = params?["properties"] as? [String: Any]
        XCTAssertNotNil(props?["city"])
        XCTAssertNotNil(props?["days"])
        XCTAssertEqual((props?["city"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((props?["days"] as? [String: Any])?["type"] as? String, "integer")
        let required = params?["required"] as? [String]
        XCTAssertEqual(required, ["city"])  // only the required param

        // Minimal schema: none of the keys Gemini rejects.
        XCTAssertNil(params?["additionalProperties"])
        XCTAssertNil(params?["$ref"])
        XCTAssertNil(params?["oneOf"])
    }

    func testBodyHasNoToolsWhenNoneProvidedAndBuiltinsOff() {
        let s = ModelSettings(geminiBuiltins: false)
        let body = provider.makeBodyTools(messages: [ChatMessage(role: .user, content: "hi")],
                                          model: "gemini-2.5-flash", settings: s, tools: [])
        XCTAssertNil(body["tools"])
    }

    // MARK: - Server-side built-in tools (Google Search / URL context / code execution)

    func testBuiltinToolsSuppressedWhenFunctionToolsPresent() {
        // LIVE-VERIFIED: the API 400s on ANY built-in + functionDeclarations. With function tools
        // present, ONLY functionDeclarations may be sent — no built-ins at all.
        let body = provider.makeBodyTools(messages: [ChatMessage(role: .user, content: "latest news?")],
                                          model: "gemini-2.5-flash", settings: ModelSettings(), tools: [weatherTool])
        let tools = body["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, 1, "only functionDeclarations when function tools are present")
        XCTAssertNotNil(tools.first?["functionDeclarations"])
        XCTAssertFalse(tools.contains { $0["google_search"] != nil })
        XCTAssertFalse(tools.contains { $0["url_context"] != nil })
        XCTAssertFalse(tools.contains { $0["code_execution"] != nil })
    }

    func testBuiltinToolsAddedEvenWithNoFunctionTools() {
        let body = provider.makeBodyTools(messages: [ChatMessage(role: .user, content: "what's 2^40?")],
                                          model: "gemini-2.5-flash", settings: ModelSettings(), tools: [])
        let tools = body["tools"] as? [[String: Any]] ?? []
        // No functionDeclarations → all three built-ins, including code_execution.
        XCTAssertEqual(tools.count, 3, "three built-ins, no functionDeclarations block")
        XCTAssertTrue(tools.contains { $0["code_execution"] != nil }, "code_execution available on tool-less turns")
        XCTAssertNil(tools.first { $0["functionDeclarations"] != nil })
    }

    func testBuiltinsSuppressedWhenDisabledOrUnsupportedModel() {
        let off = provider.makeBodyTools(messages: [ChatMessage(role: .user, content: "hi")],
                                         model: "gemini-2.5-flash", settings: ModelSettings(geminiBuiltins: false), tools: [weatherTool])
        let offTools = off["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(offTools.count, 1, "only functionDeclarations when builtins off")
        // A media/tts model never gets built-ins even when the flag is on.
        XCTAssertFalse(GeminiProvider.supportsBuiltins(model: "gemini-2.5-flash-image"))
        XCTAssertFalse(GeminiProvider.supportsBuiltins(model: "gemini-2.5-flash-preview-tts"))
        XCTAssertTrue(GeminiProvider.supportsBuiltins(model: "gemini-2.5-flash"))
        XCTAssertTrue(GeminiProvider.supportsBuiltins(model: "gemini-3.1-pro"))
    }

    func testJsonOutputSetsResponseMimeType() {
        let on = provider.makeBodyTools(messages: [ChatMessage(role: .user, content: "give me JSON")],
                                        model: "gemini-2.5-flash", settings: ModelSettings(jsonOutput: true), tools: [])
        XCTAssertEqual((on["generationConfig"] as? [String: Any])?["responseMimeType"] as? String, "application/json")
        let off = provider.makeBodyTools(messages: [ChatMessage(role: .user, content: "prose")],
                                         model: "gemini-2.5-flash", settings: ModelSettings(), tools: [])
        XCTAssertNil((off["generationConfig"] as? [String: Any])?["responseMimeType"])
    }

    func testGenerationKnobsEmittedWhenSet() {
        let s = ModelSettings(seed: 42, topK: 32, stopSequences: ["STOP", "END"],
                              frequencyPenalty: 0.5, presencePenalty: -0.2, thinkingBudget: 1024)
        let gen = provider.makeBodyTools(messages: [ChatMessage(role: .user, content: "hi")],
                                         model: "gemini-2.5-flash", settings: s, tools: [])["generationConfig"] as? [String: Any]
        XCTAssertEqual(gen?["seed"] as? Int, 42)
        XCTAssertEqual(gen?["topK"] as? Int, 32)
        XCTAssertEqual(gen?["stopSequences"] as? [String], ["STOP", "END"])
        XCTAssertEqual(gen?["frequencyPenalty"] as? Double, 0.5)
        XCTAssertEqual(gen?["presencePenalty"] as? Double, -0.2)
        XCTAssertEqual((gen?["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int, 1024)
    }

    func testDisableThinkingWinsOverBudgetAndDefaultsOmitNothing() {
        let off = provider.makeBodyTools(messages: [ChatMessage(role: .user, content: "hi")],
                                         model: "gemini-2.5-flash",
                                         settings: ModelSettings(disableThinking: true, thinkingBudget: 9999), tools: [])
        let gen = off["generationConfig"] as? [String: Any]
        XCTAssertEqual((gen?["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int, 0)
        // Defaults: none of the optional knobs appear.
        let bare = provider.makeBodyTools(messages: [ChatMessage(role: .user, content: "hi")],
                                          model: "gemini-2.5-flash", settings: ModelSettings(), tools: [])["generationConfig"] as? [String: Any]
        XCTAssertNil(bare?["topK"]); XCTAssertNil(bare?["seed"]); XCTAssertNil(bare?["stopSequences"]); XCTAssertNil(bare?["thinkingConfig"])
    }

    func testGemini3OmitsSamplingControlsButKeepsSeed() {
        let s = ModelSettings(seed: 7, topK: 10, frequencyPenalty: 0.3)
        let gen = provider.makeBodyTools(messages: [ChatMessage(role: .user, content: "hi")],
                                         model: "gemini-3.1-pro", settings: s, tools: [])["generationConfig"] as? [String: Any]
        XCTAssertNil(gen?["topK"], "gemini-3 ignores sampling controls")
        XCTAssertNil(gen?["frequencyPenalty"])
        XCTAssertNil(gen?["temperature"])
        XCTAssertEqual(gen?["seed"] as? Int, 7, "seed still applies")
    }

    func testToolChoiceEmitsToolConfig() {
        func mode(_ choice: ToolChoice) -> String? {
            let body = provider.makeBodyTools(messages: [ChatMessage(role: .user, content: "hi")],
                                              model: "gemini-2.5-flash", settings: ModelSettings(toolChoice: choice), tools: [weatherTool])
            return ((body["toolConfig"] as? [String: Any])?["functionCallingConfig"] as? [String: Any])?["mode"] as? String
        }
        XCTAssertNil(mode(.auto), "AUTO is the API default → omitted")
        XCTAssertEqual(mode(.any), "ANY")
        XCTAssertEqual(mode(.none), "NONE")
    }

    func testJsonSchemaEmitsResponseSchema() {
        let schema = #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#
        let body = provider.makeBodyTools(messages: [ChatMessage(role: .user, content: "extract")],
                                          model: "gemini-2.5-flash", settings: ModelSettings(jsonSchema: schema), tools: [])
        let gen = body["generationConfig"] as? [String: Any]
        XCTAssertEqual(gen?["responseMimeType"] as? String, "application/json")
        let rs = gen?["responseSchema"] as? [String: Any]
        XCTAssertEqual(rs?["type"] as? String, "object")
        XCTAssertNotNil((rs?["properties"] as? [String: Any])?["name"])
        // Malformed schema is ignored (no crash, no responseSchema), not blindly forwarded.
        let bad = provider.makeBodyTools(messages: [ChatMessage(role: .user, content: "x")],
                                         model: "gemini-2.5-flash", settings: ModelSettings(jsonSchema: "{not json"), tools: [])
        XCTAssertNil((bad["generationConfig"] as? [String: Any])?["responseSchema"])
    }

    func testCapabilitiesAdvertiseBuiltins() {
        let caps = provider.capabilities(forModel: "gemini-2.5-flash")
        XCTAssertTrue(caps.grounding)
        XCTAssertTrue(caps.urlContext)
        XCTAssertTrue(caps.codeExecution)
        XCTAssertTrue(caps.structuredOutput)
    }

    func testParsesCodeExecutionAndGroundingFromSSE() {
        // executableCode + codeExecutionResult parts → fenced blocks in the delta stream.
        let codeSSE = """
        {"candidates":[{"content":{"parts":[{"executableCode":{"language":"PYTHON","code":"print(2**40)"}},{"codeExecutionResult":{"outcome":"OUTCOME_OK","output":"1099511627776"}}]}}]}
        """
        let codeText = GeminiProvider.eventsWithTools(fromSSE: codeSSE).compactMap { if case .delta(let d) = $0 { return d } else { return nil } }.joined()
        XCTAssertTrue(codeText.contains("print(2**40)"))
        XCTAssertTrue(codeText.contains("1099511627776"))

        // groundingMetadata → a "Sources:" line with the cited URLs.
        let groundSSE = """
        {"candidates":[{"content":{"parts":[{"text":"It is sunny."}]},"groundingMetadata":{"groundingChunks":[{"web":{"uri":"https://example.com/wx","title":"Weather"}}]}}]}
        """
        let groundText = GeminiProvider.eventsWithTools(fromSSE: groundSSE).compactMap { if case .delta(let d) = $0 { return d } else { return nil } }.joined()
        XCTAssertTrue(groundText.contains("Sources:"))
        XCTAssertTrue(groundText.contains("https://example.com/wx"))
    }

    func testDisableThinkingAddsThinkingBudgetForPlainAndToolBodies() {
        let settings = ModelSettings(maxTokens: 64, disableThinking: true)
        let plain = provider.makeBody(messages: [ChatMessage(role: .user, content: "OK")],
                                      model: "gemini-2.5-flash", settings: settings)
        let plainConfig = plain["generationConfig"] as? [String: Any]
        XCTAssertEqual((plainConfig?["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int, 0)

        let tools = provider.makeBodyTools(messages: [ChatMessage(role: .user, content: "OK")],
                                           model: "gemini-2.5-flash", settings: settings, tools: [weatherTool])
        let toolsConfig = tools["generationConfig"] as? [String: Any]
        XCTAssertEqual((toolsConfig?["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int, 0)
    }

    // MARK: - (b) assistant + toolCalls encodes to a functionCall part

    func testAssistantToolCallsEncodeToFunctionCallPart() {
        let assistant = ChatMessage(role: .assistant, content: "", toolCalls: [
            ToolCallRef(id: "call_get_weather", name: "get_weather", argumentsJSON: "{\"city\":\"Hartford\",\"days\":3}")
        ])
        let body = provider.makeBodyTools(messages: [assistant], model: "gemini-2.5-flash", settings: settings, tools: [weatherTool])

        let contents = body["contents"] as? [[String: Any]]
        XCTAssertEqual(contents?.count, 1)
        let modelTurn = contents?.first
        XCTAssertEqual(modelTurn?["role"] as? String, "model")  // assistant → model

        let parts = modelTurn?["parts"] as? [[String: Any]]
        let fcPart = parts?.first(where: { $0["functionCall"] != nil })
        let fc = fcPart?["functionCall"] as? [String: Any]
        XCTAssertEqual(fc?["name"] as? String, "get_weather")

        // args is an OBJECT (parsed back from argumentsJSON), not a string.
        let args = fc?["args"] as? [String: Any]
        XCTAssertEqual(args?["city"] as? String, "Hartford")
        XCTAssertEqual(args?["days"] as? Int, 3)
    }

    // MARK: - (c) a .tool message encodes to a functionResponse with the looked-up NAME

    func testToolResultEncodesFunctionResponseWithLookedUpName() {
        // Note the call ID and the tool NAME differ on purpose — the encoder must use the
        // NAME from the preceding assistant call (matched by id), NOT the toolCallId.
        let assistant = ChatMessage(role: .assistant, content: "", toolCalls: [
            ToolCallRef(id: "xyz-123", name: "get_weather", argumentsJSON: "{\"city\":\"Hartford\"}")
        ])
        let toolResult = ChatMessage.toolResult(callId: "xyz-123", content: "Sunny, 72F")
        let body = provider.makeBodyTools(messages: [assistant, toolResult],
                                          model: "gemini-2.5-flash", settings: settings, tools: [weatherTool])

        let contents = body["contents"] as? [[String: Any]]
        // model turn (functionCall) immediately followed by user turn (functionResponse).
        XCTAssertEqual(contents?.count, 2)
        XCTAssertEqual(contents?[0]["role"] as? String, "model")
        XCTAssertEqual(contents?[1]["role"] as? String, "user")

        let respPart = (contents?[1]["parts"] as? [[String: Any]])?.first
        let fr = respPart?["functionResponse"] as? [String: Any]
        XCTAssertEqual(fr?["name"] as? String, "get_weather")  // NAME, not "xyz-123"
        let response = fr?["response"] as? [String: Any]
        XCTAssertEqual(response?["result"] as? String, "Sunny, 72F")
    }

    func testToolResultNameFallsBackToStrippedCallId() {
        // No preceding assistant call to match → fall back to the synthesized id. Legacy
        // `call_<name>` (no suffix) → strip prefix only.
        let orphanResult = ChatMessage.toolResult(callId: "call_search", content: "ok")
        let body = provider.makeBodyTools(messages: [orphanResult],
                                          model: "gemini-2.5-flash", settings: settings, tools: [])
        let contents = body["contents"] as? [[String: Any]]
        let fr = ((contents?.first?["parts"] as? [[String: Any]])?.first)?["functionResponse"] as? [String: Any]
        XCTAssertEqual(fr?["name"] as? String, "search")  // "call_" prefix stripped
    }

    func testToolResultNameFallsBackStripsUniqueSuffix() {
        // Current id format `call_<name>_<8hex>` → strip prefix AND the fixed-length suffix.
        let orphan = ChatMessage.toolResult(callId: "call_get_weather_a1b2c3d4", content: "ok")
        let body = provider.makeBodyTools(messages: [orphan], model: "gemini-2.5-flash", settings: settings, tools: [])
        let fr = (((body["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])?.first)?["functionResponse"] as? [String: Any]
        XCTAssertEqual(fr?["name"] as? String, "get_weather")  // suffix stripped, name intact
        // A tool name that itself contains underscores must survive (suffix is fixed-length).
        XCTAssertEqual(GeminiProvider.recoverToolName(fromSyntheticID: "call_read_file_deadbeef"), "read_file")
        // A name ending in something that merely LOOKS like the suffix but isn't 8 hex → untouched.
        XCTAssertEqual(GeminiProvider.recoverToolName(fromSyntheticID: "call_do_thing"), "do_thing")
    }

    // MARK: - (d) a candidates SSE payload with a functionCall parses to .toolCall

    func testFunctionCallSSEParsesToToolCallEvent() {
        let json = """
        {"candidates":[{"content":{"parts":[{"functionCall":{"name":"get_weather","args":{"city":"Hartford","days":3}}}]}}]}
        """
        let events = GeminiProvider.eventsWithTools(fromSSE: json)
        let toolCalls = events.compactMap { event -> (String, String, String)? in
            if case let .toolCall(id, name, argsJSON) = event { return (id, name, argsJSON) }
            return nil
        }
        XCTAssertEqual(toolCalls.count, 1)
        // Synthesized id: `call_<name>_<8hex>` (unique suffix so repeated names don't collide).
        XCTAssertTrue(toolCalls.first?.0.hasPrefix("call_get_weather_") ?? false, "id=\(toolCalls.first?.0 ?? "")")
        XCTAssertEqual(toolCalls.first?.0.count, "call_get_weather_".count + 8)
        XCTAssertEqual(toolCalls.first?.1, "get_weather")
        // args serialized back to a canonical (sorted-keys) JSON string.
        XCTAssertEqual(toolCalls.first?.2, "{\"city\":\"Hartford\",\"days\":3}")
    }

    func testRepeatedSameNameCallsGetUniqueIDs() {
        // REGRESSION (Codex r-native HIGH): two calls to the SAME function in one turn must get
        // DISTINCT ids — a shared `call_<name>` id breaks toolCallId→name routing for the 2nd result.
        let json = """
        {"candidates":[{"content":{"parts":[
          {"functionCall":{"name":"read_file","args":{"path":"a.txt"}}},
          {"functionCall":{"name":"read_file","args":{"path":"b.txt"}}}
        ]}}]}
        """
        let ids = GeminiProvider.eventsWithTools(fromSSE: json).compactMap { e -> String? in
            if case let .toolCall(id, _, _) = e { return id }
            return nil
        }
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1], "same-name calls must not share an id")
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("call_read_file_") })
    }

    func testRepeatedSameNameRoundTripsToCorrectNames() {
        // End-to-end: an assistant turn with two distinct-id same-name calls + two results must
        // encode BOTH functionResponses with the right name (proves the routing the unique id buys).
        let calls = [
            ToolCallRef(id: "call_read_file_aaaaaaaa", name: "read_file", argumentsJSON: "{\"path\":\"a.txt\"}"),
            ToolCallRef(id: "call_read_file_bbbbbbbb", name: "read_file", argumentsJSON: "{\"path\":\"b.txt\"}")
        ]
        let assistant = ChatMessage(role: .assistant, content: "", toolCalls: calls)
        let r1 = ChatMessage.toolResult(callId: "call_read_file_aaaaaaaa", content: "AAA")
        let r2 = ChatMessage.toolResult(callId: "call_read_file_bbbbbbbb", content: "BBB")
        let body = provider.makeBodyTools(messages: [assistant, r1, r2], model: "gemini-2.5-flash", settings: settings, tools: [])
        let contents = body["contents"] as? [[String: Any]]
        // model(2 functionCalls) + user(2 functionResponse parts — Gemini coalesces same-role turns).
        XCTAssertEqual(contents?.count, 2)
        let respParts = (contents?[1]["parts"] as? [[String: Any]]) ?? []
        XCTAssertEqual(respParts.count, 2)
        let fr1 = respParts[0]["functionResponse"] as? [String: Any]
        let fr2 = respParts[1]["functionResponse"] as? [String: Any]
        XCTAssertEqual(fr1?["name"] as? String, "read_file")
        XCTAssertEqual(fr2?["name"] as? String, "read_file")
        // Each result keeps its OWN payload — proves the unique ids routed correctly.
        XCTAssertEqual((fr1?["response"] as? [String: Any])?["result"] as? String, "AAA")
        XCTAssertEqual((fr2?["response"] as? [String: Any])?["result"] as? String, "BBB")
    }

    func testTextPartsStillParseToDelta() {
        let json = """
        {"candidates":[{"content":{"parts":[{"text":"Hello "},{"text":"world"}]}}]}
        """
        let events = GeminiProvider.eventsWithTools(fromSSE: json)
        XCTAssertEqual(events, [.delta("Hello "), .delta("world")])
    }

    func testMixedTextAndFunctionCallSSE() {
        let json = """
        {"candidates":[{"content":{"parts":[{"text":"Let me check."},{"functionCall":{"name":"get_weather","args":{"city":"Boston"}}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":11,"candidatesTokenCount":4}}
        """
        let events = GeminiProvider.eventsWithTools(fromSSE: json)
        // The toolCall id carries a random suffix, so assert structurally rather than by equality.
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0], .delta("Let me check."))
        if case let .toolCall(id, name, args) = events[1] {
            XCTAssertTrue(id.hasPrefix("call_get_weather_"))
            XCTAssertEqual(name, "get_weather")
            XCTAssertEqual(args, "{\"city\":\"Boston\"}")
        } else { XCTFail("expected .toolCall, got \(events[1])") }
        XCTAssertEqual(events[2], .finish(reason: "STOP"))
        XCTAssertEqual(events[3], .usage(promptTokens: 11, completionTokens: 4))
    }

    // MARK: - round-trip: parseArgs ↔ serializeArgs helpers

    func testArgsRoundTripObjectShape() {
        let parsed = GeminiProvider.parseArgs("{\"a\":1,\"b\":\"two\"}")
        XCTAssertEqual(parsed["a"] as? Int, 1)
        XCTAssertEqual(parsed["b"] as? String, "two")
        // malformed / non-object → empty object (never crash, never a string body).
        XCTAssertTrue(GeminiProvider.parseArgs("not json").isEmpty)
        XCTAssertEqual(GeminiProvider.serializeArgs([:]), "{}")
    }
}
