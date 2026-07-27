import XCTest
@testable import AgentCore

/// The reconstruct→render→compare loop: iterate on visual diffs until similarity clears the threshold, and
/// NEVER claim a match we didn't measure. A failed comparison/render/build is a diff to fix, not a match.
final class ReconstructOrchestratorTests: XCTestCase {

    final class StubStages: ReconstructStages, @unchecked Sendable {
        var buildOK = true
        var renderOK = true
        var compareOK = true
        var similarityByRound: [Double] = [0.97]   // similarity returned on each round (clamped to last)
        var failBuildOnRound: Int?
        var buildCount = 0
        var lastFeedback: [VisualDiff] = []

        func reconstruct(goal: String, reference: VisualReference, feedback: [VisualDiff]) async -> ReconstructBuild {
            buildCount += 1; lastFeedback = feedback
            let ok = (failBuildOnRound == buildCount) ? false : buildOK
            return ReconstructBuild(branch: "b\(buildCount)", ok: ok, note: ok ? "built" : "build failed")
        }
        func render(_ build: ReconstructBuild) async -> RenderedView {
            RenderedView(imagePath: "shot\(buildCount).png", ok: renderOK, note: renderOK ? "" : "no screenshot")
        }
        func compare(reference: VisualReference, rendered: RenderedView) async -> VisualComparison {
            let sim = similarityByRound[min(buildCount - 1, similarityByRound.count - 1)]
            let diffs = sim >= 0.95 ? [] : [VisualDiff(area: "header", description: "color off", severity: "minor")]
            return VisualComparison(similarity: sim, diffs: diffs, ok: compareOK, note: compareOK ? "" : "vision error")
        }
    }

    let ref = VisualReference(label: "real app", source: "/tmp/real.png")

    func testMatchesWhenSimilarityClearsThreshold() async {
        let s = StubStages(); s.similarityByRound = [0.97]
        let r = await ReconstructOrchestrator(stages: s, threshold: 0.95).run(goal: "clone", reference: ref)
        XCTAssertTrue(r.didMatch)
        XCTAssertEqual(r.bestSimilarity, 0.97, accuracy: 0.001)
        XCTAssertEqual(r.rounds.count, 1)
    }

    func testImproveLoopThreadsDiffsUntilMatch() async {
        let s = StubStages(); s.similarityByRound = [0.80, 0.96]
        let r = await ReconstructOrchestrator(stages: s, threshold: 0.95, maxRounds: 4).run(goal: "clone", reference: ref)
        XCTAssertTrue(r.didMatch)
        XCTAssertEqual(r.rounds.count, 2)
        // round 2 reconstruction received round 1's visual diff to fix
        XCTAssertTrue(s.lastFeedback.contains { $0.area == "header" })
    }

    func testGiveUpReportsHonestBestSimilarity() async {
        let s = StubStages(); s.similarityByRound = [0.70, 0.80, 0.85]
        let r = await ReconstructOrchestrator(stages: s, threshold: 0.95, maxRounds: 3).run(goal: "clone", reference: ref)
        XCTAssertFalse(r.didMatch)
        XCTAssertEqual(r.bestSimilarity, 0.85, accuracy: 0.001)
        if case .unmatched(_, _, let reason) = r { XCTAssertTrue(reason.contains("best 85%")) } else { XCTFail() }
    }

    // fail-closed fidelity boundary: 0.949 must NOT match a 0.95 threshold.
    func testBelowThresholdIsNotAMatch() async {
        let s = StubStages(); s.similarityByRound = [0.949]
        let r = await ReconstructOrchestrator(stages: s, threshold: 0.95, maxRounds: 1).run(goal: "clone", reference: ref)
        XCTAssertFalse(r.didMatch)
    }

    // a comparison that DID NOT complete must never be read as a match, even with a high reported number.
    func testFailedComparisonNeverMatches() async {
        let s = StubStages(); s.compareOK = false; s.similarityByRound = [0.99]
        let r = await ReconstructOrchestrator(stages: s, threshold: 0.95, maxRounds: 1).run(goal: "clone", reference: ref)
        XCTAssertFalse(r.didMatch)
        XCTAssertEqual(r.bestSimilarity, 0.0, accuracy: 0.001, "an incomplete comparison must not raise best")
    }

    func testBuildFailureFeedsBackAndContinues() async {
        let s = StubStages(); s.failBuildOnRound = 1; s.similarityByRound = [0.99, 0.99]
        let r = await ReconstructOrchestrator(stages: s, threshold: 0.95, maxRounds: 2).run(goal: "clone", reference: ref)
        XCTAssertTrue(r.didMatch)                 // round 2 builds fine and matches
        XCTAssertNil(r.rounds[0].comparison)      // round 1 never compared (build failed)
        XCTAssertTrue(s.lastFeedback.contains { $0.area == "build" })
    }

    func testRenderFailureIsNotAMatch() async {
        let s = StubStages(); s.renderOK = false; s.similarityByRound = [0.99]
        let r = await ReconstructOrchestrator(stages: s, threshold: 0.95, maxRounds: 1).run(goal: "clone", reference: ref)
        XCTAssertFalse(r.didMatch)
        XCTAssertNil(r.rounds[0].comparison)
    }

    func testVisualDiffsAccumulateAcrossBuildFailure() async {
        let s = StubStages(); s.failBuildOnRound = 2; s.similarityByRound = [0.80, 0.80, 0.96]
        let r = await ReconstructOrchestrator(stages: s, threshold: 0.95, maxRounds: 3).run(goal: "clone", reference: ref)
        // R1 compare diff [header]; R2 build fails; R3 must still carry the R1 visual diff
        XCTAssertTrue(s.lastFeedback.contains { $0.area == "header" }, "R1 visual diff must survive an R2 build failure")
        XCTAssertTrue(r.didMatch)
        XCTAssertEqual(r.rounds.count, 3)
    }
}
