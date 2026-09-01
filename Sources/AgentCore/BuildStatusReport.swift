import Foundation

/// A hard, at-a-glance CONTRACT for a build turn: did we actually
/// PATCH → APPLY → CHANGE FILES → BUILD/TEST → update the BOARD, or did the model just SAY it would?
///
/// Computed PURELY from the turn's recorded trajectory (the same external evidence the verifier trusts),
/// so a confident "I will apply the patch" summary can never be mistaken for a real, applied, verified
/// change. Renders the "🔧 BUILD STATUS … Result: NOT COMPLETE" block so the true state is impossible
/// to confuse.
public struct BuildStatusReport: Sendable, Equatable {
    public let patchGenerated: Bool   // a mutating tool call was attempted
    public let patchApplied: Bool     // a mutating tool call SUCCEEDED (confirmed file change)
    public let filesChanged: Int      // count of applied (confirmed) mutations this turn
    public let buildOrTestRan: Bool   // a build/test command actually executed and succeeded
    public let boardUpdated: Bool     // the shared task board was written
    public let delegatedMutationCompleted: Bool // a synchronous/joined child passed its mutation gate
    private let delegatedMutationRemainsVerified: Bool
    private let finalOutcomeSucceeded: Bool

    /// A build turn is only DONE when the change was actually applied AND a build/test executed to
    /// prove it. Applied-but-unverified, or generated-but-never-applied, are NOT COMPLETE — exactly the
    /// gap where Kist used to launder "here's the patch" into a success summary.
    public var isComplete: Bool {
        finalOutcomeSucceeded
            && (delegatedMutationRemainsVerified || (patchApplied && buildOrTestRan))
    }

    public init(trajectory: [ActionRecord], finalSuccess: Bool? = nil) {
        patchGenerated = trajectory.contains { $0.observedEffects.mutation != .none }
        let applied = trajectory.filter { $0.success && $0.observedEffects.confirmsMutation }
        patchApplied = !applied.isEmpty
        filesChanged = applied.count
        // Verification only counts if a build/test SUCCEEDED AFTER the last applied source mutation —
        // a build that ran before the final edit doesn't prove the change (mirrors the final-verifier).
        let lastMutation = trajectory.lastIndex { $0.success && $0.observedEffects.confirmsMutation }
        let verifyScope = lastMutation.map { trajectory[($0 + 1)...] } ?? trajectory[...]
        buildOrTestRan = verifyScope.contains { $0.success && $0.observedEffects.verification == .buildOrTest }
        boardUpdated = trajectory.contains { $0.success && $0.observedEffects.progress == .taskBoard }
        delegatedMutationCompleted = trajectory.contains {
            $0.success && $0.observedEffects.progress == .delegatedMutation
        }
        delegatedMutationRemainsVerified = delegatedMutationCompleted
            && CompletionVerifier().check(
                trajectory: trajectory, canRunCommands: true,
                expectedOutcome: .mutation, taskIntent: .build).isAccept
        finalOutcomeSucceeded = finalSuccess ?? true
    }

    public func render(color: Bool) -> String {
        func mark(_ ok: Bool) -> String {
            if color { return ok ? "\u{001B}[32m✓\u{001B}[0m" : "\u{001B}[31m✕\u{001B}[0m" }
            return ok ? "✓" : "✕"
        }
        let title = color ? "\u{001B}[1m🔧 BUILD STATUS\u{001B}[0m" : "🔧 BUILD STATUS"
        let result: String = isComplete
            ? (color ? "\u{001B}[32;1mCOMPLETE\u{001B}[0m" : "COMPLETE")
            : (color ? "\u{001B}[31;1mNOT COMPLETE\u{001B}[0m" : "NOT COMPLETE")
        return """
        \(title)
          Patch generated    \(mark(patchGenerated))
          Patch applied      \(mark(patchApplied))
          Files changed      \(filesChanged)
          Build / tests run  \(mark(buildOrTestRan))
          Delegated result   \(mark(delegatedMutationCompleted))
          Board updated      \(mark(boardUpdated))
          Result             \(result)
        """
    }
}
