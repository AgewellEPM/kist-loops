import Foundation

/// A bounded subprocess for sibling products that need execution without the agent tool protocol.
/// The caller supplies its own environment. Cancellation waits for process-group teardown and reap.
public enum BoundedProcessRunner {
    public struct Result: Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        public let timedOut: Bool
        public let cancelled: Bool
        public let outputTruncated: Bool
        public let wasSignalled: Bool

        public var succeeded: Bool {
            exitCode == 0 && !timedOut && !cancelled && !wasSignalled && !outputTruncated
        }
    }

    public static func run(executable: String, arguments: [String], cwd: String,
                           environment: [String: String], timeoutSeconds: Int,
                           maximumOutputBytes: Int, stdin: Data? = nil) async -> Result {
        guard (1...86_400).contains(timeoutSeconds),
              (1...16_777_216).contains(maximumOutputBytes) else {
            return Result(stdout: "", stderr: "invalid process timeout or output limit", exitCode: -1,
                          timedOut: false, cancelled: false, outputTruncated: false, wasSignalled: false)
        }
        let outcome = await ProcessGroupRunner.runAsync(
            launchPath: executable, launchArgs: arguments, cwd: cwd, env: environment,
            timeoutSeconds: timeoutSeconds, capPerStream: maximumOutputBytes, stdinData: stdin)
        return Result(stdout: outcome.stdout,
                      stderr: outcome.stderr.isEmpty && outcome.exitCode < 0 ? outcome.combined : outcome.stderr,
                      exitCode: outcome.exitCode, timedOut: outcome.timedOut, cancelled: outcome.cancelled,
                      outputTruncated: outcome.outputTruncated, wasSignalled: outcome.wasSignalled)
    }
}
