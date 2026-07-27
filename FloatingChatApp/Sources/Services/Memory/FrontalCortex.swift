import Foundation
import Combine

/// Frontal Cortex Memory System
/// Manages short-term and long-term memories with time-based decay
/// Implements working memory with cognitive limits and memory consolidation
@MainActor
final class FrontalCortex: ObservableObject {
    static let shared = FrontalCortex()

    // MARK: - Published State

    @Published var memories: [CortexMemory] = []
    @Published var workingMemory = WorkingMemory()
    @Published var consolidations: [MemoryConsolidation] = []
    @Published var stats = FrontalCortexStats()
    @Published var config = MemoryConfig.default

    // MARK: - Private State

    private var saveTask: Task<Void, Never>?
    private var decayTimer: Timer?
    private let storageURL: URL

    // MARK: - Initialization

    private init() {
        // Setup storage directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let memoryDir = appSupport.appendingPathComponent("FloatingChatApp/Memory", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)

        self.storageURL = memoryDir

        // Load saved state
        loadMemories()
        loadWorkingMemory()
        loadConsolidations()
        loadConfig()

        // Start decay timer
        startDecayTimer()

        // Update stats
        updateStats()
    }

    deinit {
        decayTimer?.invalidate()
    }

    // MARK: - Memory Storage

    /// Store a new memory
    @discardableResult
    func store(
        content: String,
        category: MemoryCategory,
        importance: Double = 0.5,
        tags: [String] = [],
        entities: [String] = [],
        sessionId: UUID? = nil
    ) -> CortexMemory {
        let memory = CortexMemory(
            content: content,
            category: category,
            importance: importance,
            tags: tags,
            entities: entities,
            sessionId: sessionId,
            memoryType: .shortTerm
        )

        memories.append(memory)

        // Enforce capacity limits
        enforceCapacityLimits()

        // Schedule save
        scheduleSave()

        // Update stats
        updateStats()

        return memory
    }

    /// Store multiple memories at once
    func storeMultiple(_ items: [(content: String, category: MemoryCategory, importance: Double)]) {
        for item in items {
            store(content: item.content, category: item.category, importance: item.importance)
        }
    }

    // MARK: - Memory Retrieval

    /// Retrieve memories relevant to a query
    func retrieve(
        query: String,
        category: MemoryCategory? = nil,
        limit: Int = 10,
        minImportance: Double = 0.1
    ) -> [CortexMemory] {
        let queryWords = query.lowercased().components(separatedBy: .whitespaces)

        var results = memories
            .filter { memory in
                // Filter by category if specified
                if let cat = category, memory.category != cat { return false }

                // Filter by minimum importance (with decay)
                if memory.currentImportance(halfLifeHours: config.decayHalfLifeHours) < minImportance {
                    return false
                }

                return true
            }
            .map { memory -> (memory: CortexMemory, score: Double) in
                // Calculate relevance score
                let contentWords = memory.content.lowercased().components(separatedBy: .whitespaces)
                let tagMatches = memory.tags.filter { tag in
                    queryWords.contains { $0.contains(tag.lowercased()) || tag.lowercased().contains($0) }
                }.count

                var score = 0.0

                // Content matches
                for word in queryWords where word.count > 2 {
                    if contentWords.contains(where: { $0.contains(word) }) {
                        score += 1.0
                    }
                }

                // Tag matches (weighted higher)
                score += Double(tagMatches) * 2.0

                // Boost by importance
                score *= memory.currentImportance(halfLifeHours: config.decayHalfLifeHours)

                // Boost by recency
                let daysSinceAccess = memory.hoursSinceAccess / 24
                let recencyBoost = max(0.5, 1.0 - (daysSinceAccess / 30))
                score *= recencyBoost

                return (memory, score)
            }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0.memory }

        // Mark retrieved memories as accessed
        for memory in results {
            access(memoryId: memory.id)
        }

