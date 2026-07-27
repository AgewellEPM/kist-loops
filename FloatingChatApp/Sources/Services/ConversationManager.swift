import Foundation
import Combine

/// Manages conversations, memory, and context persistence
@MainActor
final class ConversationManager: ObservableObject {
    static let shared = ConversationManager()

    @Published var conversations: [ChatConversation] = []
    @Published var currentConversationId: UUID?
    @Published var contextMemory: ContextMemory

    private let conversationsKey = "saved_conversations"
    private let memoryKey = "context_memory"

    var currentConversation: ChatConversation? {
        get {
            conversations.first { $0.id == currentConversationId }
        }
        set {
            if let newValue = newValue,
               let index = conversations.firstIndex(where: { $0.id == newValue.id }) {
                conversations[index] = newValue
                saveConversations()
            }
        }
    }

    private init() {
        // Load context memory
        if let data = UserDefaults.standard.data(forKey: memoryKey),
           let memory = try? JSONDecoder().decode(ContextMemory.self, from: data) {
            self.contextMemory = memory
        } else {
            self.contextMemory = ContextMemory()
        }

        // Load conversations
        loadConversations()

        // Create default conversation if none exist
        if conversations.isEmpty {
            createNewConversation()
        } else {
            currentConversationId = conversations.first?.id
        }
    }

    // MARK: - Conversation Management

    func createNewConversation(title: String = "New Chat") -> ChatConversation {
        let conversation = ChatConversation(title: title)
        conversations.insert(conversation, at: 0)
        currentConversationId = conversation.id
        saveConversations()
        return conversation
    }

    func selectConversation(_ conversation: ChatConversation) {
        currentConversationId = conversation.id
    }

    func deleteConversation(_ conversation: ChatConversation) {
        conversations.removeAll { $0.id == conversation.id }

        // If we deleted the current conversation, select another
        if currentConversationId == conversation.id {
            currentConversationId = conversations.first?.id
            if currentConversationId == nil {
                _ = createNewConversation()
            }
        }

        saveConversations()
    }

    func updateConversation(id: UUID, messages: [ChatMessage]) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }

        // Convert ChatMessage to SerializableMessage
        let serializableMessages = messages.map { msg in
            ChatConversation.SerializableMessage(
                id: msg.id,
                role: msg.role,
                content: msg.content,
                timestamp: msg.timestamp,
                imageBase64: msg.imageData?.base64EncodedString()
            )
        }

        conversations[index].messages = serializableMessages
        conversations[index].updatedAt = Date()

        // Auto-generate title from first user message if still default
        if conversations[index].title == "New Chat",
           let firstUserMessage = messages.first(where: { $0.role == .user }) {
            let title = String(firstUserMessage.content.prefix(50))
            conversations[index].title = title.isEmpty ? "New Chat" : title
        }

        // Move to top of list
        let conversation = conversations.remove(at: index)
        conversations.insert(conversation, at: 0)

        saveConversations()

        // Update context memory with new information
        extractAndStoreContext(from: messages)
    }

    func renameConversation(_ conversation: ChatConversation, to newTitle: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index].title = newTitle
        saveConversations()
    }

    // MARK: - Memory Management

    func extractAndStoreContext(from messages: [ChatMessage]) {
        // Extract key information from messages for context memory
        for message in messages where message.role == .user {
            // Store topics discussed
            let words = message.content.lowercased().components(separatedBy: .whitespacesAndNewlines)
            for word in words where word.count > 4 {
                contextMemory.addTopic(word)
            }
        }

        // Store the conversation summary
        if let lastUserMsg = messages.last(where: { $0.role == .user }),
           let lastAssistantMsg = messages.last(where: { $0.role == .assistant }) {
            let snippet = ContextSnippet(
                userQuery: String(lastUserMsg.content.prefix(200)),
                aiResponse: String(lastAssistantMsg.content.prefix(500)),
                timestamp: Date()
            )
            contextMemory.addSnippet(snippet)
        }

        saveMemory()
    }

    func addActiveContext(_ context: ActiveContext) {
        // Remove existing context of same type
        contextMemory.activeContexts.removeAll { $0.type == context.type && $0.identifier == context.identifier }
        contextMemory.activeContexts.append(context)

        // Keep only last 10 active contexts
        if contextMemory.activeContexts.count > 10 {
            contextMemory.activeContexts.removeFirst()
        }

        saveMemory()
    }

    func clearActiveContext(type: ActiveContext.ContextType) {
        contextMemory.activeContexts.removeAll { $0.type == type }
        saveMemory()
    }

    func getContextSummary() -> String {
        var summary = ""

        // Add active contexts
        if !contextMemory.activeContexts.isEmpty {
            summary += "Active Context:\n"
            for context in contextMemory.activeContexts {
                summary += "- \(context.type.rawValue): \(context.name)\n"
            }
            summary += "\n"
        }

        // Add recent topics
        let recentTopics = Array(contextMemory.topics.prefix(10))
        if !recentTopics.isEmpty {
            summary += "Recent Topics: \(recentTopics.joined(separator: ", "))\n"
        }

        return summary
    }

    // MARK: - Persistence

    private func loadConversations() {
        guard let data = UserDefaults.standard.data(forKey: conversationsKey),
              let saved = try? JSONDecoder().decode([ChatConversation].self, from: data) else {
            return
        }
        conversations = saved.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func saveConversations() {
        if let data = try? JSONEncoder().encode(conversations) {
            UserDefaults.standard.set(data, forKey: conversationsKey)
        }
    }

    private func saveMemory() {
        if let data = try? JSONEncoder().encode(contextMemory) {
            UserDefaults.standard.set(data, forKey: memoryKey)
        }
    }

    func clearAllData() {
        conversations.removeAll()
        contextMemory = ContextMemory()
        _ = createNewConversation()
        saveConversations()
        saveMemory()
    }
}

