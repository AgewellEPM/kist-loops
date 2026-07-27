import Foundation

// MARK: - Model Info

struct AIModel: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let displayName: String
    var isVision: Bool = false
    var isLocal: Bool = false
    var size: String? = nil

    init(id: String, name: String, displayName: String? = nil, isVision: Bool = false, isLocal: Bool = false, size: String? = nil) {
        self.id = id
        self.name = name
        self.displayName = displayName ?? name
        self.isVision = isVision
        self.isLocal = isLocal
        self.size = size
    }
}

// MARK: - AI Provider Protocol

protocol AIProvider: Identifiable, Hashable {
    var id: String { get }
    var name: String { get }
    var iconName: String { get }
    var supportsStreaming: Bool { get }
    var supportsVision: Bool { get }
    var requiresAPIKey: Bool { get }
    var apiKeySettingKey: String { get }
    var isLocal: Bool { get }

    // Model management
    var availableModels: [AIModel] { get }
    var selectedModel: AIModel? { get set }

    // Fetch available models from server
    func refreshModels() async -> [AIModel]

    // Check if provider is available/running
    func checkStatus() async -> Bool

    // Send message with settings
    func sendMessage(
        messages: [ChatMessage],
        settings: ModelSettings,
        stream: Bool
    ) async throws -> AsyncThrowingStream<String, Error>

    func validateAPIKey(_ key: String) async -> Bool
}

// Default implementations
extension AIProvider {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    var supportsVision: Bool { false }
    var isLocal: Bool { false }

    func checkStatus() async -> Bool { true }

    func refreshModels() async -> [AIModel] {
        return availableModels
    }

    // Default implementation that ignores settings (for backwards compatibility)
    func sendMessage(
        messages: [ChatMessage],
        stream: Bool
    ) async throws -> AsyncThrowingStream<String, Error> {
        try await sendMessage(messages: messages, settings: .default, stream: stream)
    }
}

// MARK: - Provider Errors

enum AIProviderError: LocalizedError {
    case invalidAPIKey
    case networkError(underlying: Error)
    case rateLimited
    case invalidResponse
    case modelNotAvailable
    case contextTooLong
    case serverNotRunning
    case configurationError(String)
    case unknown(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Invalid API key. Please check your settings."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .rateLimited:
            return "Rate limited. Please wait and try again."
        case .invalidResponse:
            return "Invalid response from AI provider."
        case .modelNotAvailable:
            return "Selected model is not available."
        case .contextTooLong:
            return "Conversation too long. Please start a new chat."
        case .serverNotRunning:
            return "Local server is not running. Please start it first."
        case .configurationError(let message):
            return "Configuration error: \(message)"
        case .unknown(let message):
            return message
        }
    }

    /// Whether this error is transient and can be retried
    var isRetryable: Bool {
        switch self {
        case .networkError, .rateLimited:
            return true
        default:
            return false
        }
    }
}

// MARK: - Retry Helper

/// Executes an async operation with retry logic for transient failures
func withRetry<T>(
    maxAttempts: Int = 3,
    initialDelay: TimeInterval = 1.0,
    operation: () async throws -> T
) async throws -> T {
    var lastError: Error?
    var delay = initialDelay

    for attempt in 1...maxAttempts {
        do {
            return try await operation()
        } catch let error as AIProviderError where error.isRetryable {
            lastError = error
            if attempt < maxAttempts {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay *= 2 // Exponential backoff
            }
        } catch {
            throw error // Non-retryable errors propagate immediately
        }
    }

    throw lastError ?? AIProviderError.unknown(message: "Max retry attempts reached")
}

// MARK: - Message Format for API

struct APIMessage: Codable {
    let role: String
    let content: String

    init(from message: ChatMessage) {
        self.role = message.role.rawValue
        self.content = message.content
    }
}

struct APIMessageWithImage: Codable {
    let role: String
    let content: [ContentPart]

    struct ContentPart: Codable {
        let type: String
        let text: String?
        let image_url: ImageURL?

        struct ImageURL: Codable {
            let url: String
        }
    }

    init(from message: ChatMessage) {
        self.role = message.role.rawValue
        var parts: [ContentPart] = []

        if !message.content.isEmpty {
            parts.append(ContentPart(type: "text", text: message.content, image_url: nil))
        }

        if let imageData = message.imageData {
            let base64 = imageData.base64EncodedString()
            let mimeType = message.imageMimeType ?? "image/jpeg"
            let dataUrl = "data:\(mimeType);base64,\(base64)"
            parts.append(ContentPart(type: "image_url", text: nil, image_url: .init(url: dataUrl)))
        }

        self.content = parts
    }
}
