import XCTest
@testable import Kist

/// `/ballbusting` — the contract IS the product. If the system prompt ever softens (opens with praise,
/// stops demanding a fix per finding, or drops the no-gaslight rule) the command silently becomes the
/// polite reviewer Luke was fed up with. These pin it.
final class BallBustingTests: XCTestCase {

    func testSystemPromptForbidsGaslightingAndDemandsFixes() {
        let s = BallBusting.systemPrompt.lowercased()
        XCTAssertTrue(s.contains("never gaslight"), "must forbid gaslighting")
        XCTAssertTrue(s.contains("do not open with praise") || s.contains("not open with praise"),
                      "must forbid the praise-opening")
        XCTAssertTrue(s.contains("lgtm"), "must explicitly ban 'LGTM'-style softening")
        XCTAssertTrue(s.contains("concrete change") || s.contains("propose the concrete"),
                      "must demand a concrete fix per finding")
        // Honesty guard: it must NOT be told to fabricate problems.
        XCTAssertTrue(s.contains("do not invent problems") || s.contains("not invent problems"),
                      "must forbid inventing problems (honesty over theater)")
        XCTAssertTrue(s.contains("🟥") && s.contains("🟩"), "must carry the blunt rating scale")
    }

    func testPromptEmbedsSubjectAndGrounding() {
        let p = BallBusting.prompt(subject: "let x = broken()", label: "the working-tree diff",
                                   grounding: "RULE: files under 1000 lines")
        XCTAssertTrue(p.contains("the working-tree diff"), "labels the subject")
        XCTAssertTrue(p.contains("let x = broken()"), "includes the actual subject")
        XCTAssertTrue(p.contains("RULE: files under 1000 lines"), "includes project grounding to judge against")
        XCTAssertTrue(p.lowercased().contains("do not soften"), "the ask itself reinforces no-softening")
    }

    func testPromptOmitsEmptyGroundingCleanly() {
        let p = BallBusting.prompt(subject: "x", label: "your plan", grounding: "   \n  ")
        XCTAssertFalse(p.contains("PROJECT CONTEXT"), "no empty grounding block when there's no grounding")
        XCTAssertTrue(p.contains("your plan"))
    }
}
