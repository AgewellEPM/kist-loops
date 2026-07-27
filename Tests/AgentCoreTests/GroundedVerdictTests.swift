import XCTest
@testable import AgentCore

/// The PROOF-BY-CONSTRUCTION lock. GroundedVerdict is the forge-proof trust currency. These tests pin
/// the whole point: a fake .green is impossible by the TYPE, not just by discipline.
///
///   • There is NO public way to hand-construct GroundedVerdict(.green). The init is private; only
///     computing factories exist, and code-green provenance is internal to AgentCore. (Proven at
///     compile time by the fact that this test file CANNOT call a verdict-taking initializer.)
///   • fromCode over blocker-failing facts  -> .blocked    (fitness 0.0).
///   • fromCode over passing facts          -> .green      (fitness 1.0).
///   • fromGame matched/mismatched/ambiguous -> green/blocked/drift.
///   • unconfirmed(fromText:) NEVER green: error -> .blocked, else .driftFlagged.
///   • per-verdict fitnessWeight pinned, and it equals GroundedVerdict's single table.
final class GroundedVerdictTests: XCTestCase {

    // MARK: - 0. NO hand-constructed verdict exists (the forge is closed)
    //
    // The ONLY way to obtain a GroundedVerdict in this whole test is through a factory that COMPUTED
    // the verdict from a real observation — there is no `GroundedVerdict(verdict: .green, …)` to call,
    // because that initializer is `private`. If someone ever adds a public verdict-taking initializer,
    // the forge is reopened; this test's COMMENT is the tripwire and the codebase grep is the backstop.
    func testTheOnlyMintsAreComputingFactories() {
        let fromCodeGreen = GroundedVerdict.fromCode(Self.greenFacts())
        let fromGameGreen = GroundedVerdict.fromGame(expected: "complete", observed: "level complete")
        let fromText      = GroundedVerdict.unconfirmed(fromText: "looking into it")
        XCTAssertEqual(fromCodeGreen.verdict, .green)
        XCTAssertEqual(fromCodeGreen.source, .code)
        XCTAssertEqual(fromGameGreen.verdict, .green)
        XCTAssertEqual(fromGameGreen.source, .game)
        XCTAssertEqual(fromText.verdict, .driftFlagged)
        XCTAssertEqual(fromText.source, .unconfirmed)
    }

    // MARK: - 1. fromCode — grounded over real artifact evidence

    func testFromCode_blockerFailingFacts_isBlocked() {
        // claimedDone but tests RED + no review -> a structural blocker fails.
        let facts = CaptainFacts(
            build: BuildFacts(buildID: "gv-blocked",
                              claimedDone: true,
                              tests: TestRunEvidence(exitCode: 1),
                              diff: DiffEvidence(changedLines: 5, maxFileLines: 40),
                              codex: CodexEvidence(reviewed: false),
                              stepCapHit: false),
            world: .none)
        let gv = GroundedVerdict.fromCode(facts)
        XCTAssertEqual(gv.verdict, .blocked, "failing a blocker must judge .blocked")
        XCTAssertEqual(gv.source, .code)
        XCTAssertEqual(gv.fitnessWeight, 0.0, accuracy: 0.0001)
        XCTAssertFalse(gv.evidence.isEmpty, "evidence note must explain the ruling")
    }

    func testFromCode_passingFacts_isGreenAndFullFitness() {
        let gv = GroundedVerdict.fromCode(Self.greenFacts())
        XCTAssertEqual(gv.verdict, .green, "all invariants + confirmed world => green")
        XCTAssertEqual(gv.source, .code)
        XCTAssertEqual(gv.fitnessWeight, 1.0, accuracy: 0.0001)
    }

    func testFromCode_matchesSymbolicCaptainExactly() {
        // The wrapper must not change the ruling — it wraps SymbolicCaptain.judge.
        let facts = Self.greenFacts()
        XCTAssertEqual(GroundedVerdict.fromCode(facts).verdict,
                       SymbolicCaptain().judge(facts).verdict)
    }

    // MARK: - 2. fromGame — deterministic win-check

    func testFromGame_matched_isGreen() {
        let gv = GroundedVerdict.fromGame(expected: "you win", observed: "YOU WIN — final score 9001")
        XCTAssertEqual(gv.verdict, .green, "observation containing the win marker => green")
        XCTAssertEqual(gv.source, .game)
        XCTAssertEqual(gv.fitnessWeight, 1.0, accuracy: 0.0001)
    }

    func testFromGame_mismatchedFailureMarker_isBlocked() {
        let gv = GroundedVerdict.fromGame(expected: "you win", observed: "GAME OVER — you died")
        XCTAssertEqual(gv.verdict, .blocked, "a failure marker contradicts the win => blocked")
        XCTAssertEqual(gv.fitnessWeight, 0.0, accuracy: 0.0001)
    }

