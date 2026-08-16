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

    func testRunCommandRejectsRawShellBeforeExecution() {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "test", tool: "run_command",
                     argumentsJSON: #"{"command":"swift test"}"#),
        ])
        XCTAssertEqual(plan.validate(), [
            .invalidArguments(stepId: "E1", reason: "raw 'command' is forbidden in plans; use 'executable' and an 'args' array (never working_directory)"),
        ])
    }

    func testRunCommandAcceptsStructuredPlanArguments() {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "test", tool: "run_command",
                     argumentsJSON: #"{"executable":"swift","args":["test"],"cwd":".","stdin":"hostile; $(ignored)","allowed_exit_codes":[0,1]}"#),
        ])
        XCTAssertTrue(plan.validate().isEmpty)
    }

    func testHostOwnedFinalReviewRejectsUnprovenSelfReviewTools() {
        let plans = [
            PlanStep(id: "G", intent: "independent final review", tool: "generate",
                     argumentsJSON: #"{"prompt":"act as independent reviewer"}"#),
            PlanStep(id: "A", intent: "authoritative review", tool: "grounded_answer",
                     argumentsJSON: #"{"question":"final review"}"#),
            PlanStep(id: "S", intent: "call Anthropic for distinct reviewer identity", tool: "run_command",
                     argumentsJSON: #"{"executable":"python3","args":["review.py"]}"#),
        ]
        for step in plans {
            let errors = ExecutablePlan(goal: "g", steps: [step])
                .validate(hostOwnedFinalReview: true)
            XCTAssertTrue(errors.contains {
                if case .invalidArguments(let id, let reason) = $0 {
                    return id == step.id && reason.contains("outer BuilderRun host")
                }
                return false
            }, "host-owned review step must fail before execution: \(step)")
        }
    }

    func testHostOwnedFinalReviewAllowsFunctionalGenerationAndCommands() {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "G", intent: "generate parser source", tool: "generate",
                     argumentsJSON: #"{"prompt":"write parser code"}"#),
            PlanStep(id: "T", intent: "run functional tests", tool: "run_command",
                     argumentsJSON: #"{"executable":"swift","args":["test"]}"#),
        ])
        XCTAssertTrue(plan.validate(hostOwnedFinalReview: true).isEmpty)
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

    // MARK: - Field-path refs (${id.field}) — chaining a structured MCP tool output
    // (2026-08-04: a vm plan passed the literal `${E3.qmp}` to perslis because only whole-output
    // refs resolved; the tool then tried to open a socket at "${E3.qmp}".)

    func testResolveFieldPathExtractsJSONField() {
        // vm_launch returns {"pid":..,"qmp":".."}; a later step chains ${E3.qmp}.
        let launch = #"{"pid":64406,"qmp":"/tmp/perslis-run.sock","vnc":5900}"#
        let resolved = ExecutablePlan.resolveArguments(#"{"qmp":"${E3.qmp}"}"#, outputs: ["E3": launch])
        XCTAssertEqual(resolved["qmp"] as? String, "/tmp/perslis-run.sock",
                       "field ref must resolve, not pass the literal token")
    }

    func testResolveFieldPathScalarsAndNesting() {
        let out = #"{"a":{"b":{"c":"deep"}},"n":42,"flag":true}"#
        XCTAssertEqual(ExecutablePlan.resolveArguments(#"{"v":"${E1.a.b.c}"}"#, outputs: ["E1": out])["v"] as? String, "deep")
        XCTAssertEqual(ExecutablePlan.resolveArguments(#"{"v":"${E1.n}"}"#, outputs: ["E1": out])["v"] as? String, "42")
        XCTAssertEqual(ExecutablePlan.resolveArguments(#"{"v":"pid=${E1.n}"}"#, outputs: ["E1": out])["v"] as? String, "pid=42")
    }

    func testResolveFieldPathMissingOrNonJSONBecomesEmpty() {
        // id exists but output isn't JSON → "" (never the literal token).
        XCTAssertEqual(ExecutablePlan.resolveArguments(#"{"v":"${E1.qmp}"}"#, outputs: ["E1": "plain text"])["v"] as? String, "")
        // id exists, JSON, but field missing → "".
        XCTAssertEqual(ExecutablePlan.resolveArguments(#"{"v":"${E1.nope}"}"#, outputs: ["E1": #"{"qmp":"x"}"#])["v"] as? String, "")
        // whole-ref still works alongside field-refs.
        XCTAssertEqual(ExecutablePlan.resolveArguments(#"{"v":"${E1}"}"#, outputs: ["E1": #"{"qmp":"x"}"#])["v"] as? String, #"{"qmp":"x"}"#)
    }

    func testFieldRefStillCountsBaseIdAsDependency() {
        // The optional .field suffix must not change dependency detection.
        XCTAssertEqual(ExecutablePlan.referencedIds(in: #"{"qmp":"${E3.qmp}","x":"${E1}"}"#), ["E3", "E1"])
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
