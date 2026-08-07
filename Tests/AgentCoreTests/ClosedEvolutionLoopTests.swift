import XCTest
@testable import AgentCore

/// The closed loop's control flow — every gate and every reject path — pinned with fake organs. This is the
/// anti-growth-hack spine: a candidate reaches `.promoted` ONLY by surviving the gate, the symbolic veto,
/// AND an independent (different-provider) adversary. Any short-circuit is a rejection, never a ship.
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
        let provider: String; let verdict: AdversaryVerdict
        func attack(_ c: CapabilityCandidate) async -> AdversaryVerdict { verdict }
    }

    private func candidate(name: String = "self__do_thing", author: String = "deepseek") -> CapabilityCandidate {
        CapabilityCandidate(toolName: name, workdir: "/tmp/x", contract: "does X under Y", authorProvider: author)
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
                     decision d: SelfEvolutionDecision? = nil) async -> EvolutionResult {
        await ClosedEvolutionLoop.run(decision: d ?? decision(), author: author, gate: gate, veto: veto, adversary: adversary)
    }

    // MARK: the ONE happy path

    func testSurvivesEverythingPromotes() async {
        let r = await run(author: Author(cand: candidate()))
        XCTAssertEqual(r.outcome, .promoted)
        XCTAssertEqual(r.toolName, "self__do_thing")
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

    func testGateRejects() async {
        let r = await run(author: Author(cand: candidate()), gate: Gate(ok: false, why: "CIIntegrityGuard: deleted a test"))
        XCTAssertEqual(r.outcome, .rejectedGate)
        XCTAssertTrue(r.reason.contains("deleted a test"))
    }

    func testSymbolicVetoRejects() async {
        let r = await run(author: Author(cand: candidate()), veto: Veto(vetoed: true))
        XCTAssertEqual(r.outcome, .rejectedVeto)
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
}