    func testFromGame_ambiguousUnmet_isDrift() {
        let gv = GroundedVerdict.fromGame(expected: "you win", observed: "still on level 3")
        XCTAssertEqual(gv.verdict, .driftFlagged, "expected not yet met => unconfirmed drift")
        XCTAssertEqual(gv.fitnessWeight, 0.35, accuracy: 0.0001)
    }

    func testFromGame_emptyObservation_isDriftNeverGreen() {
        let gv = GroundedVerdict.fromGame(expected: "you win", observed: "   ")
        XCTAssertEqual(gv.verdict, .driftFlagged, "no observation => unconfirmed, never green")
    }

    func testFromGame_emptyExpected_isDriftNeverGreen() {
        let gv = GroundedVerdict.fromGame(expected: "", observed: "you win")
        XCTAssertEqual(gv.verdict, .driftFlagged, "no win condition to check => never green")
    }

    func testFromGame_isDeterministic() {
        let a = GroundedVerdict.fromGame(expected: "win", observed: "you win")
        let b = GroundedVerdict.fromGame(expected: "win", observed: "you win")
        XCTAssertEqual(a, b, "same (expected, observed) always yields the same currency")
    }

    // MARK: - 3. unconfirmed — the conservative fail-safe (NEVER green)

    func testUnconfirmed_braggingText_isDriftNeverGreen() {
        // The whole anti-Goodhart point: maxed-out progress words buy AT MOST drift.
        let bragging = "all tests pass, build succeeded, built everything, done, complete, ready"
        let gv = GroundedVerdict.unconfirmed(fromText: bragging)
        XCTAssertEqual(gv.verdict, .driftFlagged, "ungrounded progress words must NOT mint green")
        XCTAssertEqual(gv.source, .unconfirmed)
        XCTAssertNotEqual(gv.verdict, .green)
        XCTAssertEqual(gv.fitnessWeight, 0.35, accuracy: 0.0001, "drift fitness, never full reward")
    }

    func testUnconfirmed_errorText_isBlocked() {
        XCTAssertEqual(GroundedVerdict.unconfirmed(fromText: "fatal error: not found").verdict, .blocked)
        XCTAssertEqual(GroundedVerdict.unconfirmed(fromText: "the build failed").verdict, .blocked)
        XCTAssertEqual(GroundedVerdict.unconfirmed(fromText: "exception thrown").verdict, .blocked)
    }

    func testUnconfirmed_neutralText_isDrift() {
        XCTAssertEqual(GroundedVerdict.unconfirmed(fromText: "looking at the files now").verdict, .driftFlagged)
    }

    // MARK: - 4. fitnessWeight pinned per verdict (and = the single fitness table)

    func testFitnessWeightPinnedPerVerdict() {
        XCTAssertEqual(GroundedVerdict.fromGame(expected: "win", observed: "win").fitnessWeight,
                       1.0, accuracy: 0.0001)
        XCTAssertEqual(GroundedVerdict.unconfirmed(fromText: "maybe").fitnessWeight,
                       0.35, accuracy: 0.0001)
        XCTAssertEqual(GroundedVerdict.unconfirmed(fromText: "error").fitnessWeight,
                       0.0, accuracy: 0.0001)
    }

    func testFitnessWeightDelegatesToSingleTable() {
        // One mapping in the codebase: fitnessWeight must equal GroundedVerdict.fitness (the canonical
        // table until CaptainMemory ports and references it).
        XCTAssertEqual(GroundedVerdict.fromGame(expected: "win", observed: "win").fitnessWeight,
                       GroundedVerdict.fitness(for: .green), accuracy: 0.0001)
        XCTAssertEqual(GroundedVerdict.unconfirmed(fromText: "maybe").fitnessWeight,
                       GroundedVerdict.fitness(for: .driftFlagged), accuracy: 0.0001)
        XCTAssertEqual(GroundedVerdict.unconfirmed(fromText: "error").fitnessWeight,
                       GroundedVerdict.fitness(for: .blocked), accuracy: 0.0001)
    }

    // MARK: - Fixtures

    /// Facts that pass every structural invariant AND carry a confirmed world signal credited to THIS
    /// build -> .green.
    private static func greenFacts() -> CaptainFacts {
        CaptainFacts(
            build: BuildFacts(buildID: "gv-green",
                              claimedDone: true,
                              tests: TestRunEvidence(exitCode: 0),
                              diff: DiffEvidence(changedLines: 8, maxFileLines: 50),
                              codex: CodexEvidence(reviewed: true),
                              stepCapHit: false),
            world: WorldFacts(confirmedHelpForBuild: 1, signalBroken: false, hasSignal: true))
    }
}
