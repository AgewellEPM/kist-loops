import Foundation

/// Persistent storage for conversation sessions
/// Saves to Application Support directory
final class ConversationStore {
    static let shared = ConversationStore()

    private let storeURL: URL
    private let fileManager = FileManager.default

    private init() {
        // Get Application Support directory
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storeURL = appSupport.appendingPathComponent("FloatingChatApp/conversations", isDirectory: true)

        // Create directory if needed
        try? fileManager.createDirectory(at: storeURL, withIntermediateDirectories: true)
    }

    // MARK: - Session Operations

    /// Save a conversation session
    func save(_ session: SavedSession) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(session)
        let url = storeURL.appendingPathComponent("\(session.id).json")
        try data.write(to: url)
    }

    /// Load a conversation session by ID
    func load(id: String) throws -> SavedSession {
        let url = storeURL.appendingPathComponent("\(id).json")
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SavedSession.self, from: data)
    }

    /// Delete a conversation session
    func delete(id: String) throws {
        let url = storeURL.appendingPathComponent("\(id).json")
        try fileManager.removeItem(at: url)
    }

    /// List all saved sessions
    func listAll() -> [SessionSummary] {
        guard let files = try? fileManager.contentsOfDirectory(atPath: storeURL.path) else {
            return []
        }

        return files
            .filter { $0.hasSuffix(".json") }
            .compactMap { filename -> SessionSummary? in
                let id = filename.replacingOccurrences(of: ".json", with: "")
                guard let session = try? load(id: id) else { return nil }

                return SessionSummary(
                    id: session.id,
                    title: session.title,
                    createdAt: session.createdAt,
                    updatedAt: session.updatedAt,
                    messageCount: session.messages.count,
                    projectPath: session.projectPath
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }  // Most recent first
    }

    /// Search sessions by title or content
    func search(query: String) -> [SessionSummary] {
        let queryLower = query.lowercased()

        return listAll().filter { summary in
            summary.title.lowercased().contains(queryLower)
        }
    }

    /// Get most recent session for a project
    func mostRecent(for projectPath: String) -> SavedSession? {
        let summaries = listAll().filter { $0.projectPath == projectPath }
        guard let mostRecent = summaries.first else { return nil }
        return try? load(id: mostRecent.id)
    }

    // MARK: - Quick Save/Load

    /// Auto-save the current engine state
    /// Must be called from MainActor context
    @MainActor
    func autoSave(engine: AgentLoopEngine, title: String? = nil) {
        let sessionId = engine.currentSession?.id ?? UUID().uuidString
        let conversationHistory = engine.conversationHistory
        let projectPath = engine.currentSession?.projectPath ?? ""
        let createdAt = engine.currentSession?.createdAt ?? Date()
        let agents = engine.currentSession?.agents ?? []

        let session = SavedSession(
            id: sessionId,
            title: title ?? generateTitle(from: conversationHistory),
            projectPath: projectPath,
            createdAt: createdAt,
            updatedAt: Date(),
            messages: conversationHistory,
            agents: agents
        )

        try? save(session)
    }

    /// Restore engine state from a saved session
    @MainActor
    func restore(sessionId: String, into engine: AgentLoopEngine) throws {
        let session = try load(id: sessionId)

        engine.setup(
            projectPath: session.projectPath,
            agents: session.agents
        )

        // Restore conversation history
        for message in session.messages {
            engine.conversationHistory.append(message)
        }
    }

    // MARK: - Helpers

    private func generateTitle(from messages: [AgentMessage]) -> String {
        // Use first user message as title
        for message in messages {
            if case .user(let content, _, _) = message {
                let title = content.prefix(50)
                return title.count < content.count ? "\(title)..." : String(title)
            }
        }
        return "Untitled Conversation"
    }
}

// MARK: - Data Models

/// A saved conversation session
struct SavedSession: Codable, Identifiable {
    let id: String
    var title: String
    let projectPath: String
    let createdAt: Date
    var updatedAt: Date
    var messages: [AgentMessage]
    var agents: [AgentConfig]
}

/// Summary info for listing sessions
struct SessionSummary: Identifiable {
    let id: String
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let messageCount: Int
    let projectPath: String

    var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: updatedAt, relativeTo: Date())
    }
}
