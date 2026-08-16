import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runs an agent turn while watching the keyboard for ESC — Claude-Code's "esc to interrupt".
/// R1 (2026-07-28) semantics:
///   • single ESC  → `.interject`: stop the turn so the user can take over (work checkpointed).
///   • double ESC  → `.cancel`: hard stop AND the caller discards the checkpoint (abandoned).
/// Either way the turn's Task is cancelled; the loops' cooperative `Task.isCancelled` checks finish
/// cleanly at the next boundary. The terminal is restored on every exit path.
///
/// While a turn runs the watcher owns stdin. Per surface (R2a): REPL turns + escalations COLLECT
/// typed keys into TurnInputQueue (rendered live, Enter queues a message); the TUI still discards
/// them (no drain path there yet — R2b). Interrupt lands at the next loop-iteration boundary —
/// after the in-flight model/tool step — not the instant ESC is pressed. Single-ESC classification
/// waits out the double-press window (~0.3s) before firing.
enum InterruptibleTurn {
    /// Why the turn was interrupted: take-over (single ESC) vs hard cancel (double ESC).
    enum InterruptReason: Equatable, Sendable { case interject, cancel }

    /// - enabled: false (pipes/tests) just runs `work` with no watcher.
    /// - onInterrupt: called once, after the turn returns, only if ESC caused the stop (for a UI notice).
    static func run<T>(enabled: Bool = isInteractive(),
                       onInterrupt: @escaping (InterruptReason) -> Void = { _ in },
                       _ work: @escaping () async -> T) async -> T {
        guard enabled else { return await work() }
        // A submitted-message session already owns stdin from routing through post-review. Borrow
        // its one watcher and only swap the cancellable task; never create a competing stdin reader.
        if let session = TurnInteractionSession.current {
            return await session.runModelTask(onInterrupt: onInterrupt, work)
        }

        let raw = RawMode()
        // Bracketed paste ON while the watcher owns stdin (R2a): a paste arrives as one
        // CSI 200~ … 201~ span and is collected as TEXT — without it, a pasted blob containing
        // ESC would hard-cancel the turn. Paired with every enable/disable transition below
        // (the prompt readers manage their own ?2004 state).
        @discardableResult
        func armWatch() -> Bool {
            raw.enableForWatch()
            guard raw.isActive else { return false }
            FileHandle.standardOutput.write(Data("\u{001B}[?2004h".utf8))
            return true
        }
        func disarmWatch() {
            if raw.isActive {
                FileHandle.standardOutput.write(Data("\u{001B}[?2004l".utf8))
            }
            raw.disable()
        }
        // Never create a background read against cooked stdin. If raw-mode setup is unavailable,
        // preserve the turn and simply run without the optional keyboard interrupt watcher.
        guard armWatch() else { return await work() }
        let flag = InterruptFlag()
        // Hand stdin off to in-turn interactor prompts (approvals / clarifying questions): while an
        // interactor reads, the watcher pauses and stdin drops back to its pre-watch mode (Codex BLOCKER).
        StdinArbiter.shared.registerWatcher(
            suspend: { disarmWatch() },
            resume: { _ = armWatch() })

        let turn = Task { await work() }
        let watcher = Task.detached {
            // On watcher exit (ESC or cancel): FIRST restore the pre-watch terminal mode, THEN release the
            // arbiter. Order matters — a waiter released by unregister runs its read with suspend==nil, so
            // raw must already be disabled or it reads in watch-raw mode (no echo) (Codex BLOCKER). And
            // unregister-in-defer (vs after the awaits below) is what prevents a post-cancel approval from
            // blocking forever on watcherPaused (Codex deadlock).
            defer { disarmWatch(); StdinArbiter.shared.unregisterWatcher() }
            while !Task.isCancelled {
                guard StdinArbiter.shared.watcherMayRead() else {   // an interactor owns stdin — yield
                    usleep(15_000); continue
                }
                // A cooked-prompt lease may fail to re-arm raw mode. Exit before read(2), which would
                // otherwise block canonically and prevent the watcher join from completing.
                guard raw.isActive else { return }
                switch scanOnce(readByte: { raw.readByteTimed() },
                                collect: { TurnInputQueue.shared.feed($0) }) {
                case .interject:
                    await flag.set(.interject)
                    turn.cancel()
                    return
                case .cancel:
                    await flag.set(.cancel)
                    turn.cancel()
                    return
                case .none, .swallowedSequence:
                    continue
                }
            }
        }

        let result = await turn.value
        watcher.cancel()
        // Join the watcher BEFORE restoring the terminal — otherwise a watcher still blocked in
        // readByteTimed() could swallow the first byte the user types into the next prompt (Codex HIGH).
        // Typical exit is 1-2 VTIME ticks (~0.1-0.2s); a scanOnce mid-sequence can take a few more
        // (drain reads check Task.isCancelled, bounding the adversarial byte-trickle case).
        _ = await watcher.value
        StdinArbiter.shared.unregisterWatcher()
        disarmWatch()
        if let reason = await flag.reason { onInterrupt(reason) }
        return result
    }

