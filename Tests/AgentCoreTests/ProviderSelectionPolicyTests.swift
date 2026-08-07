import XCTest
@testable import AgentCore

/// Cost-vs-power selection (Luke 2026-08-06: "a cost determination option — by cost or by power").
final class ProviderSelectionPolicyTests: XCTestCase {

    func testLooseParsingAndDefault() {
        XCTAssertEqual(ProviderSelectionPolicy.default, .power)
        for s in ["cost", "Cheap", "cheapest", "budget", "economy", "$"] {
            XCTAssertEqual(ProviderSelectionPolicy(loose: s), .cost, s)
        }
        for s in ["power", "STRONGEST", "best", "quality"] {
            XCTAssertEqual(ProviderSelectionPolicy(loose: s), .power, s)
        }
        XCTAssertNil(ProviderSelectionPolicy(loose: "banana"))
    }

    // Subscription CLIs bill a flat fee → 0 marginal; local models are 0; cheap APIs beat premium APIs.
    func testMarginalCostOrdering() {
        XCTAssertEqual(ProviderCostRank.marginalPerMillion("claude-cli"), 0.0)
        XCTAssertEqual(ProviderCostRank.marginalPerMillion("codex-cli"), 0.0)
        XCTAssertEqual(ProviderCostRank.marginalPerMillion("ollama"), 0.0)
        XCTAssertEqual(ProviderCostRank.marginalPerMillion("mlx"), 0.0)
        // mimo (0.10/0.40) cheaper than deepseek (0.27/1.10) cheaper than openai (5/15).
        XCTAssertLessThan(ProviderCostRank.marginalPerMillion("mimo"),
                          ProviderCostRank.marginalPerMillion("deepseek"))
        XCTAssertLessThan(ProviderCostRank.marginalPerMillion("deepseek"),
                          ProviderCostRank.marginalPerMillion("gemini"))
        XCTAssertLessThan(ProviderCostRank.marginalPerMillion("gemini"),
                          ProviderCostRank.marginalPerMillion("openai"))
        // Unknown vendor sorts as expensive so `.cost` never silently prefers an unpriced one.
        XCTAssertEqual(ProviderCostRank.marginalPerMillion("nonesuch"), .greatestFiniteMagnitude)
    }
}
