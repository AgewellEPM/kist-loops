import XCTest
@testable import AgentCore

/// The closed loop's control flow — every gate and every reject path — pinned with fake organs. This is the
/// anti-growth-hack spine. The current organs are advisory and therefore can never return `.promoted`;
/// even a provider-distinct pass is quarantined until a separately typed hard-contained path exists. The
/// explicit same-model grade remains fresh, separate, non-independent advisory evidence.
final class ClosedEvolutionLoopTests: XCTestCase {

    // MARK: fakes
    struct Author: CapabilityAuthor {
        let cand: CapabilityCandidate?
        func author(brief: String, culpritTool: String, signature: String) async -> CapabilityCandidate? { cand }
    }
    struct Gate: CandidateGate {
        let ok: Bool; let why: String
        func verify(_ c: CapabilityCandidate) async -> (passed: Bool, reason: String) { (ok, why) }
    }
    struct Veto: SymbolicVeto {
        let vetoed: Bool
        func veto(contract: String) async -> (vetoed: Bool, reason: String) { (vetoed, vetoed ? "contradiction" : "abstain") }
    }
    struct Adversary: CapabilityAdversary {
        let provider: String
        let verdict: AdversaryVerdict
        let reviewContext: EvolutionReviewContext

        init(provider: String, verdict: AdversaryVerdict,
             model: String = "review-model",
             grade: EvolutionReviewGrade = .independent,
             canonicalIdentity: String? = nil,
             invocationID: String = "critic-call",
             freshConversation: Bool = true) {
            self.provider = provider
            self.verdict = verdict
            self.reviewContext = EvolutionReviewContext(
                grade: grade, provider: provider, model: model,
                canonicalIdentity: canonicalIdentity ?? "\(provider):\(model)",
                invocationID: invocationID, freshConversation: freshConversation)
        }
        func attack(_ c: CapabilityCandidate) async -> AdversaryVerdict { verdict }
    }
    /// Fake held-out regression organ (P3): canned before/after passing sets, so the loop's monotonic
    /// invariant can be pinned without live models. The real organ (CapabilityRegressionOrgan) runs the
    /// capability corpus; here we prove only that the LOOP hard-rejects a regression an organ reports.
    struct Regress: RegressionInvariant {
        let before: Set<String>; let after: Set<String>
        func baselinePassing() async -> Set<String> { before }
        func passingWith(_ c: CapabilityCandidate) async -> Set<String> { after }
    }

    private func candidate(name: String = "self__do_thing", author: String = "deepseek") -> CapabilityCandidate {
        CapabilityCandidate(
            toolName: name, workdir: "/tmp/x", contract: "does X under Y", authorProvider: author,
            authorModel: "author-model", authorCanonicalIdentity: "\(author):author-model",
            authorInvocationID: "author-call")
    }
    private func decision(kind: RecoveryKind = .extendTool, ownership: ToolOwnership? = .kist,
                          skipped: String? = nil) -> SelfEvolutionDecision {
        SelfEvolutionDecision(category: .toolLimit, kind: kind, brief: "extend it", culpritTool: "run_command",
                              discovery: nil, ownership: ownership, foreignServer: nil,
                              signature: "run_command|sig", skipped: skipped)
    }
    private func run(author: Author, gate: Gate = Gate(ok: true, why: "green"),
                     veto: Veto = Veto(vetoed: false),
                     adversary: Adversary = Adversary(provider: "gemini", verdict: AdversaryVerdict(survived: true, confidence: 0.9)),
                     regression: Regress? = nil,
                     decision d: SelfEvolutionDecision? = nil) async -> EvolutionResult {
        await ClosedEvolutionLoop.run(decision: d ?? decision(), author: author, gate: gate, veto: veto,
                                      adversary: adversary, regression: regression)
    }

    // MARK: the advisory ceiling

    func testSurvivesEverythingIsQuarantinedWithoutHardContainment() async {
        let r = await run(author: Author(cand: candidate()))
        XCTAssertEqual(r.outcome, .quarantinedHardContainment)
        XCTAssertFalse(r.promoted)
        XCTAssertEqual(r.toolName, "self__do_thing")
        XCTAssertTrue(r.reason.contains("hard-containment"))
    }

