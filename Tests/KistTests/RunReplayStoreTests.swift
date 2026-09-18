import XCTest
import AgentCore
@testable import Kist

final class RunReplayStoreTests: XCTestCase {

    func testResumePreservesManifestAndMonotonicEventSequence() throws {
        let root = NSTemporaryDirectory() + "replay-resume-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let original = RunReplayStore(projectRoot: root, provider: "first", model: nil, runID: "mission")
        original.startTurn(goal: "first turn")
        original.recordEvent(kind: "checkpoint", text: "paused")
        let resumed = RunReplayStore(projectRoot: root, provider: "second", model: "new", runID: "mission")
        resumed.startTurn(goal: "continue")
        XCTAssertEqual(resumed.manifest, original.manifest)
        let events = RunReplayStore.loadEvents(projectRoot: root, runID: "mission")
        XCTAssertEqual(events.map(\.sequence), [1, 2, 3, 4])
        XCTAssertEqual(events[2].kind, "runResumed")
        XCTAssertTrue(events[2].text.contains("second:new"))
    }

    func testMissingInvalidAndExistingReplayHaveDistinctExitStatuses() throws {
        let root = NSTemporaryDirectory() + "replay-status-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertEqual(KistRunner.replayRun(projectRoot: root, id: "absent"), 1)
        XCTAssertEqual(KistRunner.replayRun(projectRoot: root, id: "../outside"), 2)
        _ = RunReplayStore(projectRoot: root, provider: "codex-cli", model: "test", runID: "exists")
        XCTAssertEqual(KistRunner.replayRun(projectRoot: root, id: "exists"), 0)
    }

