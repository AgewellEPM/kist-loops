import XCTest
@testable import AgentCore

/// The Captain CONTROLLER — the loop-owner that sits on top of the agent and makes the LLM a
/// subordinate proposer. These tests pin the exact behaviors that were missing (why the agent
/// "analyzed forever, never built"): the Captain forces action out of analysis-paralysis, refuses a
/// premature "done", and only completes on a proven artifact. Fakes stand in for the LLM + executor.
final class CaptainControllerTests: XCTestCase {

    // MARK: - Fakes

    /// Returns scripted moves, then a fallback forever. Records the `forcedAction` flag it was told.
    private final class ScriptedDecider: CaptainDecider, @unchecked Sendable {
        private let lock = NSLock()
        private var moves: [CaptainMove]
        private let fallback: CaptainMove
        private(set) var forcedFlags: [Bool] = []
        private(set) var proposeCount = 0
        init(_ moves: [CaptainMove], fallback: CaptainMove = .investigate(step: "analyze more")) {
            self.moves = moves; self.fallback = fallback
        }
        func propose(objective: String, history: [MoveOutcome], forcedAction: Bool) async -> CaptainMove {
            lock.lock(); defer { lock.unlock() }
            forcedFlags.append(forcedAction); proposeCount += 1
            return moves.isEmpty ? fallback : moves.removeFirst()
        }
    }

