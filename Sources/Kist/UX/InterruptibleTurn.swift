import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runs an agent turn while watching the keyboard for ESC — Claude-Code's "esc to interrupt". Pressing
/// ESC cancels the turn's Task; the loop's cooperative `Task.isCancelled` checks finish it cleanly as an
/// interrupted outcome. The terminal is restored on every exit path.
///
/// Caveat (documented, not a bug): while a turn runs the watcher owns stdin, so other keys typed mid-turn
/// are consumed and discarded (only ESC is acted on). Interrupt lands at the next loop-iteration boundary
/// — i.e. after the in-flight model/tool step — not necessarily the instant ESC is pressed.
enum InterruptibleTurn {
    /// - enabled: false (pipes/tests) just runs `work` with no watcher.
    /// - onInterrupt: called once, after the turn returns, only if ESC caused the stop (for a UI notice).
    static func run<T>(enabled: Bool = isInteractive(),
                       onInterrupt: @escaping () -> Void = {},
                       _ work: @escaping () async -> T) async -> T {
        guard enabled else { return await work() }

        let raw = RawMode()
        raw.enableForWatch()
        let flag = InterruptFlag()
        // Hand stdin off to in-turn interactor prompts (approvals / clarifying questions): while an
        // interactor reads, the watcher pauses and stdin drops back to its pre-watch mode (Codex BLOCKER).
        StdinArbiter.shared.registerWatcher(suspend: { raw.disable() }, resume: { raw.enableForWatch() })

        let turn = Task { await work() }
        let watcher = Task.detached {
            // On watcher exit (ESC or cancel): FIRST restore the pre-watch terminal mode, THEN release the
            // arbiter. Order matters — a waiter released by unregister runs its read with suspend==nil, so
            // raw must already be disabled or it reads in watch-raw mode (no echo) (Codex BLOCKER). And
            // unregister-in-defer (vs after the awaits below) is what prevents a post-cancel approval from
            // blocking forever on watcherPaused (Codex deadlock).
            defer { raw.disable(); StdinArbiter.shared.unregisterWatcher() }
            while !Task.isCancelled {
                guard StdinArbiter.shared.watcherMayRead() else {   // an interactor owns stdin — yield
                    usleep(15_000); continue
                }
                if raw.readByteTimed() == 0x1B {   // ESC
                    await flag.set()
                    turn.cancel()
                    return
                }
            }
        }

        let result = await turn.value
        watcher.cancel()
        // Join the watcher BEFORE restoring the terminal — otherwise a watcher still blocked in
        // readByteTimed() could swallow the first byte the user types into the next prompt (Codex HIGH).
        // It exits within one VTIME tick (~0.1s) of the cancel.
        _ = await watcher.value
        StdinArbiter.shared.unregisterWatcher()
        raw.disable()
        if await flag.value { onInterrupt() }
        return result
    }

    static func isInteractive() -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        return isatty(STDIN_FILENO) != 0
        #else
        return false
        #endif
    }
}

/// Tiny actor so the detached watcher and the awaiting caller share the "ESC was pressed" fact safely.
actor InterruptFlag {
    private(set) var value = false
    func set() { value = true }
}

/// A reference cell for shuttling an `inout` value (e.g. the transcript) into and out of the escaping
/// work closure InterruptibleTurn.run takes — `inout` can't cross that boundary directly.
final class MutableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
