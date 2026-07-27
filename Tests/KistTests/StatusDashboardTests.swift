import XCTest
@testable import Kist

final class StatusDashboardTests: XCTestCase {
    func dash() -> StatusDashboard {
        StatusDashboard(
            minds: [.init(name: "Claude", role: "Captain"), .init(name: "Gemini", role: "Research"),
                    .init(name: "DeepSeek", role: "Review")],
            tasks: [.init(title: "Wireframe generated", state: .done),
                    .init(title: "Alias resolver", state: .pending),
                    .init(title: "Benchmark review", state: .pending)],
            learned: ["Fleet orchestration works.", "Planner architecture validated."],
            research: [
                .init(title: "Study Claude Code's fleet scheduling",
                      priority: .high,
                      reason: "Compare orchestration strategy",
                      visit: "Claude Code docs",
                      impact: 5,
                      estimatedLearning: "2 hours",
                      expectedBenefit: ["better delegation"]),
                .init(title: "Read Apple Foundation Models docs",
                      priority: .medium,
                      reason: "Local reasoning roadmap",
                      visit: "Apple developer docs",
                      impact: 4,
                      estimatedLearning: "3 hours",
                      expectedBenefit: ["offline orchestration"])
            ],
            knowledgeDebt: [
                .init(need: "Need to understand", topic: "Apple Foundation Models",
                      impact: "Captain roadmap", severity: 5)
            ],
            questions: ["Can Captain become fully autonomous?"],
            futureEvolution: .init(capability: "Persistent research memory",
                                   estimatedImpact: "High"),
            observation: .init(message: "Research should shape the next orchestration pass.",
                               recommendedReading: ["Apple Foundation Models"],
                               expectedROI: "High"),
            confidence: 0.91, next: "Continue implementation")
    }

    func testRendersAllSectionsPlain() {
        let s = dash().render(color: false)
        XCTAssertTrue(s.contains("🧠 Active Minds"))
        XCTAssertTrue(s.contains("Claude (Captain)"))
        XCTAssertTrue(s.contains("📋 Build Queue"))
        XCTAssertTrue(s.contains("✓ Wireframe generated"))
        XCTAssertTrue(s.contains("⏳ Alias resolver"))
        XCTAssertTrue(s.contains("🧠 What We Learned"))
        XCTAssertTrue(s.contains("• Fleet orchestration works."))
        XCTAssertTrue(s.contains("🔬 Research Queue"))
        XCTAssertTrue(s.contains("High Priority"))
        XCTAssertTrue(s.contains("Study Claude Code's fleet scheduling"))
        XCTAssertTrue(s.contains("Why: Compare orchestration strategy"))
        XCTAssertTrue(s.contains("Visit: Claude Code docs"))
        XCTAssertTrue(s.contains("Impact: ★★★★★ · learning: 2 hours"))
        XCTAssertTrue(s.contains("Expected benefit: better delegation"))
        XCTAssertTrue(s.contains("📚 Knowledge Debt"))
        XCTAssertTrue(s.contains("Need to understand: Apple Foundation Models"))
        XCTAssertTrue(s.contains("🧠 Questions"))
        XCTAssertTrue(s.contains("? Can Captain become fully autonomous?"))
        XCTAssertTrue(s.contains("💡 Future Evolution"))
        XCTAssertTrue(s.contains("Persistent research memory"))
        XCTAssertTrue(s.contains("Captain Observation"))
        XCTAssertTrue(s.contains("Expected ROI: High"))
        XCTAssertTrue(s.contains("Confidence"))
        XCTAssertTrue(s.contains("91%"))
        XCTAssertTrue(s.contains("→ Continue implementation"))
        XCTAssertTrue(s.contains("━"))
    }

    func testConfidenceBarLength() {
        // 91% → 9 filled, 1 empty
        let s = StatusDashboard(confidence: 0.91).render(color: false)
        XCTAssertTrue(s.contains(String(repeating: "█", count: 9) + "░"))
    }

