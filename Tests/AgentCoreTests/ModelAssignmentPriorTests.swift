import XCTest
@testable import AgentCore

/// Pins the confidence-decaying model-NAME prior (`ModelAssignmentEngine.namePriorWeight`) — the router-audit
/// fix that lets measured evidence DRIVE routing instead of merely nudging a static name-strength table. The
/// central safety property is the COLD-START FAIL-SAFE: with no evidence the prior weight is exactly 1.0, so
/// routing is byte-identical to before the change until the scorecard has real samples.
final class ModelAssignmentPriorTests: XCTestCase {

    /// Cold start (no samples) ⇒ prior fully holds ⇒ routing unchanged. This is the fail-safe that makes the
    /// change safe to land on the live path: it can only diverge from prior behavior once evidence exists.
    func testColdStartHoldsFullPrior() {
        XCTAssertEqual(ModelAssignmentEngine.namePriorWeight(samples: 0), 1.0, accuracy: 1e-9)
    }

    /// K=8 shrinkage: the name prior is at exactly half weight by ~8 accumulated runs.
    func testHalfWeightByEightSamples() {
        XCTAssertEqual(ModelAssignmentEngine.namePriorWeight(samples: 8), 0.5, accuracy: 1e-9)
    }

    /// The prior decays MONOTONICALLY toward 0 (never oscillates ⇒ routing converges as evidence grows) and
    /// stays within [0,1] the whole way.
    func testDecaysMonotonicallyAndStaysBounded() {
        var prev = 2.0
        for s in [0, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89] {
            let w = ModelAssignmentEngine.namePriorWeight(samples: s)
            XCTAssertLessThan(w, prev + 1e-12, "must not increase as samples grow (s=\(s))")
            XCTAssertGreaterThanOrEqual(w, 0.0)
            XCTAssertLessThanOrEqual(w, 1.0)
            prev = w
        }
        // At high evidence the name prior is effectively faded — the earned signal is in control.
        XCTAssertLessThan(ModelAssignmentEngine.namePriorWeight(samples: 200), 0.05)
    }

    /// Below the promotion threshold the prior is still DOMINANT (>0.7) — evidence hasn't earned control yet, so
    /// a couple of lucky/unlucky early runs can't flip routing. Ties the curve to the scorecard's own minSamples.
    func testBelowMinSamplesPriorStillDominant() {
        XCTAssertGreaterThan(ModelAssignmentEngine.namePriorWeight(samples: ScorecardThresholds.minSamples), 0.7)
    }

    /// Defensive: a negative/garbage sample count is treated as cold start (full prior), never a >1 or negative
    /// weight that would invert or amplify the prior.
    func testNegativeSamplesClampToColdStart() {
        XCTAssertEqual(ModelAssignmentEngine.namePriorWeight(samples: -5), 1.0, accuracy: 1e-9)
    }
}
