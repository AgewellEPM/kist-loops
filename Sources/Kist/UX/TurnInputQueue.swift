import Foundation

/// R2a (2026-07-28): keystrokes typed WHILE a turn runs. The InterruptibleTurn watcher already owns
/// stdin during a turn and used to DISCARD every non-ESC byte; now it feeds them here. The live
/// status line renders the pending text (you can see what you're typing 24/7), Enter commits a line
/// to a FIFO of queued messages, and the REPL drains the queue through its normal input path at the
/// next boundary — or immediately on single-ESC interject. Double-ESC (hard cancel) clears it all.
///
/// Collection is OPT-IN per turn (`begin()`/`end()`): only surfaces whose loop actually drains the
/// queue (the line-mode REPL and its plan-execute/council/research escalations) enable it — the TUI
/// keeps its old discard behavior until it grows a drain path (R2b).
final class TurnInputQueue: @unchecked Sendable {
    static let shared = TurnInputQueue()

    private let lock = NSLock()
    private var collecting = false
    private var bytes: [UInt8] = []      // uncommitted UTF-8 being typed (bounded)
    private var queued: [String] = []    // committed lines (Enter), FIFO
    private var typedThisTurn = false    // did any byte arrive since begin()? gates commitPending
    private var changeHooks: [@Sendable () -> Void] = []
    private static let maxPendingBytes = 4096
    private static let maxHooks = 8

    /// Register a re-render hook (typing feedback must not wait for the 1s spinner tick).
    /// ADDITIVE with a small cap: side-built loops (vision borrow, model substitution) register
    /// their own sinks without unregistering the active one — a single slot would leave the
    /// live sink's per-keystroke refresh dead after any side turn (review catch). Stale hooks
    /// no-op safely: refreshLiveStatus only writes while ITS spinner is on screen.
    func addOnChange(_ hook: @escaping @Sendable () -> Void) {
        lock.lock()
        changeHooks.append(hook)
        if changeHooks.count > Self.maxHooks { changeHooks.removeFirst() }
        lock.unlock()
    }

    func begin() { lock.lock(); collecting = true; typedThisTurn = false; lock.unlock() }
    func end() { lock.lock(); collecting = false; lock.unlock() }

    /// A committed line is only queued as a real instruction if it has SOME alphanumeric content — a stray
    /// punctuation keystroke ("$", ";", "!") is not an instruction and must never become the next turn
    /// (the garbage-turn bug: a queued "$" ran `ask_user` instead of the user's real question). Pure/testable.
    static func isQueueableInstruction(_ line: String) -> Bool {
        line.rangeOfCharacter(from: .alphanumerics) != nil
    }

    /// One raw byte from the watcher. Printable bytes accumulate; Enter commits a line;
    /// backspace removes the last UTF-8 scalar; other control bytes are ignored.
    func feed(_ b: UInt8) {
        lock.lock()
        guard collecting else { lock.unlock(); return }
        switch b {
        case 0x0D, 0x0A:                                  // Enter → commit the line
            let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            bytes.removeAll()
            if !line.isEmpty, Self.isQueueableInstruction(line) { queued.append(line) }
        case 0x7F, 0x08:                                  // backspace → drop last scalar:
            // strip trailing CONTINUATION bytes (10xxxxxx) first, then the lead byte.
            while let last = bytes.last, last & 0b1100_0000 == 0b1000_0000 { bytes.removeLast() }
            if !bytes.isEmpty { bytes.removeLast() }
        case 0x00..<0x20:                                 // other control bytes: ignore
            break
        default:
            if bytes.count < Self.maxPendingBytes { bytes.append(b) }
        }
        typedThisTurn = true
        let hooks = changeHooks
        lock.unlock()
        for hook in hooks { hook() }
    }

    /// Snapshot for the live status line: what's being typed + how many messages wait.
    func preview() -> (pending: String, queuedCount: Int) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: bytes, as: UTF8.self), queued.count)
    }

    /// Next queued message (FIFO) — drained by the REPL's deferredInput chain.
    func popQueued() -> String? {
        lock.lock(); defer { lock.unlock() }
        return queued.isEmpty ? nil : queued.removeFirst()
    }

    /// Take the uncommitted text (e.g. to seed the next prompt box), clearing it.
    func takePending() -> String {
        lock.lock(); defer { lock.unlock() }
        let s = String(decoding: bytes, as: UTF8.self)
        bytes.removeAll()
        return s
    }

    /// Single-ESC interject: what you typed IS your instruction — commit it so the drain
    /// picks it up immediately. ONLY text typed during THIS turn commits (review catch: stale
    /// half-typed text from turns ago must never auto-execute on a later interject — it stays
    /// pending and seeds the next prompt box instead).
    func commitPending() {
        lock.lock()
        guard typedThisTurn else { lock.unlock(); return }
        let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        bytes.removeAll()
        if !line.isEmpty, Self.isQueueableInstruction(line) { queued.append(line) }
        lock.unlock()
    }

    /// Double-ESC hard cancel: drop everything (typed + queued).
    func clearAll() {
        lock.lock(); bytes.removeAll(); queued.removeAll(); lock.unlock()
    }
}
