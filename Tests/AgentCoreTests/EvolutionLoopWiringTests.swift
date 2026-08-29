import XCTest
@testable import AgentCore

/// P0 (self__ ownership), P5 (ledger outcome mapping → real dedup), and the P6 two-gate consistency pin.
final class EvolutionLoopWiringTests: XCTestCase {

    // P0 — self-authored namespace is its own owner (not foreign, not confused with a bare kist tool).
    func testSelfAuthoredOwnership() {
        XCTAssertEqual(ToolOwnershipResolver.owner(of: "self__do_thing"), .selfAuthored)
        XCTAssertNil(ToolOwnershipResolver.foreignServer(of: "self__do_thing"), "self__ is not foreign")
        XCTAssertEqual(ToolOwnershipResolver.owner(of: "perslis__vm_key"), .foreign)
        XCTAssertEqual(ToolOwnershipResolver.owner(of: "run_command"), .kist)
    }

    // P5 — a hard-contained promotion remains terminal, while the current advisory ceiling is recorded as
    // blocked (retryable after the missing host authority is actually wired), never as promoted.
    func testLedgerOutcomeMapping() {
        XCTAssertEqual(ClosedEvolutionLoop.ledgerOutcome(for: .promoted), "promoted")
        XCTAssertEqual(ClosedEvolutionLoop.ledgerOutcome(for: .quarantinedHardContainment), "blocked")
        for r in [EvolutionOutcome.rejectedGate, .rejectedVeto, .rejectedAdversary,
                  .rejectedSameProvider, .quarantinedSameModel, .authorFailed] {
            XCTAssertEqual(ClosedEvolutionLoop.ledgerOutcome(for: r), "rejected", "\(r) must be recorded so we don't retry it")
        }
        XCTAssertNil(ClosedEvolutionLoop.ledgerOutcome(for: .notApplicable))
        XCTAssertNil(ClosedEvolutionLoop.ledgerOutcome(for: .skippedByLedger))
    }

    // P5 — a recorded resolved outcome actually blocks a retry of the same signature (the dedup that was
    // dead before, because only "attempted" was ever written).
    func testRecordedRejectionBlocksRetry() {
        let sig = "run_command|unsupported flag"
        for resolved in ["promoted", "rejected"] {
            let hist = [SelfEvolutionAttempt(tool: "run_command", category: "toolLimit",
                                             signature: sig, outcome: resolved, atEpoch: 990)]
            let d = SelfEvolutionLedger.decideShouldAttempt(signature: sig, now: 1000, history: hist,
                                                            maxAttemptsPerWindow: 3, windowSeconds: 3600)
            XCTAssertFalse(d.ok, "a \(resolved) evolution must not be re-attempted")
        }
    }

    // P6 — SOURCE PIN (multi-site discipline): the interactive turn-end scorecard must AND the same strong
    // GreatLoopVerifier the great-loop done-gate uses, so it can't log verified=true for an ungrounded
    // mutating turn. Pins the fix at the scorecard site so it can't silently regress to `success && grounded`.
    func testInteractiveScorecardAndsGreatLoopVerifier() throws {
        let candidates = [
            "/Volumes/PRO-G40/kist-evoloop/Sources/Kist/KistREPL+SelfHeal.swift",
            "/Volumes/PRO-G40/kist-loops/Sources/Kist/KistREPL+SelfHeal.swift",
        ]
        let path = candidates.first { FileManager.default.fileExists(atPath: $0) }
        guard let path, let src = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw XCTSkip("KistREPL+SelfHeal.swift not found from the test CWD")
        }
        // The scorecard region must invoke GreatLoopVerifier and AND its verdict into `verified`.
        XCTAssertTrue(src.contains("GreatLoopVerifier.verify(") && src.contains("verified = strongVerdict.isVerified"),
                      "the interactive scorecard must AND GreatLoopVerifier (P6) — not just success && grounded")
    }
}
