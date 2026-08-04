import Foundation

/// TTY-ness of stdout, captured ONCE at process start — the fix for the 2026-08-03 white-out.
///
/// During a sticky turn, `TerminalScreenCoordinator` dup2's a pipe onto STDOUT/STDERR to serialize
/// panel writes, so any LIVE `isatty(fileno(stdout))` mid-turn returns 0 and every color decision
/// renders plain white — worse, a `TerminalEventSink` constructed mid-capture (auto-routing rebuilds
/// the loop) CACHES color=false for the rest of the session. The bytes still reach the real terminal
/// (the transcript firewall passes SGR); only the isatty-based decision was wrong.
///
/// The launch-time value is the truth: if stdout is a terminal at launch, it stays one for the
/// process's life (capture is an internal detour back to the same terminal); if kist is piped
/// (`kist -p … | tee`), launch-time isatty is 0 and stays honest. Color-DECISION sites must use this
/// snapshot; transport guards that genuinely care about the CURRENT descriptor (e.g. ModelPicker's
/// fail-closed raw-mode gate, TerminalMediaRenderer's inline-image protocol pick) keep live isatty.
enum TerminalCapabilities {
    /// `static let` is lazily evaluated — if first touched mid-capture it would cache the wrong
    /// value, so `prime()` MUST run at startup (main.swift, before any coordinator exists).
    static let stdoutIsInteractive: Bool = isatty(fileno(stdout)) != 0

    /// Force evaluation of the snapshot while descriptors are still untouched.
    static func prime() { _ = stdoutIsInteractive }
}
