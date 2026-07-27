import Foundation

/// The FIRST REAL oracle backend — executes an actual external program and captures its behavior, so the
/// equivalence engine can be pointed at a real legacy CLI instead of a Swift closure. `run(_:)` matches the
/// `(String) throws -> String` shape the whole engine consumes, so it plugs straight into EquivalenceRun /
/// PortVerifier / MutationMeter / GoldenCorpus.
///
/// DETERMINISM SEALING (pragmatic first tier): the process runs in a PINNED, minimal environment (fixed
/// timezone, C locale, a fixed SOURCE_DATE_EPOCH, a fixed PATH) with no inherited environment, in a fixed
/// working directory. This is NOT a complete seal — a program that reads the wall clock or /dev/urandom via
/// syscall still leaks (full libfaketime-style syscall interception is a later tier). That's fine BY DESIGN:
/// Gate 0 (the engine runs the oracle twice) refuses to certify off a leaky oracle rather than trusting one.
public struct ProcessOracle {

    public enum InputMode: Sendable {
        case stdin                        // the case input is written to the child's stdin
        case argument(placeholder: String) // the case input replaces a placeholder token in the arguments
    }

    /// Which parts of the process result become the equivalence surface. Exit code and stderr ARE behavior;
    /// a port that crashes (exit≠0) or emits different diagnostics is not equivalent. But stderr is commonly
    /// noisy/nondeterministic, so the default is stdout + exit code (both usually deterministic). Include
    /// `.stderr` for strict equivalence — and apply the SAME surface to oracle and candidate.
    public struct OutputSurface: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let stdout   = OutputSurface(rawValue: 1 << 0)
        public static let exitCode = OutputSurface(rawValue: 1 << 1)
        public static let stderr   = OutputSurface(rawValue: 1 << 2)
        public static let `default`: OutputSurface = [.stdout, .exitCode]
        public static let all: OutputSurface = [.stdout, .exitCode, .stderr]
    }

    public enum OracleError: Error, CustomStringConvertible {
        case launchFailed(String, Error)
        case timedOut(String, TimeInterval)
        public var description: String {
            switch self {
            case .launchFailed(let exe, let e): return "failed to launch \(exe): \(e)"
            case .timedOut(let exe, let t): return "\(exe) exceeded \(t)s timeout"
            }
        }
    }

    public let executable: String
    public let arguments: [String]
    public let inputMode: InputMode
    public let outputs: OutputSurface
    public let environment: [String: String]
    public let workingDirectory: String?
    public let timeout: TimeInterval

    public init(executable: String, arguments: [String] = [], inputMode: InputMode = .stdin,
                outputs: OutputSurface = .default,
                environment: [String: String] = ProcessOracle.sealedEnvironment(),
                workingDirectory: String? = nil, timeout: TimeInterval = 10) {
        self.executable = executable; self.arguments = arguments; self.inputMode = inputMode
        self.outputs = outputs; self.environment = environment
        self.workingDirectory = workingDirectory; self.timeout = timeout
    }

    /// The pinned environment that seals the common, cheap nondeterminism sources. Deliberately minimal —
    /// no inherited env — so a run doesn't depend on the caller's shell.
    public static func sealedEnvironment(epoch: Int = 0) -> [String: String] {
        ["TZ": "UTC", "LC_ALL": "C", "LANG": "C", "SOURCE_DATE_EPOCH": "\(epoch)",
         "PATH": "/usr/bin:/bin", "LANGUAGE": "C"]
    }

    public func run(_ input: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        switch inputMode {
        case .stdin: proc.arguments = arguments
        case .argument(let ph): proc.arguments = arguments.map { $0 == ph ? input : $0 }
        }
        proc.environment = environment
        if let wd = workingDirectory { proc.currentDirectoryURL = URL(fileURLWithPath: wd) }

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        proc.standardOutput = outPipe; proc.standardError = errPipe; proc.standardInput = inPipe

        do { try proc.run() } catch { throw OracleError.launchFailed(executable, error) }

        // FULLY CONCURRENT IO — stdin write, stdout read, and stderr read each run on their own queue so no
        // combination of large stdin / stdout / stderr can deadlock (the classic pipe-buffer trap). A
        // DispatchGroup joins them, so the reads are guaranteed complete (no truncation) before we compose.
        let outBox = DataBox(), errBox = DataBox()
        let group = DispatchGroup()
        if case .stdin = inputMode {
            DispatchQueue.global().async(group: group) {
                let h = inPipe.fileHandleForWriting
                h.write(Data(input.utf8)); try? h.close()
            }
        } else {
            try? inPipe.fileHandleForWriting.close()
        }
        DispatchQueue.global().async(group: group) { outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile()) }
        DispatchQueue.global().async(group: group) { errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile()) }

        // Timeout watchdog — terminate a hung child so a bad oracle can't wedge the whole run.
        let flag = TimeoutFlag()
        let watchdog = DispatchWorkItem { flag.trip(); proc.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        proc.waitUntilExit()
        watchdog.cancel()
        group.wait()                                   // all IO fully drained before we read the boxes
        try? outPipe.fileHandleForReading.close()      // explicit fd cleanup across many calls
        try? errPipe.fileHandleForReading.close()

        // A normally-exited process is NEVER a timeout even if the watchdog raced the flag: only a process
        // WE terminated reports `.uncaughtSignal`. This removes the false-timeout race.
        if flag.tripped && proc.terminationReason != .exit {
            throw OracleError.timedOut(executable, timeout)
        }
        return compose(stdout: outBox.value, exitCode: proc.terminationStatus, stderr: errBox.value)
    }

    /// The equivalence surface, per `outputs`. Losslessly encoded (see `losslessString`) so no two distinct
    /// byte outputs can ever collapse to the same string.
    func compose(stdout: Data, exitCode: Int32, stderr: Data) -> String {
        var parts: [String] = []
        if outputs.contains(.exitCode) { parts.append("exit=\(exitCode)") }
        if outputs.contains(.stdout) { parts.append(Self.losslessString(stdout)) }
        if outputs.contains(.stderr) { parts.append("stderr=" + Self.losslessString(stderr)) }
        return parts.joined(separator: "\n")
    }

    /// UTF-8 when the bytes are valid UTF-8 (so text stays readable and canonicalizable); otherwise a
    /// `base64:`-tagged lossless encoding. Guarantees distinct bytes ⇒ distinct strings (the fix for the
    /// council's false-equivalent on binary output — `String(data:utf8) ?? ""` collapsed all binary to "").
    static func losslessString(_ d: Data) -> String {
        if let s = String(data: d, encoding: .utf8) { return s }
        return "base64:" + d.base64EncodedString()
    }

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func trip() { lock.lock(); value = true; lock.unlock() }
        var tripped: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock(); private var data = Data()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
