import XCTest
@testable import AgentCore

final class AdvisorSessionTests: XCTestCase {

    private func matcher() -> TaskPersonaMatcher { TaskPersonaMatcher(registry: nil) }

    func testConvenesTopMatchedPersonaComedian() async {
        var convened: String?
        let out = await AdvisorSession.advise(task: "write me a joke about debugging at 3am", matcher: matcher()) { persona, _ in
            convened = persona.name
            return "Q: why did the null pointer cross the road?"
        }
        XCTAssertEqual(convened, "comedian", "a joke task must convene the comedian")
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("advisor · comedian"))
        XCTAssertTrue(out!.contains("why did the null pointer"))
    }

    func testRegulatedAdvisorGetsMechanicalDisclaimer() async {
        let out = await AdvisorSession.advise(task: "I need to clear a sample and get a sync license for this song",
                                              matcher: matcher()) { _, _ in "here is some licensing analysis" }
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains(AdvisorSafety.disclaimer),
                      "a regulated (music-licensing) advisor's output must carry the mechanical disclaimer")
    }

    func testNonRegulatedAdvisorHasNoDisclaimer() async {
        let out = await AdvisorSession.advise(task: "write me a joke", matcher: matcher()) { _, _ in "ha" }
        XCTAssertNotNil(out)
        XCTAssertFalse(out!.contains("Advisory only"), "a comedian is not regulated — must NOT carry the licensed-advice disclaimer")
    }

    func testNoPersonaMatchReturnsNilForFallthrough() async {
        // no domain signal ⇒ nil, so the REPL falls through to normal handling instead of forcing a persona
        let out = await AdvisorSession.advise(task: "zxqw", matcher: matcher()) { _, _ in "x" }
        XCTAssertNil(out)
    }

    func testEmptyTaskReturnsNil() async {
        let out = await AdvisorSession.advise(task: "   ", matcher: matcher()) { _, _ in "x" }
        XCTAssertNil(out)
    }

    func testConsultedPanelListedWhenMultipleMatch() async {
        let out = await AdvisorSession.advise(task: "review this mortgage clause and the financial risks",
                                              matcher: matcher(), limit: 3) { _, _ in "advice" }
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("also considered:"), "a multi-match convening should name the consulted personas")
    }

    func testIsRegulatedInvariant() {
        XCTAssertTrue(AdvisorSafety.isRegulated("legal-research-analyst"))
        XCTAssertTrue(AdvisorSafety.isRegulated("music-licensing-advisor"))
        XCTAssertTrue(AdvisorSafety.isRegulated("medical-researcher"))
        XCTAssertFalse(AdvisorSafety.isRegulated("comedian"))
        XCTAssertFalse(AdvisorSafety.isRegulated("swift-engineer"))
    }
}
