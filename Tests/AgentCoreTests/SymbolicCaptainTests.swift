import XCTest
@testable import AgentCore

/// Pin the deterministic Captain's judgments: the STRUCTURAL referee (one assertion per invariant),
/// the DRIFT alarm (rules green, world unconfirmed — incl. no-signal and tamper), DETERMINISM incl.
/// output ORDERING, the rulebook AUDIT, and the build-scoped world-fact invariant (a build with no
/// confirmation of ITS OWN drifts — never false-greens off another build's history).
final class SymbolicCaptainTests: XCTestCase {

    /// A clean, shippable, world-confirmed build. Override one field per test.
    private func facts(claimedDone: Bool = true, testsGreen: Bool = true, diffPresent: Bool = true,
                       codexReviewed: Bool = true, maxFileLines: Int = 200, stepCapHit: Bool = false,
                       runIncomplete: Bool = false,
                       confirmedHelp: Int = 1, signalBroken: Bool = false, hasSignal: Bool = true,
                       buildID: String = "B1") -> CaptainFacts {
        CaptainFacts(
            build: BuildFacts(buildID: buildID, claimedDone: claimedDone,
                              tests: TestRunEvidence(exitCode: testsGreen ? 0 : 1),
                              diff: DiffEvidence(changedLines: diffPresent ? 10 : 0, maxFileLines: maxFileLines),
                              codex: CodexEvidence(reviewed: codexReviewed), stepCapHit: stepCapHit,
                              runIncomplete: runIncomplete),
            world: WorldFacts(confirmedHelpForBuild: confirmedHelp, signalBroken: signalBroken, hasSignal: hasSignal))
    }
    private let cap = SymbolicCaptain()

    // MARK: Green
    func testGreenWhenAllInvariantsHoldAndHelpConfirmed() {
        let j = cap.judge(facts())
        XCTAssertEqual(j.verdict, .green)
        XCTAssertTrue(j.failedBlockers.isEmpty)
        XCTAssertNil(j.driftReason)
    }

    // MARK: Structural referee — one assertion per invariant
    func testMonolithBlocks() {
        let j = cap.judge(facts(maxFileLines: 1600))
        XCTAssertEqual(j.verdict, .blocked)
        XCTAssertTrue(j.failedBlockers.contains("monolith_limit"))
    }
    func testDoneNeedsTests() { XCTAssertTrue(cap.judge(facts(testsGreen: false)).failedBlockers.contains("done_needs_tests")) }
    func testDoneNeedsDiff() { XCTAssertTrue(cap.judge(facts(diffPresent: false)).failedBlockers.contains("done_needs_diff")) }
    func testDoneNeedsCodex() { XCTAssertTrue(cap.judge(facts(codexReviewed: false)).failedBlockers.contains("done_needs_codex")) }
    func testStepCapIsNotDone() { XCTAssertTrue(cap.judge(facts(stepCapHit: true)).failedBlockers.contains("stepcap_is_not_done")) }

    func testGatesOnlyBiteADoneClaim() {
        let j = cap.judge(facts(claimedDone: false, diffPresent: false, codexReviewed: false, confirmedHelp: 0))
        XCTAssertEqual(j.verdict, .green, "no 'done' claim → the done-gates and drift are not applicable")
    }

    // MARK: Drift — the alarm (rules green, world unconfirmed)
    func testDriftWhenProxyGreenButZeroConfirmedHelp() {
        let j = cap.judge(facts(confirmedHelp: 0))
        XCTAssertEqual(j.verdict, .driftFlagged)
        XCTAssertTrue(j.driftReason?.contains("world says nothing") ?? false)
        XCTAssertTrue(j.failedBlockers.isEmpty, "drift is not a process violation")
    }
    func testDriftWhenNoWorldSignalWired() {
        let j = cap.judge(facts(confirmedHelp: 0, hasSignal: false))
        XCTAssertEqual(j.verdict, .driftFlagged)
        XCTAssertTrue(j.worldSignalMissing)
        XCTAssertTrue(j.driftReason?.contains("NO world-signal") ?? false)
    }
    func testDriftWhenWorldSignalBrokenEvenWithHelp() {
        let j = cap.judge(facts(confirmedHelp: 5, signalBroken: true))
        XCTAssertEqual(j.verdict, .driftFlagged, "tamper invalidates any confirmation count")
        XCTAssertTrue(j.driftReason?.contains("integrity") ?? false)
    }

