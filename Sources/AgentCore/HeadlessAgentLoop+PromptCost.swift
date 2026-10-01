import Foundation

extension HeadlessAgentLoop {
    /// Count the effective prompt, including the settings-level system instructions and schemas.
    /// Providers replace transcript system messages when settings supplies the authoritative one.
    /// Character counts remain estimates; measured provider usage reconciles the reservation.
    static func promptCharacters(messages: [ChatMessage], settings: ModelSettings,
                                 tools: [ToolSpec] = []) -> Int {
        let messages = settings.systemPrompt.isEmpty ? messages : messages.filter { $0.role != .system }
        let body = messages.reduce(settings.systemPrompt.count) {
            $0 + ContextWindowManager.default.cost($1)
        }
        let schemas = tools.reduce(0) { total, tool in
            let definition: [String: Any] = ["type": "function", "function": [
                "name": tool.name, "description": tool.description,
                "parameters": OpenAICompatibleProvider.jsonSchema(tool.parameters)
            ]]
            let data = try? JSONSerialization.data(withJSONObject: definition, options: [.sortedKeys])
            return total + (data?.count ?? 0)
        }
        return body + schemas + (settings.jsonSchema?.count ?? 0)
    }
}