    func testCompilerDiagnosticsAndContractSurviveExecutionWorkspaceCleanup() throws {
        let root = NSTemporaryDirectory() + "replay-retention-\(UUID().uuidString)"
        let staging = root + "-staging"
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: staging)
        }
        let replay = RunReplayStore(projectRoot: root, provider: "codex-cli", model: "test",
                                    runID: "build-attempt", executionRoot: staging,
                                    parentContractID: "contract-42")
        let proof = TurnProofStore(replayStore: replay)
        proof.startTurn(goal: "create a parser")
        let sink = TerminalEventSink(color: false, style: .calm, proofStore: proof)
        sink.emit(.actionStarted(index: 1, tool: "run_command", description: "make verify"))
        sink.emit(.actionFinished(index: 1, success: false,
            output: "solution.c:17: error: expected ';'\nsecret sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef",
            error: "exit code 2; allowed exit codes: [0]"))
        try FileManager.default.removeItem(atPath: staging)

        let rendered = RunReplayStore.read(projectRoot: root, id: "build-attempt")
        XCTAssertEqual(rendered.exitCode, 0)
        XCTAssertTrue(rendered.text.contains("contract-42"))
        XCTAssertTrue(rendered.text.contains("exit code 2"))
        XCTAssertTrue(rendered.text.contains("solution.c:17: error: expected ';'"))
        XCTAssertTrue(proof.renderLast().contains("solution.c:17: error: expected ';'"))
        XCTAssertFalse(rendered.text.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        XCTAssertFalse(proof.renderLast().contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    }

    func testReplayLimitKeepsTheFinalFailureVisible() {
        let root = NSTemporaryDirectory() + "replay-tail-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let replay = RunReplayStore(projectRoot: root, provider: "test", model: nil, runID: "tail")
        for index in 1...125 {
            replay.record(.init(kind: .actionFinished, tool: "read_file", success: true, text: "read \(index)"))
        }
        replay.record(.init(kind: .failed, tool: nil, success: false, text: "final compiler failure"))
        let rendered = RunReplayStore.render(projectRoot: root, id: "tail", limit: 2)
        XCTAssertTrue(rendered.contains("124 earlier event(s)"))
        XCTAssertTrue(rendered.contains("final compiler failure"))
    }

    func testReplayPersistsProofEventsAndRedactsSecrets() throws {
        let root = NSTemporaryDirectory() + "kist-replay-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let store = RunReplayStore(projectRoot: root, provider: "gemini", model: "gemini-3.1-pro",
                                   runID: "test-run")
        let proof = TurnProofStore(replayStore: store)
        proof.startTurn(goal: "build from screenshot")
        proof.record(.init(kind: .actionStarted, tool: "view_image", success: nil, text: "\(root)/shot.png"))
        proof.record(.init(kind: .actionFinished, tool: "view_image", success: true,
                           text: "secret sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef"))
        proof.record(.init(kind: .completed, tool: nil, success: true, text: "done"))

        let rendered = RunReplayStore.render(projectRoot: root, id: "test-run", limit: 20)

        XCTAssertTrue(rendered.contains("Replay test-run"))
        XCTAssertTrue(rendered.contains("Model: gemini:gemini-3.1-pro"))
        XCTAssertTrue(rendered.contains("turnStarted"))
        XCTAssertTrue(rendered.contains("view_image"))
        XCTAssertTrue(rendered.contains("ok - done"))
        XCTAssertFalse(rendered.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        XCTAssertEqual(RunReplayStore.latestRunID(projectRoot: root), "test-run")
    }

    func testReplayAppendIsSerializedForConcurrentProofEvents() throws {
        let root = NSTemporaryDirectory() + "kist-replay-concurrent-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = RunReplayStore(projectRoot: root, provider: "gemini", model: nil, runID: "concurrent-run")
        let proof = TurnProofStore(replayStore: store)
        proof.startTurn(goal: "concurrent events")

        let count = 300
        DispatchQueue.concurrentPerform(iterations: count) { i in
            proof.record(.init(kind: .actionFinished, tool: "tool-\(i % 7)", success: true, text: "event-\(i)"))
        }

        let events = RunReplayStore.loadEvents(projectRoot: root, runID: "concurrent-run")
        XCTAssertEqual(events.count, count + 1)
        XCTAssertEqual(events.map(\.sequence), Array(1...(count + 1)))
        XCTAssertEqual(Set(events.map(\.sequence)).count, count + 1)
        let texts = Set(events.map(\.text))
        for i in 0..<count {
            XCTAssertTrue(texts.contains("event-\(i)"), "missing event-\(i)")
        }
    }

    func testReplayRejectsTraversalShapedIDs() throws {
        let root = NSTemporaryDirectory() + "kist-replay-invalid-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let rendered = RunReplayStore.render(projectRoot: root, id: "../outside")

        XCTAssertTrue(rendered.contains("Invalid replay id"))
        XCTAssertTrue(RunReplayStore.loadEvents(projectRoot: root, runID: "../outside").isEmpty)
    }

    func testReplayDistinguishesTurnDecisionsAndOneCanonicalFinal() {
        let root = NSTemporaryDirectory() + "kist-replay-typed-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = RunReplayStore(projectRoot: root, provider: "openai", model: "gpt",
                                   runID: "typed-turn")
        let proof = TurnProofStore(replayStore: store)
        proof.startTurn(goal: "fix the parser")
        proof.record(.init(kind: .routeSelected, tool: nil, success: nil,
                           text: "intent=build execution=inline model=openai:gpt"))
        proof.record(.init(kind: .reviewAssessment, tool: nil, success: nil,
                           text: "not requested"))
        proof.record(.init(kind: .verificationAssessment, tool: nil, success: true,
                           text: "passed: swift test"))
        proof.record(.init(kind: .turnFinalized, tool: nil, success: true,
                           text: "parser fixed"))

        let events = RunReplayStore.loadEvents(projectRoot: root, runID: "typed-turn")

        XCTAssertEqual(events.filter { $0.kind == "turnFinalized" }.count, 1)
        XCTAssertTrue(events.contains { $0.kind == "routeSelected" })
        XCTAssertTrue(events.contains { $0.kind == "verificationAssessment" })
    }

    func testREPLActuallyEmitsTypedTurnDecisions() throws {
        let repl = kistREPLFamilySource()

        XCTAssertTrue(repl.contains("kind: .routeSelected"))
        XCTAssertTrue(repl.contains("kind: .reviewAssessment"))
        XCTAssertTrue(repl.contains("kind: .verificationAssessment"))
        XCTAssertTrue(repl.contains("kind: .turnFinalized"))
        XCTAssertTrue(repl.contains("await router.resolve(messageText, mode: turnMode,"),
                      "pragmatic outcome resolution must run before execution routing")
        XCTAssertTrue(repl.contains("previous: lastOutcomeContract"),
                      "resolution must consume the last host-admitted goal")
        XCTAssertTrue(repl.contains("humanTranscript, turnOutcome"),
                      "prompt compilation must consume the same outcome contract persisted by the turn")
        XCTAssertTrue(repl.contains("guard lastTurnInterruption != .cancel"),
                      "a hard-cancelled turn must not leave continuation authority behind")
        XCTAssertTrue(repl.contains("rawRequest: messageText, resolvedIntent: turnIntent"),
                      "the existing REPL must pass its canonical contract into AgentCore")
        XCTAssertTrue(repl.contains("expected == .mutation, !fulfilledMutationContract"),
                      "a promised build/fleet result must not finalize successfully as a no-op")
    }
}
