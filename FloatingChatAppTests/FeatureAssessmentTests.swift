import XCTest
@testable import FloatingChatApp

/// Feature Assessment Tests for FloatingChatApp
/// Tests Git Tool safety, Memory decay, Working memory limits, and Reflection aggregation
final class FeatureAssessmentTests: XCTestCase {

    // MARK: - Memory Decay Formula Tests

    func testDecayFormula_AtZeroHours_ReturnsFullImportance() {
        // Given: A fresh memory with importance 1.0
        let now = Date()
        let memory = CortexMemory(
            id: UUID(),
            content: "Test memory",
            category: .learning,
            importance: 1.0,
            accessCount: 1,
            createdAt: now,
            lastAccessedAt: now,
            decayedAt: nil,
            tags: [],
            associatedEntities: [],
            sourceSessionId: nil,
            memoryType: .shortTerm
        )

        // When: We calculate current importance
        let currentImportance = memory.currentImportance(halfLifeHours: 168)

        // Then: It should be approximately 1.0
        XCTAssertEqual(currentImportance, 1.0, accuracy: 0.01)
    }

    func testDecayFormula_AtOneHalfLife_ReturnsHalfImportance() {
        // Given: A memory 168 hours (1 week) old with importance 1.0
        let now = Date()
        let oneWeekAgo = now.addingTimeInterval(-168 * 3600)
        let memory = CortexMemory(
            id: UUID(),
            content: "Week old memory",
            category: .learning,
            importance: 1.0,
            accessCount: 1,
            createdAt: oneWeekAgo,
            lastAccessedAt: oneWeekAgo,
            decayedAt: nil,
            tags: [],
            associatedEntities: [],
            sourceSessionId: nil,
            memoryType: .shortTerm
        )

        // When: We calculate current importance
        let currentImportance = memory.currentImportance(halfLifeHours: 168)

        // Then: It should be approximately 0.5
        XCTAssertEqual(currentImportance, 0.5, accuracy: 0.05)
    }

    func testDecayFormula_AtTwoHalfLives_ReturnsQuarterImportance() {
        // Given: A memory 336 hours (2 weeks) old with importance 1.0
        let now = Date()
        let twoWeeksAgo = now.addingTimeInterval(-336 * 3600)
        let memory = CortexMemory(
            id: UUID(),
            content: "Two week old memory",
            category: .learning,
            importance: 1.0,
            accessCount: 1,
            createdAt: twoWeeksAgo,
            lastAccessedAt: twoWeeksAgo,
            decayedAt: nil,
            tags: [],
            associatedEntities: [],
            sourceSessionId: nil,
            memoryType: .shortTerm
        )

        // When: We calculate current importance
        let currentImportance = memory.currentImportance(halfLifeHours: 168)

        // Then: It should be approximately 0.25
        XCTAssertEqual(currentImportance, 0.25, accuracy: 0.03)
    }

    // MARK: - Working Memory Cognitive Limit Tests

    func testWorkingMemory_CognitiveLimit_EnforcesSevenItemMax() {
        // Given: A working memory instance
        var workingMemory = WorkingMemory()

        // When: We add 10 attention items
        for i in 1...10 {
            workingMemory.addAttentionItem("Item \(i)", priority: 0.5)
        }

        // Then: Only 7 items should be stored (cognitive limit)
        XCTAssertEqual(workingMemory.attentionItems.count, 7)
    }

    func testWorkingMemory_PriorityOrdering_HighPriorityFirst() {
        // Given: A working memory instance
        var workingMemory = WorkingMemory()

        // When: We add items with different priorities
        workingMemory.addAttentionItem("Low priority", priority: 0.2)
        workingMemory.addAttentionItem("High priority", priority: 0.9)

        // Then: High priority should be first
        XCTAssertTrue(workingMemory.attentionItems.first?.contains("High") ?? false)
    }

    // MARK: - Git Tool Safety Tests

