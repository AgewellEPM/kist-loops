import Foundation

// MARK: - MCP logging (cross-platform)
//
// AgentCore cannot depend on Apple's os.Logger because it also builds on Linux.
// Diagnostics normally go to stderr. A terminal host can install one process-wide
// sink so warnings/errors never write behind its renderer; routing state is locked
// because MCP pipe callbacks arrive from Foundation-owned threads.
public enum MCPLog {
    private static let router = DiagnosticRouter()
    private static let generalPayloadLimit = 4 * 1024
    private static let serverStderrPayloadLimit = 2 * 1024

    /// Route MCP diagnostics to a host-owned renderer. While installed, every
    /// warning/error and every verbose-allowed server stderr line goes only to this
    /// sink, never to `FileHandle.standardError`.
    public static func installDiagnosticSink(_ sink: @escaping @Sendable (String) -> Void) {
        router.install(sink)
    }

    /// Restore the default stderr destination.
    public static func resetDiagnosticSink() {
        router.reset()
    }

    static func info(_ message: String) {
        guard verbose else { return }
        route(formattedLine(level: "INFO", payload: message, payloadLimit: generalPayloadLimit))
    }

    static func warn(_ message: String) {
        route(formattedLine(level: "WARN", payload: message, payloadLimit: generalPayloadLimit))
    }

    static func error(_ message: String) {
        route(formattedLine(level: "ERROR", payload: message, payloadLimit: generalPayloadLimit))
    }

    /// Emit untrusted server stderr, bounded to 2 KB so a chatty/hostile server
    /// cannot flood either destination. It remains opt-in through `KIST_MCP_LOG=1`
    /// or `KIST_VERBOSE=1`; installing a sink does not silently enable it.
    static func serverStderr(server: String?, text: String) {
        guard let line = serverStderrLine(server: server, text: text, verbose: verbose) else { return }
        route(line)
    }

    /// Pure formatting/gating decision for tests. Both the server label and payload
    /// pass through the same ANSI/control/bidi sanitizer used by live routing.
    static func serverStderrLine(server: String?, text: String, verbose: Bool) -> String? {
        guard verbose else { return nil }
        let safeServer = sanitizeDiagnostic(server ?? "?", byteLimit: 128)
        let safeText = sanitizeDiagnostic(text, byteLimit: serverStderrPayloadLimit)
        return "[mcp STDERR] [\(safeServer)] \(safeText)\n"
    }

    /// Internal pure hook used to pin the trust boundary without intercepting the
    /// process-global stderr descriptor in the test runner.
    static func sanitizedDiagnosticForTesting(_ text: String, byteLimit: Int = generalPayloadLimit) -> String {
        sanitizeDiagnostic(text, byteLimit: byteLimit)
    }

    private static func formattedLine(level: String, payload: String, payloadLimit: Int) -> String {
        "[mcp \(level)] \(sanitizeDiagnostic(payload, byteLimit: payloadLimit))\n"
    }

    private static func route(_ line: String) {
        // `line` is already bounded and sanitized. Keeping this assertion at the
        // final common chokepoint prevents a future call site from routing raw text.
        assert(line.utf8.count <= generalPayloadLimit + 256,
               "MCP diagnostic reached its destination without a finite bound")
        router.deliver(line)
    }

    private static var verbose: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["KIST_MCP_LOG"] == "1" || env["KIST_VERBOSE"] == "1"
    }

    /// Bound by UTF-8 bytes first, then strip complete ANSI escape sequences,
    /// terminal controls, Unicode format characters (including bidi controls), and
    /// line-rewriting whitespace. The result is always one printable diagnostic line.
    private static func sanitizeDiagnostic(_ input: String, byteLimit: Int) -> String {
        precondition(byteLimit > 0)

        // Inspect at most byteLimit + 1 bytes. This avoids traversing or copying an
        // attacker-sized string merely to decide that it needs truncation.
        let observed = input.utf8.prefix(byteLimit + 1)
        let wasTruncated = observed.count > byteLimit
        let bounded = String(decoding: observed.prefix(byteLimit), as: UTF8.self)

        enum ANSIState {
            case plain
            case escape
            case csi
            case operatingSystemCommand
            case operatingSystemCommandEscape
            case controlString
            case controlStringEscape
        }

        var state = ANSIState.plain
        var output = String.UnicodeScalarView()
        output.reserveCapacity(bounded.unicodeScalars.count)

        for scalar in bounded.unicodeScalars {
            let value = scalar.value
            switch state {
            case .plain:
                switch value {
                case 0x1B:
                    state = .escape
                case 0x9B:
                    state = .csi
                case 0x9D:
                    state = .operatingSystemCommand
                case 0x90, 0x98, 0x9E, 0x9F:
                    state = .controlString
                default:
                    if scalar == "\n" || scalar == "\t" {
                        output.append(" ")
                    } else {
                        switch scalar.properties.generalCategory {
                        case .control, .format, .lineSeparator, .paragraphSeparator,
                             .surrogate, .unassigned:
                            break
                        default:
                            output.append(scalar)
                        }
                    }
                }

            case .escape:
                switch value {
                case 0x5B: state = .csi                         // ESC [
                case 0x5D: state = .operatingSystemCommand      // ESC ]
                case 0x50, 0x58, 0x5E, 0x5F: state = .controlString
                default: state = .plain                         // two-byte escape
                }

            case .csi:
                if (0x40...0x7E).contains(value) { state = .plain }

            case .operatingSystemCommand:
                if value == 0x07 || value == 0x9C {
                    state = .plain
                } else if value == 0x1B {
                    state = .operatingSystemCommandEscape
                }

            case .operatingSystemCommandEscape:
                state = value == 0x5C || value == 0x9C
                    ? .plain
                    : .operatingSystemCommand

            case .controlString:
                if value == 0x9C {
                    state = .plain
                } else if value == 0x1B {
                    state = .controlStringEscape
                }

            case .controlStringEscape:
                state = value == 0x5C || value == 0x9C ? .plain : .controlString
            }
        }

        var result = String(output)
        if wasTruncated {
            result += " …[truncated]"
        }
        return result
    }
}

final class DiagnosticRouter: @unchecked Sendable {
    typealias Sink = @Sendable (String) -> Void

    private let stateLock = NSLock()
    private let stderrLock = NSLock()
    private let stderrWriter: Sink
    private var sink: Sink?

    init(stderrWriter: @escaping Sink = { line in
        FileHandle.standardError.write(Data(line.utf8))
    }) {
        self.stderrWriter = stderrWriter
    }

    func install(_ sink: @escaping Sink) {
        stateLock.lock()
        self.sink = sink
        stateLock.unlock()
    }

    func reset() {
        stateLock.lock()
        sink = nil
        stateLock.unlock()
    }

    func deliver(_ line: String) {
        stateLock.lock()
        let destination = sink
        stateLock.unlock()

        if let destination {
            destination(line)
            return
        }

        stderrLock.lock()
        stderrWriter(line)
        stderrLock.unlock()
    }
}
