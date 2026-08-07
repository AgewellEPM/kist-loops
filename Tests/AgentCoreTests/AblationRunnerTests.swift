import XCTest
@testable import AgentCore

/// The arm-executor orchestration — pinned with fake COLD/WARM agents so the wiring is proven without a live
/// model. (The runtime injects real cold/warm kist agents at the edge.)
final class AblationRunnerTests: XCTestCase {

    private func cases(_ names: [String]) -> [EvalCase] {
        names.map { EvalCase(name: $0, prompt: "solve \($0)", assertions: [.outputContains("PASS")]) }
    }
    // A fake agent that passes exactly the named cases (by whether its output contains PASS).
    private func agent(passing: Set<String>) -> EvalRunner.Agent {
        { prompt in
            let name = prompt.replacingOccurrences(of: "solve ", with: "")
            return EvalRunner.RunOutcome(output: passing.contains(name) ? "PASS" : "nope", trajectory: [])
        }
    }

    func testWarmBeatsColdYieldsPositiveAdvantage() async {
        let held = cases(["h1", "h2", "h3", "h4"])
        // COLD passes 1/4; WARM passes 3/4 → advantage +0.5.
        let r = await AblationRunner.run(
            heldOut: held, accumulatedFrom: ["t1", "t2"], corpusHash: "c", epoch: 1,
            cold: agent(passing: ["h1"]),
            warm: agent(passing: ["h1", "h2", "h3"]))
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.coldSuccess, 0.25, accuracy: 1e-9)
        XCTAssertEqual(r!.warmSuccess, 0.75, accuracy: 1e-9)
        XCTAssertEqual(r!.advantage, 0.5, accuracy: 1e-9)
    }

    func testContaminatedCorpusRefusesBeforeSpendingRuns() async {
        var ran = false
        let spy: EvalRunner.Agent = { _ in ran = true; return .init(output: "PASS", trajectory: []) }
        let held = cases(["shared", "h2"])
        let r = await AblationRunner.run(
            heldOut: held, accumulatedFrom: ["shared"], corpusHash: "c", epoch: 1,   // "shared" contaminates
            cold: spy, warm: spy)
        XCTAssertNil(r, "contaminated held-out must refuse")
        XCTAssertFalse(ran, "must refuse BEFORE spending any (expensive) runs")
    }

    func testNegativeTransferSurvivesTheRunner() async {
        let held = cases(["h1", "h2", "h3", "h4"])
        // WARM does WORSE than COLD → negative advantage, still measured (honesty).
        let r = await AblationRunner.run(
            heldOut: held, accumulatedFrom: [], corpusHash: "c", epoch: 1,
            cold: agent(passing: ["h1", "h2", "h3"]),
            warm: agent(passing: ["h1"]))
        XCTAssertNotNil(r)
        XCTAssertTrue(r!.negativeTransfer)
        XCTAssertLessThan(r!.advantage, 0)
    }
}
