import XCTest
@testable import AgentCore

/// The MiMo audit gap: research/audit loops read until max-iterations without synthesizing. The loop
/// now nudges the model to stop gathering and write findings. These pin the decision logic.
final class ForcedSynthesisTests: XCTestCase {

    func testEquivalentSearchesStayStalledAcrossNudges() {
        var progress = HeadlessGatheringProgress()
        for index in 0..<10 {
            progress.observe(tool: "glob_files", args: ["pattern": "**/missing-\(index)*", "limit": index + 1],
                result: ToolResult(success: true, output: ""), visibleBody: "", readOnly: true)
            if index == 6 { progress.didNudge() }
        }
        XCTAssertTrue(progress.exhausted, "changing an empty glob or sending a nudge is not progress")
        progress.observe(tool: "read_file", args: ["path": "found.swift"],
            result: ToolResult(success: true, output: "source"), visibleBody: "source", readOnly: true)
        XCTAssertFalse(progress.exhausted)
    }

    func testLargeBudgetsStillNudgeWithinSixStalledCalls() {
        XCTAssertTrue(HeadlessAgentLoop.shouldForceSynthesis(
            consecutiveGathering: 6, iteration: 9, lastNudge: -100, maxIterations: 100))
    }

    func testDistinctDirectoriesWithSameEntriesRemainNewEvidence() {
        var progress = HeadlessGatheringProgress()
        for index in 0..<20 {
            progress.observe(tool: "list_files", args: ["path": "project-\(index)"],
                result: ToolResult(success: true, output: "README.md"), visibleBody: "README.md", readOnly: true)
            XCTAssertEqual(progress.callsWithoutProgress, 0)
        }
    }

    func testOnlyRepeatedOrFailedObservationsCountAsStalledGathering() {
        var progress = HeadlessGatheringProgress()
        let result = ToolResult(success: true, output: "same contents")
        let prefix = String(repeating: "long-directory/", count: 5)
        for index in 0..<40 {
            progress.observe(tool: "read_file", args: ["path": prefix + "\(index).txt"],
                             result: result, visibleBody: result.output, readOnly: true)
            XCTAssertEqual(progress.stalledCalls, 0)
        }
        let args: [String: Any] = ["path": prefix + "39.txt"]
        for index in 1...6 {
            progress.observe(tool: "read_file", args: args, result: result,
                             visibleBody: result.output, readOnly: true)
            XCTAssertEqual(progress.stalledCalls, index)
        }
        progress.observe(tool: "read_file", args: args, result: result,
                         visibleBody: "changed contents", readOnly: true)
        XCTAssertEqual(progress.stalledCalls, 0)
        progress.observe(tool: "read_file", args: ["path": "absent"],
                         result: ToolResult(success: false, output: "", error: "missing"),
                         visibleBody: "missing", readOnly: true)
        XCTAssertEqual(progress.stalledCalls, 1)
        progress.didNudge()
        XCTAssertEqual(progress.stalledCalls, 0)
    }

    func testFiresAfterThresholdGathering() {
        // maxIterations 12 → threshold 6.
        XCTAssertFalse(HeadlessAgentLoop.shouldForceSynthesis(consecutiveGathering: 5, iteration: 5, lastNudge: -100, maxIterations: 12))
        XCTAssertTrue(HeadlessAgentLoop.shouldForceSynthesis(consecutiveGathering: 6, iteration: 6, lastNudge: -100, maxIterations: 12))
    }

    func testDoesNotSpamWithinAWindow() {
        // Just nudged at iteration 6; at iteration 8 (only 2 later) it must NOT fire again.
        XCTAssertFalse(HeadlessAgentLoop.shouldForceSynthesis(consecutiveGathering: 6, iteration: 8, lastNudge: 6, maxIterations: 12))
        // A full window later it can fire again.
        XCTAssertTrue(HeadlessAgentLoop.shouldForceSynthesis(consecutiveGathering: 6, iteration: 12, lastNudge: 6, maxIterations: 12))
    }

    func testFloorThresholdForSmallBudgets() {
        // maxIterations 4 → threshold floors at 4 (not 2).
        XCTAssertFalse(HeadlessAgentLoop.shouldForceSynthesis(consecutiveGathering: 3, iteration: 3, lastNudge: -100, maxIterations: 4))
        XCTAssertTrue(HeadlessAgentLoop.shouldForceSynthesis(consecutiveGathering: 4, iteration: 4, lastNudge: -100, maxIterations: 4))
    }

    func testSteeringTellsItToStopAndSynthesize() {
        let s = HeadlessAgentLoop.synthesisSteering().lowercased()
        XCTAssertTrue(s.contains("stop gathering"))
        XCTAssertTrue(s.contains("synthesize"))
        XCTAssertTrue(s.contains("done"))
    }

    func testFinalSteeringForTextProtocolForbidsMoreTools() {
        let s = HeadlessAgentLoop.finalSynthesisSteering(textProtocol: true).lowercased()
        XCTAssertTrue(s.contains("final answer pass"))
        XCTAssertTrue(s.contains("do not call any more tools"))
        XCTAssertTrue(s.contains(#""done":true"#))
    }

    func testFinalOnlySystemPromptDoesNotAdvertiseTools() {
        let text = HeadlessAgentLoop.finalOnlySystemPrompt(textProtocol: true).lowercased()
        XCTAssertTrue(text.contains("final answer only"))
        XCTAssertTrue(text.contains("there are no tools available"))
        XCTAssertFalse(text.contains("available tools"))
        XCTAssertFalse(text.contains("read_file"))

        let native = HeadlessAgentLoop.finalOnlySystemPrompt(textProtocol: false).lowercased()
        XCTAssertTrue(native.contains("there are no tools available"))
        XCTAssertTrue(native.contains("answer in plain text"))
    }

    func testResumeBudgetIsRelativeToCheckpointCursor() {
        XCTAssertEqual(HeadlessAgentLoop.iterationLimit(from: 10, budget: 6), 16)
        XCTAssertNil(HeadlessAgentLoop.iterationLimit(from: Int.max, budget: 6))
        XCTAssertNil(HeadlessAgentLoop.iterationLimit(from: 0, budget: 0))
    }
}
