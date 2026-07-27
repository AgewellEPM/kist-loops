import XCTest
@testable import AgentCore

/// The verify-and-sign gate, exercised with INJECTED seams (no real git/shell). Each test pins one
/// distinct gate behavior and asserts the ACTUAL guarantee: a real measured GREEN seals a signoff into
/// the ledger; every failure class is BLOCKED with precise corrective context and NO signoff.
final class ForemanTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        ForgeSeal.forceEphemeralKeyForTesting()   // fresh per-test seal key, no disk write
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForemanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    // MARK: fake-seam factory

    private func makeForeman(
        ledger: FleetSignoffLedger,
        commits: Int = 1, diff: String = "+ a change", changed: [String] = ["Foo.swift"],
        maxLines: Int = 200, exit: Int32 = 0, dirtyAfterTest: [String] = [], codex: Bool = false,
        claims: AgentClaims? = nil, claimFiles: [String] = ["Foo.swift"], claimDiff: String = "+ a change",
        leaseRequired: Bool = false, claimsRequired: Bool = false, acceptanceTestRequired: Bool = false,
        heldOut: Int32?? = nil   // .none = no held-out runner wired (abstain); .some(x) = runner returns x
    ) -> Foreman {
        Foreman(
            ledger: ledger, leaseRequired: leaseRequired, claimsRequired: claimsRequired,
            acceptanceTestRequired: acceptanceTestRequired,
            commitCount: { _ in commits }, diff: { _ in diff }, changedPaths: { _ in changed },
            maxFileLines: { _, _ in maxLines }, runTests: { _ in exit },
            runHeldOutTests: heldOut.map { v in { _ in v } },
            trackedDirty: { _ in dirtyAfterTest },
            codexReviewed: { _ in codex },
            readClaims: { _ in claims }, claimEvidence: { _ in (claimFiles, claimDiff) })
    }

    // MARK: reward-hacking gap (held-out evaluator)

    // Visible GREEN but HELD-OUT RED ⇒ the reward-hacking signal is ADVISORY, not blocking (it can't
    // distinguish gaming from a legit API change). The signoff STILL seals green, but its evidence carries
    // a HELD-OUT ADVISORY for human review — so a legit refactor is never false-blocked.
    func testRewardHackingGapIsAdvisoryNotBlocking() async {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let s = subject()
        let r = await makeForeman(ledger: ledger, exit: 0, heldOut: .some(1)).inspect(subject: s, goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .green, "a held-out gap is advisory — it does NOT block the signoff")
        XCTAssertNotNil(r.signoff)
        XCTAssertTrue(r.failedBlockers.isEmpty)
        XCTAssertTrue(r.evidence.contains("HELD-OUT ADVISORY"), "the gap is surfaced for review: \(r.evidence)")
        XCTAssertTrue(ledger.signedOff(agentID: s.agentID))
    }

    // Held-out GREEN ⇒ no gap ⇒ the green still seals normally.
    func testHeldOutGreenStillSignsOff() async {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let s = subject()
        let r = await makeForeman(ledger: ledger, exit: 0, heldOut: .some(0)).inspect(subject: s, goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .green, "visible + held-out both green ⇒ green")
        XCTAssertTrue(ledger.signedOff(agentID: s.agentID))
    }

    // NO held-out runner wired ⇒ the guard ABSTAINS (never invents an unmeasured gap) ⇒ unchanged behavior.
    func testNoHeldOutRunnerAbstainsAndSigns() async {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let s = subject()
        let r = await makeForeman(ledger: ledger, exit: 0, heldOut: nil).inspect(subject: s, goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .green, "no held-out suite ⇒ abstain ⇒ a clean visible green still signs")
        XCTAssertTrue(ledger.signedOff(agentID: s.agentID))
    }

    // A WIRED held-out runner that RETURNS NIL (suite couldn't run / no held-out applicable) also abstains
    // — distinct from "no runner at all": the runner exists but reports nil ⇒ .noHeldOut, never a gap.
    func testWiredHeldOutRunnerReturningNilAbstains() async {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let s = subject()
        let r = await makeForeman(ledger: ledger, exit: 0, heldOut: .some(nil)).inspect(subject: s, goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .green, "a wired runner returning nil ⇒ abstain ⇒ clean green still signs")
        XCTAssertTrue(ledger.signedOff(agentID: s.agentID))
    }

    // A visible-RED is NOT mislabeled as reward-hacking — it's a normal failure the referee handles; the
    // gap gate only fires on the genuine visible-green+held-out-red signature.
    func testVisibleRedNotMislabeledAsRewardHacking() async {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let r = await makeForeman(ledger: ledger, exit: 1, heldOut: .some(1)).inspect(subject: subject(), goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .blocked)
        XCTAssertFalse(r.failedBlockers.contains("reward_hacking_gap"), "a visible-red is a normal fail, not a reward-hacking gap")
    }

    private func subject(scope: [String] = [], criterion: String = "") -> ForemanSubject {
        ForemanSubject(agentID: UUID(), branch: "feat/x", worktreePath: tempDir.path,
                       baseSHA: "base", scopeGlobs: scope, title: "subtask", acceptanceCriterion: criterion)
    }

    // MARK: green — a real measured pass seals a signoff

    func testMeasuredGreenSealsSignoffIntoLedger() async {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let f = makeForeman(ledger: ledger)
        let s = subject()
        let r = await f.inspect(subject: s, goalID: "G", nowEpoch: 1)

        XCTAssertEqual(r.verdict, .green, "commits + diff + tests-pass + small files ⇒ green")
        XCTAssertTrue(r.isGreen)
        XCTAssertNotNil(r.signoff, "a green seals a signoff")
        XCTAssertTrue(r.failedBlockers.isEmpty)
        XCTAssertTrue(ledger.signedOff(agentID: s.agentID), "the signoff actually landed in the ledger")
        XCTAssertNil(ledger.verifyChain(), "the ledger chain is intact")
    }

    func testLedgerRecordFailureBlocksInsteadOfReturningGreenWithoutSignoff() async throws {
        let notADirectory = tempDir.appendingPathComponent("not-a-directory")
        try Data("file, not dir".utf8).write(to: notADirectory)
        let ledger = FleetSignoffLedger(baseDir: notADirectory)
        let f = makeForeman(ledger: ledger)
        let s = subject()

        let r = await f.inspect(subject: s, goalID: "G", nowEpoch: 1)

        XCTAssertEqual(r.verdict, .blocked,
                       "a report must not be green unless the ledger actually sealed + persisted it")
        XCTAssertEqual(r.failedBlockers, ["signoff_record_failed"])
        XCTAssertFalse(r.isGreen)
        XCTAssertNil(r.signoff)
        XCTAssertTrue(ledger.all().isEmpty, "the failed record left no in-memory proof row")
    }

    func testFleetCaptainExcludesCodexBlockerSoGreenWithoutReview() async {
        // codexReviewed=false (default) must NOT block — code review is a downstream promotion gate.
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let r = await makeForeman(ledger: ledger, codex: false).inspect(subject: subject(), goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .green, "the fleet referee omits done_needs_codex")
    }

    // MARK: blocked — each failure class, with no signoff

    func testNoCommitIsBlockedOnDiff() async {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let s = subject()
        let r = await makeForeman(ledger: ledger, commits: 0).inspect(subject: s, goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .blocked)
        XCTAssertTrue(r.failedBlockers.contains("done_needs_diff"), "no commit ⇒ no diff ⇒ blocked")
        XCTAssertEqual(r.changedLines, 0)
        XCTAssertNil(r.signoff)
        XCTAssertFalse(ledger.signedOff(agentID: s.agentID))
    }

    func testFailingTestsAreBlocked() async {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let r = await makeForeman(ledger: ledger, exit: 1).inspect(subject: subject(), goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .blocked)
        XCTAssertTrue(r.failedBlockers.contains("done_needs_tests"))
        XCTAssertEqual(r.testExitCode, 1)
        XCTAssertNil(r.signoff)
    }

    func testMissingTestRunMapsToFailingNeverGreen() async {
        // runTests returns nil (script unlaunchable) → mapped to exit 1 → blocked, never a silent green.
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let f = Foreman(ledger: ledger, commitCount: { _ in 1 }, diff: { _ in "+ x" },
                        changedPaths: { _ in ["Foo.swift"] }, maxFileLines: { _, _ in 100 },
                        runTests: { _ in nil }, codexReviewed: { _ in false },
                        readClaims: { _ in nil }, claimEvidence: { _ in ([], "") })
        let r = await f.inspect(subject: subject(), goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .blocked)
        XCTAssertEqual(r.testExitCode, 1, "nil exit maps to a failing code")
    }

    func testMonolithIsBlocked() async {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let r = await makeForeman(ledger: ledger, maxLines: 1600).inspect(subject: subject(), goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .blocked)
        XCTAssertTrue(r.failedBlockers.contains("monolith_limit"))
        XCTAssertNil(r.signoff)
    }

    func testTrackedDirtyAfterTestBlocksEvenWhenTestsPass() async {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let s = subject()
        let f = makeForeman(ledger: ledger, dirtyAfterTest: ["Feature.swift"])

        let r = await f.inspect(subject: s, goalID: "G", nowEpoch: 1)

        XCTAssertEqual(r.verdict, .blocked,
                       "a passing test cannot sign off bytes it rewrote after the committed snapshot")
        XCTAssertEqual(r.failedBlockers, ["tree_dirty_after_test"])
        XCTAssertTrue(r.evidence.contains("Feature.swift"))
        XCTAssertNil(r.signoff)
        XCTAssertFalse(ledger.signedOff(agentID: s.agentID))
    }

    // MARK: lease (C10 — enforced AT SIGNOFF, not just at the merge gate; mandatory when flagged)

    func testOutOfLeaseWriteBlocksSignoff() async {
        // C10: an agent that DECLARED a lease and committed outside it is refused at signoff (was
        // record-only-and-defer-to-merge). Off-lease work can no longer seal a green.
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let f = makeForeman(ledger: ledger, changed: ["Other/Bar.swift"])
        let s = subject(scope: ["Core/*"])
        let r = await f.inspect(subject: s, goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .blocked, "an out-of-lease commit must be refused at signoff")
        XCTAssertEqual(r.failedBlockers, ["out_of_lease"])
        XCTAssertEqual(r.outOfScopePaths, ["Other/Bar.swift"], "the escape is measured + surfaced")
        XCTAssertNil(r.signoff)
        XCTAssertFalse(ledger.signedOff(agentID: s.agentID),
                       "the inspected agent leaves no sealed signoff")
    }

    func testInLeaseWriteStillSignsGreen() async {
        // Contrast: a change fully inside the declared lease still seals green — the block is specific to
        // ESCAPES, not a blanket lease penalty.
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let f = makeForeman(ledger: ledger, changed: ["Core/A.swift"])
        let r = await f.inspect(subject: subject(scope: ["Core/*"]), goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .green, "in-lease work is unaffected")
        XCTAssertTrue(r.outOfScopePaths.isEmpty)
        XCTAssertNotNil(r.signoff)
    }

    func testMixedInAndOutOfLeaseStillBlocks() async {
        // A PARTIAL escape (some files in-lease, some out) must still block — ANY out-of-lease commit
        // invalidates the signoff; it does not require ALL paths to be out-of-scope (council: MiMo).
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let f = makeForeman(ledger: ledger, changed: ["Core/A.swift", "Other/Bar.swift"])
        let r = await f.inspect(subject: subject(scope: ["Core/*"]), goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .blocked)
        XCTAssertEqual(r.failedBlockers, ["out_of_lease"])
        XCTAssertEqual(r.outOfScopePaths, ["Other/Bar.swift"], "only the escapee is out-of-scope")
        XCTAssertNil(r.signoff)
    }

    func testValidatedLeaseRoundTripsIntoOutOfScope() {
        // Pin the contract Codex flagged as untested: the lease the VALIDATOR produces is exactly what
        // Foreman.outOfScopePaths enforces — so the agent is judged against the lease it was told.
        let v = FleetScopeValidator.validate(scopesPerStep: [["Core"]], knownDirs: ["Core"])
        let lease = v.scopesPerStep[0]   // "Core" canonicalizes to ["Core", "Core/*"]
        XCTAssertTrue(Foreman.outOfScopePaths(changed: ["Core/A.swift"], scopeGlobs: lease).isEmpty,
                      "a file under the leased dir is in-scope")
        XCTAssertEqual(Foreman.outOfScopePaths(changed: ["Other/B.swift"], scopeGlobs: lease), ["Other/B.swift"],
                       "a sibling dir is out-of-scope under the validated lease")
    }

    func testMandatoryLeaseRefusesUnscopedAgentBeforeMeasurement() async {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let r = await makeForeman(ledger: ledger, leaseRequired: true)
            .inspect(subject: subject(scope: []), goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .blocked)
        XCTAssertEqual(r.failedBlockers, ["done_needs_lease"])
        XCTAssertEqual(r.testExitCode, -1, "refused before any measurement")
    }

    // MARK: anti-hallucination — a contradicted claim blocks even a green referee

    func testContradictedClaimBlocksEvenWhenRefereeGreen() async {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let claims = AgentClaims(files: ["Ghost.swift"], symbols: [], testsPass: nil, actions: [])
        let s = subject()
        // Referee would be green (commits/diff/tests all pass), but the claimed file isn't in evidence.
        let f = makeForeman(ledger: ledger, claims: claims, claimFiles: ["Foo.swift"], claimDiff: "+ real")
        let r = await f.inspect(subject: s, goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .blocked, "a hallucinated claim blocks the signoff")
        XCTAssertTrue(r.failedBlockers.contains("claim_file_not_touched"))
        XCTAssertNil(r.signoff)
        XCTAssertFalse(ledger.signedOff(agentID: s.agentID))
    }

    func testHonestClaimDoesNotBlock() async {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let claims = AgentClaims(files: ["Foo.swift"], symbols: [], testsPass: true, actions: [])
        let f = makeForeman(ledger: ledger, claims: claims, claimFiles: ["Foo.swift"], claimDiff: "+ x")
        let r = await f.inspect(subject: subject(), goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .green, "claims that match the measured evidence pass through")
    }

    func testClaimsRequiredRefusesNoClaims() async {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let r = await makeForeman(ledger: ledger, claims: nil, claimsRequired: true)
            .inspect(subject: subject(), goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .blocked)
        XCTAssertTrue(r.failedBlockers.contains("claims_required"))
    }

    // MARK: acceptance test (G2/TDD, flag-gated)

    func testAcceptanceCriterionWithoutAddedTestIsBlocked() async {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let f = makeForeman(ledger: ledger, claimDiff: "+ func render() {}", acceptanceTestRequired: true)
        let r = await f.inspect(subject: subject(criterion: "renders the view"), goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .blocked)
        XCTAssertTrue(r.failedBlockers.contains("acceptance_test_missing"))
    }

    func testAcceptanceCriterionWithAddedTestPasses() async {
        let ledger = FleetSignoffLedger(baseDir: tempDir)
        let f = makeForeman(ledger: ledger,
                            claimDiff: "+    func testRenders() {\n+      // ...\n+    }",
                            acceptanceTestRequired: true)
        let r = await f.inspect(subject: subject(criterion: "renders the view"), goalID: "G", nowEpoch: 1)
        XCTAssertEqual(r.verdict, .green, "a committed test proving the criterion satisfies the gate")
    }

    // MARK: pure helpers

    func testOutOfScopePathsHelper() {
        XCTAssertEqual(Foreman.outOfScopePaths(changed: ["Core/A.swift", "Other/B.swift"],
                                               scopeGlobs: ["Core/*"]), ["Other/B.swift"])
        XCTAssertTrue(Foreman.outOfScopePaths(changed: ["Anything"], scopeGlobs: []).isEmpty,
                      "no declared lease ⇒ no invented violations")
    }

    func testRawWildcardLeaseCoversNothing() {
        XCTAssertEqual(Foreman.outOfScopePaths(changed: ["Core/A.swift", "Other/B.swift"],
                                               scopeGlobs: ["*"]),
                       ["Core/A.swift", "Other/B.swift"],
                       "a raw wildcard the validator would reject must not silence every escape")
        XCTAssertEqual(Foreman.outOfScopePaths(changed: ["Core/A.swift"],
                                               scopeGlobs: ["Core/A*"]),
                       ["Core/A.swift"],
                       "partial-component wildcards are malformed leases and cover nothing")
        XCTAssertEqual(Foreman.outOfScopePaths(changed: ["Core/A.swift", "Core/Sub/B.swift", "Other.swift"],
                                               scopeGlobs: ["Core/A.swift", "Core/Sub/*"]),
                       ["Other.swift"],
                       "canonical exact paths and canonical subtree globs still cover their files")
    }

    func testCanonicalLeaseGlobGrammar() {
        XCTAssertTrue(Foreman.isCanonicalLeaseGlob("Core/A.swift"))
        XCTAssertTrue(Foreman.isCanonicalLeaseGlob("Core/Sub/*"))
        XCTAssertFalse(Foreman.isCanonicalLeaseGlob("*"))
        XCTAssertFalse(Foreman.isCanonicalLeaseGlob("Core/A*"))
        XCTAssertFalse(Foreman.isCanonicalLeaseGlob("Core/*/A.swift"))
        XCTAssertFalse(Foreman.isCanonicalLeaseGlob("/*"))
        XCTAssertFalse(Foreman.isCanonicalLeaseGlob("   "))
    }

    func testBuildIDIsStableAndReproducible() {
        let id = UUID()
        let a = Foreman.buildID(goalID: "G", agentID: id, turnNumber: 3, claimHash: 42)
        let b = Foreman.buildID(goalID: "G", agentID: id, turnNumber: 3, claimHash: 42)
        XCTAssertEqual(a, b, "same components ⇒ same buildID (uuidString, not per-process hashValue)")
        XCTAssertTrue(a.contains(id.uuidString) && a.contains("@t3#42"))
    }
}