    // MARK: every reject path

    func testForeignToolNeverAutoEvolves() async {
        let r = await run(author: Author(cand: candidate()), decision: decision(ownership: .foreign))
        XCTAssertEqual(r.outcome, .notApplicable, "foreign tools are spec-only — never blend repos")
    }

    func testLedgerSkipShortCircuits() async {
        let r = await run(author: Author(cand: candidate()), decision: decision(skipped: "already rejected"))
        XCTAssertEqual(r.outcome, .skippedByLedger)
    }

    func testAuthorFailure() async {
        let r = await run(author: Author(cand: nil))
        XCTAssertEqual(r.outcome, .authorFailed)
    }

    func testOutOfNamespaceRejected() async {
        let r = await run(author: Author(cand: candidate(name: "run_command")))  // not self__
        XCTAssertEqual(r.outcome, .rejectedGate)
        XCTAssertTrue(r.reason.contains("self__"))
    }

    func testSameProviderFailsClosed() async {
        // author == adversary provider ⇒ self-certification ⇒ refuse BEFORE any gate.
        let r = await run(author: Author(cand: candidate(author: "gemini")),
                          adversary: Adversary(provider: "gemini", verdict: AdversaryVerdict(survived: true, confidence: 1)))
        XCTAssertEqual(r.outcome, .rejectedSameProvider)
    }

    func testFreshContextSameModelIsQuarantinedAndNeverClaimsIndependence() async {
        let r = await run(
            author: Author(cand: candidate(author: "codex-cli")),
            adversary: Adversary(
                provider: "codex-cli",
                verdict: AdversaryVerdict(survived: true, confidence: 1),
                model: "gpt-5.6-sol", grade: .freshContextSameModel,
                canonicalIdentity: "codex-cli:author-model"))

        XCTAssertEqual(r.outcome, .quarantinedSameModel)
        XCTAssertFalse(r.promoted)
        XCTAssertEqual(r.review?.grade, .freshContextSameModel)
        XCTAssertEqual(r.review?.independent, false)
        XCTAssertEqual(r.review?.freshConversation, true)
        XCTAssertEqual(r.review?.separateInvocation, true)
        XCTAssertTrue(r.reason.contains("independent=false"))
        XCTAssertTrue(r.reason.contains("quarantined"))
        XCTAssertFalse(r.reason.contains("independent adversary"))
    }

    func testFreshContextGradeRejectsDifferentIdentityOrReusedConversation() async {
        let different = await run(
            author: Author(cand: candidate(author: "codex-cli")),
            adversary: Adversary(
                provider: "codex-cli",
                verdict: AdversaryVerdict(survived: true, confidence: 1),
                grade: .freshContextSameModel,
                canonicalIdentity: "codex-cli:different-model"))
        XCTAssertEqual(different.outcome, .rejectedSameProvider)
        XCTAssertTrue(different.reason.contains("independent=false"))

        let reused = await run(
            author: Author(cand: candidate(author: "codex-cli")),
            adversary: Adversary(
                provider: "codex-cli",
                verdict: AdversaryVerdict(survived: true, confidence: 1),
                grade: .freshContextSameModel,
                canonicalIdentity: "codex-cli:author-model",
                invocationID: "author-call"))
        XCTAssertEqual(reused.outcome, .rejectedSameProvider)
        XCTAssertTrue(reused.reason.contains("separateInvocation=false"))
    }

    func testDefaultCrossProviderReviewClaimsIndependenceButCannotPromote() async {
        let r = await run(author: Author(cand: candidate()))
        XCTAssertEqual(r.outcome, .quarantinedHardContainment)
        XCTAssertFalse(r.promoted)
        XCTAssertEqual(r.review?.grade, .independent)
        XCTAssertEqual(r.review?.independent, true)
        XCTAssertTrue(r.reason.contains("independent adversarial review"))
    }

    func testGateRejects() async {
        let r = await run(author: Author(cand: candidate()), gate: Gate(ok: false, why: "CIIntegrityGuard: deleted a test"))
        XCTAssertEqual(r.outcome, .rejectedGate)
        XCTAssertTrue(r.reason.contains("deleted a test"))
        XCTAssertNil(r.review, "a gate rejection occurs before critic invocation")
    }

