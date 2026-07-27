import Foundation

// MARK: - Agent Reflection

/// A reflection entry from an agent session
struct AgentReflection: Identifiable, Codable {
    let id: UUID
    let sessionId: UUID
    let agentId: String
    let agentName: String
    let timestamp: Date

    var taskSummary: String
    var keyInsights: [Insight]
    var lessonsLearned: [Lesson]
    var successfulApproaches: [Approach]
    var improvementSuggestions: [Suggestion]
    var patternsObserved: [ObservedPattern]
    var overallSuccessScore: Double         // 0.0 - 1.0

    // MARK: - Nested Types

    struct Insight: Codable, Identifiable {
        let id: UUID
        var content: String
        var confidence: Double              // 0.0 - 1.0
        var relatedFiles: [String]
        var category: InsightCategory

        enum InsightCategory: String, Codable, CaseIterable {
            case technical = "technical"
            case process = "process"
            case userBehavior = "user"
            case codebase = "codebase"
            case performance = "performance"
            case security = "security"
        }

        init(content: String, confidence: Double = 0.7, relatedFiles: [String] = [], category: InsightCategory = .technical) {
            self.id = UUID()
            self.content = content
            self.confidence = confidence
            self.relatedFiles = relatedFiles
            self.category = category
        }
    }

    struct Lesson: Codable, Identifiable {
        let id: UUID
        var what: String                    // What was learned
        var why: String                     // Why it matters
        var when: String                    // When to apply
        var applicability: Double           // How broadly applicable (0-1)

        init(what: String, why: String, when: String, applicability: Double = 0.5) {
            self.id = UUID()
            self.what = what
            self.why = why
            self.when = when
            self.applicability = applicability
        }
    }

    struct Approach: Codable, Identifiable {
        let id: UUID
        var approach: String
        var context: String
        var outcome: String
        var reusability: Double             // How reusable (0-1)

        init(approach: String, context: String, outcome: String, reusability: Double = 0.5) {
            self.id = UUID()
            self.approach = approach
            self.context = context
            self.outcome = outcome
            self.reusability = reusability
        }
    }

    struct Suggestion: Codable, Identifiable {
        let id: UUID
        var suggestion: String
        var rationale: String
        var priority: Priority
        var implemented: Bool

        enum Priority: String, Codable, CaseIterable {
            case low, medium, high, critical
        }

        init(suggestion: String, rationale: String, priority: Priority = .medium) {
            self.id = UUID()
            self.suggestion = suggestion
            self.rationale = rationale
            self.priority = priority
            self.implemented = false
        }
    }

    struct ObservedPattern: Codable, Identifiable {
        let id: UUID
        var pattern: String
        var frequency: Int
        var context: String
        var isPositive: Bool

        init(pattern: String, frequency: Int = 1, context: String, isPositive: Bool) {
            self.id = UUID()
            self.pattern = pattern
            self.frequency = frequency
            self.context = context
            self.isPositive = isPositive
        }
    }

    // MARK: - Initialization

    init(
        sessionId: UUID,
        agentId: String,
        agentName: String,
        taskSummary: String = "",
        keyInsights: [Insight] = [],
        lessonsLearned: [Lesson] = [],
        successfulApproaches: [Approach] = [],
        improvementSuggestions: [Suggestion] = [],
        patternsObserved: [ObservedPattern] = [],
        overallSuccessScore: Double = 0.5
    ) {
        self.id = UUID()
        self.sessionId = sessionId
        self.agentId = agentId
        self.agentName = agentName
        self.timestamp = Date()
        self.taskSummary = taskSummary
        self.keyInsights = keyInsights
        self.lessonsLearned = lessonsLearned
        self.successfulApproaches = successfulApproaches
        self.improvementSuggestions = improvementSuggestions
        self.patternsObserved = patternsObserved
        self.overallSuccessScore = overallSuccessScore
    }
}

// MARK: - Aggregated Learning

