import XCTest
@testable import AgentCore

final class OllamaNativeProtocolTests: XCTestCase {
    private let provider = OllamaProvider()
    private let model = "qwen2.5-coder:7b"
    private let tool = ToolSpec(name: "read_file", description: "Read a file", parameters: [
        ToolParameter(name: "path", type: "string", description: "Relative path", required: true)
    ])

    func testNativeExchangeReturnsToolEvidenceWithMatchingNames() throws {
        let history: [ChatMessage] = [
            .init(role: .user, content: "Read two files"),
            .init(role: .assistant, content: "", toolCalls: [
                .init(id: "a", name: "read_file", argumentsJSON: #"{"path":"first.swift"}"#),
                .init(id: "b", name: "search_code", argumentsJSON: #"{"query":"second"}"#)
            ]),
            .toolResult(callId: "b", content: "second.swift:12"),
            .toolResult(callId: "a", content: "let value = 42")
        ]
        let body = try provider.makeBodyTools(messages: history, model: model,
                                             settings: ModelSettings(systemPrompt: "Use the evidence"), tools: [tool])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "tool", "tool"])
        let calls = try XCTUnwrap(messages[2]["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls[0]["function"] as? [String: Any])
        XCTAssertEqual((function["arguments"] as? [String: String])?["path"], "first.swift")
        XCTAssertEqual(messages[3]["tool_name"] as? String, "search_code")
        XCTAssertEqual(messages[4]["tool_name"] as? String, "read_file")
        XCTAssertEqual(messages[4]["content"] as? String, "let value = 42")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let definition = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual((definition["parameters"] as? [String: Any])?["required"] as? [String], ["path"])
    }

    func testBadHistoryCannotBecomeEmptyArgumentsOrAnUnrelatedUserMessage() {
        for args in ["oops", "[]", "null", #""text""#] {
            let history = [ChatMessage(role: .assistant, content: "", toolCalls: [
                .init(id: "a", name: "write_file", argumentsJSON: args)
            ])]
            XCTAssertThrowsError(try provider.makeBodyTools(messages: history, model: model,
                                                            settings: .init(), tools: [tool]))
        }
        XCTAssertThrowsError(try provider.makeBodyTools(messages: [.toolResult(callId: "missing", content: "result")],
                                                        model: model, settings: .init(), tools: [tool]))
        let pending = ChatMessage(role: .assistant, content: "", toolCalls: [
            .init(id: "a", name: "read_file", argumentsJSON: #"{"path":"one"}"#)
        ])
        for history in [[pending], [pending, .init(role: .user, content: "continue")],
                        [pending, .init(role: .assistant, content: "done")]] {
            XCTAssertThrowsError(try provider.makeBodyTools(messages: history, model: model,
                                                            settings: .init(), tools: [tool]))
        }
    }

    func testTranscriptSystemInstructionsSurviveUnlessSettingsReplaceThem() throws {
        let messages: [ChatMessage] = [.init(role: .system, content: "system contract"), .init(role: .user, content: "hello")]
        for native in [false, true] {
            for prompt in ["", "replacement"] {
                let settings = ModelSettings(systemPrompt: prompt)
                let body = try native ? provider.makeBodyTools(messages: messages, model: model, settings: settings, tools: [tool])
                    : provider.makeBody(messages: messages, model: model, settings: settings)
                let wire = try XCTUnwrap(body["messages"] as? [[String: Any]])
                XCTAssertEqual(wire.count, 2)
                XCTAssertEqual(wire[0]["role"] as? String, "system")
                XCTAssertEqual(wire[0]["content"] as? String, prompt.isEmpty ? "system contract" : prompt)
            }
        }
    }

    func testToolChoiceNoneWithholdsDefinitionsAndAnyIsNotSilentlyIgnored() throws {
        let body = try provider.makeBodyTools(messages: [], model: model,
                                             settings: .init(toolChoice: .none), tools: [tool])
        XCTAssertNil(body["tools"])
        XCTAssertThrowsError(try provider.makeBodyTools(messages: [], model: model,
                                                        settings: .init(toolChoice: .any), tools: [tool]))
    }

    func testInlineVisionSentOnBothPathsAndDeduplicated() throws {
        let bytes = Data([1, 2, 3])
        let message = ChatMessage(role: .user, content: "Describe this", imageData: bytes,
                                  attachments: [.init(kind: .image, mimeType: "image/png", payload: .inline(bytes))])
        for body in [provider.makeBody(messages: [message], model: "qwen3-vl:4b-instruct", settings: .init()),
                     try provider.makeBodyTools(messages: [message], model: "qwen3.5:9b-q4_K_M",
                                                settings: .init(), tools: [tool])] {
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertEqual(messages[0]["images"] as? [String], [bytes.base64EncodedString()])
        }
        XCTAssertThrowsError(try provider.validateMedia(messages: [message], model: model))
        let remote = ChatMessage(role: .user, content: "Describe", attachments: [
            .init(kind: .image, mimeType: "image/png", payload: .fileURI("https://example.test/image"))
        ])
        XCTAssertThrowsError(try provider.validateMedia(messages: [remote], model: "qwen3.5:9b"))
    }

    func testJSONAndThinkingControlsReachOllamaWithoutInflatingTokenCap() throws {
        let settings = ModelSettings(maxTokens: 321, seed: 42, disableThinking: true,
                                     jsonSchema: #"{"type":"object","required":["answer"]}"#, topK: 20)
        let body = provider.makeBody(messages: [], model: "qwen3.5:9b-q4_K_M", settings: settings)
        XCTAssertEqual(body["think"] as? Bool, false)
        XCTAssertEqual((body["format"] as? [String: Any])?["required"] as? [String], ["answer"])
        let options = try XCTUnwrap(body["options"] as? [String: Any])
        XCTAssertEqual(options["num_predict"] as? Int, 321)
        XCTAssertEqual(options["seed"] as? Int, 42)
        XCTAssertEqual(options["top_k"] as? Int, 20)
        XCTAssertNil(provider.makeBody(messages: [], model: "custom:latest", settings: settings)["think"])
        XCTAssertEqual(provider.makeBody(messages: [], model: model, settings: .init(jsonOutput: true))["format"] as? String, "json")
    }

    func testCapabilitiesAreConservativeAndDispatchThroughProtocol() {
        let generic: any ChatProvider = provider
        XCTAssertFalse(generic.capabilities(forModel: model).nativeTools)
        XCTAssertTrue(generic.capabilities(forModel: "qwen3-vl:4b-instruct").nativeTools)
        XCTAssertTrue(generic.capabilities(forModel: "qwen3.5:9b-q4_K_M").vision)
        XCTAssertFalse(generic.capabilities(forModel: "qwen3.50:9b").nativeTools)
        XCTAssertFalse(generic.capabilities(forModel: "hf.co/custom/model:Q4_K_M").nativeTools)
        XCTAssertFalse(generic.capabilities(forModel: "llama3.1").vision)
        XCTAssertFalse(OllamaProvider.cobol().supportsNativeTools)
        XCTAssertFalse(OllamaProvider.cobol().capabilities(forModel: model).nativeTools)
        let custom = OllamaProvider(availableModels: [.init(id: "custom", isVision: true, isLocal: true,
                                                           contextWindowTokens: 8192)])
        XCTAssertTrue(custom.capabilities(forModel: "custom").vision)
        XCTAssertEqual(custom.capabilities(forModel: "custom").contextWindowTokens, 8192)
    }

    func testStreamSeparatesReasoningAndPreservesMeasuredUsageAndFinishReason() throws {
        var decoder = OllamaStreamDecoder()
        XCTAssertEqual(try decoder.consume(#"{"message":{"thinking":"checking","content":"Answer"},"done":false}"#),
                       [.reasoning("checking"), .delta("Answer")])
        XCTAssertThrowsError(try decoder.validateCompletion())
        XCTAssertEqual(try decoder.consume(#"{"done":true,"done_reason":"length","prompt_eval_count":40,"eval_count":17}"#),
                       [.usage(promptTokens: 40, completionTokens: 17), .finish(reason: "length")])
        XCTAssertNoThrow(try decoder.validateCompletion())
    }

    func testMultipleToolChunksAndTurnsHaveUniqueIDsAndObjectArguments() throws {
        let frame = #"{"message":{"tool_calls":[{"function":{"index":0,"name":"read_file","arguments":{"path":"one"}}}]},"done":false}"#
        var first = OllamaStreamDecoder(), second = OllamaStreamDecoder()
        let events = try first.consume(frame) + first.consume(frame) + second.consume(frame)
        var ids = Set<String>()
        for event in events {
            guard case .toolCall(let id, let name, let arguments) = event else { return XCTFail("Missing native call") }
            ids.insert(id)
            XCTAssertEqual(name, "read_file")
            XCTAssertEqual(arguments, #"{"path":"one"}"#)
        }
        XCTAssertEqual(ids.count, 3)
    }

    func testMalformedOrErrorFramesAndTruncatedStreamsCannotSucceed() {
        for frame in ["not json", "{}", #"{"error":"runner crashed"}"#,
                      #"{"message":{"tool_calls":"wrong type"}}"#,
                      #"{"message":{"tool_calls":[{"function":{"name":"write_file","arguments":"{}"}}]}}"#,
                      #"{"message":{"tool_calls":[{"function":{"arguments":{}}}]}}"#] {
            var decoder = OllamaStreamDecoder()
            XCTAssertThrowsError(try decoder.consume(frame))
            XCTAssertFalse(decoder.finished)
        }
        let decoder = OllamaStreamDecoder()
        XCTAssertThrowsError(try decoder.validateCompletion())
    }
}
