import XCTest
@testable import Kist

/// Pins the auto-explore wiring in the REPL: a lookup turn must run EstateSearch and inject what it finds
/// ahead of the model, so Kist answers "find what we did for X" from real files instead of hallucinating.
/// The injection lives inside the REPL run loop (not unit-reachable), so it's asserted at the source.
final class EstateAutoExploreWiringTests: XCTestCase {
    private func repl() -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Kist/KistREPL.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testLookupTurnRunsEstateSearchAndInjectsGrounding() {
        let s = repl()
        XCTAssertTrue(s.contains("EstateLookupIntent.matches(messageText)"),
                      "lookup questions must be detected before the model turn")
        XCTAssertTrue(s.contains("EstateSearch()") && s.contains("groundingBlock(for:"),
                      "a lookup turn must search the estate and build a grounding block")
        XCTAssertTrue(s.contains("grounding + \"\\n\\n\" + enriched"),
                      "retrieved context must be injected AHEAD of the normal turn input")
    }

    func testSearchRunsOffTheMainTaskAndIsVisible() {
        let s = repl()
        XCTAssertTrue(s.contains("Task.detached"),
                      "the blocking file walk must run off the cooperative pool")
        XCTAssertTrue(s.contains("searchTask.cancel()") && s.contains("file search interrupted"),
                      "the session ESC contract must cancel auto-explore instead of ignoring the user")
        XCTAssertTrue(s.contains("🔎"),
                      "the search must be visible to the user (a 🔎 status line)")
    }
}
