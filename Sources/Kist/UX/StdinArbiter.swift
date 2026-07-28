import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Arbitrates the single stdin between the esc-to-interrupt watcher (which holds stdin in raw watch mode
/// for the whole turn) and interactor prompts that must read it DURING the same turn — REPL approvals
/// (cooked `readLine`, needs echo) and TUI approvals (the TUI's own raw single-key read). Without this,
/// the watcher both (a) steals the keypress and (b) leaves stdin in the wrong termios mode for the
/// interactor (Codex BLOCKER).
///
/// The watcher registers suspend/resume hooks. An interactor calls `withStdin { ... }`, which requests a
/// pause, waits until the watcher acks it has STOPPED reading, then runs the watcher's `suspend` (which
/// restores the PRE-watch termios — cooked for the REPL, the TUI's raw for --tui), executes the read,
/// and finally `resume`s (re-arms the raw watcher). Because the interactor acquires BEFORE it prompts,
/// the user's keypress always lands while the watcher is paused — no byte is lost, no mode is wrong.
///
/// USAGE CONTRACT (correctness depends on it — verified by a 4-model panel; DeepSeek+MiMo traced every
/// interleaving as correct under these, Codex/Gemini found defects ONLY when they are violated):
///   1. SINGLE watcher at a time. The interactive REPL/TUI chat turn AND (since R1, 2026-07-28) the
///      REPL's plan-execute / council / research escalations wrap in InterruptibleTurn and register
///      here; fleet does NOT (parallel workers, sentinel-file lifecycle). All registering turns are
///      SEQUENTIAL — an escalation runs INSTEAD of a chat turn, never inside one — so a new turn
///      can't register until the current one (blocked on its interactor) returns, and
///      `registerWatcher` is never called while a `withStdin` from a prior watcher is still in
///      flight. The assert below traps a violation in debug builds.
///   2. NON-REENTRANT bodies. An interactor `body()` (readLine / readApproval) must NOT itself call
///      `withStdin` — `bodyLock` is a plain NSLock, so re-entry would self-deadlock. The concrete bodies
///      (TerminalInteractor, TUIBridge) never recurse.
final class StdinArbiter: @unchecked Sendable {
    static let shared = StdinArbiter()

    private let cond = NSCondition()
    private let bodyLock = NSLock()   // serializes interactor reads: only ONE owns stdin at a time
    private var suspendWatcher: (() -> Void)?
    private var resumeWatcher: (() -> Void)?
    private var wantPause = false
    private var watcherPaused = true

    /// Called by InterruptibleTurn when the watcher starts. `suspend` drops out of raw watch mode
    /// (restoring the pre-watch termios); `resume` re-arms it. CONTRACT: no watcher may already be
    /// registered (single-watcher invariant) — traps in debug if violated (the Codex concurrent-register
    /// interleaving), so a future concurrent use is caught loud instead of racing silently.
    func registerWatcher(suspend: @escaping () -> Void, resume: @escaping () -> Void) {
        cond.lock()
        assert(suspendWatcher == nil, "StdinArbiter: a watcher is already registered — the single-watcher / sequential-turn invariant was violated")
        suspendWatcher = suspend; resumeWatcher = resume
        wantPause = false; watcherPaused = false; cond.unlock()
    }

    func unregisterWatcher() {
        cond.lock(); suspendWatcher = nil; resumeWatcher = nil
        wantPause = false; watcherPaused = true; cond.broadcast(); cond.unlock()
    }

    /// Watcher: may it read this tick? If a pause is pending, it acks (marks itself paused) and returns
    /// false so it stops reading until the interactor releases.
    func watcherMayRead() -> Bool {
        cond.lock(); defer { cond.unlock() }
        if wantPause { watcherPaused = true; cond.broadcast(); return false }
        watcherPaused = false; return true
    }

    /// Interactor: take exclusive stdin for a read. Pauses the watcher (restoring the pre-watch mode),
    /// runs `body`, then resumes the watcher. A no-op passthrough when no watcher is active.
    func withStdin<T>(_ body: () -> T) -> T {
        // Serialize the WHOLE critical section (handshake → suspend → body → resume → clear) so two
        // interactors can never own stdin at once, and a later caller can't consume a stale ack from an
        // earlier caller still finishing its defer (Codex: overlapping-caller race).
        bodyLock.lock()
        defer { bodyLock.unlock() }

        cond.lock()
        guard suspendWatcher != nil else { cond.unlock(); return body() }
        wantPause = true
        // Also exit the wait if the watcher unregisters mid-wait (suspendWatcher → nil): it already
        // restored the terminal mode in its defer, so we fall through and read as a plain passthrough.
        while !watcherPaused && suspendWatcher != nil { cond.wait() }
        let suspend = suspendWatcher   // nil if the watcher exited while we waited (mode already restored)
        cond.unlock()

        suspend?()                                    // raw watch → pre-watch mode (cooked / TUI-raw)
        defer {
            // Re-arm raw FIRST (only if the watcher is still alive), THEN clear the pause flags — so the
            // watcher can never resume reading in the wrong terminal mode between clear and re-arm (Codex).
            cond.lock()
            let resume = (suspendWatcher != nil) ? resumeWatcher : nil
            cond.unlock()
            resume?()
            cond.lock()
            wantPause = false
            watcherPaused = false
            cond.broadcast()
            cond.unlock()
        }
        return body()
    }
}
