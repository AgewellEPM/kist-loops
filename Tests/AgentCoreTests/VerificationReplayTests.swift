import XCTest
import Foundation
@testable import AgentCore

/// Pins the symbolic re-verify replay (dogfood find 2026-08-06): a done-claim with an
/// unverified source edit must FIRST replay the last passing build/test of the run
/// deterministically — the model only gets nudged when no replay exists or it fails.
/// (The COBOL round: kist built + ran the app, made one more correct edit, said done,
/// ignored the nudges, and a correct result failed unverified. The loop now proves the
/// edit itself.)
final class VerificationReplayTests: XCTestCase {

    private var root: String!
    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "replay-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
    }
    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }

    private func loop(_ responses: [String], maxIterations: Int = 10) -> HeadlessAgentLoop {
        let registry = ProviderRegistry(providers: [ScriptedProvider(responses)], keyStore: NullKeyStore())
        return HeadlessAgentLoop(providers: registry, providerId: "scripted", model: nil,
                                 tools: .headless(),
                                 context: ToolContext(projectRoot: root,
                                                      shell: ShellPolicy(enabled: true, autoApprove: true)),
                                 sink: NullEventSink(), maxIterations: maxIterations)
    }

    /// build passes → source edit → "done": the loop replays the build itself and ACCEPTS —
    /// no nudge round-trip, the model's later scripted claims are never consumed.
    func testReplayOfPassingBuildAcceptsDoneAfterFinalEdit() async throws {
        // `make` (no args) classifies as buildOrTest; the target always succeeds.
        try "all:\n\t@echo build-ok\n".write(toFile: root + "/Makefile", atomically: true, encoding: .utf8)

        let out = await loop([
            #"{"tool":"run_command","parameters":{"executable":"make","args":[]}}"#,
            #"{"tool":"write_file","parameters":{"path":"Sources/New.swift","content":"struct New {}"}}"#,
            #"{"done":true,"summary":"done after final edit"}"#,
            // If the loop asked the model instead of replaying, these would be consumed:
            #"{"done":true,"summary":"nudge-consumed-1"}"#,
            #"{"done":true,"summary":"nudge-consumed-2"}"#,
        ]).run(goal: "add a Swift source file with a verified build")

        XCTAssertTrue(out.success, out.summary)
        XCTAssertEqual(out.summary, "done after final edit",
                       "the FIRST done claim must be accepted via deterministic replay, not a later nudge round")
    }

    /// The replayed build FAILS on re-run: the loop must fall back to nudging and finally
    /// fail HONESTLY as unverified — a broken re-verify can never launder success.
    func testFailingReplayFallsBackToNudgeThenHonestFailure() async throws {
        // First `make` passes and drops a marker; every re-run fails on the marker.
        try "all:\n\t@test ! -f ran.marker\n\t@touch ran.marker\n"
            .write(toFile: root + "/Makefile", atomically: true, encoding: .utf8)

        let out = await loop([
            #"{"tool":"run_command","parameters":{"command":"make"}}"#,
            #"{"tool":"write_file","parameters":{"path":"Sources/New.swift","content":"struct New {}"}}"#,
            #"{"done":true,"summary":"done after final edit"}"#,
            #"{"done":true,"summary":"still claiming done"}"#,
            #"{"done":true,"summary":"insisting done"}"#,
            #"{"done":true,"summary":"final insistence"}"#,
        ]).run(goal: "add a Swift source file with a verified build")

        XCTAssertFalse(out.success, out.summary)
        XCTAssertTrue(out.summary.lowercased().contains("unverified"), out.summary)
    }

    /// Source pin (multi-site): BOTH done sites route through the replay-aware decision —
    /// a missed sibling would silently keep the old nudge-only behavior on one path.
    func testBothDoneSitesConsultReplay() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for file in ["HeadlessAgentLoop.swift", "HeadlessAgentLoop+TextDrive.swift"] {
        let src = try String(contentsOf: repo.appendingPathComponent("Sources/AgentCore/" + file), encoding: .utf8)
        let replayGates = src.components(separatedBy: "if case .nudge = doneDecision, let replay = lastVerify").count - 1
        XCTAssertGreaterThanOrEqual(replayGates, 1,
            "both done sites (text + native) must attempt the deterministic replay before nudging")
        let captures = src.components(separatedBy: "Self.replayCandidate(").count - 1
        XCTAssertGreaterThanOrEqual(captures, 1,
            "both execution sites (text + native) must capture the replay candidate")
        }
    }
}

// File-private test doubles (per-file duplication is this suite's convention).
private struct NullKeyStore: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

/// Returns canned completions in sequence (one per `stream` call).
private final class ScriptedProvider: ChatProvider {
    let id = "scripted", name = "Scripted", iconName = "cpu"
    let requiresAPIKey = false, keyAccount = "scripted", defaultModel = "scripted-1"
    let availableModels = [AIModel(id: "scripted-1")]
    private let responses: ScriptedResponses
    init(_ responses: [String]) { self.responses = ScriptedResponses(responses) }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let r = await responses.next()
        return AsyncThrowingStream { cont in cont.yield(.delta(r)); cont.finish() }
    }
}

private actor ScriptedResponses {
    private let responses: [String]
    private var idx = 0
    init(_ responses: [String]) { self.responses = responses }
    func next() -> String {
        defer { idx += 1 }
        return idx < responses.count ? responses[idx] : #"{"done":true,"summary":"(out of script)"}"#
    }
}
