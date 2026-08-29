import Foundation

/// Public, narrow process runner for callers that require kernel-enforced sandboxing.
///
/// This intentionally does not expose the raw `ProcessGroupRunner`: callers must request an
/// OS sandbox, and unavailable sandbox support fails closed instead of silently running the
/// command unsandboxed.
public enum SandboxedProcessRunner {
    public struct Outcome: Sendable, Equatable {
        public let combined: String
        public let exitCode: Int32
        public let timedOut: Bool
        public let sandboxed: Bool
        public let sandbox: String
    }

    public static func runRequired(launchPath: String,
                                   launchArgs: [String],
                                   root: String,
                                   cwd: String,
                                   env: [String: String],
                                   timeoutSeconds: Int,
                                   capPerStream: Int,
                                   policy: SandboxPolicy = .confined()) -> Outcome {
        guard policy.enabled else {
            return Outcome(combined: "OS sandbox required but SandboxPolicy is disabled",
                           exitCode: 126,
                           timedOut: false,
                           sandboxed: false,
                           sandbox: "unavailable")
        }

        let finalPath: String
        let finalArgs: [String]
        let sandboxName: String
        switch SeatbeltSandbox.wrap(launchPath: launchPath, args: launchArgs, root: root,
                                    policy: policy, cwd: cwd) {
        case .passthrough:
            return Outcome(combined: "OS sandbox required but wrapper returned passthrough",
                           exitCode: 126,
                           timedOut: false,
                           sandboxed: false,
                           sandbox: "unavailable")
        case .wrapped(let path, let args):
            finalPath = path
            finalArgs = args
            sandboxName = "macOS Seatbelt"
        case .unavailable(let reason):
            return Outcome(combined: "OS sandbox required but unavailable: \(reason)",
                           exitCode: 126,
                           timedOut: false,
                           sandboxed: false,
                           sandbox: "unavailable")
        }

        let outcome = ProcessGroupRunner.run(launchPath: finalPath,
                                             launchArgs: finalArgs,
                                             cwd: cwd,
                                             env: env,
                                             timeoutSeconds: timeoutSeconds,
                                             capPerStream: capPerStream)
        return Outcome(combined: outcome.combined,
                       exitCode: outcome.exitCode,
                       timedOut: outcome.timedOut,
                       sandboxed: true,
                       sandbox: sandboxName)
    }

    public static func canApplyRequiredSandbox(root: String) -> Bool {
        let outcome = runRequired(launchPath: "/usr/bin/true",
                                  launchArgs: [],
                                  root: root,
                                  cwd: root,
                                  env: ["PATH": "/usr/bin:/bin"],
                                  timeoutSeconds: 5,
                                  capPerStream: 2_000)
        return outcome.sandboxed && !outcome.timedOut && outcome.exitCode == 0
    }
}
