import Foundation
import Combine

/// Engine for generating and managing agent reflections
/// Integrates with FrontalCortex for memory storage
@MainActor
final class AgentReflectionEngine: ObservableObject {
    static let shared = AgentReflectionEngine()

    // MARK: - Published State

    @Published var reflections: [AgentReflection] = []
    @Published var aggregatedLearnings: [AggregatedLearning] = []
    @Published var isReflecting = false

    // MARK: - Private State

    private var saveTask: Task<Void, Never>?
    private let storageURL: URL

    // MARK: - Initialization

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let reflectionDir = appSupport.appendingPathComponent("FloatingChatApp/Reflections", isDirectory: true)

        try? FileManager.default.createDirectory(at: reflectionDir, withIntermediateDirectories: true)

        self.storageURL = reflectionDir

        loadReflections()
        loadAggregatedLearnings()
    }

    // MARK: - Reflection Generation

    /// Generate reflection at end of session
    func generateReflection(
        sessionId: UUID,
        agentId: String,
        agentName: String,
        conversationHistory: [AgentMessage]
    ) async -> AgentReflection {
        isReflecting = true
        defer { isReflecting = false }

        // Build context from conversation
        let context = buildContextFromHistory(conversationHistory)

        // Create reflection (in real implementation, would call LLM)
        // For now, generate a basic reflection from the conversation
        let reflection = createReflectionFromContext(
            sessionId: sessionId,
            agentId: agentId,
            agentName: agentName,
            context: context,
            history: conversationHistory
        )

        // Store the reflection
        reflections.append(reflection)

        // Feed to frontal cortex
        feedToFrontalCortex(reflection)

        // Update aggregated learnings
        updateAggregatedLearnings(from: reflection)

        // Save
        scheduleSave()

        return reflection
    }

    /// Quick reflection after task completion
    func reflectOnTask(
        taskDescription: String,
        outcome: String,
        agentId: String,
        success: Bool
    ) -> AgentReflection.Lesson? {
        guard success else { return nil }

        let lesson = AgentReflection.Lesson(
            what: "Successfully completed: \(taskDescription)",
            why: "This approach worked well",
            when: "When facing similar tasks",
            applicability: 0.6
        )

        // Store as quick memory
        FrontalCortex.shared.store(
            content: "Task success: \(taskDescription) -> \(outcome)",
            category: .learning,
            importance: 0.6,
            tags: ["task-completion", "success"]
        )

        return lesson
    }

    /// Reflect on error recovery
    func reflectOnError(
        error: String,
        recovery: String,
        agentId: String
    ) -> AgentReflection.Lesson {
        let lesson = AgentReflection.Lesson(
            what: "Error '\(error)' was resolved by: \(recovery)",
            why: "This recovery strategy worked",
            when: "When encountering similar errors",
            applicability: 0.7
        )

        // Store in frontal cortex as error learning
        FrontalCortex.shared.store(
            content: "Error recovery: \(error) -> \(recovery)",
            category: .error,
            importance: 0.7,
            tags: ["error-recovery", "lesson"]
        )

        return lesson
    }

    // MARK: - Context Building

    private func buildContextFromHistory(_ history: [AgentMessage]) -> String {
        var context = ""

        for message in history.suffix(50) {  // Last 50 messages
            switch message {
            case .user(let content, _, _):
                context += "User: \(content.prefix(200))\n"
            case .assistant(_, let content, _, _):
                context += "Assistant: \(content.prefix(300))\n"
            case .toolUse(_, let name, let args, _, _):
                let argsStr = args.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                context += "Tool: \(name)(\(argsStr.prefix(100)))\n"
            case .toolResult(_, let name, let result, _, _):
                context += "Result [\(name)]: \(result.success ? "Success" : "Failed")\n"
            case .error(_, let msg, _, _):
                context += "Error: \(msg)\n"
            default:
                break
            }
        }

        return context
    }

    private func createReflectionFromContext(
        sessionId: UUID,
        agentId: String,
        agentName: String,
        context: String,
        history: [AgentMessage]
    ) -> AgentReflection {
        // Analyze the history to extract insights
        var insights: [AgentReflection.Insight] = []
        var lessons: [AgentReflection.Lesson] = []
        var approaches: [AgentReflection.Approach] = []
        var patterns: [AgentReflection.ObservedPattern] = []

        // Extract tools used
        let toolUses = history.compactMap { msg -> (String, Bool)? in
            if case .toolResult(_, let name, let result, _, _) = msg {
                return (name, result.success)
            }
            return nil
        }

        // Group tool usage
        let toolStats = Dictionary(grouping: toolUses, by: { $0.0 })
        for (tool, uses) in toolStats {
            let successRate = Double(uses.filter { $0.1 }.count) / Double(max(1, uses.count))
            if uses.count >= 2 {
                patterns.append(AgentReflection.ObservedPattern(
                    pattern: "Used \(tool) \(uses.count) times",
                    frequency: uses.count,
                    context: "Tool usage pattern",
                    isPositive: successRate > 0.7
                ))
            }
        }

        // Check for error patterns
        let errors = history.compactMap { msg -> String? in
            if case .error(_, let message, _, _) = msg {
                return message
            }
            if case .toolResult(_, _, let result, _, _) = msg, !result.success {
                return result.error
            }
            return nil
        }

        if !errors.isEmpty {
            lessons.append(AgentReflection.Lesson(
                what: "Encountered \(errors.count) errors during session",
                why: "Errors indicate areas needing attention",
                when: "Review error handling before similar tasks",
                applicability: 0.5
            ))
        }

        // Extract successful approaches from tool chains
        var lastSuccessfulChain: [String] = []
        for message in history {
            if case .toolResult(_, let name, let result, _, _) = message {
                if result.success {
                    lastSuccessfulChain.append(name)
                } else {
                    lastSuccessfulChain = []
                }
            }
        }

        if lastSuccessfulChain.count >= 3 {
            approaches.append(AgentReflection.Approach(
                approach: "Tool chain: \(lastSuccessfulChain.joined(separator: " -> "))",
                context: "Sequential tool usage",
                outcome: "Successfully completed operation",
                reusability: 0.6
            ))
        }

        // Generate task summary
        let userMessages = history.compactMap { msg -> String? in
            if case .user(let content, _, _) = msg { return content }
            return nil
        }
        let taskSummary = userMessages.isEmpty ?
            "Session completed" :
            "Addressed user requests: \(userMessages.first?.prefix(100) ?? "")..."

        // Calculate success score
        let totalResults = toolUses.count
        let successfulResults = toolUses.filter { $0.1 }.count
        let successScore = totalResults > 0 ? Double(successfulResults) / Double(totalResults) : 0.5

        // Add a technical insight if we have tool usage data
        if !toolStats.isEmpty {
            insights.append(AgentReflection.Insight(
                content: "Session used \(toolStats.count) different tools with \(String(format: "%.0f", successScore * 100))% success rate",
                confidence: 0.8,
                category: .technical
            ))
        }

        return AgentReflection(
            sessionId: sessionId,
            agentId: agentId,
            agentName: agentName,
            taskSummary: taskSummary,
            keyInsights: insights,
            lessonsLearned: lessons,
            successfulApproaches: approaches,
            patternsObserved: patterns,
            overallSuccessScore: successScore
        )
    }

    // MARK: - Learning Integration

    /// Feed reflection insights to frontal cortex
    func feedToFrontalCortex(_ reflection: AgentReflection) {
        let cortex = FrontalCortex.shared

        // Store insights as memories
        for insight in reflection.keyInsights {
            cortex.store(
                content: insight.content,
                category: .learning,
                importance: insight.confidence,
                tags: ["insight", insight.category.rawValue],
                sessionId: reflection.sessionId
            )
        }

        // Store lessons
        for lesson in reflection.lessonsLearned {
            cortex.store(
                content: "Lesson: \(lesson.what) - Apply when: \(lesson.when)",
                category: .learning,
                importance: lesson.applicability,
                tags: ["lesson"],
                sessionId: reflection.sessionId
            )
        }

        // Store successful approaches
        for approach in reflection.successfulApproaches {
            cortex.store(
                content: "Approach: \(approach.approach) in context: \(approach.context)",
                category: .decision,
                importance: approach.reusability,
                tags: ["approach", "success"],
                sessionId: reflection.sessionId
            )
        }
    }

    /// Update aggregated learnings from new reflection
    private func updateAggregatedLearnings(from reflection: AgentReflection) {
        // Group lessons by topic keywords
        for lesson in reflection.lessonsLearned {
            // Find existing aggregation or create new
            let keywords = extractKeywords(from: lesson.what)
            let topic = keywords.first ?? "general"

            if let index = aggregatedLearnings.firstIndex(where: {
                extractKeywords(from: $0.topic).contains(where: keywords.contains)
            }) {
                // Update existing
                aggregatedLearnings[index].learnings.append(lesson.what)
                aggregatedLearnings[index].sourceReflectionIds.append(reflection.id)
                aggregatedLearnings[index].updatedAt = Date()

                // Boost confidence with more evidence
                let count = Double(aggregatedLearnings[index].sourceReflectionIds.count)
                aggregatedLearnings[index].confidence = min(1.0, 0.3 + (0.1 * count))
            } else {
                // Create new aggregated learning
                let learning = AggregatedLearning(
                    topic: topic,
                    learnings: [lesson.what],
                    sourceReflectionIds: [reflection.id],
                    confidence: 0.4
                )
                aggregatedLearnings.append(learning)
            }
        }
    }

    private func extractKeywords(from text: String) -> [String] {
        // Simple keyword extraction - words > 4 chars, lowercased
        let words = text.lowercased()
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count > 4 }

        // Remove common words
        let stopWords = Set(["about", "after", "being", "could", "would", "should", "their", "there", "these", "those", "which", "while"])
        return words.filter { !stopWords.contains($0) }
    }

    // MARK: - Querying

    /// Get applicable learnings for current context
    func getApplicableLearnings(for context: String) -> [AggregatedLearning] {
        let keywords = extractKeywords(from: context)

        return aggregatedLearnings
            .filter { learning in
                let topicKeywords = extractKeywords(from: learning.topic)
                let learningKeywords = learning.learnings.flatMap { extractKeywords(from: $0) }
                let allKeywords = Set(topicKeywords + learningKeywords)

                return keywords.contains { keyword in
                    allKeywords.contains { $0.contains(keyword) || keyword.contains($0) }
                }
            }
            .sorted { $0.confidence > $1.confidence }
            .prefix(5)
            .map { $0 }
    }

    /// Mark learning as applied
    func markLearningApplied(learningId: UUID, success: Bool) {
        guard let index = aggregatedLearnings.firstIndex(where: { $0.id == learningId }) else { return }
        aggregatedLearnings[index].recordApplication(success: success)
        scheduleSave()
    }

    /// Get reflections with query
    func getReflections(query: ReflectionQuery) -> [AgentReflection] {
        var results = reflections

        if let agentId = query.agentId {
            results = results.filter { $0.agentId == agentId }
        }

        if let sessionId = query.sessionId {
            results = results.filter { $0.sessionId == sessionId }
        }

        if let range = query.dateRange {
            results = results.filter { range.contains($0.timestamp) }
        }

        if let minScore = query.minSuccessScore {
            results = results.filter { $0.overallSuccessScore >= minScore }
        }

        if let search = query.hasInsightsFor {
            let keywords = extractKeywords(from: search)
            results = results.filter { reflection in
                reflection.keyInsights.contains { insight in
                    let insightKeywords = extractKeywords(from: insight.content)
                    return keywords.contains { kw in insightKeywords.contains { $0.contains(kw) } }
                }
            }
        }

        return Array(results.sorted { $0.timestamp > $1.timestamp }.prefix(query.limit))
    }

    /// Build context string for prompt injection
    func buildLearningsContext(for query: String, maxLearnings: Int = 3) -> String {
        let learnings = getApplicableLearnings(for: query).prefix(maxLearnings)

        if learnings.isEmpty {
            return ""
        }

        var context = "LEARNINGS FROM PAST SESSIONS:\n"
        for learning in learnings {
            context += "- \(learning.topic) (confidence: \(String(format: "%.0f", learning.confidence * 100))%): "
            context += learning.learnings.first ?? ""
            context += "\n"
        }

        return context
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 seconds
            if !Task.isCancelled {
                await save()
            }
        }
    }

    func save() async {
        saveReflections()
        saveAggregatedLearnings()
    }

    private func saveReflections() {
        let url = storageURL.appendingPathComponent("reflections.json")
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(reflections)
            try data.write(to: url)
        } catch {
            print("Failed to save reflections: \(error)")
        }
    }

    private func loadReflections() {
        let url = storageURL.appendingPathComponent("reflections.json")
        guard let data = try? Data(contentsOf: url) else { return }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            reflections = try decoder.decode([AgentReflection].self, from: data)
        } catch {
            print("Failed to load reflections: \(error)")
        }
    }

    private func saveAggregatedLearnings() {
        let url = storageURL.appendingPathComponent("aggregated_learnings.json")
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(aggregatedLearnings)
            try data.write(to: url)
        } catch {
            print("Failed to save learnings: \(error)")
        }
    }

    private func loadAggregatedLearnings() {
        let url = storageURL.appendingPathComponent("aggregated_learnings.json")
        guard let data = try? Data(contentsOf: url) else { return }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            aggregatedLearnings = try decoder.decode([AggregatedLearning].self, from: data)
        } catch {
            print("Failed to load learnings: \(error)")
        }
    }
}
