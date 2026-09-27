import Foundation
import AgentCore

/// The sealed build contract, rendered for the plan-execute worker (0.17.63).
///
/// The sealed planning pass freezes exactly which files may change and which command proves the
/// build, but the plan-execute worker never saw either: it planned from the goal alone, chose its
/// own filenames and its own test invocation, and learned the contract only from failures — a
/// `run_command` argument mismatch on the first test step of every build, then, after the files
/// were written, "Workspace contains undeclared mutation: app.py" at final verification (live
/// 2026-09-27: the sealed plan said hello.py / test_hello.py; the worker wrote app.py / test_app.py).
/// Telling the worker the contract up front costs a few hundred prompt bytes and removes both
/// failure modes from the healthy path. It grants nothing: the same host checks still run.
extension KistRunner {
    /// Human-readable, host-frozen contract block, or nil when there is no sealed plan.
    static func builderSealedContractPrompt(_ plan: BuilderPreflightPlan?) -> String? {
        guard let plan, !plan.operations.isEmpty || !plan.verificationCommands.isEmpty else { return nil }
        var lines: [String] = ["SEALED BUILD CONTRACT (host-frozen; these are limits, not suggestions):"]
        if !plan.operations.isEmpty {
            lines.append("- The ONLY file mutations allowed, by exact project-relative path and kind:")
            for operation in plan.operations {
                lines.append("  - \(operation.kind.rawValue) \(operation.path)")
            }
            lines.append("  Touching any other file fails the build at final verification "
                         + "(\"Workspace contains undeclared mutation\"). Do not rename, move, or add files "
                         + "outside this list; put the work in these paths.")
        }
        if !plan.verificationCommands.isEmpty {
            lines.append("- The host will prove the build by running exactly:")
            for command in plan.verificationCommands {
                lines.append("  - \(command.canonicalStatement)")
                lines.append("    run_command argument object (use it VERBATIM for your own test step; omit cwd): "
                             + sealedArgumentObject(command))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Same JSON shape the sealed `run_command` wrapper advertises in its usage examples, so the
    /// worker can copy it byte for byte.
    static func sealedArgumentObject(_ command: BuilderPreflightCommand) -> String {
        let object: [String: Any] = ["executable": command.executable, "args": command.arguments,
                                     "timeout": command.timeoutSeconds]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return command.canonicalStatement
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The worker goal with the contract block appended (unchanged when there is no sealed plan).
    static func builderGoalWithSealedContract(_ goal: String, plan: BuilderPreflightPlan?) -> String {
        guard let block = builderSealedContractPrompt(plan) else { return goal }
        return goal + "\n\n" + block
    }
}
