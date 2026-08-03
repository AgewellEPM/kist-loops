import XCTest
@testable import AgentCore

/// The adaptive effort brain: trivial goals get near-zero overhead, complex ones get thinking + planning +
/// team, and a struggling run escalates. Pure policy, pinned deterministically.
final class EffortControllerTests: XCTestCase {

    func testTrivialGoalGetsMinimalEffort() {
        let a = EffortController.assess(goal: "rename the variable foo to bar")
        XCTAssertEqual(a.thinking, .none)
        XCTAssertEqual(a.planning, .direct)
        XCTAssertEqual(a.team, .solo)
        XCTAssertLessThan(a.iterationBudget, 60)
    }

    func testComplexGoalGetsThinkingPlanningAndTeam() {
        let a = EffortController.assess(goal:
            "Design and implement an end-to-end authentication system: build the token service, integrate it "
            + "with the API, migrate existing users, and add production-ready tests.")
        XCTAssertEqual(a.thinking, .deep)
        XCTAssertEqual(a.planning, .decompose)
        XCTAssertTrue(a.team == .review || a.team == .council)
        XCTAssertGreaterThan(a.iterationBudget, 120)
    }

    func testModerateGoalIsInTheMiddle() {
        let a = EffortController.assess(goal: "add a subtract function and a test for it")
        XCTAssertNotEqual(a.thinking, .deep, "a small feature shouldn't demand deep thinking")
        XCTAssertNotEqual(a.team, .council)
    }

    func testStuckRunEscalatesEffort() {
        let cold = EffortController.assess(goal: "fix the failing parser")
        let stuck = EffortController.assess(goal: "fix the failing parser",
                                            signals: .init(failureRate: 0.6, iterationsUsed: 20, isStuck: true, replansUsed: 2))
        XCTAssertGreaterThan(stuck.complexity, cold.complexity, "a struggling run earns more effort")
        XCTAssertGreaterThanOrEqual(stuck.iterationBudget, cold.iterationBudget)
    }

    func testRigorWordsRaiseCareEvenWhenShort() {
        let plain = EffortController.assess(goal: "update the config")
        let rigor = EffortController.assess(goal: "update the production payment config")
        XCTAssertGreaterThan(rigor.complexity, plain.complexity)
    }

    func testScoreAndBudgetAreBounded() {
        let huge = EffortController.assess(goal: String(repeating: "build and integrate and migrate a system ", count: 50),
                                           signals: .init(failureRate: 1, iterationsUsed: 999, isStuck: true, replansUsed: 5))
        XCTAssertLessThanOrEqual(huge.complexity, 100)
        XCTAssertLessThanOrEqual(huge.iterationBudget, 400)
        XCTAssertGreaterThanOrEqual(huge.complexity, 0)
    }

    func testRationaleIsHumanReadable() {
        let a = EffortController.assess(goal: "build a parser")
        XCTAssertTrue(a.rationale.contains("complexity"))
        XCTAssertTrue(a.rationale.contains("think:"))
    }

    func testSearchWidthScalesWithComplexity() {
        XCTAssertEqual(EffortController.assess(goal: "rename a var").searchWidth, 1)
        XCTAssertGreaterThanOrEqual(EffortController.assess(goal: "design and implement an end-to-end migration system, integrate it, and add production tests").searchWidth, 2)
    }

    func testModelTierScalesWithComplexity() {
        XCTAssertEqual(EffortController.assess(goal: "rename a var").modelTier, .economy)
        let hard = EffortController.assess(goal:
            "design and implement an end-to-end migration system, integrate it, and add production tests").modelTier
        XCTAssertEqual(hard, .frontier)
    }

    // MARK: ModelEscalator — hard cycles route to a stronger keyed mind

    func testEconomyKeepsTheSessionDefault() {
        let pick = ModelEscalator.pick(tier: .economy, keyed: ["mimo", "anthropic"], preferred: "mimo")
        XCTAssertEqual(pick, "mimo", "economy tier never escalates")
    }

    func testFrontierPicksTheStrongestKeyed() {
        let pick = ModelEscalator.pick(tier: .frontier, keyed: ["mimo", "deepseek", "anthropic"], preferred: "mimo")
        XCTAssertEqual(pick, "anthropic", "frontier grabs the strongest keyed provider")
    }

    func testNeverDowngradesBelowPreferred() {
        // Only weak providers are keyed besides a strong default → keep the strong default.
        let pick = ModelEscalator.pick(tier: .frontier, keyed: ["mimo", "baichuan"], preferred: "anthropic")
        XCTAssertEqual(pick, "anthropic")
    }