    /// Executes moves and reports outcomes; a build produces an artifact per config. Records moves.
    private final class ConfigurablePerformer: CaptainPerformer, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var performed: [CaptainMove] = []
        private let buildSucceeds: Bool
        private let buildProducesArtifact: Bool
        init(buildSucceeds: Bool = true, buildProducesArtifact: Bool = true) {
            self.buildSucceeds = buildSucceeds; self.buildProducesArtifact = buildProducesArtifact
        }
        func perform(_ move: CaptainMove, objective: String) async -> MoveOutcome {
            lock.lock(); performed.append(move); lock.unlock()
            switch move {
            case .build:
                return MoveOutcome(success: buildSucceeds,
                                   producedArtifact: buildSucceeds && buildProducesArtifact, summary: "built")
            case .investigate:
                return MoveOutcome(success: true, producedArtifact: false, summary: "analyzed")
            default:
                return MoveOutcome(success: true, producedArtifact: false, summary: "noop")
            }
        }
    }

    // MARK: - THE core fix: analysis-paralysis is forced into action

    func testBuildObjectiveForcesActionAfterAnalysisPatience() async {
        let decider = ScriptedDecider([])                       // always tries to analyze
        let performer = ConfigurablePerformer(buildProducesArtifact: true)
        let captain = CaptainController(maxTicks: 6, analysisPatience: 2)
        let outcome = await captain.drive(objective: "build X", requiresArtifact: true,
                                          decider: decider, performer: performer)
        // tick1 analyze, tick2 analyze, tick3 FORCED build → artifact → done.
        XCTAssertEqual(outcome, .completed(ticks: 3))
        XCTAssertTrue(performer.performed.contains { $0.isAction }, "Captain must have FORCED a build")
        XCTAssertEqual(decider.forcedFlags, [false, false, true], "the proposer is told when it's forced")
    }

    // MARK: - The LLM does not get to end the loop by claiming done

    func testPrematureDoneOnBuildObjectiveIsRejectedAndDrivesOn() async {
        let decider = ScriptedDecider([.declareDone])          // claims done with nothing built
        let performer = ConfigurablePerformer(buildProducesArtifact: true)
        let captain = CaptainController(maxTicks: 6, analysisPatience: 2)
        let outcome = await captain.drive(objective: "build X", requiresArtifact: true,
                                          decider: decider, performer: performer)
        // The premature done at tick1 is rejected; the Captain drives on and forces a build.
        XCTAssertEqual(outcome, .completed(ticks: 3), "a claimed done with no artifact must NOT stop the loop")
        XCTAssertTrue(performer.performed.contains { $0.isAction })
    }

    func testSuccessfulBuildCompletesOnProvenArtifact() async {
        let decider = ScriptedDecider([.build(step: "make it")])
        let performer = ConfigurablePerformer(buildProducesArtifact: true)
        let captain = CaptainController(maxTicks: 6, analysisPatience: 5)
        let outcome = await captain.drive(objective: "build X", requiresArtifact: true,
                                          decider: decider, performer: performer)
        XCTAssertEqual(outcome, .completed(ticks: 1))
        XCTAssertEqual(performer.performed.count, 1)
    }

    func testEmptyBuildsNeverFakeCompletionAndAreBounded() async {
        let decider = ScriptedDecider([], fallback: .build(step: "spin"))
        let performer = ConfigurablePerformer(buildSucceeds: true, buildProducesArtifact: false) // builds nothing
        let captain = CaptainController(maxTicks: 4, analysisPatience: 1)
        let outcome = await captain.drive(objective: "build X", requiresArtifact: true,
                                          decider: decider, performer: performer)
        XCTAssertEqual(outcome, .exhausted(ticks: 4), "a build that produces no artifact is never 'done'")
    }

    // MARK: - Analysis objectives are NOT forced (analyzing is the deliverable there)

    func testAnalysisObjectiveCompletesOnDeclareDoneAndIsNeverForced() async {
        let decider = ScriptedDecider([.investigate(step: "read"), .declareDone])
        let performer = ConfigurablePerformer()
        let captain = CaptainController(maxTicks: 6, analysisPatience: 1)
        let outcome = await captain.drive(objective: "analyze yourself", requiresArtifact: false,
                                          decider: decider, performer: performer)
        XCTAssertEqual(outcome, .completed(ticks: 2))
        XCTAssertFalse(decider.forcedFlags.contains(true), "an analysis objective is never forced to build")
    }

    // MARK: - Safety spine: bounded, killable, hand-back

    func testKillSwitchHonoredBeforeAnyWork() async {
        let decider = ScriptedDecider([.build(step: "x")])
        let performer = ConfigurablePerformer()
        let captain = CaptainController(maxTicks: 4, isKilled: { true })
        let outcome = await captain.drive(objective: "build X", requiresArtifact: true,
                                          decider: decider, performer: performer)
        XCTAssertEqual(outcome, .killed(tick: 1))
        XCTAssertTrue(performer.performed.isEmpty, "nothing may be performed after a kill")
        XCTAssertEqual(decider.proposeCount, 0, "no proposal after a kill")
    }

    func testHandBackTerminatesWithoutActing() async {
        let decider = ScriptedDecider([.handBack(reason: "need an API key")])
        let performer = ConfigurablePerformer()
        let captain = CaptainController(maxTicks: 4, analysisPatience: 2)
        let outcome = await captain.drive(objective: "build X", requiresArtifact: true,
                                          decider: decider, performer: performer)
        XCTAssertEqual(outcome, .handedBack(reason: "need an API key", tick: 1))
        XCTAssertTrue(performer.performed.isEmpty)
    }

    // MARK: - The default judge is deterministic + artifact-grounded

    func testDefaultJudgeIsArtifactGroundedAndDeterministic() {
        let none: [MoveOutcome] = [MoveOutcome(success: true, producedArtifact: false, summary: "analyzed")]
        let built = [MoveOutcome(success: true, producedArtifact: true, summary: "built")]
        let brokeAfter = built + [MoveOutcome(success: false, producedArtifact: false, summary: "broke")]
        if case .done = CaptainController.defaultJudge(objective: "x", history: none) { XCTFail("analysis alone is not done") }
        guard case .done = CaptainController.defaultJudge(objective: "x", history: built) else { return XCTFail("a proven artifact is done") }
        if case .done = CaptainController.defaultJudge(objective: "x", history: brokeAfter) { XCTFail("a trailing failure is not done") }
    }
}
