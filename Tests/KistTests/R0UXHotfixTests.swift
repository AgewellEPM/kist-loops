import XCTest
import AgentCore
@testable import Kist

/// R0 UX hotfixes (2026-07-28) — the four fixes behind the "78 minutes at ~0 tok" hang and the
/// "arrow key cancels my turn" bug. See docs/CAPTAIN_UX_OVERHAUL_PLAN_2026_07_28.md § R0.
final class R0UXHotfixTests: XCTestCase {

    // MARK: R0.3 — ESC-vs-CSI disambiguation in the interrupt watcher

    /// Feed a scripted byte stream (nil = VTIME timeout) to the pure scanner.
    private func scan(_ script: [UInt8?]) -> InterruptibleTurn.WatchAction {
        var s = script[...]
        return InterruptibleTurn.scanOnce(readByte: {
            s.isEmpty ? nil : s.removeFirst()
        })
    }

    func testLoneESCInterrupts() {
        // R1 refined the action: a lone ESC (window expires with no second press) = interject.
        XCTAssertEqual(scan([0x1B]), .interject, "a bare ESC press (follow-up read times out) must interrupt as interject")
    }

    func testArrowKeysDoNotInterrupt() {
        // The bug this fixes: Up-arrow = ESC [ A used to cancel the running turn.
        let arrows: [(String, [UInt8?])] = [
            ("Up",    [0x1B, 0x5B, 0x41]),
            ("Down",  [0x1B, 0x5B, 0x42]),
            ("Right", [0x1B, 0x5B, 0x43]),
            ("Left",  [0x1B, 0x5B, 0x44]),
        ]
        for (name, bytes) in arrows {
            XCTAssertEqual(scan(bytes), .swallowedSequence, "\(name)-arrow must NOT cancel the turn")
        }
    }

    func testModifiedCSIAndSS3AndOtherKeysSwallowed() {
        XCTAssertEqual(scan([0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x41]), .swallowedSequence, "Ctrl-Up (CSI 1;5A) swallowed")
        XCTAssertEqual(scan([0x1B, 0x5B, 0x33, 0x7E]), .swallowedSequence, "Delete (CSI 3~) swallowed")
        XCTAssertEqual(scan([0x1B, 0x4F, 0x50]), .swallowedSequence, "F1 (SS3 P) swallowed")
        XCTAssertEqual(scan([0x61]), InterruptibleTurn.WatchAction.none, "plain keys are discarded, not interrupts")
        XCTAssertEqual(scan([]), InterruptibleTurn.WatchAction.none, "timeout with no byte does nothing")
    }

    func testESCPlusNonSequenceByteStillInterrupts() {
        // R1: ESC ESC = hard cancel; an Alt-chord still counts as single-ESC intent.
        XCTAssertEqual(scan([0x1B, 0x1B]), .cancel, "ESC ESC (one burst) is a hard cancel")
        XCTAssertEqual(scan([0x1B, 0x61]), .interject, "Alt-chord (ESC+letter) treated as single-ESC intent")
    }

    func testRunawayCSIDrainIsBounded() {
        // A malformed endless parameter stream must not wedge the watcher: drain is capped.
        let junk: [UInt8?] = [0x1B, 0x5B] + Array(repeating: UInt8(0x30), count: 40)
        XCTAssertEqual(scan(junk), .swallowedSequence)
    }

    // MARK: R0.1 / R0.2 / R0.4 — source pins (SURFACES pattern) for the event fixes

    /// The three burial/starvation sites, each pinned in its own file so a regression names itself.
    func testEventFixSurfacesStayWired() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        // R0.1: TerminalEventSink must HANDLE planReady (it used to fall into `default: break`,
        // leaving the spinner timer to overwrite the approval prompt).
        let sink = try String(contentsOf: repo.appendingPathComponent("Sources/Kist/TerminalEventSink.swift"), encoding: .utf8)
        XCTAssertTrue(sink.contains("case .planReady"), "TerminalEventSink dropped its planReady handler — approval prompts can be buried by the spinner again")

        // R0.2: the dangerous-step gate must emit awaitingApproval BEFORE blocking on the prompt.
        let loop = try String(contentsOf: repo.appendingPathComponent("Sources/AgentCore/PlanExecuteLoop.swift"), encoding: .utf8)
        guard let gateRange = loop.range(of: "func approveDangerousStep") else {
            return XCTFail("approveDangerousStep not found — update this pin")
        }
        let gateBody = String(loop[gateRange.lowerBound...].prefix(700))
        XCTAssertTrue(gateBody.contains("sink.emit(.awaitingApproval"),
                      "approveDangerousStep no longer emits awaitingApproval before blocking — the spinner will overwrite the prompt")

        // R0.4: meteredComplete must surface usage to the sink (kills the '~0 tok' display lie).
        guard let mcRange = loop.range(of: "func meteredComplete") else {
            return XCTFail("meteredComplete not found — update this pin")
        }
        let mcBody = String(loop[mcRange.lowerBound...].prefix(3500))
        XCTAssertTrue(mcBody.contains("sink.emit(.usage"),
                      "meteredComplete no longer emits usage — planning shows ~0 tok for its whole window")

        // R0.4 SIBLING (review catch): coder `generate` calls are the longest in a plan and must
        // also emit usage — and PlanExecuteLoop must actually thread its sink into the tool.
        let gen = try String(contentsOf: repo.appendingPathComponent("Sources/AgentCore/Tools/GenerateTool.swift"), encoding: .utf8)
        XCTAssertTrue(gen.contains("sink?.emit(.usage"),
                      "GenerateTool no longer emits usage — coder steps show ~0 tok during execution")
        XCTAssertTrue(loop.contains("budget: budget, sink: eventSink)]"),
                      "PlanExecuteLoop no longer threads its sink into GenerateTool — the coder usage emit is dead")
        XCTAssertTrue(loop.contains("self.sink = eventSink"), "planner and coder must share the downstream event sink")

        // planReady proof honesty: the sink must record kind .planReady, NEVER .awaitingApproval
        // (that wrote phantom 'waiting for approval' entries into --yolo replay ledgers).
        guard let prRange = sink.range(of: "case .planReady") else {
            return XCTFail("planReady handler not found — update this pin")
        }
        let prBody = String(sink[prRange.lowerBound...].prefix(1500))
        XCTAssertTrue(prBody.contains("kind: .planReady"), "planReady must record its own proof kind")
        XCTAssertFalse(prBody.contains("kind: .awaitingApproval"),
                       "planReady must not masquerade as an approval wait in the fact-only replay ledger")
    }

    // MARK: planReady proof kind renders honestly

    func testPlanReadyProofKindRendersAsPlanReady() {
        let store = TurnProofStore()
        store.startTurn(goal: "test goal")
        store.record(.init(kind: .planReady, tool: nil, success: nil, text: "Plan for: test goal"))
        let rendered = store.renderLast()
        XCTAssertTrue(rendered.contains("plan ready:"), "planReady entries must render as 'plan ready', got: \(rendered)")
        XCTAssertFalse(rendered.contains("waiting for approval"),
                       "a plan that needed no approval must not claim it waited for one")
    }
}
