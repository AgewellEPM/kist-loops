import XCTest
@testable import AgentCore

/// The baton is the forge-proof handoff token. Its legality lives in ONE place (BatonState.canTransition);
/// these tests pin the full state machine, the single-mutator `advanced` (nil on illegal), append-only
/// context, the deadline predicate, and additive decode.
final class BatonTests: XCTestCase {

    private func baton(_ state: BatonState = .created, deadline: Double? = nil) -> Baton {
        Baton(fleetID: UUID(), missionGoal: "ship", repo: "/r", state: state, deadlineEpoch: deadline)
    }

    // MARK: state machine — the §4 backbone, every legal + illegal edge

    func testLegalTransitions() {
        XCTAssertTrue(BatonState.created.canTransition(to: .held))
        XCTAssertTrue(BatonState.held.canTransition(to: .submitted))
        XCTAssertTrue(BatonState.held.canTransition(to: .timedOut))
        XCTAssertTrue(BatonState.submitted.canTransition(to: .verified))
        XCTAssertTrue(BatonState.submitted.canTransition(to: .rejected))
        XCTAssertTrue(BatonState.verified.canTransition(to: .passed))
        XCTAssertTrue(BatonState.rejected.canTransition(to: .held))     // retry
        XCTAssertTrue(BatonState.rejected.canTransition(to: .failed))   // budget exhausted
        XCTAssertTrue(BatonState.timedOut.canTransition(to: .failed))
        XCTAssertTrue(BatonState.timedOut.canTransition(to: .held))     // manual re-hand
    }

    func testIllegalTransitionsAreRefused() {
        XCTAssertFalse(BatonState.created.canTransition(to: .verified), "can't skip straight to verified")
        XCTAssertFalse(BatonState.held.canTransition(to: .passed), "must be verified before passed")
        XCTAssertFalse(BatonState.submitted.canTransition(to: .passed), "foreman must verify first")
        XCTAssertFalse(BatonState.verified.canTransition(to: .rejected), "a verified baton can't be rejected")
        XCTAssertFalse(BatonState.created.canTransition(to: .created), "no self-loop")
    }

    func testTerminalStatesHaveNoExit() {
        XCTAssertTrue(BatonState.passed.isTerminal)
        XCTAssertTrue(BatonState.failed.isTerminal)
        for next in [BatonState.created, .held, .submitted, .verified, .passed, .rejected, .timedOut, .failed] {
            XCTAssertFalse(BatonState.passed.canTransition(to: next), "passed is terminal")
            XCTAssertFalse(BatonState.failed.canTransition(to: next), "failed is terminal")
        }
        XCTAssertFalse(BatonState.held.isTerminal)
    }

    // MARK: advanced() — the single mutator, gated by legality

    func testAdvancedRecordsHopOnLegalTransition() throws {
        let b = baton(.created)
        let held = try XCTUnwrap(b.advanced(to: .held, from: "captain", to: "agentA", atEpoch: 10))
        XCTAssertEqual(held.state, .held)
        XCTAssertEqual(held.lineage.count, 1)
        XCTAssertEqual(held.lineage.last?.from, "captain")
        XCTAssertEqual(held.lineage.last?.to, "agentA")
        XCTAssertEqual(held.lineage.last?.state, .held)
    }

    func testAdvancedReturnsNilAndDoesNotMutateOnIllegalTransition() {
        let b = baton(.created)
        XCTAssertNil(b.advanced(to: .passed, from: "x", to: "y", atEpoch: 1),
                     "an illegal transition yields nil — the supervisor must not write it")
        XCTAssertEqual(b.state, .created, "the original is untouched (value type, no mutation)")
        XCTAssertTrue(b.lineage.isEmpty)
    }

    // MARK: append-only proven context

    func testAppendingContributionIsAppendOnly() {
        let c = BatonContribution(subtaskTitle: "parser", branch: "mythos/a", commitSHA: "abc",
                                  summary: "did the parser", signoffSeq: 0, evidence: "tests green", signedAtEpoch: 5)
        let b1 = baton(.verified).appendingContribution(c)
        XCTAssertEqual(b1.accumulatedContext.count, 1)
        let c2 = BatonContribution(subtaskTitle: "lexer", branch: "mythos/b", commitSHA: "def",
                                   summary: "did the lexer", signoffSeq: 1, evidence: "tests green", signedAtEpoch: 6)
        let b2 = b1.appendingContribution(c2)
        XCTAssertEqual(b2.accumulatedContext.map(\.subtaskTitle), ["parser", "lexer"], "both proven slices kept, in order")
    }

    // MARK: deadline predicate

    func testIsPastDeadline() {
        XCTAssertFalse(baton(.held, deadline: nil).isPastDeadline(nowEpoch: 9_999), "no deadline never times out")
        XCTAssertFalse(baton(.held, deadline: 100).isPastDeadline(nowEpoch: 100), "at the deadline is not past it")
        XCTAssertTrue(baton(.held, deadline: 100).isPastDeadline(nowEpoch: 101), "past the deadline")
    }

    // MARK: persistence + additive decode

    func testRoundTrips() throws {
        let b = baton(.held, deadline: 500).advanced(to: .submitted, from: "a", to: "captain", atEpoch: 3)!
        let data = try JSONEncoder().encode(b)
        let back = try JSONDecoder().decode(Baton.self, from: data)
        XCTAssertEqual(back.state, .submitted)
        XCTAssertEqual(back.deadlineEpoch, 500)
        XCTAssertEqual(back.lineage.count, 1)
    }

    func testAdditiveDecodeToleratesOldBaton() throws {
        // Only the genesis-required fields. Must decode with safe defaults.
        let json = #"""
        {"id":"\#(UUID().uuidString)","fleetID":"\#(UUID().uuidString)","missionGoal":"g","repo":"/r","state":"created"}
        """#
        let b = try JSONDecoder().decode(Baton.self, from: Data(json.utf8))
        XCTAssertEqual(b.state, .created)
        XCTAssertNil(b.holder)
        XCTAssertTrue(b.accumulatedContext.isEmpty)
        XCTAssertEqual(b.rejectCount, 0)
    }

    func testUnknownStateRawValueIsRejected() {
        let json = #"{"id":"\#(UUID().uuidString)","fleetID":"\#(UUID().uuidString)","missionGoal":"g","repo":"/r","state":"warpspeed"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Baton.self, from: Data(json.utf8)),
                             "an unknown state must NOT be coerced to a wrong-but-known one")
    }
}