/// Aggregated learnings from multiple reflections
struct AggregatedLearning: Identifiable, Codable {
    let id: UUID
    var topic: String
    var learnings: [String]
    var sourceReflectionIds: [UUID]
    var confidence: Double
    var timesApplied: Int
    var successRate: Double
    var lastApplied: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        topic: String,
        learnings: [String],
        sourceReflectionIds: [UUID] = [],
        confidence: Double = 0.5
    ) {
        self.id = UUID()
        self.topic = topic
        self.learnings = learnings
        self.sourceReflectionIds = sourceReflectionIds
        self.confidence = confidence
        self.timesApplied = 0
        self.successRate = 0.0
        self.lastApplied = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// Record an application of this learning
    mutating func recordApplication(success: Bool) {
        timesApplied += 1
        lastApplied = Date()

        // Update success rate with exponential moving average
        let alpha = 0.3
        let successValue = success ? 1.0 : 0.0
        successRate = alpha * successValue + (1 - alpha) * successRate

        // Adjust confidence based on success rate
        if timesApplied >= 3 {
            confidence = 0.3 + (0.7 * successRate)
        }

        updatedAt = Date()
    }
}

// MARK: - Reflection Prompt

/// Prompt template for generating reflections
struct ReflectionPrompt {
    static let template = """
    You just completed a task. Reflect on your work by answering these questions:

    1. TASK SUMMARY: What did you accomplish? (2-3 sentences)

    2. KEY INSIGHTS: What insights did you gain about the codebase, user needs, or task? (list 2-5)

    3. LESSONS LEARNED: What lessons did you learn that could help in future sessions?
       For each lesson, provide:
       - What: The lesson itself
       - Why: Why it matters
       - When: When to apply it

    4. SUCCESSFUL APPROACHES: What approaches worked well and should be reused?
       For each, describe:
       - The approach
       - The context where it worked
       - The outcome

    5. IMPROVEMENT SUGGESTIONS: What could be improved next time?
       - What to improve
       - Why/rationale
       - Priority (low/medium/high/critical)

    6. PATTERNS OBSERVED: Any patterns you noticed (positive or negative)?

    7. SUCCESS SCORE: Rate your overall success from 0.0 to 1.0

    Format your response as JSON matching this structure:
    {
      "taskSummary": "string",
      "keyInsights": [{"content": "string", "confidence": 0.0-1.0, "category": "technical|process|user|codebase|performance|security"}],
      "lessonsLearned": [{"what": "string", "why": "string", "when": "string", "applicability": 0.0-1.0}],
      "successfulApproaches": [{"approach": "string", "context": "string", "outcome": "string", "reusability": 0.0-1.0}],
      "improvementSuggestions": [{"suggestion": "string", "rationale": "string", "priority": "low|medium|high|critical"}],
      "patternsObserved": [{"pattern": "string", "context": "string", "isPositive": true|false}],
      "overallSuccessScore": 0.0-1.0
    }
    """

    static func buildPrompt(context: String) -> String {
        return """
        Context of the completed task:
        \(context)

        ---

        \(template)
        """
    }
}

// MARK: - Reflection Query

/// Query for searching reflections
struct ReflectionQuery {
    var agentId: String?
    var sessionId: UUID?
    var dateRange: ClosedRange<Date>?
    var minSuccessScore: Double?
    var hasInsightsFor: String?     // Search insight content
    var hasLessonsFor: String?      // Search lesson content
    var limit: Int = 20
}

// MARK: - Agent Stat

/// Stats for a single agent
struct AgentStat: Codable, Identifiable {
    let id: UUID
    var agentName: String
    var reflectionCount: Int

    init(agentName: String, reflectionCount: Int) {
        self.id = UUID()
        self.agentName = agentName
        self.reflectionCount = reflectionCount
    }
}

// MARK: - Reflection Statistics

/// Statistics about reflections
struct ReflectionStats: Codable {
    var totalReflections: Int
    var averageSuccessScore: Double
    var totalInsights: Int
    var totalLessons: Int
    var topAgents: [AgentStat]
    var insightCategories: [String: Int]
    var recentReflectionDate: Date?

    init() {
        self.totalReflections = 0
        self.averageSuccessScore = 0
        self.totalInsights = 0
        self.totalLessons = 0
        self.topAgents = []
        self.insightCategories = [:]
        self.recentReflectionDate = nil
    }
}
