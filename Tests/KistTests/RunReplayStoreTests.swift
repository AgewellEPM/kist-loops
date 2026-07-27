import XCTest
@testable import Kist

final class RunReplayStoreTests: XCTestCase {

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
}