    func testSymbolicVetoRejects() async {
        let r = await run(author: Author(cand: candidate()), veto: Veto(vetoed: true))
        XCTAssertEqual(r.outcome, .rejectedVeto)
        XCTAssertNil(r.review, "a symbolic veto occurs before critic invocation")
    }

    func testAdversaryBreakingItRejects() async {
        let r = await run(author: Author(cand: candidate()),
                          adversary: Adversary(provider: "gemini",
                                               verdict: AdversaryVerdict(survived: false, attackFound: "empty input crashes", confidence: 0.9)))
        XCTAssertEqual(r.outcome, .rejectedAdversary)
    }

    func testAdversaryLowConfidenceHolds() async {
        // survived but unsure ⇒ promote gate holds ⇒ not shipped.
        let r = await run(author: Author(cand: candidate()),
                          adversary: Adversary(provider: "gemini", verdict: AdversaryVerdict(survived: true, confidence: 0.4)))
        XCTAssertEqual(r.outcome, .rejectedAdversary)
    }

    func testNonExtendKindNotApplicable() async {
        let r = await run(author: Author(cand: candidate()), decision: decision(kind: .discoverAndRetry))
        XCTAssertEqual(r.outcome, .notApplicable)
    }

    // MARK: P3 — held-out regression guard (the wire runEvolve now arms)

    /// A candidate that survives gate + veto + adversary but DROPS a previously-passing held-out case is a
    /// HARD reject — no adversary confidence overrides it. This is the exact "looks better, quietly breaks
    /// things" ship the guard exists to stop; before P3 was wired, the live /evolve path never ran this.
    func testHeldOutRegressionRejectsEvenAfterAdversaryPasses() async {
        let r = await run(author: Author(cand: candidate()),
                          adversary: Adversary(provider: "gemini", verdict: AdversaryVerdict(survived: true, confidence: 1.0)),
                          regression: Regress(before: ["cap_a", "cap_b"], after: ["cap_a"]))
        XCTAssertEqual(r.outcome, .rejectedRegression, "dropping cap_b must hard-reject despite a confident adversary pass")
        // The reason must NAME the regressed case (matches the reason-assertion convention of the sibling
        // reject tests) — so a bug that flipped before.subtracting(after) → after.subtracting(before) can't
        // stay green with a wrong/empty reason.
        XCTAssertTrue(r.reason.contains("cap_b"), "reject reason must name the regressed case: \(r.reason)")
    }

    /// Multi-case regression: dropping 2 of 3 previously-passing cases still hard-rejects and names them.
    func testHeldOutMultiCaseRegressionRejects() async {
        let r = await run(author: Author(cand: candidate()),
                          regression: Regress(before: ["cap_a", "cap_b", "cap_c"], after: ["cap_a"]))
        XCTAssertEqual(r.outcome, .rejectedRegression)
        XCTAssertTrue(r.reason.contains("cap_b") && r.reason.contains("cap_c"), "reason must name both regressed cases: \(r.reason)")
    }

    /// No regression keeps the advisory result alive, but it still cannot cross hard containment.
    func testNoHeldOutRegressionStillQuarantines() async {
        let r = await run(author: Author(cand: candidate()),
                          regression: Regress(before: ["cap_a", "cap_b"], after: ["cap_a", "cap_b", "cap_c"]))
        XCTAssertEqual(r.outcome, .quarantinedHardContainment)
    }

    /// Adding capability from an EMPTY baseline is never a regression, but remains quarantined.
    func testEmptyBaselineNonEmptyAfterStillQuarantines() async {
        let r = await run(author: Author(cand: candidate()),
                          regression: Regress(before: [], after: ["cap_a"]))
        XCTAssertEqual(r.outcome, .quarantinedHardContainment)
    }

    /// ADDITIVE / FAIL-SAFE: an empty held-out corpus (equal empty sets) can NEVER manufacture a false
    /// reject — the exact guarantee behind arming this on the live path by default.
    func testEmptyHeldOutIsAdditiveNoOp() async {
        let r = await run(author: Author(cand: candidate()),
                          regression: Regress(before: [], after: []))
        XCTAssertEqual(r.outcome, .quarantinedHardContainment)
    }
}
