import XCTest
import AgentCore
@testable import Kist

/// The plan-execute worker is told the sealed contract up front (0.17.63): exact allowed paths and
/// the verbatim verifier argument object, so it stops discovering them from failures.
final class SealedContractPromptTests: XCTestCase {
    private func plan() -> KistRunner.BuilderPreflightPlan {
        KistRunner.BuilderPreflightPlan(
            schemaVersion: KistRunner.BuilderPreflightPlan.currentSchemaVersion,
            adapter: "planExecute",
            operations: [
                .init(kind: .create, path: "hello.py", preimageSHA256: nil),
                .init(kind: .modify, path: "README.md", preimageSHA256: String(repeating: "a", count: 64)),
            ],
            verificationCommands: [
                .init(executable: "python3", arguments: ["-m", "unittest", "test_hello.py"], timeoutSeconds: 5),
            ],
            partitions: [])
    }

    func testPromptListsEveryAllowedPathWithKindAndTheVerbatimArgumentObject() throws {
        let block = try XCTUnwrap(KistRunner.builderSealedContractPrompt(plan()))
        XCTAssertTrue(block.contains("- create hello.py"), block)
        XCTAssertTrue(block.contains("- modify README.md"), block)
        XCTAssertTrue(block.contains("python3 -m unittest test_hello.py"), block)
        XCTAssertTrue(block.contains(#"{"args":["-m","unittest","test_hello.py"],"executable":"python3","timeout":5}"#),
                      "the argument object must match the sealed run_command wrapper's advertised shape byte for byte: \(block)")
        XCTAssertTrue(block.contains("undeclared mutation"), "the consequence is spelled out")
    }

    func testGoalIsUnchangedWithoutASealedPlan() {
        XCTAssertEqual(KistRunner.builderGoalWithSealedContract("build it", plan: nil), "build it")
        XCTAssertNil(KistRunner.builderSealedContractPrompt(nil))
    }

    func testGoalGetsTheBlockAppendedAfterTheOriginalText() {
        let goal = KistRunner.builderGoalWithSealedContract("build it", plan: plan())
        XCTAssertTrue(goal.hasPrefix("build it\n\nSEALED BUILD CONTRACT"), goal)
    }

    func testPlanExecuteAdapterFeedsTheSealedGoalToTheWorker() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Kist/KistRunner+BuilderAdapters.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("builderGoalWithSealedContract(\n                            boundedExecutionGoal, plan: preflightEnvelope?.plan)"),
                      "plan-execute adapter must compose the sealed goal")
        XCTAssertTrue(src.contains("opts, goal: sealedGoal, registry: registry,"),
                      "and hand exactly that goal to runPlanExecute")
        XCTAssertTrue(src.contains("functionalObjective: builderGoalWithSealedContract(\n                                    functionalExecutionGoal, plan: preflightEnvelope?.plan)"),
                      "the planner reads the functional objective, so the contract must ride there too")
    }
}
