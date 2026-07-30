import XCTest
import AgentCore
@testable import Kist

/// Regression pins for the "every answer prints twice" bug (2026-07-29).
///
/// ROOT CAUSE: `.stateChanged(.completed)` is emitted immediately before `.completed(summary:)`. The
/// former calls `finishLiveStatus()` which zeroes `state.streamedChars`, so the old
/// `streamedChars > 0` guard on the "done" tail was ALWAYS false by the time `.completed` rendered —
/// the whole answer was re-emitted as the `● done · <full answer>` tail. The fix introduces a
/// `textWasStreamed` flag that `finishLiveStatus` does NOT touch, so the guard survives the reset.
///
/// These are SOURCE pins (the sink writes straight to stdout, so behaviour is asserted at the source
/// per the codebase convention). Per the multi-site rule, the invariant is pinned at EVERY site: both
/// sinks, all three sink terminal-event resets, and both streaming finish paths in the loop — each in
/// its own assertion so a regression names the exact site.
final class DonePrintDoublePrintTests: XCTestCase {

    private func source(_ rel: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8)
    }

    // MARK: TerminalEventSink — the guard must key on `textWasStreamed`, not the reset-prone counter

    func testTerminalSinkGuardsDoneTailOnTextWasStreamed() throws {
        let s = try source("Sources/Kist/TerminalEventSink.swift")
        XCTAssertTrue(s.contains("state.textWasStreamed = true"),
                      "TerminalEventSink must SET textWasStreamed on tokenDelta")
        XCTAssertTrue(s.contains("(state.textWasStreamed || summary.isEmpty) ? \"\" : c(\"37\", \" · \" + summary)"),
                      "the `done` tail guard must key on textWasStreamed — a streamedChars>0 guard is reset to false by finishLiveStatus before .completed renders, so the answer double-prints")
        XCTAssertFalse(s.contains("(state.streamedChars > 0 || summary.isEmpty) ? \"\""),
                      "the OLD streamedChars-based guard reintroduces the double-print (finishLiveStatus zeroes streamedChars first)")
    }

    /// `finishLiveStatus(clearOnly:false)` is the reset that broke the old guard — it must NOT touch the
    /// new flag, or the fix regresses to the exact original bug.
    func testFinishLiveStatusDoesNotResetTheStreamedFlag() throws {
        let s = try source("Sources/Kist/TerminalEventSink.swift")
        guard let range = s.range(of: "private func finishLiveStatus(") else {
            return XCTFail("finishLiveStatus not found")
        }
        let body = String(s[range.lowerBound..<(s.index(range.lowerBound, offsetBy: 500, limitedBy: s.endIndex) ?? s.endIndex)])
        XCTAssertFalse(body.contains("textWasStreamed"),
                      "finishLiveStatus must NOT reset textWasStreamed — that reset firing before .completed IS the bug")
    }

    /// SURFACES: the flag is reset at EVERY terminal event so turn N+1 starts un-streamed. One reset
    /// missed = that terminal path leaks the flag and a later tool-only turn wrongly suppresses its summary.
    func testTerminalSinkResetsFlagAtEveryTerminalEvent() throws {
        let s = try source("Sources/Kist/TerminalEventSink.swift")
        let resets = s.components(separatedBy: "state.textWasStreamed = false").count - 1
        XCTAssertGreaterThanOrEqual(resets, 3,
            "textWasStreamed must be reset at ALL THREE terminal events (completed / failed / cancelled); found \(resets) resets")
    }

    // MARK: TUIEventSink — independent second sink, identical bug shape

    func testTUISinkGuardsDoneTailOnTextWasStreamed() throws {
        let s = try source("Sources/Kist/TUI/TUIBridge.swift")
        XCTAssertTrue(s.contains("textWasStreamed = true"),
                      "TUIEventSink must SET textWasStreamed on tokenDelta")
        XCTAssertTrue(s.contains("(textWasStreamed || summary.isEmpty) ? \"\""),
                      "TUIEventSink `done` tail must guard on textWasStreamed — it too always reprinted the summary")
    }

    // MARK: HeadlessAgentLoop — the streaming finish paths must emit tokenDelta BEFORE completing

    /// The sink guard only suppresses the reprint if the full answer was actually streamed first. Both
    /// full-text finish paths must emit `.tokenDelta(<full text>)` before `.completed`. Pinned per-site.
    func testStreamingFinishPathsStreamBeforeCompleting() throws {
        let s = try source("Sources/AgentCore/HeadlessAgentLoop.swift")
        // Site B — driveNative no-tool-call: the answer text is streamed as one tokenDelta before finish.
        XCTAssertTrue(s.contains("if !text.isEmpty { sink.emit(.tokenDelta(text)) }"),
                      "driveNative no-tool-call path must stream the answer via tokenDelta before .completed, or the done-tail guard can't suppress the reprint")
        // Site C — attemptNativeFinalSynthesis: the synthesis is streamed before finishCompleted.
        XCTAssertTrue(s.contains("sink.emit(.tokenDelta(plain))"),
                      "attemptNativeFinalSynthesis must stream the synthesis via tokenDelta before finishCompleted")
    }
}
