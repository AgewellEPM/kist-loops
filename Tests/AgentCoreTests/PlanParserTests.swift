import XCTest
@testable import AgentCore

/// Parsing a planner model's JSON into an ExecutablePlan — tolerant of fences, prose, field aliases,
/// and missing ids, the way real models actually respond.
final class PlanParserTests: XCTestCase {

    func testParsesCanonicalPlan() throws {
        let raw = """
        {"goal":"summarize the config","steps":[
          {"id":"E1","intent":"read config","tool":"read_file","arguments":{"path":"config.json"},"dependsOn":[]},
          {"id":"E2","intent":"write summary","tool":"write_file","arguments":{"path":"out.txt","content":"from ${E1}"},"dependsOn":["E1"]}
        ]}
        """
        let plan = try XCTUnwrap(PlanParser.parse(raw))
        XCTAssertEqual(plan.goal, "summarize the config")
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.steps[0].tool, "read_file")
        XCTAssertEqual(plan.steps[1].dependsOn, ["E1"])
        // arguments serialized to a stable JSON string (sorted keys).
        XCTAssertEqual(plan.steps[1].argumentsJSON, #"{"content":"from ${E1}","path":"out.txt"}"#)
        XCTAssertTrue(plan.validate().isEmpty)   // a clean parse yields a runnable plan
    }

    func testStripsMarkdownFenceAndProse() throws {
        let raw = """
        Here's the plan:
        ```json
        {"goal":"g","steps":[{"id":"E1","tool":"list_files"}]}
        ```
        Hope that helps!
        """
        let plan = try XCTUnwrap(PlanParser.parse(raw))
        XCTAssertEqual(plan.steps.first?.tool, "list_files")
    }

    func testAcceptsFieldAliases() throws {
        // name/action for tool, args/parameters for arguments, depends_on/deps/after, role, plan-as-steps.
        let raw = """
        {"objective":"x","plan":[
          {"id":"A","description":"do a","name":"read_file","args":{"path":"a"}},
          {"id":"B","action":"write_file","parameters":{"path":"b"},"depends_on":["A"],"role":"coder"}
        ]}
        """
        let plan = try XCTUnwrap(PlanParser.parse(raw))
        XCTAssertEqual(plan.goal, "x")
        XCTAssertEqual(plan.steps[0].tool, "read_file")
        XCTAssertEqual(plan.steps[0].intent, "do a")
        XCTAssertEqual(plan.steps[1].tool, "write_file")
        XCTAssertEqual(plan.steps[1].dependsOn, ["A"])
        XCTAssertEqual(plan.steps[1].ownerRole, "coder")
    }

    func testSynthesizesMissingIds() throws {
        let raw = #"{"steps":[{"tool":"list_files"},{"tool":"read_file","arguments":{"path":"x"}}]}"#
        let plan = try XCTUnwrap(PlanParser.parse(raw))
        XCTAssertEqual(plan.steps.map(\.id), ["E1", "E2"])   // stable E<n> fallback
    }

    func testSkipsMalformedStepsButKeepsValidOnes() throws {
        // A step with no tool is dropped; the rest survive.
        let raw = #"{"steps":[{"id":"E1","tool":"list_files"},{"id":"E2","intent":"no tool here"}]}"#
        let plan = try XCTUnwrap(PlanParser.parse(raw))
        XCTAssertEqual(plan.steps.map(\.id), ["E1"])
    }

    func testSingleStringDependencyCoerced() throws {
        let raw = #"{"steps":[{"id":"A","tool":"list_files"},{"id":"B","tool":"read_file","arguments":{"path":"x"},"dependsOn":"A"}]}"#
        let plan = try XCTUnwrap(PlanParser.parse(raw))
        XCTAssertEqual(plan.steps[1].dependsOn, ["A"])
    }

    func testArgumentsAsStringPassThrough() throws {
        let raw = #"{"steps":[{"id":"E1","tool":"run_command","args":"{\"command\":\"ls\"}"}]}"#
        let plan = try XCTUnwrap(PlanParser.parse(raw))
        XCTAssertEqual(plan.steps[0].argumentsJSON, #"{"command":"ls"}"#)
    }

    func testNoStepsReturnsNil() {
        XCTAssertNil(PlanParser.parse(#"{"goal":"g","steps":[]}"#))
        XCTAssertNil(PlanParser.parse("I'm not sure how to plan this."))
        XCTAssertNil(PlanParser.parse(#"{"goal":"g"}"#))
    }

    func testParsedPlanFeedsValidation() throws {
        // A parsed plan with a bad ref is structurally fine but fails validation (caller's job).
        let raw = #"{"steps":[{"id":"E1","tool":"write_file","arguments":{"content":"${GHOST}"}}]}"#
        let plan = try XCTUnwrap(PlanParser.parse(raw))
        XCTAssertTrue(plan.validate().contains(.unknownDependency(stepId: "E1", missing: "GHOST")))
    }
}