    static func isInteractive() -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        return isatty(STDIN_FILENO) != 0
        #else
        return false
        #endif
    }

    /// One watcher scan step, PURE over an injected byte reader so it's unit-testable.
    ///
    /// R0.3 (2026-07-28): the old watcher compared the RAW FIRST BYTE to 0x1B — but arrow and
    /// function keys are ESC-prefixed sequences (Up = ESC '[' 'A'), so pressing an arrow key
    /// CANCELLED the running turn. Disambiguate: after an ESC, read the follow-up byte within
    /// the VTIME window (~0.1s — terminal sequences arrive in one burst, humans can't type that
    /// fast). '['/'O' introduces a CSI/SS3 key sequence → swallow it, do NOT interrupt.
    ///
    /// R1 (2026-07-28): a real ESC is then classified by the double-press window (~0.3s):
    /// a second bare ESC inside the window → `.cancel`; window expiry or any other key →
    /// `.interject`. An ESC whose "second press" turns out to be an arrow key (CSI/SS3 prefix)
    /// counts as a SINGLE ESC with the arrow swallowed.
    enum WatchAction: Equatable { case none, swallowedSequence, interject, cancel }

    /// `collect` (R2a): non-ESC bytes are no longer discarded — they feed the TurnInputQueue so
    /// the user can TYPE while the turn runs (rendered live on the status line, Enter queues).
    /// Bytes belonging to key sequences (CSI/SS3 tails) are still swallowed, never collected.
    static func scanOnce(readByte: () -> UInt8?, collect: (UInt8) -> Void = { _ in }) -> WatchAction {
        guard let b = readByte() else { return .none }        // VTIME timeout — keep looping
        // RawMode deliberately clears ISIG, so terminal Ctrl-C arrives here as ETX instead of
        // delivering SIGINT. Treat it as the same hard-cancel intent as a bare double ESC and never
        // leak the control byte into the type-ahead queue.
        if b == 0x03 { return .cancel }
        guard b == 0x1B else { collect(b); return .none }     // typed key → the live input buffer
        guard let follow = readByte() else {                  // lone ESC so far → run the double window
            return waitForSecondEsc(readByte: readByte, collect: collect)
        }
        if follow == 0x5B || follow == 0x4F {                 // '[' (CSI) or 'O' (SS3) → a KEY, not intent
            if drainSequence(readByte) == .pasteBegin {
                collectPasteSpan(readByte, collect: collect)  // bracketed paste: payload is TEXT
            }
            return .swallowedSequence
        }
        if follow == 0x1B { return .cancel }                  // ESC ESC in one burst → hard cancel
        return .interject                                     // Alt-chord (ESC+other) → single-ESC intent
    }

    /// The double-press window: ~3 VTIME ticks (~0.3s) after a lone ESC.
    private static func waitForSecondEsc(readByte: () -> UInt8?, collect: (UInt8) -> Void) -> WatchAction {
        for _ in 0..<3 {
            if Task.isCancelled { return .interject }
            guard let b = readByte() else { continue }        // tick with no byte — keep waiting
            if b == 0x1B {
                // Second ESC. Disambiguate what follows IT:
                //   nil / another ESC → a bare second press (or hammering) → hard cancel.
                //   CSI/SS3 intro     → it was an arrow/function key → single ESC, key swallowed.
                //   any other byte    → an Alt/Meta chord — conservative: single ESC (only bare
                //                       double-ESC may trigger the destructive cancel path).
                guard let f2 = readByte() else { return .cancel }
                if f2 == 0x1B { return .cancel }
                if f2 == 0x5B || f2 == 0x4F {
                    if drainSequence(readByte) == .pasteBegin {
                        collectPasteSpan(readByte, collect: collect)
                    }
                    return .interject
                }
                return .interject
            }
            collect(b)                                        // typed key during the window is KEPT
            return .interject                                 // …and the ESC classifies as single
        }
        return .interject                                     // window expired → single ESC
    }

    /// Drain a CSI/SS3 sequence tail, bounded: CSI params end at a final byte 0x40–0x7E (SS3's
    /// single final byte is in the same range). The cancellation check keeps the watcher-join
    /// latency bounded even under an adversarial byte-per-tick trickle. Returns `.pasteBegin`
    /// when the sequence was the bracketed-paste opener (CSI 200~).
    enum DrainResult: Equatable { case key, pasteBegin }

    @discardableResult
    private static func drainSequence(_ readByte: () -> UInt8?) -> DrainResult {
        var params: [UInt8] = []
        var drained = 0
        while drained < 12, !Task.isCancelled, let nb = readByte() {
            drained += 1
            if (0x40...0x7E).contains(nb) {
                return (nb == 0x7E && params == Array("200".utf8)) ? .pasteBegin : .key
            }
            params.append(nb)
        }
        return .key
    }

    /// R2a (review catch): a PASTE during a turn must be text, not keystrokes — without this, a
    /// pasted blob containing ESC would hard-cancel the turn and wipe the queue. The watcher
    /// enables bracketed paste (?2004h) while it owns stdin, so a paste arrives as
    /// CSI 200~ <payload> CSI 201~. This feeds the payload to `collect` verbatim (feed() drops
    /// control bytes like raw ESC; newlines commit lines) until the closing marker. Bounded by
    /// bytes + consecutive-timeout count so a missing terminator can't wedge the watcher.
    private static func collectPasteSpan(_ readByte: () -> UInt8?, collect: (UInt8) -> Void) {
        let terminator: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]   // ESC [ 2 0 1 ~
        var matched = 0
        var total = 0
        var emptyReads = 0
        while total < 65_536, emptyReads < 20, !Task.isCancelled {
            guard let b = readByte() else { emptyReads += 1; continue }
            emptyReads = 0
            total += 1
            if b == terminator[matched] {
                matched += 1
                if matched == terminator.count { return }     // paste closed cleanly
                continue
            }
            if matched > 0 {                                   // false partial match → flush it
                for t in terminator[0..<matched] { collect(t) }
                matched = (b == terminator[0]) ? 1 : 0
                if matched == 1 { continue }
            }
            collect(b)
        }
    }
}

/// Tiny actor so the detached watcher and the awaiting caller share the interrupt reason safely.
/// `.cancel` is sticky — an interject can upgrade to cancel, never the reverse.
actor InterruptFlag {
    private(set) var reason: InterruptibleTurn.InterruptReason?
    func set(_ r: InterruptibleTurn.InterruptReason) {
        if reason != .cancel { reason = r }
    }
}

/// A reference cell for shuttling an `inout` value (e.g. the transcript) into and out of the escaping
/// work closure InterruptibleTurn.run takes — `inout` can't cross that boundary directly.
final class MutableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
