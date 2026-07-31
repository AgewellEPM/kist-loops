import XCTest
@testable import AgentCore

final class EstateLookupIntentTests: XCTestCase {

    func testLookupQuestionsMatch() {
        XCTAssertTrue(EstateLookupIntent.matches("find what we did for tinkyspeak"))
        XCTAssertTrue(EstateLookupIntent.matches("what did we build for perslis?"))
        XCTAssertTrue(EstateLookupIntent.matches("where is the estate search code"))
        XCTAssertTrue(EstateLookupIntent.matches("what's the state of the tinky dashboard"))
        XCTAssertTrue(EstateLookupIntent.matches("show me our windows port work"))
        XCTAssertTrue(EstateLookupIntent.matches("how does your router work?"))
    }

    func testBuildTasksDoNotMatch() {
        // Build/creation tasks route to plan-execute, never to retrieval.
        XCTAssertFalse(EstateLookupIntent.matches("add a dark mode toggle to the settings page"))
        XCTAssertFalse(EstateLookupIntent.matches("create a new endpoint for uploads"))
        XCTAssertFalse(EstateLookupIntent.matches("implement the retry logic"))
        XCTAssertFalse(EstateLookupIntent.matches("fix the failing test in the parser"))
    }

    func testChitChatDoesNotMatch() {
        XCTAssertFalse(EstateLookupIntent.matches("ok"))
        XCTAssertFalse(EstateLookupIntent.matches("thanks!"))
        XCTAssertFalse(EstateLookupIntent.matches("hello there"))
    }

    func testSelfQuestionNeedsQuestionShape() {
        // A bare mention of "kist" isn't a lookup; a self QUESTION is.
        XCTAssertTrue(EstateLookupIntent.matches("how does kist verify work before done?"))
        XCTAssertFalse(EstateLookupIntent.matches("kist"))
    }

    func testSearchTermsKeepDistinctiveNounsDropFiller() {
        let terms = EstateLookupIntent.searchTerms("find what we did for tinkyspeak")
        XCTAssertEqual(terms, ["tinkyspeak"], "filler/question words drop; the project name survives")
    }

    func testSearchTermsAreDedupedAndCapped() {
        let terms = EstateLookupIntent.searchTerms("perslis perslis kist tinkyspeak jeeves cobol mythos router extra", limit: 4)
        XCTAssertEqual(terms.count, 4)
        XCTAssertEqual(Array(Set(terms)).count, 4, "no duplicates")
        XCTAssertEqual(terms.first, "perslis")
    }

    func testEmptyTermsWhenAllFiller() {
        XCTAssertTrue(EstateLookupIntent.searchTerms("what did we do").isEmpty,
                      "an all-filler question yields no terms → caller skips the search")
    }
}
