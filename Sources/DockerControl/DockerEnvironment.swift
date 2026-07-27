import Foundation

/// Detects whether a usable Docker daemon is present. Fail-closed: anything other
/// than a clean version response is `unavailable` (with a reason), so callers never
/// assume Docker when it isn't there.
public enum DockerEnvironment {
    public enum Availability: Equatable, Sendable {
        case available(version: String)
        case unavailable(reason: String)

        public var isAvailable: Bool { if case .available = self { return true }; return false }
    }

    /// Runs `docker version --format {{.Server.Version}}`. A non-zero exit or empty
    /// output (daemon not running, CLI absent) ⇒ unavailable.
    public static func detect(runner: (( [String] ) -> (Int32, String))? = nil) -> Availability {
        let run = runner ?? Self.processRunner
        let (code, out) = run(["version", "--format", "{{.Server.Version}}"])
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code == 0, !trimmed.isEmpty else {
            return .unavailable(reason: code != 0
                ? "docker not usable (exit \(code)) — is the daemon running?"
                : "docker returned no server version")
        }
        return .available(version: trimmed)
    }

    /// Default runner: shells to `docker`. Returns (-1, "") if the binary can't launch.
    static func processRunner(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["docker"] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "")
        }
    }
}