    // BUG 3: keyless subscription providers (Claude Max / Codex CLI) are heavy hitters and must rank as
    // such, so strong-on-repair escalates to them rather than sitting on a weak model like MiMo.
    func testKeylessSubscriptionProvidersRankAsHeavyHitters() {
        XCTAssertEqual(ModelEscalator.rank("claude-cli"), 100)
        XCTAssertEqual(ModelEscalator.rank("codex-cli"), 95)
        XCTAssertGreaterThan(ModelEscalator.rank("claude-cli"), ModelEscalator.rank("mimo"))
    }

    func testRepairEscalatesFromWeakToStrongestAvailable() {
        // A self-heal repair agent inheriting MiMo must escalate to the strongest available heavy hitter.
        XCTAssertEqual(ModelEscalator.pick(tier: .frontier, keyed: ["mimo", "gemini", "claude-cli"], preferred: "mimo"), "claude-cli")
        XCTAssertEqual(ModelEscalator.pick(tier: .frontier, keyed: ["mimo", "gemini"], preferred: "mimo"), "gemini")
    }

    func testStandardStepsUpOnlyWhenClearlyStronger() {
        // deepseek(70) is only +25 over mimo(45) → steps up; ollama(20) would not.
        XCTAssertEqual(ModelEscalator.pick(tier: .standard, keyed: ["mimo", "deepseek"], preferred: "mimo"), "deepseek")
        XCTAssertEqual(ModelEscalator.pick(tier: .standard, keyed: ["mimo", "ollama"], preferred: "mimo"), "mimo")
    }

    func testStandardDoesNotEscalateToReasoningFrontier() {
        // standard tier must step up to a MID model (gemini 85), NOT gpt-5.5/claude (reserved for frontier).
        XCTAssertEqual(ModelEscalator.pick(tier: .standard, keyed: ["mimo","gemini","openai"], preferred: "mimo"), "gemini")
        XCTAssertEqual(ModelEscalator.pick(tier: .frontier, keyed: ["mimo","gemini","openai"], preferred: "mimo"), "openai")
    }

    // MARK: Fault tolerance — an errored provider is routed AROUND

    func testExcludedProviderIsRoutedAround() {
        // gemini(85) 500'd → excluded → standard tier falls to the next mid model (deepseek 70).
        let pick = ModelEscalator.pick(tier: .standard, keyed: ["mimo","gemini","deepseek"],
                                       preferred: "mimo", exclude: ["gemini"])
        XCTAssertEqual(pick, "deepseek", "an errored provider must not be re-selected")
    }

    func testFrontierSkipsExcludedStrongest() {
        // anthropic is strongest but excluded → frontier picks the next strongest keyed (openai 95).
        let pick = ModelEscalator.pick(tier: .frontier, keyed: ["mimo","openai","anthropic"],
                                       preferred: "mimo", exclude: ["anthropic"])
        XCTAssertEqual(pick, "openai")
    }

    func testExcludingEveryProviderFallsBackNotCrashes() {
        // Fail-safe: if every keyed provider is excluded, don't strand the loop — fall back to the full set.
        let pick = ModelEscalator.pick(tier: .frontier, keyed: ["gemini"],
                                       preferred: "gemini", exclude: ["gemini"])
        XCTAssertEqual(pick, "gemini", "the only option is still usable rather than crashing/empty")
    }

    func testExcludedDefaultStillRoutesForward() {
        // Even the session default, if it errored, is stepped away from when a healthy stronger key exists.
        let pick = ModelEscalator.pick(tier: .frontier, keyed: ["mimo","deepseek"],
                                       preferred: "mimo", exclude: ["mimo"])
        XCTAssertEqual(pick, "deepseek")
    }

    func testStandardExcludedDefaultPicksMidNotFrontier() {
        // Session default (gemini) faulted → routed around. A STANDARD cycle must move to the best MID
        // usable (deepseek 70), NOT silently upgrade to the frontier (openai 95) just because the default
        // is gone — that would re-introduce the captain over-escalation bug.
        let pick = ModelEscalator.pick(tier: .standard, keyed: ["deepseek","openai","gemini"],
                                       preferred: "gemini", exclude: ["gemini"])
        XCTAssertEqual(pick, "deepseek", "standard tier stays mid-tier even when routing around a broken default")
    }
}