    // MARK: Precedence — a process violation outranks drift, but drift is still reported
    func testBlockerOutranksDriftButDriftStillReported() {
        let j = cap.judge(facts(codexReviewed: false, confirmedHelp: 0))
        XCTAssertEqual(j.verdict, .blocked, "a process violation is the hardest no")
        XCTAssertTrue(j.failedBlockers.contains("done_needs_codex"))
        XCTAssertNotNil(j.driftReason, "drift is still surfaced even when blocked")
    }

    // MARK: Determinism — value AND output ordering
    func testJudgmentIsDeterministic() {
        let f = facts(confirmedHelp: 0)
        XCTAssertEqual(cap.judge(f), cap.judge(f), "same facts must always yield the same judgment")
    }
    func testFailedBlockersInStableDeclarationOrder() {
        // monolith_limit is declared first, done_needs_codex later. Trigger both.
        let j = cap.judge(facts(codexReviewed: false, maxFileLines: 1600))
        XCTAssertEqual(j.failedBlockers, ["monolith_limit", "done_needs_codex"],
                       "blockers come out in stable declaration order — no unordered accumulation")
    }

    // MARK: The "are the rules right?" surface
    func testDefaultRulebookHasNoUngroundedProxies() {
        XCTAssertTrue(cap.judge(facts()).ungroundedProxies.isEmpty)
        let audit = cap.auditRules()
        XCTAssertEqual(audit.structural, 6)
        XCTAssertEqual(audit.groundedProxies, 1)
        XCTAssertTrue(audit.ungroundedProxies.isEmpty)
        XCTAssertEqual(audit.structuralFraction, 6.0 / 7.0, accuracy: 0.001)
    }

    /// An incomplete run (killed / step-capped / aborted) must NEVER fall through every done-gated rule
    /// to a false green — it is blocked unconditionally.
    func testIncompleteRunIsBlockedNotGreen() {
        let j = cap.judge(facts(claimedDone: false, runIncomplete: true))
        XCTAssertEqual(j.verdict, .blocked, "an aborted run is not green")
        XCTAssertTrue(j.failedBlockers.contains("run_must_complete"))
    }
    func testUngroundedProxyIsReported() {
        let rogue = ProxyRule(id: "vibes_ok", summary: "ships if it feels right",
                              truthCorrespondent: nil, check: { _, _ in .pass })
        let captain = SymbolicCaptain(structural: [], proxies: [rogue])
        XCTAssertTrue(captain.judge(facts()).ungroundedProxies.contains("vibes_ok"))
        XCTAssertEqual(captain.auditRules().ungroundedProxies, ["vibes_ok"])
    }

    /// BUILD-SCOPING INVARIANT (Stage 1.4 adaptation of the Conscience-sourced test): the same identical
    /// build facts drift vs green based SOLELY on whether THIS build carries a confirmed outcome. A
    /// build with confirmedHelp=0 drifts even though everything else is green — it cannot false-green
    /// off a sibling build's confirmation, because confirmedHelpForBuild is build-scoped at the source.
    func testWorldFactConfirmationIsTheOnlyDifferenceBetweenGreenAndDrift() {
        let confirmed = cap.judge(facts(confirmedHelp: 1, buildID: "B1"))
        let unconfirmed = cap.judge(facts(confirmedHelp: 0, buildID: "B2"))
        XCTAssertEqual(confirmed.verdict, .green, "B1 has its own confirmed outcome → green")
        XCTAssertEqual(unconfirmed.verdict, .driftFlagged,
                       "B2 with no confirmation of ITS OWN drifts — never inherits B1's green")
    }
}
