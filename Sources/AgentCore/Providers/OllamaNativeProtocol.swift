import Foundation

extension OllamaProvider {
    /// Ollama uses argument OBJECTS and tool_name results, unlike OpenAI's JSON strings and
    /// tool_call_id. Preserve the native exchange so a local model can act on tool evidence.
    public func makeBodyTools(messages: [ChatMessage], model: String, settings: ModelSettings,
                              tools: [ToolSpec]) throws -> [String: Any] {
        guard settings.toolChoice != .any else {
            throw AIProviderError.configuration("Ollama does not expose a forced tool-choice control")
        }
        var body = makeBody(messages: [], model: model, settings: settings)
        var wire = body["messages"] as? [[String: Any]] ?? []
        var names: [String: String] = [:]
        for message in messages where message.role != .system || settings.systemPrompt.isEmpty {
            var item: [String: Any] = ["role": message.role.rawValue, "content": message.content]
            switch message.role {
            case .assistant:
                guard names.isEmpty else { throw AIProviderError.configuration("Ollama history has unanswered tool calls") }
                names = [:]
                if let calls = message.toolCalls, !calls.isEmpty {
                    item["tool_calls"] = try calls.map { call -> [String: Any] in
                        guard !call.id.isEmpty, !call.name.isEmpty, names[call.id] == nil,
                              let data = call.argumentsJSON.data(using: .utf8),
                              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            throw AIProviderError.configuration("Invalid Ollama assistant tool-call history")
                        }
                        names[call.id] = call.name
                        return ["type": "function", "function": ["name": call.name, "arguments": args]]
                    }
                }
            case .tool:
                guard let id = message.toolCallId, let name = names.removeValue(forKey: id) else {
                    throw AIProviderError.configuration("Ollama tool result has no matching assistant call")
                }
                item["tool_name"] = name
            case .user:
                guard names.isEmpty else { throw AIProviderError.configuration("Ollama history has unanswered tool calls") }
                names = [:]
                if capabilities(forModel: model).vision {
                    let images = message.allAttachments.filter { $0.kind == .image }
                        .compactMap { $0.inlineData?.base64EncodedString() }
                    if !images.isEmpty { item["images"] = images }
                }
            case .system: break
            }
            wire.append(item)
        }
        guard names.isEmpty else { throw AIProviderError.configuration("Ollama history has unanswered tool calls") }
        body["messages"] = wire
        if !tools.isEmpty, settings.toolChoice != .none {
            body["tools"] = tools.map {
                ["type": "function", "function": ["name": $0.name, "description": $0.description,
                                                    "parameters": OpenAICompatibleProvider.jsonSchema($0.parameters)]]
            }
        }
        return body
    }

    /// Never silently answer about an attachment that the local request did not actually carry.
    func validateMedia(messages: [ChatMessage], model: String) throws {
        for message in messages {
            for attachment in message.allAttachments {
                guard message.role == .user, capabilities(forModel: model).vision, attachment.kind == .image,
                      let bytes = attachment.inlineData, !bytes.isEmpty else {
                    throw AIProviderError.configuration("This Ollama model path accepts only supported inline user images; attachment was not sent")
                }
            }
        }
    }
}

/// One decoder per HTTP response. Tool calls arrive as complete objects in Ollama NDJSON,
/// not fragmented OpenAI deltas. Synthesized IDs must remain unique across chunks AND turns.
struct OllamaStreamDecoder {
    private let responseID = UUID().uuidString
    private var callCount = 0
    private(set) var finished = false

    mutating func consume(_ line: String) throws -> [StreamEvent] {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return [] }
        guard !finished, line.utf8.count <= 1_048_576,
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIProviderError.invalidResponse("Invalid Ollama NDJSON frame")
        }
        if let error = json["error"] as? String {
            throw AIProviderError.invalidResponse("Ollama: " + String(error.prefix(600)))
        }
        guard json["message"] is [String: Any] || json["done"] as? Bool == true else {
            throw AIProviderError.invalidResponse("Ollama frame contains no message or completion")
        }
        var events: [StreamEvent] = []
        if let message = json["message"] as? [String: Any] {
            if let thinking = message["thinking"] as? String, !thinking.isEmpty {
                events.append(.reasoning(thinking))
            }
            if let content = message["content"] as? String, !content.isEmpty {
                events.append(.delta(content))
            }
            if let rawCalls = message["tool_calls"] {
                guard let calls = rawCalls as? [[String: Any]], calls.count + callCount <= 128 else {
                    throw AIProviderError.invalidResponse("Invalid Ollama tool-call list")
                }
                for call in calls {
                    guard let function = call["function"] as? [String: Any],
                          let name = function["name"] as? String, !name.isEmpty,
                          let args = function["arguments"] as? [String: Any],
                          JSONSerialization.isValidJSONObject(args) else {
                        throw AIProviderError.invalidResponse("Invalid Ollama tool-call name or arguments")
                    }
                    callCount += 1
                    let encoded = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
                    events.append(.toolCall(id: "ollama_\(responseID)_\(callCount)", name: name,
                                            argumentsJSON: String(decoding: encoded, as: UTF8.self)))
                }
            }
        }
        if json["done"] as? Bool == true {
            finished = true
            if json["prompt_eval_count"] != nil || json["eval_count"] != nil {
                events.append(.usage(promptTokens: max(0, json["prompt_eval_count"] as? Int ?? 0),
                                     completionTokens: max(0, json["eval_count"] as? Int ?? 0)))
            }
            events.append(.finish(reason: json["done_reason"] as? String))
        }
        return events
    }

    func validateCompletion() throws {
        guard finished else {
            throw AIProviderError.invalidResponse("Ollama stream ended before done:true; completion is incomplete")
        }
    }
}
