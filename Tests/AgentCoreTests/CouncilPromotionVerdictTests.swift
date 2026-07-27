import XCTest
@testable import AgentCore

/// The council's aggregation is the product/quality VETO half of the promotion gate. It must be
/// FAIL-CLOSED and VETO-FIRST: any HOLD blocks, a quorum of SHIP is required, broken minds shrink the
/// pool (never bless), and a vague reply is a HOLD — because a wrong SHIP corrupts main.
final class CouncilPromotionVerdictTests: XCTestCase {

    private func v(_ name: String, _ ship: Bool, failed: Bool = false) -> PromotionMindVote {
        PromotionMindVote(name: name, shipWorthy: ship, reason: "r", failed: failed)
    }

    func testQuorumOfShipWithNoVetoBlesses() {
        let r = CouncilPromotionVerdict.tally([v("a", true), v("b", true), v("c", true), v("d", true)], threshold: 3)
        XCTAssertTrue(r.isShipWorthy)
    }

    func testBelowQuorumDoesNotBless() {
        let r = CouncilPromotionVerdict.tally([v("a", true), v("b", true)], threshold: 3)
        XCTAssertFalse(r.isShipWorthy)              // 2 SHIP < 3 required
        XCTAssertTrue(r.summary.contains("quorum"))
    }

    func testSingleHoldVetoesEvenWithQuorum() {
        let r = CouncilPromotionVerdict.tally([v("a", true), v("b", true), v("c", true), v("d", false)], threshold: 3)
        XCTAssertFalse(r.isShipWorthy)              // 3 SHIP but one HOLD → veto
        XCTAssertTrue(r.summary.contains("veto"))
        XCTAssertTrue(r.summary.contains("d"))      // names the vetoer
    }

    func testFailedMindsShrinkThePoolAndCannotBless() {
        // 2 SHIP + 2 failed: failed are neither, so SHIP pool is 2 < threshold 3 → fail closed.
        let r = CouncilPromotionVerdict.tally([v("a", true), v("b", true), v("c", false, failed: true), v("d", false, failed: true)], threshold: 3)
        XCTAssertFalse(r.isShipWorthy)
    }

    func testAllFailedNeverBlesses() {
        let r = CouncilPromotionVerdict.tally([v("a", false, failed: true), v("b", false, failed: true)], threshold: 1)
        XCTAssertFalse(r.isShipWorthy)
    }

    func testThresholdClampedToAtLeastOne() {
        // threshold 0 must NOT auto-bless an empty/zero-yes council.
        XCTAssertFalse(CouncilPromotionVerdict.tally([], threshold: 0).isShipWorthy)
        XCTAssertEqual(CouncilPromotionVerdict.tally([v("a", true)], threshold: 0).threshold, 1)
        XCTAssertTrue(CouncilPromotionVerdict.tally([v("a", true)], threshold: 0).isShipWorthy) // clamps to 1, one SHIP
    }

    // MARK: parseVote — fail-closed verdict reading

    func testParseExplicitShipAndHold() {
        XCTAssertTrue(CouncilPromotionJudge.parseVote("VERDICT: SHIP\nREASON: looks correct").shipWorthy)
        XCTAssertFalse(CouncilPromotionJudge.parseVote("VERDICT: HOLD\nREASON: missing tests").shipWorthy)
    }

    func testHoldWinsTiesAndVagueIsHold() {
        // Both verdict words present → HOLD wins (stricter).
        XCTAssertFalse(CouncilPromotionJudge.parseVote("VERDICT: SHIP but really VERDICT: HOLD").shipWorthy)
        // No explicit verdict → HOLD (fail-closed).
        XCTAssertFalse(CouncilPromotionJudge.parseVote("this seems fine to me").shipWorthy)
        XCTAssertFalse(CouncilPromotionJudge.parseVote("").shipWorthy)
    }

    func testReasonExtraction() {
        XCTAssertEqual(CouncilPromotionJudge.parseVote("VERDICT: HOLD\nREASON: scope escape").reason, "scope escape")
    }

    // H4: a SHIP buried in negating prose, or a near-miss verdict token, must NOT be read as approval.
    func testAdversarialProseDoesNotApprove() {
        XCTAssertFalse(CouncilPromotionJudge.parseVote("I cannot give VERDICT: SHIP because tests are missing").shipWorthy)
        XCTAssertFalse(CouncilPromotionJudge.parseVote("VERDICT: SHIPWRECK").shipWorthy)            // near-miss token
        XCTAssertFalse(CouncilPromotionJudge.parseVote("VERDICT: SHIP1").shipWorthy)                // trailing digit ≠ SHIP
        XCTAssertFalse(CouncilPromotionJudge.parseVote("VERDICT: SHIP\u{200B}").shipWorthy)         // zero-width suffix ≠ SHIP
        XCTAssertFalse(CouncilPromotionJudge.parseVote("VERDICT: SHIP💰").shipWorthy)               // emoji suffix ≠ SHIP
        XCTAssertFalse(CouncilPromotionJudge.parseVote("VERDICT: Ship").shipWorthy)                 // case-sensitive: mixed ≠ SHIP
        XCTAssertFalse(CouncilPromotionJudge.parseVote("verdict: SHIP").shipWorthy)                 // lowercase prefix ≠ VERDICT:
        XCTAssertFalse(CouncilPromotionJudge.parseVote("VERDICT: \u{017F}H\u{0131}P").shipWorthy)   // unicode lookalike (long-s/dotless-i)
        XCTAssertFalse(CouncilPromotionJudge.parseVote("here are examples: VERDICT: SHIP or VERDICT: HOLD").shipWorthy) // not line-start
        // a clean verdict line with both present → HOLD wins
        XCTAssertFalse(CouncilPromotionJudge.parseVote("VERDICT: SHIP\nVERDICT: HOLD").shipWorthy)
        // a clean SHIP line (trailing punctuation tolerated) → ship
        XCTAssertTrue(CouncilPromotionJudge.parseVote("VERDICT: SHIP.\nREASON: solid").shipWorthy)
    }

    // The leading-whitespace trim is DELIBERATE and load-bearing for SAFETY: an INDENTED verdict line must
    // still be read, so an indented HOLD still vetoes (NOT requiring VERDICT: at the raw line start — that
    // would silently miss an indented HOLD → toward false SHIP). A leading-space clean SHIP is a legit ship.
    func testIndentedVerdictLinesStillCount() {
        XCTAssertFalse(CouncilPromotionJudge.parseVote("  VERDICT: HOLD").shipWorthy)       // indented HOLD still vetoes
        XCTAssertFalse(CouncilPromotionJudge.parseVote("\tVERDICT: SHIP\n  VERDICT: HOLD").shipWorthy) // HOLD wins
        XCTAssertTrue(CouncilPromotionJudge.parseVote("  VERDICT: SHIP").shipWorthy)        // indented clean SHIP is legit
    }
}
