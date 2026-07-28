import XCTest
import AgentCore
@testable import Kist

/// R2a (2026-07-28): type-while-working. The turn watcher feeds non-ESC bytes into TurnInputQueue,
/// the live status line renders them, Enter queues messages (FIFO) drained via the REPL's
/// deferredInput chain, and half-typed text seeds the next prompt box. Single-ESC commits the
/// pending text as the next instruction; double-ESC drops everything.
final class R2TypedInputTests: XCTestCase {

    private func freshQueue() -> TurnInputQueue {
        let q = TurnInputQueue()
        q.begin()
        return q
    }

    private func type(_ s: String, into q: TurnInputQueue) {
        for b in Array(s.utf8) { q.feed(b) }
    }

    // MARK: - queue mechanics

    func testTypedBytesAccumulateAndEnterQueues() {
        let q = freshQueue()
        type("fix the tests", into: q)
        XCTAssertEqual(q.preview().pending, "fix the tests")
        XCTAssertEqual(q.preview().queuedCount, 0)
        q.feed(0x0D)   // Enter
        XCTAssertEqual(q.preview().pending, "")
        XCTAssertEqual(q.preview().queuedCount, 1)
        XCTAssertEqual(q.popQueued(), "fix the tests")
        XCTAssertNil(q.popQueued())
    }

    func testQueueIsFIFO() {
        let q = freshQueue()
        type("first", into: q); q.feed(0x0A)
        type("second", into: q); q.feed(0x0A)
        XCTAssertEqual(q.popQueued(), "first")
        XCTAssertEqual(q.popQueued(), "second")
    }

    func testBackspaceRemovesWholeUTF8Scalar() {
        let q = freshQueue()
        type("café", into: q)          // é = 2 bytes
        q.feed(0x7F)                   // backspace
        XCTAssertEqual(q.preview().pending, "caf", "backspace must remove the whole scalar, not one byte")
    }

    func testControlBytesIgnoredAndEmptyEnterDoesNotQueue() {
        let q = freshQueue()
        q.feed(0x09); q.feed(0x03)     // tab, Ctrl-C
        XCTAssertEqual(q.preview().pending, "")
        q.feed(0x0D)                   // Enter on empty buffer
        XCTAssertEqual(q.preview().queuedCount, 0)
    }

    func testNotCollectingUnlessBegun() {
        let q = TurnInputQueue()       // no begin()
        type("ghost", into: q)
        XCTAssertEqual(q.preview().pending, "", "feed must be a no-op outside a collecting turn (TUI keeps old behavior)")
    }

    func testCommitPendingQueuesTypedTextForInterject() {
        let q = freshQueue()
        type("use deepseek instead", into: q)
        q.commitPending()
        XCTAssertEqual(q.popQueued(), "use deepseek instead", "single-ESC: typed text IS the next instruction")
    }

    func testStaleTextFromEarlierTurnNeverAutoCommits() {
        // Review catch: half-typed text from turns ago must not auto-execute on a later interject.
        let q = freshQueue()
        type("half a thought", into: q)
        q.end()
        q.begin()                       // NEW turn, nothing typed yet
        q.commitPending()               // interject on the new turn
        XCTAssertNil(q.popQueued(), "stale pending text must NOT commit")
        XCTAssertEqual(q.preview().pending, "half a thought", "…it stays pending to seed the next prompt box")
        type("!", into: q)              // but text typed THIS turn commits fine
        q.commitPending()
        XCTAssertEqual(q.popQueued(), "half a thought!")
    }

    func testClearAllDropsEverythingForHardCancel() {
        let q = freshQueue()
        type("queued one", into: q); q.feed(0x0D)
        type("half typed", into: q)
        q.clearAll()
        XCTAssertEqual(q.preview().pending, "")
        XCTAssertNil(q.popQueued())
    }

    func testTakePendingSeedsPromptAndClears() {
        let q = freshQueue()
        type("half a thought", into: q)
        XCTAssertEqual(q.takePending(), "half a thought")
        XCTAssertEqual(q.preview().pending, "")
    }

