import XCTest
import Foundation
@testable import AgentCore

/// Pure-function tests for the Anthropic NATIVE tool-calling path (no network).
/// Covers: (a) request body carries `tools` with `input_schema` + names;
/// (b) an assistant+toolCalls message encodes to a `tool_use` block (id/name/input);
/// (c) a `.tool` message encodes to a USER message with a `tool_result` block (tool_use_id);
/// (d) the SSE accumulator reassembles `input_json_delta` fragments into one `.toolCall`.
final class AnthropicNativeToolsTests: XCTestCase {

    private let provider = AnthropicProvider()
    private let settings = ModelSettings(maxTokens: 256, systemPrompt: "be precise")

    private let sampleTools: [ToolSpec] = [
        ToolSpec(name: "list_files",
                 description: "List files in a directory",
                 parameters: [
                    ToolParameter(name: "path", type: "string", description: "directory to list", required: true),
                    ToolParameter(name: "limit", type: "integer", description: "max results", required: false)
                 ])
    ]

    // MARK: helpers

    /// Pull the single tool_use block out of an assistant content array.
    private func toolUseBlocks(_ msg: [String: Any]) -> [[String: Any]] {
        guard let content = msg["content"] as? [[String: Any]] else { return [] }
        return content.filter { ($0["type"] as? String) == "tool_use" }
    }

    // MARK: (a) body carries tools + input_schema + names

    func testBodyCarriesToolsWithInputSchemaAndNames() {
        let body = provider.makeBodyTools(
            messages: [ChatMessage(role: .user, content: "list the files")],
            model: "claude-sonnet-4-5-20250514", settings: settings, tools: sampleTools, stream: true)

        XCTAssertTrue(provider.supportsNativeTools)

        guard let tools = body["tools"] as? [[String: Any]] else {
            return XCTFail("body missing tools array: \(body)")
        }
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"] as? String, "list_files")
        XCTAssertEqual(tools[0]["description"] as? String, "List files in a directory")

        guard let schema = tools[0]["input_schema"] as? [String: Any] else {
            return XCTFail("tool missing input_schema")
        }
        XCTAssertEqual(schema["type"] as? String, "object")
        let props = schema["properties"] as? [String: Any]
        XCTAssertNotNil(props?["path"])
        XCTAssertNotNil(props?["limit"])
        // Only `required: true` params land in `required`.
        XCTAssertEqual(schema["required"] as? [String], ["path"])

        // System hoisted to top level; messages present.
        XCTAssertEqual(body["system"] as? String, "be precise")
        XCTAssertNotNil(body["messages"])
    }

    func testInputSchemaIsPureMapping() {
        let schema = AnthropicProvider.inputSchema([
            ToolParameter(name: "q", type: "string", description: "query", required: true)
        ])
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual((schema["properties"] as? [String: Any])?.count, 1)
        let q = (schema["properties"] as? [String: Any])?["q"] as? [String: Any]
        XCTAssertEqual(q?["type"] as? String, "string")
        XCTAssertEqual(q?["description"] as? String, "query")
    }

    // MARK: (b) assistant + toolCalls → tool_use block

    func testAssistantToolCallsEncodeToToolUseBlock() {
        let assistant = ChatMessage(
            role: .assistant, content: "let me check",
            toolCalls: [ToolCallRef(id: "toolu_abc", name: "list_files",
                                    argumentsJSON: "{\"path\":\"/src\",\"limit\":10}")])
        let body = provider.makeBodyTools(messages: [assistant], model: "m", settings: settings, tools: sampleTools, stream: false)

        guard let messages = body["messages"] as? [[String: Any]],
              let assistantMsg = messages.first(where: { ($0["role"] as? String) == "assistant" }) else {
            return XCTFail("no assistant message: \(body)")
        }
        // Content is a block array: a text block + one tool_use block.
        guard let content = assistantMsg["content"] as? [[String: Any]] else {
            return XCTFail("assistant content not a block array")
        }
        XCTAssertTrue(content.contains { ($0["type"] as? String) == "text" && ($0["text"] as? String) == "let me check" })

        let uses = toolUseBlocks(assistantMsg)
        XCTAssertEqual(uses.count, 1)
        XCTAssertEqual(uses[0]["id"] as? String, "toolu_abc")
        XCTAssertEqual(uses[0]["name"] as? String, "list_files")
        // argumentsJSON parsed back into the input OBJECT.
        let input = uses[0]["input"] as? [String: Any]
        XCTAssertEqual(input?["path"] as? String, "/src")
        XCTAssertEqual(input?["limit"] as? Int, 10)
    }

    func testEmptyContentAssistantOmitsTextBlock() {
        let assistant = ChatMessage(
            role: .assistant, content: "",
            toolCalls: [ToolCallRef(id: "toolu_x", name: "list_files", argumentsJSON: "{}")])
        let body = provider.makeBodyTools(messages: [assistant], model: "m", settings: settings, tools: sampleTools, stream: false)
        let messages = body["messages"] as! [[String: Any]]
        let content = messages[0]["content"] as! [[String: Any]]
        // No empty text block — only the tool_use.
        XCTAssertFalse(content.contains { ($0["type"] as? String) == "text" })
        XCTAssertEqual(content.filter { ($0["type"] as? String) == "tool_use" }.count, 1)
        // Unparseable/empty arguments degrade to an empty object, never drop the block.
        XCTAssertEqual((content[0]["input"] as? [String: Any])?.isEmpty, true)
    }

