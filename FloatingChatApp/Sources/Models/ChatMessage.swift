import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: Role
    var content: String
    let timestamp: Date
    var isStreaming: Bool

    // Image support for vision models
    var imageData: Data?
    var imageMimeType: String?

    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        imageData: Data? = nil,
        imageMimeType: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.imageData = imageData
        self.imageMimeType = imageMimeType
    }

    var hasImage: Bool {
        imageData != nil
    }

    static func user(_ content: String, imageData: Data? = nil, imageMimeType: String? = nil) -> ChatMessage {
        ChatMessage(role: .user, content: content, imageData: imageData, imageMimeType: imageMimeType)
    }

    static func assistant(_ content: String, isStreaming: Bool = false) -> ChatMessage {
        ChatMessage(role: .assistant, content: content, isStreaming: isStreaming)
    }

    static func system(_ content: String) -> ChatMessage {
        ChatMessage(role: .system, content: content)
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id &&
        lhs.role == rhs.role &&
        lhs.content == rhs.content &&
        lhs.isStreaming == rhs.isStreaming &&
        lhs.imageData == rhs.imageData
    }
}

// MARK: - Chat Conversation

struct ChatConversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [SerializableMessage]
    let createdAt: Date
    var updatedAt: Date
    var modelSettings: ModelSettings?

    struct SerializableMessage: Codable {
        let id: UUID
        let role: ChatMessage.Role
        let content: String
        let timestamp: Date
        let imageBase64: String?
    }

    init(id: UUID = UUID(), title: String = "New Chat", modelSettings: ModelSettings? = nil) {
        self.id = id
        self.title = title
        self.messages = []
        self.createdAt = Date()
        self.updatedAt = Date()
        self.modelSettings = modelSettings
    }
}
