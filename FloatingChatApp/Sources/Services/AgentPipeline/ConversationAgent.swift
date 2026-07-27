import Foundation

/// Part 1: Understands user intent in natural language
final class ConversationAgent {

    private let systemPrompt = """
    You are a conversation analyzer for a coding assistant that builds macOS/iOS apps.
    Your job is to understand what the user wants to build or modify.

    Analyze their message and extract:
    1. What feature, fix, or change they're requesting
    2. Any context about their project from the conversation
    3. Questions to clarify if the request is unclear
    4. Whether this is ready for development (clear enough to code)
    5. Complexity estimate (simple: <1 file, medium: 2-5 files, complex: >5 files)

    IMPORTANT: Output ONLY valid JSON in this exact format, no other text:
    {
      "userIntent": "clear description of what they want",
      "projectContext": "relevant project details mentioned",
      "clarifications": ["question1", "question2"],
      "isReadyForDevelopment": true,
      "complexity": "simple"
    }

    If the request is clear, set clarifications to empty array and isReadyForDevelopment to true.
    Complexity must be one of: "simple", "medium", "complex"
    """

    func analyze(
        message: String,
        history: [ChatMessage],
        projectPath: String
    ) async throws -> ConversationAnalysis {
        // Use Claude or GPT for conversation understanding
        let provider = await getConversationProvider()

        // Build context from history
        var contextMessages: [ChatMessage] = []

        // Add recent history for context (last 10 messages)
        let recentHistory = history.suffix(10)
        for msg in recentHistory {
            contextMessages.append(msg)
        }

        // Add project context
        let projectInfo = "Project path: \(projectPath)"
        contextMessages.append(ChatMessage(
            role: .user,
            content: "\(projectInfo)\n\nUser request: \(message)\n\nAnalyze this request and output JSON."
        ))

        let settings = ModelSettings(
            temperature: 0.3,  // Low temperature for structured output
            topP: 0.9,
            maxTokens: 1024,
            systemPrompt: systemPrompt
        )

        var response = ""
        let stream = try await provider.sendMessage(
            messages: contextMessages,
            settings: settings,
            stream: false
        )

        for try await chunk in stream {
            response += chunk
        }

        // Parse JSON response
        return try parseAnalysis(from: response)
    }

    @MainActor
    private func getConversationProvider() -> any AIProvider {
        let settings = AgentSettingsManager.shared.settings

        switch settings.conversationModel {
        case "gpt":
            return OpenAIProvider()
        default:
            return AnthropicProvider()
        }
    }

    private func parseAnalysis(from response: String) throws -> ConversationAnalysis {
        // Extract JSON from response (might have markdown code blocks)
        var jsonString = response

        // Remove markdown code blocks if present
        if let jsonStart = response.range(of: "{"),
           let jsonEnd = response.range(of: "}", options: .backwards) {
            jsonString = String(response[jsonStart.lowerBound...jsonEnd.upperBound])
        }

        guard let data = jsonString.data(using: .utf8) else {
            throw AgentError.invalidResponse("Could not parse analysis response")
        }

        do {
            let analysis = try JSONDecoder().decode(ConversationAnalysis.self, from: data)
            return analysis
        } catch {
            // Try to extract key fields manually
            return try parseManually(from: jsonString)
        }
    }

    private func parseManually(from json: String) throws -> ConversationAnalysis {
        // Simple regex-based extraction as fallback
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError.invalidResponse("Could not parse JSON")
        }

        let userIntent = dict["userIntent"] as? String ?? "Unknown intent"
        let projectContext = dict["projectContext"] as? String ?? ""
        let clarifications = dict["clarifications"] as? [String] ?? []
        let isReady = dict["isReadyForDevelopment"] as? Bool ?? true
        let complexityStr = dict["complexity"] as? String ?? "medium"

        let complexity: ConversationAnalysis.Complexity
        switch complexityStr.lowercased() {
        case "simple": complexity = .simple
        case "complex": complexity = .complex
        default: complexity = .medium
        }

        return ConversationAnalysis(
            userIntent: userIntent,
            projectContext: projectContext,
            clarifications: clarifications,
            isReadyForDevelopment: isReady,
            complexity: complexity
        )
    }
}

// MARK: - Agent Errors

enum AgentError: LocalizedError {
    case invalidResponse(String)
    case buildFailed(String)
    case fileOperationFailed(String)
    case providerNotConfigured(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        case .buildFailed(let msg): return "Build failed: \(msg)"
        case .fileOperationFailed(let msg): return "File operation failed: \(msg)"
        case .providerNotConfigured(let msg): return "Provider not configured: \(msg)"
        }
    }
}
