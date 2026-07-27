import Foundation

// MARK: - MCP logging (cross-platform)
//
// The GUI app version used Apple's `os.Logger`, which does NOT exist on Linux and
// would break the headless build. AgentCore must run on macOS AND Linux, so logging
// goes to stderr via Foundation only. Remote server stderr is UNTRUSTED → bounded
// and tagged before it's emitted.
//
// Writes go to `FileHandle.standardError`, which serializes individual `write`
// calls; interleaving between lines is possible under heavy concurrency but is
// harmless for diagnostics.
enum MCPLog {
    static func info(_ message: String) {
        guard verbose else { return }
        emit("INFO", message)
    }
    static func warn(_ message: String) { emit("WARN", message) }
    static func error(_ message: String) { emit("ERROR", message) }

    /// Emit untrusted server stderr, bounded to 2 KB so a chatty/hostile server
    /// can't flood the log.
    ///
    /// Server stderr is the server's OWN diagnostic logging — protocol data flows
    /// over stdout (JSON-RPC), and real spawn/handshake/EOF failures surface via
    /// `MCPConnectionError` + `warn`/`error`. A chatty server (e.g. an LSP bridge
    /// that logs "received diagnostics for <file>" per file) would otherwise flood
    /// the REPL on every turn, so this is gated behind `verbose` like `info`.
    /// Set `KIST_MCP_LOG=1` (or `KIST_VERBOSE=1`) to see it while debugging a server.
    static func serverStderr(server: String?, text: String) {
        guard let line = serverStderrLine(server: server, text: text, verbose: verbose) else { return }
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Pure formatting/gating decision for server stderr (testable without env or
    /// stderr capture). Returns the exact line `serverStderr` would write, or `nil`
    /// when suppressed. Bounds the untrusted payload to 2 KB.
    static func serverStderrLine(server: String?, text: String, verbose: Bool) -> String? {
        guard verbose else { return nil }
        return "[mcp STDERR] [\(server ?? "?")] " + String(text.prefix(2000)) + "\n"
    }

    private static func emit(_ level: String, _ message: String) {
        let line = "[mcp \(level)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static var verbose: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["KIST_MCP_LOG"] == "1" || env["KIST_VERBOSE"] == "1"
    }
}
