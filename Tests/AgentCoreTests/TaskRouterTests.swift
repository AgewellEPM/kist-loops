import XCTest
@testable import AgentCore

final class TaskRouterTests: XCTestCase {

    func testTrivialReadOnlyQuestionTakesFastLane() {
        let d = TaskRouter.route(goal: "what does the parseChord function do?")
        XCTAssertEqual(d.route, .fast)
    }

    func testShortMutatingGoalIsNotFast() {
        // "fix the typo" is short/low-score but it MUTATES — must not be answered on the fast lane.
        let d = TaskRouter.route(goal: "fix the typo in the README")
        XCTAssertNotEqual(d.route, .fast)
    }

    func testComplexBriefGoesToPipeline() {
        // A genuinely council-worthy brief: many steps, heavy engineering words, rigor.
        let goal = "Design and implement a distributed rate-limiting architecture: refactor the gateway, "
            + "migrate all services to the new middleware, add integration and load tests, benchmark "
            + "throughput, ensure backward compatibility, and document the rollout and security review "
            + "across the entire platform."
        let d = TaskRouter.route(goal: goal)
        XCTAssertEqual(d.route, .pipeline)
        XCTAssertGreaterThanOrEqual(d.complexity, TaskRouter.complexThreshold)
    }

    func testModerateRefactorIsStandardNotPipeline() {
        // Consistent with the shared EffortController brain: a moderate refactor is a single-loop task,
        // not council-worthy. The router trusts that judgment (it does not over-escalate).
        let d = TaskRouter.route(goal: "add a null check to the login handler and a test for it")
        XCTAssertEqual(d.route, .standard)
    }

    func testUserForcedRouteWins() {
        // Even a trivial goal routes to the pipeline if the user explicitly asked for it.
        let d = TaskRouter.route(goal: "what is 2+2?", userForced: .pipeline)
        XCTAssertEqual(d.route, .pipeline)
        XCTAssertTrue(d.reason.contains("user-selected"))
    }

    func testStrugglingRunEscalatesToPipeline() {
        // A stuck/failing run is promoted regardless of the base score (auto-escalation, no re-ask).
        let stuck = EffortController.Signals(failureRate: 0.6, iterationsUsed: 20, isStuck: true, replansUsed: 2)
        let d = TaskRouter.route(goal: "explain this file", signals: stuck)
        XCTAssertEqual(d.route, .pipeline)
        XCTAssertTrue(d.reason.contains("struggling"))
    }

    func testLooksMutatingDetection() {
        XCTAssertTrue(TaskRouter.looksMutating("refactor the parser"))
        XCTAssertTrue(TaskRouter.looksMutating("please add a test"))
        XCTAssertFalse(TaskRouter.looksMutating("what is the difference between A and B?"))
        XCTAssertFalse(TaskRouter.looksMutating("explain how the loop works"))
    }

    func testUnknownShortImperativeDoesNotFastPath() {
        // Council HIGH (fail-closed): mutating verbs the denylist misses must still NOT fast-path, because
        // the fast lane now requires a POSITIVE read-only signal, not just "no known mutating verb".
        for goal in ["bump version", "format the file", "patch README", "apply this diff", "tidy the imports"] {
            XCTAssertNotEqual(TaskRouter.route(goal: goal).route, .fast, "'\(goal)' must not fast-path")
        }
    }

    func testPoliteMutatingRequestQuestionsDoNotFastPath() {
        // Polite action requests are often phrased as questions; they are not read-only questions.
        for goal in ["can you bump version?", "could you patch README?", "would you format the file?",
                     "please apply this diff?", "can you tidy the imports?"] {
            XCTAssertNotEqual(TaskRouter.route(goal: goal).route, .fast, "'\(goal)' must not fast-path")
        }
    }

    func testReadOnlySignalRequiredForFast() {
        XCTAssertTrue(TaskRouter.looksReadOnly("what is a monad?"))
        XCTAssertTrue(TaskRouter.looksReadOnly("explain the loop"))
        XCTAssertTrue(TaskRouter.looksReadOnly("can you explain the loop?"))
        XCTAssertTrue(TaskRouter.looksReadOnly("is the parser thread-safe"))
        XCTAssertFalse(TaskRouter.looksReadOnly("bump version"))
        XCTAssertFalse(TaskRouter.looksReadOnly("format the file"))
        XCTAssertFalse(TaskRouter.looksReadOnly("can you bump version?"))
    }

    func testStruggleEscalationBeatsForcedFast() {
        // A struggling run escalates even if the user forced .fast (auto-recovery, no re-ask).
        let stuck = EffortController.Signals(isStuck: true)
        let d = TaskRouter.route(goal: "explain this", signals: stuck, userForced: .fast)
        XCTAssertEqual(d.route, .pipeline)
    }

    func testFastLaneIsConservativeOnAmbiguity() {
        // A question that mentions a mutating word ("build system") should NOT fast-path — safe direction.
        let d = TaskRouter.route(goal: "how does the build system decide what to compile?")
        XCTAssertNotEqual(d.route, .fast)   // conservative: under-serving is worse than a little latency
    }

    func testComplexityIsSurfacedInDecision() {
        let d = TaskRouter.route(goal: "what is a monad?")
        XCTAssertGreaterThanOrEqual(d.complexity, 0)
        XCTAssertLessThanOrEqual(d.complexity, 100)
        XCTAssertFalse(d.reason.isEmpty)
    }
}