    // MARK: - watcher collection

    private func scan(_ script: [UInt8?], into q: TurnInputQueue) -> InterruptibleTurn.WatchAction {
        var s = script[...]
        return InterruptibleTurn.scanOnce(readByte: { s.isEmpty ? nil : s.removeFirst() },
                                          collect: { q.feed($0) })
    }

    func testWatcherCollectsTypedKeysButNotSequenceTails() {
        let q = freshQueue()
        XCTAssertEqual(scan([0x68], into: q), InterruptibleTurn.WatchAction.none)   // 'h'
        XCTAssertEqual(scan([0x69], into: q), InterruptibleTurn.WatchAction.none)   // 'i'
        XCTAssertEqual(q.preview().pending, "hi")
        // Arrow key: swallowed whole, its bytes must NOT leak into the buffer.
        XCTAssertEqual(scan([0x1B, 0x5B, 0x41], into: q), .swallowedSequence)
        XCTAssertEqual(q.preview().pending, "hi")
    }

    func testKeyDuringESCWindowIsKeptAndESCInterjects() {
        let q = freshQueue()
        XCTAssertEqual(scan([0x1B, nil, 0x78], into: q), .interject)   // ESC … 'x'
        XCTAssertEqual(q.preview().pending, "x", "the key that closed the ESC window must not be lost")
    }

    // MARK: - bracketed paste (review catch: a paste with ESC must not hard-cancel the turn)

    private func pasteBytes(_ payload: String) -> [UInt8?] {
        Array("\u{1B}[200~".utf8).map { UInt8?($0) } + Array(payload.utf8).map { UInt8?($0) }
            + Array("\u{1B}[201~".utf8).map { UInt8?($0) }
    }

    func testPasteSpanIsCollectedAsTextNotKeystrokes() {
        let q = freshQueue()
        XCTAssertEqual(scan(pasteBytes("hello world"), into: q), .swallowedSequence)
        XCTAssertEqual(q.preview().pending, "hello world")
    }

    func testPasteContainingESCDoesNotCancel() {
        let q = freshQueue()
        // Raw ESC inside the payload is dropped by feed() (control byte), never treated as intent.
        XCTAssertEqual(scan(pasteBytes("a\u{1B}b"), into: q), .swallowedSequence)
        XCTAssertEqual(q.preview().pending, "ab")
    }

    func testPasteWithNewlinesQueuesLines() {
        let q = freshQueue()
        _ = scan(pasteBytes("first line\nsecond line\n"), into: q)
        XCTAssertEqual(q.popQueued(), "first line")
        XCTAssertEqual(q.popQueued(), "second line")
    }

    func testUnterminatedPasteCannotWedgeTheWatcher() {
        let q = freshQueue()
        // No 201~ terminator and the stream goes quiet: bounded timeout bail, bytes kept.
        let script: [UInt8?] = Array("\u{1B}[200~ok".utf8).map { UInt8?($0) } + Array(repeating: nil, count: 25)
        XCTAssertEqual(scan(script, into: q), .swallowedSequence)
        XCTAssertEqual(q.preview().pending, "ok")
    }

    // MARK: - status-line tail formatting

    func testTypedInputTailFormatting() {
        XCTAssertEqual(TerminalEventSink.typedInputTail(pending: "", queuedCount: 0), "")
        XCTAssertTrue(TerminalEventSink.typedInputTail(pending: "", queuedCount: 2).contains("2 queued"))
        XCTAssertTrue(TerminalEventSink.typedInputTail(pending: "abc", queuedCount: 0).contains("▸ abc"))
        let long = String(repeating: "x", count: 60) + "END"
        let tail = TerminalEventSink.typedInputTail(pending: long, queuedCount: 0)
        XCTAssertTrue(tail.contains("END"), "truncation must keep the TAIL (what the user is editing)")
        XCTAssertTrue(tail.contains("…"))
    }

