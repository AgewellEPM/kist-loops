import Foundation

// MARK: - Memory Categories

/// Categories for cortex memories
enum MemoryCategory: String, Codable, CaseIterable {
    case task = "task"                  // Current task focus
    case learning = "learning"          // Learned patterns
    case decision = "decision"          // Decisions made
    case error = "error"                // Mistakes to avoid
    case preference = "preference"      // User preferences
    case contextual = "contextual"      // Session context
    case consolidated = "consolidated"  // Compressed summaries
}

/// Types of memory storage
enum MemoryType: String, Codable {
    case shortTerm      // Current session, high priority
    case longTerm       // Persisted across sessions
    case consolidated   // Compressed from multiple memories
}

// MARK: - Cortex Memory

/// A memory item in the frontal cortex system
struct CortexMemory: Identifiable, Codable {
    let id: UUID
    var content: String
    var category: MemoryCategory
    var importance: Double              // 0.0 - 1.0
    var accessCount: Int
    var createdAt: Date
    var lastAccessedAt: Date
    var decayedAt: Date?                // When importance fell below threshold
    var tags: [String]
    var associatedEntities: [String]    // File names, function names, etc.
    var sourceSessionId: UUID?
    var memoryType: MemoryType

    init(
        id: UUID = UUID(),
        content: String,
        category: MemoryCategory,
        importance: Double = 0.5,
        tags: [String] = [],
        entities: [String] = [],
        sessionId: UUID? = nil,
        memoryType: MemoryType = .shortTerm
    ) {
        self.id = id
        self.content = content
        self.category = category
        self.importance = min(1.0, max(0.0, importance))
        self.accessCount = 0
        self.createdAt = Date()
        self.lastAccessedAt = Date()
        self.decayedAt = nil
        self.tags = tags
        self.associatedEntities = entities
        self.sourceSessionId = sessionId
        self.memoryType = memoryType
    }

    /// Calculate current importance with time decay
    /// Uses exponential decay with configurable half-life
    func currentImportance(halfLifeHours: Double = 168) -> Double {
        let hoursSinceAccess = Date().timeIntervalSince(lastAccessedAt) / 3600
        let decayFactor = pow(0.5, hoursSinceAccess / halfLifeHours)
        return importance * decayFactor
    }

    /// Check if this memory should be considered "active" (above threshold)
    func isActive(threshold: Double = 0.1, halfLifeHours: Double = 168) -> Bool {
        return currentImportance(halfLifeHours: halfLifeHours) >= threshold
    }

    /// Get age in hours
    var ageInHours: Double {
        Date().timeIntervalSince(createdAt) / 3600
    }

    /// Get time since last access in hours
    var hoursSinceAccess: Double {
        Date().timeIntervalSince(lastAccessedAt) / 3600
    }
}

// MARK: - Working Memory

/// Working memory for current task focus
/// Implements cognitive limit of ~7 items
struct WorkingMemory: Codable {
    static let maxAttentionItems = 7

    var currentTaskId: UUID?
    var currentGoal: String
    var attentionItems: [AttentionItem]     // Max 7 items (cognitive limit)
    var taskState: [String: String]         // Key-value for task state
    var activeMemoryIds: [UUID]             // Currently relevant memories
    var lastUpdated: Date

    struct AttentionItem: Codable, Identifiable {
        let id: UUID
        var content: String
        var priority: Int
        var addedAt: Date

        init(content: String, priority: Int = 1) {
            self.id = UUID()
            self.content = content
            self.priority = priority
            self.addedAt = Date()
        }
    }

    init() {
        self.currentTaskId = nil
        self.currentGoal = ""
        self.attentionItems = []
        self.taskState = [:]
        self.activeMemoryIds = []
        self.lastUpdated = Date()
    }