        return results
    }

    /// Search memories with complex query
    func search(_ query: MemoryQuery) -> [MemorySearchResult] {
        var results: [MemorySearchResult] = []

        for memory in memories {
            var matchedFields: [String] = []
            var score = 0.0

            // Category filter
            if let categories = query.categories, !categories.contains(memory.category) {
                continue
            }

            // Memory type filter
            if let memType = query.memoryType, memory.memoryType != memType {
                continue
            }

            // Session filter
            if let sessionId = query.sessionId, memory.sourceSessionId != sessionId {
                continue
            }

            // Date range filter
            if let range = query.dateRange {
                if !range.contains(memory.createdAt) {
                    continue
                }
            }

            // Minimum importance filter
            if let minImp = query.minImportance {
                if memory.currentImportance(halfLifeHours: config.decayHalfLifeHours) < minImp {
                    continue
                }
            }

            // Text search
            if let text = query.textSearch?.lowercased(), !text.isEmpty {
                if memory.content.lowercased().contains(text) {
                    matchedFields.append("content")
                    score += 2.0
                }
            }

            // Tag matches
            if let tags = query.tags {
                let matched = memory.tags.filter { tags.contains($0) }
                if !matched.isEmpty {
                    matchedFields.append("tags")
                    score += Double(matched.count)
                }
            }

            // Entity matches
            if let entities = query.entities {
                let matched = memory.associatedEntities.filter { entities.contains($0) }
                if !matched.isEmpty {
                    matchedFields.append("entities")
                    score += Double(matched.count) * 1.5
                }
            }

            // Must have matched something
            if score > 0 || matchedFields.isEmpty && query.textSearch == nil {
                // Boost by importance
                score *= memory.currentImportance(halfLifeHours: config.decayHalfLifeHours)
                results.append(MemorySearchResult(memory: memory, relevanceScore: score, matchedFields: matchedFields))
            }
        }

        return results
            .sorted { $0.relevanceScore > $1.relevanceScore }
            .prefix(query.limit)
            .map { $0 }
    }

    /// Get memories for a specific session
    func getMemories(forSession sessionId: UUID) -> [CortexMemory] {
        return memories.filter { $0.sourceSessionId == sessionId }
    }

    /// Get memories by category
    func getMemories(category: MemoryCategory) -> [CortexMemory] {
        return memories.filter { $0.category == category }
    }

    // MARK: - Memory Access & Reinforcement

    /// Mark memory as accessed (updates lastAccessedAt and accessCount)
    func access(memoryId: UUID) {
        guard let index = memories.firstIndex(where: { $0.id == memoryId }) else { return }

        memories[index].lastAccessedAt = Date()
        memories[index].accessCount += 1

        scheduleSave()
    }

    /// Reinforce a memory (boost its importance)
    func reinforce(memoryId: UUID, boost: Double = 0.1) {
        guard let index = memories.firstIndex(where: { $0.id == memoryId }) else { return }

        memories[index].importance = min(1.0, memories[index].importance + boost)
        memories[index].lastAccessedAt = Date()
        memories[index].accessCount += 1

        // Promote to long-term if importance is high enough
        if memories[index].importance >= 0.7 && memories[index].memoryType == .shortTerm {
            memories[index].memoryType = .longTerm
        }

        scheduleSave()
        updateStats()
    }

    /// Forget a specific memory
    func forget(memoryId: UUID) {
        memories.removeAll { $0.id == memoryId }
        scheduleSave()
        updateStats()
    }

    // MARK: - Working Memory

    /// Set current task focus
    func setFocus(goal: String, taskId: UUID? = nil) {
        workingMemory.currentGoal = goal
        workingMemory.currentTaskId = taskId
        workingMemory.lastUpdated = Date()
        scheduleSave()
    }

    /// Add item to attention (enforces cognitive limit of 7)
    func addToAttention(_ content: String, priority: Int = 1) {
        workingMemory.addAttentionItem(content, priority: priority)
        scheduleSave()
    }

    /// Store temporary task state
    func setTemporary(key: String, value: String) {
        workingMemory.taskState[key] = value
        workingMemory.lastUpdated = Date()
        scheduleSave()
    }

    /// Get temporary task state
    func getTemporary(key: String) -> String? {
        return workingMemory.taskState[key]
    }

    /// Clear working memory
    func clearWorkingMemory() {
        workingMemory.clear()
        scheduleSave()
    }

    /// Link memories to current working context
    func linkToWorkingMemory(memoryIds: [UUID]) {
        workingMemory.activeMemoryIds = memoryIds
        workingMemory.lastUpdated = Date()
        scheduleSave()
    }

    // MARK: - Decay System

    private func startDecayTimer() {
        // Run decay every hour
        decayTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runDecayCycle()
            }
        }
    }

    /// Run decay cycle - reduce importance of old memories
    func runDecayCycle() {
        var decayedCount = 0
        let threshold = config.importanceThreshold

        for i in memories.indices {
            let currentImp = memories[i].currentImportance(halfLifeHours: config.decayHalfLifeHours)

            // Mark as decayed if below threshold
            if currentImp < threshold && memories[i].decayedAt == nil {
                memories[i].decayedAt = Date()
                decayedCount += 1
            }
        }

        // Remove very old decayed memories (older than 30 days since decay)
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 3600)
        memories.removeAll { memory in
            if let decayedAt = memory.decayedAt, decayedAt < thirtyDaysAgo {
                return true
            }
            return false
        }

        if decayedCount > 0 {
            scheduleSave()
            updateStats()
        }

        // Trigger auto-consolidation if needed
        Task {
            await autoConsolidate()
        }
    }

    // MARK: - Consolidation

    /// Consolidate similar old memories into a summary
    func consolidate(memoryIds: [UUID], summary: String) -> MemoryConsolidation {
        let memoriesToConsolidate = memories.filter { memoryIds.contains($0.id) }

        // Determine category from most common
        let categories = memoriesToConsolidate.map { $0.category }
        let categoryCount = Dictionary(grouping: categories, by: { $0 }).mapValues { $0.count }
        let primaryCategory = categoryCount.max { $0.value < $1.value }?.key ?? .consolidated

        let consolidation = MemoryConsolidation(
            sourceMemoryIds: memoryIds,
            consolidatedContent: summary,
            category: primaryCategory
        )

        consolidations.append(consolidation)

        // Create consolidated memory
        let averageImportance = memoriesToConsolidate.map { $0.importance }.reduce(0, +) / Double(max(1, memoriesToConsolidate.count))
        let allTags = Array(Set(memoriesToConsolidate.flatMap { $0.tags }))

        store(
            content: summary,
            category: .consolidated,
            importance: averageImportance,
            tags: allTags
        )

        // Remove original memories
        memories.removeAll { memoryIds.contains($0.id) }

        scheduleSave()
        updateStats()

        return consolidation
    }

    /// Auto-consolidate old memories of similar categories
    func autoConsolidate() async {
        // Find memories eligible for consolidation
        let eligibleMemories = memories.filter { memory in
            memory.memoryType == .shortTerm &&
            memory.ageInHours > 24 * 7 && // Older than 1 week
            memory.currentImportance(halfLifeHours: config.decayHalfLifeHours) < 0.3
        }

        // Group by category
        let grouped = Dictionary(grouping: eligibleMemories, by: { $0.category })

        for (category, categoryMemories) in grouped {
            if categoryMemories.count >= config.consolidationThreshold {
                // Create summary (simple concatenation for now)
                let contents = categoryMemories.prefix(20).map { "- \($0.content)" }.joined(separator: "\n")
                let summary = "[\(category.rawValue.capitalized)] Consolidated \(categoryMemories.count) memories:\n\(contents)"

                let ids = categoryMemories.map { $0.id }
                _ = consolidate(memoryIds: ids, summary: summary)
            }
        }
    }

    // MARK: - Statistics

    private func updateStats() {
        let shortTerm = memories.filter { $0.memoryType == .shortTerm }.count
        let longTerm = memories.filter { $0.memoryType == .longTerm }.count
        let consolidated = memories.filter { $0.memoryType == .consolidated }.count

        let totalImportance = memories.map { $0.currentImportance(halfLifeHours: config.decayHalfLifeHours) }.reduce(0, +)
        let avgImportance = memories.isEmpty ? 0 : totalImportance / Double(memories.count)

        let totalAccess = memories.map { $0.accessCount }.reduce(0, +)

        let yesterday = Date().addingTimeInterval(-24 * 3600)
        let decayedLast24h = memories.filter { ($0.decayedAt ?? .distantFuture) > yesterday }.count

        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        let consolidationsLastWeek = consolidations.filter { $0.createdAt > weekAgo }.count

        stats = FrontalCortexStats(
            totalMemories: memories.count,
            shortTermCount: shortTerm,
            longTermCount: longTerm,
            consolidatedCount: consolidated,
            averageImportance: avgImportance,
            totalAccessCount: totalAccess,
            memoriesDecayedLast24h: decayedLast24h,
            consolidationsLast7Days: consolidationsLastWeek
        )

        stats.oldestMemoryDate = memories.min(by: { $0.createdAt < $1.createdAt })?.createdAt
        stats.mostAccessedMemoryId = memories.max(by: { $0.accessCount < $1.accessCount })?.id
    }

    /// Get current stats
    func getStats() -> FrontalCortexStats {
        updateStats()
        return stats
    }

    // MARK: - Capacity Management

    private func enforceCapacityLimits() {
        let shortTermMemories = memories.filter { $0.memoryType == .shortTerm }
        let longTermMemories = memories.filter { $0.memoryType == .longTerm }

        // Remove excess short-term memories (lowest importance first)
        if shortTermMemories.count > config.shortTermCapacity {
            let sorted = shortTermMemories.sorted {
                $0.currentImportance(halfLifeHours: config.decayHalfLifeHours) <
                $1.currentImportance(halfLifeHours: config.decayHalfLifeHours)
            }
            let toRemove = sorted.prefix(shortTermMemories.count - config.shortTermCapacity)
            memories.removeAll { memory in toRemove.contains { $0.id == memory.id } }
        }

        // Remove excess long-term memories
        if longTermMemories.count > config.longTermCapacity {
            let sorted = longTermMemories.sorted {
                $0.currentImportance(halfLifeHours: config.decayHalfLifeHours) <
                $1.currentImportance(halfLifeHours: config.decayHalfLifeHours)
            }
            let toRemove = sorted.prefix(longTermMemories.count - config.longTermCapacity)
            memories.removeAll { memory in toRemove.contains { $0.id == memory.id } }
        }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(config.autoSaveIntervalSeconds * 1_000_000_000))
            if !Task.isCancelled {
                await save()
            }
        }
    }

    func save() async {
        saveMemories()
        saveWorkingMemory()
        saveConsolidations()
        saveConfig()
    }

    private func saveMemories() {
        let url = storageURL.appendingPathComponent("cortex_memories.json")
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(memories)
            try data.write(to: url)
        } catch {
            print("Failed to save memories: \(error)")
        }
    }

    private func loadMemories() {
        let url = storageURL.appendingPathComponent("cortex_memories.json")
        guard let data = try? Data(contentsOf: url) else { return }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            memories = try decoder.decode([CortexMemory].self, from: data)
        } catch {
            print("Failed to load memories: \(error)")
        }
    }

    private func saveWorkingMemory() {
        let url = storageURL.appendingPathComponent("working_memory.json")
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(workingMemory)
            try data.write(to: url)
        } catch {
            print("Failed to save working memory: \(error)")
        }
    }

    private func loadWorkingMemory() {
        let url = storageURL.appendingPathComponent("working_memory.json")
        guard let data = try? Data(contentsOf: url) else { return }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            workingMemory = try decoder.decode(WorkingMemory.self, from: data)
        } catch {
            print("Failed to load working memory: \(error)")
        }
    }

    private func saveConsolidations() {
        let url = storageURL.appendingPathComponent("consolidations.json")
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(consolidations)
            try data.write(to: url)
        } catch {
            print("Failed to save consolidations: \(error)")
        }
    }

    private func loadConsolidations() {
        let url = storageURL.appendingPathComponent("consolidations.json")
        guard let data = try? Data(contentsOf: url) else { return }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            consolidations = try decoder.decode([MemoryConsolidation].self, from: data)
        } catch {
            print("Failed to load consolidations: \(error)")
        }
    }

    private func saveConfig() {
        let url = storageURL.appendingPathComponent("memory_config.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(config)
            try data.write(to: url)
        } catch {
            print("Failed to save config: \(error)")
        }
    }

    private func loadConfig() {
        let url = storageURL.appendingPathComponent("memory_config.json")
        guard let data = try? Data(contentsOf: url) else { return }

        do {
            config = try JSONDecoder().decode(MemoryConfig.self, from: data)
        } catch {
            print("Failed to load config: \(error)")
        }
    }
}

// MARK: - Context Building Extension

extension FrontalCortex {
    /// Build context string from relevant memories for injection into agent prompts
    func buildContextForPrompt(query: String, maxMemories: Int = 5) -> String {
        let relevantMemories = retrieve(query: query, limit: maxMemories, minImportance: 0.1)

        if relevantMemories.isEmpty {
            return ""
        }

        var context = "RELEVANT MEMORIES FROM PAST SESSIONS:\n"
        for memory in relevantMemories {
            let importance = String(format: "%.1f", memory.currentImportance(halfLifeHours: config.decayHalfLifeHours))
            context += "- [\(memory.category.rawValue), importance: \(importance)] \(memory.content)\n"
        }

        return context
    }
}