    func testEmptySectionsAreOmitted() {
        let s = StatusDashboard(minds: [], tasks: [], confidence: nil, next: nil).render(color: false)
        XCTAssertFalse(s.contains("Active Minds"))
        XCTAssertFalse(s.contains("Build Queue"))
        XCTAssertFalse(s.contains("What We Learned"))
        XCTAssertFalse(s.contains("Research Queue"))
        XCTAssertFalse(s.contains("Knowledge Debt"))
        XCTAssertFalse(s.contains("Questions"))
        XCTAssertFalse(s.contains("Future Evolution"))
        XCTAssertFalse(s.contains("Captain Observation"))
        XCTAssertFalse(s.contains("Confidence"))
        XCTAssertFalse(s.contains("Next"))
    }

    func testBlockedTaskShown() {
        let s = StatusDashboard(tasks: [.init(title: "DB migration", state: .blocked)]).render(color: false)
        XCTAssertTrue(s.contains("⊘ DB migration"))
    }

    func testCompactRenderKeepsResearchGlanceable() {
        let s = dash().renderCompact(color: false)

        XCTAssertTrue(s.contains("Research"))
        XCTAssertTrue(s.contains("Study Claude Code's fleet scheduling"))
        XCTAssertTrue(s.contains("details: /summary"))
        XCTAssertFalse(s.contains("Why:"))
        XCTAssertFalse(s.contains("Knowledge Debt"))
        XCTAssertFalse(s.contains("Captain Observation"))
    }

    func testCompactRenderWrapsActiveMindsWithinConfiguredWidth() {
        let width = 36
        let s = StatusDashboard(
            minds: [
                .init(name: "mimo-v2.5-pro-with-long-context", role: "Default model"),
                .init(name: "gemini-2.5-flash", role: "Research specialist"),
                .init(name: "deepseek-v4-pro", role: "Independent reviewer")
            ],
            width: width
        ).renderCompact(color: false)

        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            XCTAssertLessThanOrEqual(line.count, width, "line exceeded compact dashboard width: \(line)")
        }
        XCTAssertTrue(s.contains("✓ mimo-v2.5-pro-with-long-context"))
        XCTAssertTrue(s.contains("Default model"))
    }

    func testRenderWrapsLongDashboardRowsWithinConfiguredWidth() {
        let width = 42
        let s = StatusDashboard(
            tasks: [
                .init(title: "Create a very long dashboard task that names the exact command to run next",
                      state: .pending)
            ],
            research: [
                .init(title: "Study background agent schedulers across multiple systems",
                      priority: .high,
                      reason: "Compare lifecycle handling, blocked worker recovery, and persistence strategy before the next architecture pass",
                      visit: "Primary docs and source repositories",
                      impact: 5,
                      estimatedLearning: "2 hours",
                      expectedBenefit: ["cleaner recovery UX", "stronger supervisor gates"])
            ],
            observation: .init(message: "Captain should not let terminal auto-wrap decide whether the user can read the board.",
                               recommendedReading: ["Cursor background agents", "OpenHands runtime loop"],
                               expectedROI: "High"),
            next: "Run the self-test suite and install only if every verification gate passes.",
            width: width
        ).render(color: false)

        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            XCTAssertLessThanOrEqual(line.count, width, "line exceeded dashboard width: \(line)")
        }
        XCTAssertTrue(s.contains("⏳ Create a very long dashboard task"))
        XCTAssertTrue(s.contains("  names the exact command to run next"))
        XCTAssertTrue(s.contains("       worker recovery, and persistence"))
        XCTAssertTrue(s.contains("→ Run the self-test suite and install"))
        XCTAssertTrue(s.contains("  if every verification gate passes."))
    }

    func testRenderSplitsUnbrokenLongTokensWithinConfiguredWidth() {
        let width = 24
        let s = StatusDashboard(
            tasks: [
                .init(title: "/Users/lukekist/Downloads/kist-loops/Sources/Kist/UX/StatusDashboard.swift",
                      state: .blocked)
            ],
            next: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            width: width
        ).render(color: false)

        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            XCTAssertLessThanOrEqual(line.count, width, "line exceeded dashboard width: \(line)")
        }
        XCTAssertTrue(s.contains("⊘ /Users/lukekist/Down"))
        XCTAssertTrue(s.contains("aaaaaaaaaaaaaaaaaaaaaa"))
    }
}