    /// Add item to attention, enforcing cognitive limit
    mutating func addAttentionItem(_ content: String, priority: Int = 1) {
        let item = AttentionItem(content: content, priority: priority)

        // If at capacity, remove lowest priority or oldest item
        if attentionItems.count >= Self.maxAttentionItems {
            attentionItems.sort { $0.priority > $1.priority }
            attentionItems.removeLast()
        }

        attentionItems.append(item)
        lastUpdated = Date()
    }

    /// Clear all working memory
    mutating func clear() {
        currentTaskId = nil
        currentGoal = ""
        attentionItems = []
        taskState = [:]
        activeMemoryIds = []
        lastUpdated = Date()
    }
}

// MARK: - Memory Consolidation

/// Record of consolidated memories
struct MemoryConsolidation: Identifiable, Codable {
    let id: UUID
    let sourceMemoryIds: [UUID]
    let consolidatedContent: String
    let originalCount: Int
    let compressionRatio: Double
    let createdAt: Date
    var category: MemoryCategory

    init(
        sourceMemoryIds: [UUID],
        consolidatedContent: String,
        category: MemoryCategory
    ) {
        self.id = UUID()
        self.sourceMemoryIds = sourceMemoryIds
        self.consolidatedContent = consolidatedContent
        self.originalCount = sourceMemoryIds.count
        self.compressionRatio = sourceMemoryIds.isEmpty ? 1.0 : 1.0 / Double(sourceMemoryIds.count)
        self.createdAt = Date()
        self.category = category
    }
}

// MARK: - Memory Configuration

/// Configuration for memory system behavior
struct MemoryConfig: Codable {
    var shortTermCapacity: Int = 100
    var longTermCapacity: Int = 2000
    var decayHalfLifeHours: Double = 168    // 1 week
    var importanceThreshold: Double = 0.1   // Below = eligible for decay
    var consolidationThreshold: Int = 10    // Trigger consolidation
    var autoSaveIntervalSeconds: Double = 30
    var maxMemorySizeMB: Int = 50

    static let `default` = MemoryConfig()
}

// MARK: - Memory Statistics

/// Statistics for the frontal cortex system
struct FrontalCortexStats: Codable {
    var totalMemories: Int
    var shortTermCount: Int
    var longTermCount: Int
    var consolidatedCount: Int
    var averageImportance: Double
    var totalAccessCount: Int
    var memoriesDecayedLast24h: Int
    var consolidationsLast7Days: Int
    var oldestMemoryDate: Date?
    var mostAccessedMemoryId: UUID?

    init(
        totalMemories: Int = 0,
        shortTermCount: Int = 0,
        longTermCount: Int = 0,
        consolidatedCount: Int = 0,
        averageImportance: Double = 0,
        totalAccessCount: Int = 0,
        memoriesDecayedLast24h: Int = 0,
        consolidationsLast7Days: Int = 0
    ) {
        self.totalMemories = totalMemories
        self.shortTermCount = shortTermCount
        self.longTermCount = longTermCount
        self.consolidatedCount = consolidatedCount
        self.averageImportance = averageImportance
        self.totalAccessCount = totalAccessCount
        self.memoriesDecayedLast24h = memoriesDecayedLast24h
        self.consolidationsLast7Days = consolidationsLast7Days
    }
}

// MARK: - Memory Search

/// Query for searching memories
struct MemoryQuery {
    var textSearch: String?
    var categories: [MemoryCategory]?
    var tags: [String]?
    var entities: [String]?
    var minImportance: Double?
    var dateRange: ClosedRange<Date>?
    var memoryType: MemoryType?
    var sessionId: UUID?
    var limit: Int = 20

    init() {}
}

/// Result from memory search with relevance scoring
struct MemorySearchResult: Identifiable {
    let id: UUID
    let memory: CortexMemory
    let relevanceScore: Double
    let matchedFields: [String]

    init(memory: CortexMemory, relevanceScore: Double, matchedFields: [String]) {
        self.id = memory.id
        self.memory = memory
        self.relevanceScore = relevanceScore
        self.matchedFields = matchedFields
    }
}
