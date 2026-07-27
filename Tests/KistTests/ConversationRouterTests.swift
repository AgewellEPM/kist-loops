import XCTest
@testable import Kist

/// The router's deterministic pre-filter (isObviouslyChat) gates whether a classifier call even happens —
/// it must let plain conversation through inline (no escalation, no LLM cost) while letting substantive
/// build-shaped requests reach the model. The LLM classify() itself is live-verify, not unit-tested.
final class ConversationRouterTests: XCTestCase {

    func testObviousChatIsRecognized() {
        // Short, questions, and explainer openers → never escalate (handled inline as chat).
        XCTAssertTrue(ConversationRouter.isObviouslyChat("what is a closure?"))
        XCTAssertTrue(ConversationRouter.isObviouslyChat("why does this crash?"))
        XCTAssertTrue(ConversationRouter.isObviouslyChat("explain the supervisor loop"))
        XCTAssertTrue(ConversationRouter.isObviouslyChat("how do I run the tests"))
        XCTAssertTrue(ConversationRouter.isObviouslyChat("tell me about the trust spine"))
        XCTAssertTrue(ConversationRouter.isObviouslyChat("fix typo"), "a tiny ask is chat-cheap")
        XCTAssertTrue(ConversationRouter.isObviouslyChat("is the fleet done?"), "ends with ? → chat")
        XCTAssertFalse(ConversationRouter.isObviouslyChat(
            "Can you build a REST API with separate billing and notification modules with tests?"),
            "build-shaped questions should still be eligible for routing")
    }

    func testSubstantiveBuildRequestsReachTheClassifier() {
        // Long, imperative, multi-part build requests are NOT obviously chat → the classifier runs.
        XCTAssertFalse(ConversationRouter.isObviouslyChat(
            "Build a REST API with separate user, billing, and notification modules each with tests"))
        XCTAssertFalse(ConversationRouter.isObviouslyChat(
            "Refactor the persistence layer and add a caching module and a migration runner"))
    }

    func testClassifierReplyMustBeAOneWordRoute() {
        XCTAssertEqual(ConversationRouter.parseRoute("fleet", defaultFleetAgents: 4), .fleet(agents: 4))
        XCTAssertEqual(ConversationRouter.parseRoute("```text\nplan\n```", defaultFleetAgents: 4), .planExecute)
        XCTAssertEqual(ConversationRouter.parseRoute("council", defaultFleetAgents: 4), .council)
        XCTAssertEqual(ConversationRouter.parseRoute("research", defaultFleetAgents: 4), .council)
        XCTAssertNil(ConversationRouter.parseRoute("not fleet", defaultFleetAgents: 4))
        XCTAssertNil(ConversationRouter.parseRoute("I would choose plan.", defaultFleetAgents: 4))
        XCTAssertNil(ConversationRouter.parseRoute("build", defaultFleetAgents: 4))
    }

    func testDeepResearchRequestsReachTheClassifier() {
        XCTAssertFalse(ConversationRouter.isObviouslyChat(
            "Research the future of agentic coding systems and make a product roadmap for our system"))
        XCTAssertFalse(ConversationRouter.isObviouslyChat(
            "Do a deep dive landscape analysis and cross compare the competitors"))
    }
}
