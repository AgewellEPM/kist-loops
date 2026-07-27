import XCTest
import AgentCore
@testable import Kist

final class CouncilCardTests: XCTestCase {

    private let finalPlan = """
    Decision:
    - Build the parser first; defer the optimizer.

    Task Analysis:
    - It unblocks the rest.

    Kanban Board:
    | Status | Task | Owner | Acceptance |
    | --- | --- | --- | --- |
    | Ready | Write the tokenizer | builder | tokens emitted |
    | Ready | Add parser tests | builder | tests green |
    | Backlog | Build the optimizer | builder | later |

    Test plan:
    - swift test --filter ParserTests

    Next Builder Brief:
    - Start with the tokenizer.
    """

    private func result() -> CouncilRunResult {
        let minds = [
            CouncilMindResult(name: "Researcher", role: "worker", binding: ProviderBinding(providerId: "mimo"),
                              output: "## Researcher\n- The market wants a small, fast parser.\n- more detail"),
            CouncilMindResult(name: "Critic", role: "critic", binding: ProviderBinding(providerId: "gemini"),
                              output: "- Watch out for scope creep on the optimizer."),
            CouncilMindResult(name: "Memory", role: "memory", binding: nil,
                              output: "No project memory found. Treat this as fresh."),
        ]
        return CouncilRunResult(goal: "design the parser", minds: minds, finalPlan: finalPlan,
                                markdown: "# AI Council Result\n…wall of prose…", builderBrief: "build it")
    }

    func testCardShowsMindGistsDecisionAndReadyTasks() {
        let card = CouncilCard.render(result(), artifactPath: "/tmp/board.md", color: false)
        XCTAssertTrue(card.contains("Researcher · worker"))
        XCTAssertTrue(card.contains("The market wants a small, fast parser."))   // gist, markers stripped
        XCTAssertTrue(card.contains("Watch out for scope creep"))
        XCTAssertFalse(card.contains("No project memory found"))                 // empty memory mind hidden
        XCTAssertTrue(card.contains("Decision: Build the parser first"))
        XCTAssertTrue(card.contains("1. Write the tokenizer"))
        XCTAssertTrue(card.contains("2. Add parser tests"))
        XCTAssertFalse(card.contains("Build the optimizer"))                     // Backlog excluded
        XCTAssertTrue(card.contains("Test plan:"))
        XCTAssertTrue(card.contains("full board saved · /tmp/board.md") || card.contains("/details"))
    }

    func testReadyTasksParsedAndCappedAtFive() {
        let many = "Kanban Board:\n" + (1...8).map { "| Ready | task \($0) | b | a |" }.joined(separator: "\n")
        let r = CouncilRunResult(goal: "g", minds: [], finalPlan: many, markdown: "", builderBrief: "")
        let card = CouncilCard.render(r, artifactPath: nil, color: false)
        XCTAssertTrue(card.contains("5. task 5"))
        XCTAssertFalse(card.contains("6. task 6"))     // capped at 5
    }

    func testSectionExtractionAndGist() {
        XCTAssertEqual(CouncilCard.section("Decision: do X\nTask Analysis: y", heading: "Decision"), "do X")
        XCTAssertEqual(CouncilCard.gist("\n## Heading\n- first real line\nmore"), "first real line")
        XCTAssertEqual(CouncilCard.readyTasks("| Ready | A | x | y |\n| Backlog | B | x | y |"), ["A"])
    }
}
