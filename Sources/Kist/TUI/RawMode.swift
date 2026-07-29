import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Puts the terminal into raw mode (character-at-a-time, no echo, no line discipline) and — most
/// importantly — guarantees it's restored. A TUI that crashes without restoring leaves the user's
/// shell echo-less and broken, so restoration runs from `disable()`, `deinit`, AND a signal handler.
final class RawMode {
    #if canImport(Darwin) || canImport(Glibc)
    private var original = termios()
    private var active = false
    private let fd = STDIN_FILENO
    /// The signal-restorer that was installed before THIS instance enabled — restored on disable so a
    /// nested watcher (InterruptibleTurn's RawMode over the REPL/TUI's) can't orphan the outer one and
    /// leave the terminal raw after a SIGTERM/SIGHUP (Codex BLOCKER).
    private var previousRestore: (() -> Void)?

    /// Captured so the C signal handler (which can't capture context) can still restore.
    nonisolated(unsafe) static var restoreOnSignal: (() -> Void)?

    /// R2b: when a pinned scroll region (DECSTBM) is active, the signal handler must ALSO release it
    /// or a SIGTERM/SIGHUP leaves the user's shell with a frozen bottom strip. Set by PinnedBar while
    /// pinned; the handler writes `ESC[r` + show-cursor via async-signal-safe `write(2)` on death.
    nonisolated(unsafe) static var scrollRegionActiveOnSignal = false

    func enable() {
        guard isatty(fd) != 0, !active else { return }   // !active: don't re-capture original / double-stack
        tcgetattr(fd, &original)
        var raw = original
        // Input: no break-to-int, no CR→NL, no parity/strip, no XON/XOFF flow control.
        raw.c_iflag &= ~(tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON))
        // Local: no echo, no canonical mode, no signal chars (we handle Ctrl-C), no extended input.
        raw.c_lflag &= ~(tcflag_t(ECHO | ICANON | IEXTEN | ISIG))
        // Output: keep post-processing ON so "\n" still maps to CRLF in our prints.
        setControlChar(&raw, VMIN, 1)     // block until at least 1 byte
        setControlChar(&raw, VTIME, 0)
        tcsetattr(fd, TCSAFLUSH, &raw)
        active = true

        previousRestore = RawMode.restoreOnSignal          // stack the outer restorer
        RawMode.restoreOnSignal = { [weak self] in self?.disable() }
        installSignalHandlers()
    }

    /// Raw mode tuned for a background interrupt-watcher: instead of blocking forever on read, time out
    /// every ~0.1s (VMIN=0, VTIME=1) so the watch loop can notice the turn finished and exit cleanly.
    /// Used by InterruptibleTurn to listen for ESC while an agent turn runs.
    func enableForWatch() {
        guard isatty(fd) != 0, !active else { return }   // !active: don't clobber the saved cooked termios
        tcgetattr(fd, &original)
        var raw = original
        raw.c_iflag &= ~(tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON))
        raw.c_lflag &= ~(tcflag_t(ECHO | ICANON | IEXTEN | ISIG))
        setControlChar(&raw, VMIN, 0)     // don't block: return what's available
        setControlChar(&raw, VTIME, 1)    // ...waiting at most 0.1s for it
        tcsetattr(fd, TCSAFLUSH, &raw)
        active = true
        previousRestore = RawMode.restoreOnSignal          // stack the outer restorer
        RawMode.restoreOnSignal = { [weak self] in self?.disable() }
        installSignalHandlers()
    }

    /// One timed read for the watcher: the byte that arrived within the VTIME window, or nil on
    /// timeout/EOF (the caller just loops and re-checks cancellation).
    func readByteTimed() -> UInt8? {
        var b: UInt8 = 0
        return read(fd, &b, 1) == 1 ? b : nil
    }

    func disable() {
        guard active else { return }
        tcsetattr(fd, TCSAFLUSH, &original)
        active = false
        RawMode.restoreOnSignal = previousRestore       // un-stack: hand the signal-restore back to the outer mode
        previousRestore = nil
    }

    /// Read up to `max` bytes (blocking for at least one). Returns [] on EOF/error.
    func readBytes(max: Int = 64) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: max)
        let n = read(fd, &buf, max)
        guard n > 0 else { return [] }
        return Array(buf[0..<n])
    }

    deinit { disable() }

    // termios.c_cc is imported as a fixed-size tuple; poke a field by ordinal without hard-coding it.
    private func setControlChar(_ t: inout termios, _ index: Int32, _ value: UInt8) {
        withUnsafeMutablePointer(to: &t.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { $0[Int(index)] = value }
        }
    }

    private func installSignalHandlers() {
        let handler: @convention(c) (Int32) -> Void = { _ in
            // R2b: release a pinned scroll region first (raw write(2) is async-signal-safe), else a
            // killed kist leaves the shell with a frozen bottom strip. "\u{1B}[r\u{1B}[?25h".
            if RawMode.scrollRegionActiveOnSignal {
                let reset: [UInt8] = [0x1B, 0x5B, 0x72, 0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x68]
                _ = reset.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            }
            RawMode.restoreOnSignal?()
            // Restore default disposition and re-raise so the process still terminates.
            signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL)
        }
        signal(SIGTERM, handler)
        // SIGINT is delivered as a Ctrl-C *key* (ISIG is off), so we don't trap it here; SIGTERM/HUP do.
        signal(SIGHUP, handler)
    }
    #else
    func enable() {}
    func enableForWatch() {}
    func disable() {}
    func readBytes(max: Int = 64) -> [UInt8] { [] }
    func readByteTimed() -> UInt8? { nil }
    #endif

    /// Current terminal size (rows, cols); falls back to 24×80 when it can't be read.
    func size() -> (rows: Int, cols: Int) {
        #if canImport(Darwin) || canImport(Glibc)
        var ws = winsize()
        if ioctl(STDIN_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_row > 0 {
            return (Int(ws.ws_row), Int(ws.ws_col))
        }
        #endif
        return (24, 80)
    }
}
