import Foundation

/// Detects a tool-error SPIRAL: the agent calling the SAME tool with the SAME arguments and getting the
/// SAME failure, over and over — the classic babysit-trigger (e.g. `edit_file` on a wrong path retried
/// five times, or `run_command` with a typo). The generic "N consecutive failures" replan is blunt: it
/// counts *different* failures the same and fires late. This is sharper and earlier — an identical failing
/// call is a strong signal the model is stuck, and it lets us inject a targeted "stop repeating THIS exact
/// call, do X instead" steer to BREAK the spiral (recover) before the governor has to STOP the run.
///
/// Pure over the trajectory so it's unit-tested without a loop.
public enum ToolSpiralDetector {
    public struct Spiral: Equatable, Sendable {
        public let tool: String
        public let fingerprint: String
        public let count: Int
        /// Stable signature so the loop steers ONCE per distinct spiral (not every iteration once it trips).
        public var signature: String { tool + "|" + fingerprint }
    }

    /// Return a spiral when the trajectory TAIL is `minRepeats`+ identical (same tool, same args
    /// fingerprint) FAILED calls in a row. nil if the last call succeeded or the streak is too short.
    public static func detect(_ trajectory: [ActionRecord], minRepeats: Int = 3) -> Spiral? {
        guard let last = trajectory.last, !last.success else { return nil }
        var count = 0
        for rec in trajectory.reversed() {
            guard rec.tool == last.tool, rec.argsFingerprint == last.argsFingerprint, !rec.success else { break }
            count += 1
        }
        return count >= minRepeats
            ? Spiral(tool: last.tool, fingerprint: last.argsFingerprint, count: count)
            : nil
    }

    /// The corrective steer: name the exact repeated call + its error, forbid repeating it, and give
    /// concrete alternatives. Injected as a user message to break the loop.
    public static func steer(tool: String, count: Int, error: String, validTools: [String]) -> String {
        let err = error.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
        let tools = validTools.isEmpty ? "" : "\nAvailable tools: \(validTools.joined(separator: ", "))."
        return """
        STOP — you have called `\(tool)` \(count) times in a row with the SAME arguments and it FAILED every time. The last error was:
        \(err)
        Repeating the identical call will keep failing. Do NOT call `\(tool)` with those same arguments again. Instead do ONE of:
          • inspect first — read the file or list the directory to check the precondition you're assuming,
          • fix the wrong argument (a path, name, or value that doesn't exist or is malformed),
          • or use a DIFFERENT tool / approach to make progress.\(tools)
        """
    }
}
