import Foundation

/// Manages token counting and context window optimization
/// Helps prevent exceeding model context limits
final class TokenManager {
    static let shared = TokenManager()

    private init() {}

    // MARK: - Token Estimation

    /// Approximate token count for text
    /// Uses the common heuristic: ~4 characters per token for English
    /// More accurate would require actual tokenizer, but this is good enough for limits
    func estimateTokens(_ text: String) -> Int {
        // Average ~4 characters per token for English text
        // Code tends to be slightly more (~3.5 chars/token due to syntax)
        let charCount = text.count
        return max(1, charCount / 4)
    }

    /// Estimate tokens for a chat message including role overhead
    func estimateTokens(for message: ChatMessage) -> Int {
        // Add overhead for role markers (~4 tokens)
        return estimateTokens(message.content) + 4
    }

    /// Estimate total tokens in conversation
    func estimateTokens(for messages: [ChatMessage]) -> Int {
        return messages.reduce(0) { $0 + estimateTokens(for: $1) }
    }

    /// Estimate tokens for an AgentMessage
    func estimateTokens(for message: AgentMessage) -> Int {
        return estimateTokens(message.textContent) + 4
    }

    // MARK: - Context Management

    /// Default context limits per model family
    struct ContextLimits {
        static let claude3 = 200_000       // Claude 3 models
        static let claude35 = 200_000      // Claude 3.5 models
        static let gpt4 = 128_000          // GPT-4 Turbo
        static let gpt4o = 128_000         // GPT-4o
        static let gpt35 = 16_000          // GPT-3.5
        static let deepseek = 64_000       // DeepSeek
        static let ollama = 8_000          // Local models (conservative)

        static func limit(for modelId: String) -> Int {
            if modelId.contains("claude-3") {
                return claude35
            } else if modelId.contains("gpt-4o") {
                return gpt4o
            } else if modelId.contains("gpt-4") {
                return gpt4
            } else if modelId.contains("gpt-3.5") {
                return gpt35
            } else if modelId.contains("deepseek") {
                return deepseek
            } else {
                return ollama  // Conservative default
            }
        }
    }

    /// Reserve tokens for response generation
    let responseReserve = 4096

    /// Truncate conversation history to fit within context limit
    func truncateHistory(
        _ messages: [AgentMessage],
        maxTokens: Int,
        reserveForResponse: Int = 4096
    ) -> [AgentMessage] {
        let availableTokens = maxTokens - reserveForResponse
        guard availableTokens > 0 else { return [] }

        var result: [AgentMessage] = []
        var usedTokens = 0

        // Always try to include the most recent messages (work backwards)
        for message in messages.reversed() {
            let messageTokens = estimateTokens(for: message)

            if usedTokens + messageTokens <= availableTokens {
                result.insert(message, at: 0)
                usedTokens += messageTokens
            } else if result.isEmpty {
                // Always include at least the most recent message, even if it exceeds limit
                // (the API will handle truncation)
                result.append(message)
                break
            } else {
                // Can't fit more messages
                break
            }
        }

        return result
    }

    /// Truncate ChatMessage history for API calls
    func truncateHistory(
        _ messages: [ChatMessage],
        maxTokens: Int,
        systemPromptTokens: Int = 0,
        reserveForResponse: Int = 4096
    ) -> [ChatMessage] {
        let availableTokens = maxTokens - reserveForResponse - systemPromptTokens
        guard availableTokens > 0 else { return [] }

        var result: [ChatMessage] = []
        var usedTokens = 0

        // Keep system messages at the start
        let systemMessages = messages.filter { $0.role == .system }
        let otherMessages = messages.filter { $0.role != .system }

        for msg in systemMessages {
            let tokens = estimateTokens(for: msg)
            if usedTokens + tokens <= availableTokens {
                result.append(msg)
                usedTokens += tokens
            }
        }

        // Add recent messages (newest first in priority)
        for message in otherMessages.reversed() {
            let messageTokens = estimateTokens(for: message)

            if usedTokens + messageTokens <= availableTokens {
                // Insert after system messages
                result.insert(message, at: systemMessages.count)
                usedTokens += messageTokens
            } else if result.count == systemMessages.count {
                // Always include at least one non-system message
                result.append(message)
                break
            } else {
                break
            }
        }

        return result
    }

    // MARK: - Usage Tracking

    /// Track token usage for a session
    struct UsageStats {
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var totalCalls: Int = 0

        var totalTokens: Int { inputTokens + outputTokens }
    }

    private var sessionUsage = UsageStats()

    func recordUsage(inputTokens: Int, outputTokens: Int) {
        sessionUsage.inputTokens += inputTokens
        sessionUsage.outputTokens += outputTokens
        sessionUsage.totalCalls += 1
    }

    func getSessionUsage() -> UsageStats {
        return sessionUsage
    }

    func resetSessionUsage() {
        sessionUsage = UsageStats()
    }

    // MARK: - Summarization

    /// Check if conversation needs summarization
    func needsSummarization(_ messages: [AgentMessage], maxTokens: Int) -> Bool {
        let totalTokens = messages.reduce(0) { $0 + estimateTokens(for: $1) }
        // Summarize when we've used 70% of context
        return totalTokens > Int(Double(maxTokens) * 0.7)
    }

    /// Create a summarization prompt for the conversation
    func createSummarizationPrompt(for messages: [AgentMessage]) -> String {
        var conversation = ""
        for message in messages {
            conversation += message.textContent + "\n\n"
        }

        return """
        Please provide a concise summary of the following conversation that captures:
        1. The main task or question
        2. Key decisions made
        3. Important code changes or files mentioned
        4. Current status and any pending items

        Keep the summary under 500 words while retaining critical context.

        Conversation:
        \(conversation)
        """
    }
}

// MARK: - AgentMessage Extension

extension AgentMessage {
    /// Extract text content for token counting
    var textContent: String {
        switch self {
        case .user(let content, _, _):
            return content
        case .assistant(_, let content, _, _):
            return content
        case .thinking(_, let content, _, _):
            return content
        case .toolUse(_, let name, let args, _, _):
            return "\(name): \(args)"
        case .toolResult(_, _, let result, _, _):
            return result.output + (result.error ?? "")
        case .error(_, let message, _, _):
            return message
        case .agentHandoff(_, _, let context, _, _):
            return context
        }
    }
}