// MARK: - Context Memory Models

struct ContextMemory: Codable {
    var topics: [String] = []
    var snippets: [ContextSnippet] = []
    var activeContexts: [ActiveContext] = []
    var facts: [String: String] = [:]  // Key facts remembered

    mutating func addTopic(_ topic: String) {
        if !topics.contains(topic) {
            topics.insert(topic, at: 0)
            // Keep only last 100 topics
            if topics.count > 100 {
                topics.removeLast()
            }
        }
    }

    mutating func addSnippet(_ snippet: ContextSnippet) {
        snippets.insert(snippet, at: 0)
        // Keep only last 50 snippets
        if snippets.count > 50 {
            snippets.removeLast()
        }
    }

    mutating func addFact(key: String, value: String) {
        facts[key] = value
    }
}

struct ContextSnippet: Codable, Identifiable {
    let id: UUID
    let userQuery: String
    let aiResponse: String
    let timestamp: Date

    init(id: UUID = UUID(), userQuery: String, aiResponse: String, timestamp: Date) {
        self.id = id
        self.userQuery = userQuery
        self.aiResponse = aiResponse
        self.timestamp = timestamp
    }
}

struct ActiveContext: Codable, Identifiable, Equatable {
    let id: UUID
    let type: ContextType
    let name: String
    let identifier: String  // Bundle ID, file path, etc.
    let metadata: [String: String]
    let capturedAt: Date
    var screenData: Data?  // Screenshot if available

    enum ContextType: String, Codable {
        case application = "App"
        case document = "Document"
        case file = "File"
        case website = "Website"
        case folder = "Folder"
        case custom = "Custom"
    }

    init(
        id: UUID = UUID(),
        type: ContextType,
        name: String,
        identifier: String,
        metadata: [String: String] = [:],
        screenData: Data? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.identifier = identifier
        self.metadata = metadata
        self.capturedAt = Date()
        self.screenData = screenData
    }

    static func == (lhs: ActiveContext, rhs: ActiveContext) -> Bool {
        lhs.id == rhs.id
    }
}
