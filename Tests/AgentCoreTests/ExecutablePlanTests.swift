import XCTest
@testable import AgentCore

/// The typed plan-DAG: dependency ordering, cycle/validation, `${id}` ref extraction + resolution.
/// This is the spine of the closed plan→execute loop, so it's pinned hard.
final class ExecutablePlanTests: XCTestCase {

    // MARK: - Topological ordering

    func testLinearChainOrders() throws {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "read", tool: "read_file", argumentsJSON: #"{"path":"a"}"#),
            PlanStep(id: "E2", intent: "use", tool: "write_file", argumentsJSON: #"{"content":"${E1}"}"#),
        ])
        XCTAssertTrue(plan.validate().isEmpty)
        XCTAssertEqual(try plan.orderedSteps().map(\.id), ["E1", "E2"])   // ref forces E1 before E2
    }

    func testExplicitDependsOnOrders() throws {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "B", intent: "b", tool: "list_files", dependsOn: ["A"]),
            PlanStep(id: "A", intent: "a", tool: "list_files"),
        ])
        XCTAssertEqual(try plan.orderedSteps().map(\.id), ["A", "B"])   // A before B despite order
    }

    func testIndependentStepsKeepDeclarationOrder() throws {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "X", intent: "x", tool: "list_files"),
            PlanStep(id: "Y", intent: "y", tool: "list_files"),
            PlanStep(id: "Z", intent: "z", tool: "list_files"),
        ])
        XCTAssertEqual(try plan.orderedSteps().map(\.id), ["X", "Y", "Z"])   // deterministic, stable
    }

    func testDiamondDependencyOrders() throws {
        // A → B, A → C, (B,C) → D
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "A", intent: "a", tool: "list_files"),
            PlanStep(id: "B", intent: "b", tool: "list_files", dependsOn: ["A"]),
            PlanStep(id: "C", intent: "c", tool: "list_files", dependsOn: ["A"]),
            PlanStep(id: "D", intent: "d", tool: "list_files", dependsOn: ["B", "C"]),
        ])
        let order = try plan.orderedSteps().map(\.id)
        XCTAssertEqual(order.first, "A")
        XCTAssertEqual(order.last, "D")
        XCTAssertLessThan(order.firstIndex(of: "B")!, order.firstIndex(of: "D")!)
        XCTAssertLessThan(order.firstIndex(of: "C")!, order.firstIndex(of: "D")!)
    }

    // MARK: - Validation

    func testEmptyPlanIsInvalid() {
        XCTAssertEqual(ExecutablePlan(goal: "g", steps: []).validate(), [.empty])
    }

    func testDuplicateIdDetected() {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "a", tool: "list_files"),
            PlanStep(id: "E1", intent: "b", tool: "list_files"),
        ])
        XCTAssertTrue(plan.validate().contains(.duplicateId("E1")))
    }

    func testEmptyToolDetected() {
        let plan = ExecutablePlan(goal: "g", steps: [PlanStep(id: "E1", intent: "x", tool: "  ")])
        XCTAssertTrue(plan.validate().contains(.emptyTool(stepId: "E1")))
    }

    func testUnknownDependencyDetected() {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "x", tool: "list_files", dependsOn: ["GHOST"]),
        ])
        XCTAssertTrue(plan.validate().contains(.unknownDependency(stepId: "E1", missing: "GHOST")))
    }

    func testUnknownRefDependencyDetected() {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "x", tool: "write_file", argumentsJSON: #"{"content":"${MISSING}"}"#),
        ])
        XCTAssertTrue(plan.validate().contains(.unknownDependency(stepId: "E1", missing: "MISSING")))
    }

    func testCycleDetected() {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "A", intent: "a", tool: "list_files", dependsOn: ["B"]),
            PlanStep(id: "B", intent: "b", tool: "list_files", dependsOn: ["A"]),
        ])
        let errs = plan.validate()
        XCTAssertEqual(errs, [.cycle(involving: ["A", "B"])])
        XCTAssertThrowsError(try plan.orderedSteps())
    }

    func testSelfCycleDetected() {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "A", intent: "a", tool: "list_files", dependsOn: ["A"]),
        ])
        XCTAssertEqual(plan.validate(), [.cycle(involving: ["A"])])
    }

    // MARK: - Variable references

    func testReferencedIdsExtraction() {
        let ids = ExecutablePlan.referencedIds(in: #"{"a":"${E1}","b":"x ${E2} y","c":"none"}"#)
        XCTAssertEqual(ids, ["E1", "E2"])
    }

    func testResolveArgumentsSubstitutesOutputs() {
        let resolved = ExecutablePlan.resolveArguments(
            #"{"path":"out.txt","content":"Result was: ${E1}"}"#,
            outputs: ["E1": "42 files"])
        XCTAssertEqual(resolved["path"] as? String, "out.txt")
        XCTAssertEqual(resolved["content"] as? String, "Result was: 42 files")
    }

    func testResolveHandlesOutputWithQuotesAndNewlines() {
        // Substitution happens on PARSED values, so a messy output can't break JSON.
        let messy = "line1\nline2 \"quoted\" \\backslash"
        let resolved = ExecutablePlan.resolveArguments(#"{"content":"${E1}"}"#, outputs: ["E1": messy])
        XCTAssertEqual(resolved["content"] as? String, messy)
    }

    func testResolveUnknownRefBecomesEmpty() {
        let resolved = ExecutablePlan.resolveArguments(#"{"content":"${GONE}"}"#, outputs: [:])
        XCTAssertEqual(resolved["content"] as? String, "")
    }

    func testResolveNestedAndArrayValues() {
        let resolved = ExecutablePlan.resolveArguments(
            #"{"args":["${E1}","static"],"opts":{"k":"${E2}"}}"#,
            outputs: ["E1": "alpha", "E2": "beta"])
        XCTAssertEqual(resolved["args"] as? [String], ["alpha", "static"])
        XCTAssertEqual((resolved["opts"] as? [String: Any])?["k"] as? String, "beta")
    }

    // MARK: - Codable round-trip (checkpoint/resume)

    func testPlanCodableRoundTrips() throws {
        let plan = ExecutablePlan(goal: "build it", steps: [
            PlanStep(id: "E1", intent: "read", tool: "read_file", argumentsJSON: #"{"path":"a"}"#),
            PlanStep(id: "E2", intent: "write", tool: "write_file",
                     argumentsJSON: #"{"content":"${E1}"}"#, dependsOn: ["E1"], ownerRole: "coder"),
        ])
        let data = try JSONEncoder().encode(plan)
        let back = try JSONDecoder().decode(ExecutablePlan.self, from: data)
        XCTAssertEqual(back, plan)
    }
}