    // MARK: - wiring pins (SURFACES pattern)

    func testR2WiringStaysIntact() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func src(_ rel: String) throws -> String {
            try String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8)
        }

        // Runner: drain chain + sink typed-input provider + all three escalation begin() sites.
        let runner = try src("Sources/Kist/KistRunner.swift")
        XCTAssertTrue(runner.contains("TurnInputQueue.shared.popQueued"),
                      "the deferredInput chain no longer drains typed messages")
        XCTAssertTrue(runner.contains("typedInput: { TurnInputQueue.shared.preview() }"),
                      "the REPL sink lost its typed-input renderer — typing mid-turn is invisible again")
        XCTAssertGreaterThanOrEqual(runner.components(separatedBy: "TurnInputQueue.shared.begin()").count - 1, 3,
                                    "an escalation surface (plan-execute/council/research) stopped collecting typed input")
        // BOTH REPL sink construction sites use the shared constructor (review catch: the initial
        // loop's sink missed the provider → invisible capture on fresh/pinned sessions).
        XCTAssertGreaterThanOrEqual(runner.components(separatedBy: "sinkOverride: makeReplSink(").count - 1, 2,
                                    "a REPL sink construction site stopped using makeReplSink — typing goes invisible on that path")
        // The plan-execute surface renders typed input too (longest-running surface).
        XCTAssertTrue(runner.contains("planSink.refreshLiveStatus"),
                      "plan-execute lost its typed-input rendering — typing is blind during plan runs")

        // The keystroke refresh must only write while the spinner is ACTUALLY on screen — gating
        // on liveStartedAt alone shredded streamed prose (review catch).
        let sinkSrc = try src("Sources/Kist/TerminalEventSink.swift")
        XCTAssertTrue(sinkSrc.contains("state.timer != nil"),
                      "refreshLiveStatus lost its on-screen guard — typing during streaming corrupts the answer")

        // Interject means the user's instruction runs NEXT: no auto repair mission, no copilot
        // call, no model-substitution rerun first (review catch; one pin per gated site).
        let repl0 = try src("Sources/Kist/KistREPL.swift")
        XCTAssertTrue(repl0.contains("!success, !lastTurnInterrupted"),
                      "failure analysis no longer skips ESC'd turns — interject opens repair missions again")
        XCTAssertTrue(repl0.contains("guard !lastTurnInterrupted else { return }"),
                      "copilot review no longer skips ESC'd turns")
        XCTAssertTrue(repl0.contains("!lastTurnInterrupted,   // R2a: never re-run a turn the USER stopped"),
                      "model substitution can re-run a turn the user just ESC'd")

        // TUI must NOT begin() collection until it grows a drain path (black-hole guard).
        let tui = try src("Sources/Kist/TUI/TUIConversation.swift")
        XCTAssertFalse(tui.contains("TurnInputQueue.shared.begin"),
                       "TUIConversation began collecting typed input but has no drain — Enter'd messages black-hole")

        // REPL: collection lifecycle + interject-commit/cancel-clear + prompt seeding.
        let repl = try src("Sources/Kist/KistREPL.swift")
        XCTAssertTrue(repl.contains("TurnInputQueue.shared.begin()"), "chat turns stopped collecting typed input")
        XCTAssertTrue(repl.contains("TurnInputQueue.shared.commitPending()"),
                      "interject no longer turns typed text into the next instruction")
        XCTAssertTrue(repl.contains("TurnInputQueue.shared.clearAll()"),
                      "hard cancel no longer drops typed/queued input")
        XCTAssertTrue(repl.contains("initialText: TurnInputQueue.shared.takePending()"),
                      "half-typed text no longer survives into the next prompt box")

        // Watcher: bytes flow to the queue.
        let watcher = try src("Sources/Kist/UX/InterruptibleTurn.swift")
        XCTAssertTrue(watcher.contains("TurnInputQueue.shared.feed"),
                      "the turn watcher went back to DISCARDING typed keys")
    }
}