    func testGitTool_BlocksForcePush() async {
        // Given: A git tool instance
        let gitTool = GitTool()

        // When: We attempt a force push
        let result = await gitTool.execute(
            arguments: ["operation": "push", "args": "--force origin main"],
            projectPath: "/tmp"
        )

        // Then: It should be blocked
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.lowercased().contains("blocked") ||
                      result.output.lowercased().contains("not allowed") ||
                      result.output.lowercased().contains("safety"))
    }

    func testGitTool_BlocksHardReset() async {
        // Given: A git tool instance
        let gitTool = GitTool()

        // When: We attempt a hard reset
        let result = await gitTool.execute(
            arguments: ["operation": "reset", "args": "--hard HEAD~1"],
            projectPath: "/tmp"
        )

        // Then: It should be blocked
        XCTAssertFalse(result.success)
    }

    func testGitTool_BlocksForceDelete() async {
        // Given: A git tool instance
        let gitTool = GitTool()

        // When: We attempt to force delete a branch
        let result = await gitTool.execute(
            arguments: ["operation": "branch", "args": "-D feature-branch"],
            projectPath: "/tmp"
        )

        // Then: It should be blocked
        XCTAssertFalse(result.success)
    }

    func testGitTool_ValidatesCommitMessageLength() async {
        // Given: A git tool instance
        let gitTool = GitTool()

        // When: We attempt a commit with a too-short message
        let result = await gitTool.execute(
            arguments: ["operation": "commit", "message": "ab"],
            projectPath: "/tmp"
        )

        // Then: It should fail validation
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.lowercased().contains("short") ||
                      result.output.lowercased().contains("message"))
    }

    // MARK: - Reflection Success Rate Tests

    func testAggregatedLearning_SuccessRateEMA() {
        // Given: An aggregated learning with 100% success rate
        var learning = AggregatedLearning(
            id: UUID(),
            topic: "Testing",
            learnings: ["Test lesson"],
            sourceReflectionIds: [UUID()],
            confidence: 1.0,
            timesApplied: 5,
            successRate: 1.0,
            lastApplied: Date(),
            createdAt: Date(),
            updatedAt: Date()
        )

        // When: We record a failure (success = false)
        learning.recordApplication(success: false)

        // Then: Success rate should decrease but not to 0 (EMA with α=0.3)
        // New rate = 0.3 * 0 + 0.7 * 1.0 = 0.7
        XCTAssertEqual(learning.successRate, 0.7, accuracy: 0.05)
        XCTAssertEqual(learning.timesApplied, 6)
    }

    func testAggregatedLearning_MultipleSuccesses() {
        // Given: An aggregated learning
        var learning = AggregatedLearning(
            id: UUID(),
            topic: "Testing",
            learnings: ["Test lesson"],
            sourceReflectionIds: [UUID()],
            confidence: 1.0,
            timesApplied: 0,
            successRate: 0.5,
            lastApplied: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        // When: We record 5 successes
        for _ in 1...5 {
            learning.recordApplication(success: true)
        }

        // Then: Success rate should approach 1.0
        XCTAssertGreaterThan(learning.successRate, 0.9)
    }

    // MARK: - Memory Persistence Tests

    func testFrontalCortex_StoreAndRetrieve() async {
        // Given: FrontalCortex instance
        let cortex = await FrontalCortex.shared

        // When: We store a memory
        let storedMemory = await cortex.store(
            content: "Test memory for assessment",
            category: .learning,
            importance: 0.8,
            tags: ["test", "assessment"],
            entities: [],
            sessionId: nil
        )

        // Then: We should be able to retrieve it
        let retrieved = await cortex.retrieve(
            query: "assessment",
            category: nil,
            limit: 10,
            minImportance: 0.1
        )

        XCTAssertTrue(retrieved.contains(where: { $0.id == storedMemory.id }))

        // Cleanup
        await cortex.forget(memoryId: storedMemory.id)
    }

    // MARK: - Keyword Extraction Tests

    func testReflectionEngine_KeywordExtraction() async {
        // Given: AgentReflectionEngine instance
        let engine = await AgentReflectionEngine.shared

        // When: We extract keywords from text
        let text = "The function returns null when invalid input"
        let keywords = await engine.extractKeywords(from: text)

        // Then: Should extract meaningful keywords (>4 chars, no stopwords)
        XCTAssertTrue(keywords.contains("function"))
        XCTAssertTrue(keywords.contains("returns"))
        XCTAssertTrue(keywords.contains("invalid"))
        XCTAssertTrue(keywords.contains("input"))
        XCTAssertFalse(keywords.contains("The"))  // Stopword
        XCTAssertFalse(keywords.contains("when")) // Stopword
    }
}

// MARK: - Performance Tests

extension FeatureAssessmentTests {

    func testMemoryRetrievePerformance() async {
        // Given: FrontalCortex with many memories
        let cortex = await FrontalCortex.shared

        // Pre-populate with test memories
        for i in 1...100 {
            _ = await cortex.store(
                content: "Performance test memory \(i)",
                category: .task,
                importance: 0.5,
                tags: ["perf"],
                entities: [],
                sessionId: nil
            )
        }

        // When/Then: Retrieval should complete quickly
        let startTime = Date()
        _ = await cortex.retrieve(query: "performance", category: nil, limit: 50, minImportance: 0.1)
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertLessThan(elapsed, 0.1, "Memory retrieval should complete in under 100ms")

        // Cleanup - get memories with "perf" tag and delete
        let perfMemories = await cortex.retrieve(query: "perf", category: nil, limit: 100, minImportance: 0.0)
        for memory in perfMemories {
            await cortex.forget(memoryId: memory.id)
        }
    }
}