    // MARK: (c) .tool message → user message with tool_result block

    func testToolResultEncodesToUserMessageWithToolResultBlock() {
        let toolMsg = ChatMessage.toolResult(callId: "toolu_abc", content: "file1.swift\nfile2.swift")
        XCTAssertEqual(toolMsg.role, .tool)   // sanity: the neutral model stores it as .tool

        let body = provider.makeBodyTools(messages: [toolMsg], model: "m", settings: settings, tools: sampleTools, stream: false)
        guard let messages = body["messages"] as? [[String: Any]], let first = messages.first else {
            return XCTFail("no messages")
        }
        // Anthropic has no tool role — the result COLLAPSES to a user message.
        XCTAssertEqual(first["role"] as? String, "user")
        guard let content = first["content"] as? [[String: Any]], let block = content.first else {
            return XCTFail("tool_result content missing")
        }
        XCTAssertEqual(block["type"] as? String, "tool_result")
        XCTAssertEqual(block["tool_use_id"] as? String, "toolu_abc")
        XCTAssertEqual(block["content"] as? String, "file1.swift\nfile2.swift")
        // No `tool` role leaks into the wire format.
        XCTAssertFalse(messages.contains { ($0["role"] as? String) == "tool" })
    }

    // MARK: (d) SSE accumulator reassembles input_json_delta into one .toolCall

    func testSSEAccumulatorReassemblesToolCallArguments() {
        var acc = AnthropicProvider.ToolStreamAccumulator()
        var events: [StreamEvent] = []

        // content_block_start declares the tool_use block (id + name, empty input).
        events += acc.consume(payload: #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_99","name":"list_files","input":{}}}"#)
        // input streams as partial_json fragments — split mid-token to prove reassembly.
        events += acc.consume(payload: #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"pa"}}"#)
        events += acc.consume(payload: #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"th\":\"/s"}}"#)
        events += acc.consume(payload: #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"rc\"}"}}"#)
        // No toolCall yet — only finalized at content_block_stop.
        XCTAssertFalse(events.contains { if case .toolCall = $0 { return true } else { return false } })

        events += acc.consume(payload: #"{"type":"content_block_stop","index":0}"#)

        let calls = events.compactMap { (e) -> (String, String, String)? in
            if case let .toolCall(id, name, args) = e { return (id, name, args) } else { return nil }
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, "toolu_99")
        XCTAssertEqual(calls[0].1, "list_files")
        XCTAssertEqual(calls[0].2, "{\"path\":\"/src\"}")

        // The reassembled arguments are valid JSON with the expected value.
        let obj = try! JSONSerialization.jsonObject(with: calls[0].2.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(obj["path"] as? String, "/src")
    }

    func testSSEAccumulatorEmitsTextDeltasAndEmptyArgsFallback() {
        var acc = AnthropicProvider.ToolStreamAccumulator()
        var events: [StreamEvent] = []

        // A text block streams via text_delta → .delta.
        events += acc.consume(payload: #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
        events += acc.consume(payload: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#)
        events += acc.consume(payload: #"{"type":"content_block_stop","index":0}"#)
        // A tool_use block with NO input_json_delta → arguments fall back to "{}".
        events += acc.consume(payload: #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_e","name":"list_files","input":{}}}"#)
        events += acc.consume(payload: #"{"type":"content_block_stop","index":1}"#)
        events += acc.consume(payload: #"{"type":"message_stop"}"#)

        XCTAssertTrue(events.contains { if case .delta("Hello") = $0 { return true } else { return false } })
        let call = events.compactMap { e -> String? in if case let .toolCall(_, _, args) = e { return args } else { return nil } }.first
        XCTAssertEqual(call, "{}")
        XCTAssertTrue(events.contains { if case .finish = $0 { return true } else { return false } })
    }

    func testSSEAccumulatorInterleavesTwoToolCallsByBlockIndex() {
        var acc = AnthropicProvider.ToolStreamAccumulator()
        var events: [StreamEvent] = []
        // Two tool_use blocks open before either closes; fragments interleave by index.
        events += acc.consume(payload: #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_A","name":"a","input":{}}}"#)
        events += acc.consume(payload: #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_B","name":"b","input":{}}}"#)
        events += acc.consume(payload: #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"y\":2}"}}"#)
        events += acc.consume(payload: #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"x\":1}"}}"#)
        events += acc.consume(payload: #"{"type":"content_block_stop","index":1}"#)
        events += acc.consume(payload: #"{"type":"content_block_stop","index":0}"#)

        let calls = events.compactMap { e -> (String, String)? in
            if case let .toolCall(id, _, args) = e { return (id, args) } else { return nil }
        }
        XCTAssertEqual(calls.count, 2)
        // Each block kept its own buffer — no cross-contamination.
        XCTAssertEqual(calls.first { $0.0 == "toolu_A" }?.1, "{\"x\":1}")
        XCTAssertEqual(calls.first { $0.0 == "toolu_B" }?.1, "{\"y\":2}")
    }
}
