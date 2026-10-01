import Foundation

/// Verify-before-done: the trust spine applied to the completion signal. The most corrosive agent failure
/// is "it said it was done but wasn't" — it edited code, never compiled or tested it, and claimed success.
///
/// This deterministic gate refuses that: if the run MUTATED code (edit/write/patch/move) but ran NO
/// SUCCESSFUL build/test command AFTER the last mutation, a "done" claim is UNVERIFIED, and the loop steers
/// the model to actually verify before finishing (nudged once, so it can't loop forever). It reuses the
/// trajectory the loop already records — grounded in what the agent actually DID, not what it claims.
public struct CompletionVerifier: Sendable {
    /// Compatibility projections only. Verification decisions use each record's argument-aware effect
    /// observation; these names cannot distinguish docs from source or `swift test` from `ls`.
    @available(*, deprecated, message: "Use ActionRecord.observedEffects")
    public static let mutatingTools = ToolEffectCatalog.knownMutationTools
    @available(*, deprecated, message: "Use ActionRecord.observedEffects")
    public static let verifyingTools = ToolEffectCatalog.knownCommandTools

    public enum Verdict: Sendable, Equatable {
        case accept
        case needsVerification(reason: String)
        public var isAccept: Bool { if case .accept = self { return true }; return false }
    }

    public init() {}

    /// A passing check proves only the revision that existed when it ran. Any later recorded mutation,
    /// including an uncertain/failed custom-tool effect, makes that proof stale until a fresh deterministic
    /// check binds the final revision. Indices are one-based so terminal receipts match human-facing steps.
    public struct InvalidatedVerification: Sendable, Equatable {
        public let invalidatingStep: Int
        public let invalidatingMutation: String
        public let invalidatingMutationSucceeded: Bool
        public let lastPassedStep: Int
        public let lastPassedCheck: String
        public let lastPassedTool: String
        public let lastPassedFingerprint: String

        public var reason: String {
            let effect = invalidatingMutationSucceeded ? "mutation" : "failed or possibly-partial mutation"
            return "verification became stale: \(effect) at step \(invalidatingStep) "
                + "[\(invalidatingMutation)] occurred after the last passed build/test at step "
                + "\(lastPassedStep) [\(lastPassedCheck)]; re-run that exact check against the latest "
                + "revision before completion or independent review"
        }
    }

    /// Returns the concrete receipt pair that made prior proof stale. This is intentionally independent of
    /// model prose: only typed successful check and mutation/effect observations participate.
    public func invalidatedVerification(in trajectory: [ActionRecord]) -> InvalidatedVerification? {
        guard let lastPassed = trajectory.lastIndex(where: {
            $0.success && Self.isFinalVerification($0, in: trajectory)
        }),
        let invalidating = trajectory.indices.last(where: {
            $0 > lastPassed && trajectory[$0].observedEffects.mutation != .none
        }) else { return nil }
        let check = trajectory[lastPassed]
        let mutation = trajectory[invalidating]
        return InvalidatedVerification(
            invalidatingStep: invalidating + 1,
            invalidatingMutation: Self.receiptLabel(mutation),
            invalidatingMutationSucceeded: mutation.success,
            lastPassedStep: lastPassed + 1,
            lastPassedCheck: Self.receiptLabel(check),
            lastPassedTool: check.tool,
            lastPassedFingerprint: check.argsFingerprint)
    }

    private static func receiptLabel(_ record: ActionRecord) -> String {
        let fingerprint = record.argsFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        return fingerprint.isEmpty ? record.tool : "\(record.tool): \(fingerprint.prefix(220))"
    }

    /// Compatibility helper retained for internal callers/tests. The shared catalog owns classification.
    static func mutationNeedsBuild(_ r: ActionRecord) -> Bool {
        r.observedEffects.requiresBuildVerification
    }

    public func check(trajectory: [ActionRecord], canRunCommands: Bool,
                      expectedOutcome: TaskBrief.ExpectedOutcome? = nil,
                      taskIntent: TaskBrief.Intent? = nil) -> Verdict {
        // A failed final mutation attempt is not completion, even for a doc/config artifact that would not
        // otherwise require a build. A later successful mutation can recover from an earlier failed try.
        // EXTERNAL-ACTION exception (dogfood 2026-08-06, round 3): a failed maybe-mutating command followed
        // by SUCCESSFUL external-state evidence is not a failed deliverable — the DOS app run had OCR proof
        // of "HELLO FROM KIST" captured AFTER a failed host command, and the turn still sank on this gate.
        // Grounded external evidence recorded after the failure outranks the speculative failed step.
        if let lastMutationIndex = trajectory.lastIndex(where: { $0.observedEffects.mutation != .none }),
           !trajectory[lastMutationIndex].success {
            // EXTERNAL-ACTION excuse only (dogfood 2026-08-06): the failed final attempt is excused
            // when the work was already DELIVERED by an earlier successful mutation AND successful
            // external-state proof followed the failure — evidence in the deliverable's own domain
            // (the app observably ran in the guest). A later PASSING BUILD/TEST deliberately does
            // NOT excuse: a planted always-green test would launder a failed change (the
            // resume-boundary anti-laundering pin encodes that attack).
            let deliveredBefore = trajectory[..<lastMutationIndex].contains {
                $0.success && $0.observedEffects.mutation != .none
            }
            let externallyProvenAfter = expectedOutcome == .externalAction
                && trajectory[(lastMutationIndex + 1)...].contains {
                    $0.success && $0.observedEffects.progress == .externalState
                }
            if !(deliveredBefore && externallyProvenAfter) {
                return .needsVerification(reason:
                    "the last mutation failed — failed work cannot be accepted as complete")
            }
        }

        // A concrete failed mutation is more specific and more important than the stale proof it also
        // creates, so evaluate it first. For a resumptive workspace boundary, preserve the detailed stale
        // receipt when execution is available; when it is not, report the actual blocker instead of asking
        // the model to run a check the current policy cannot execute.
        if let invalidated = invalidatedVerification(in: trajectory) {
            let externallyProvenAfter = expectedOutcome == .externalAction
                && trajectory.dropFirst(invalidated.invalidatingStep).contains {
                    $0.success && $0.observedEffects.progress == .externalState
                }
            if !externallyProvenAfter {
                if !canRunCommands {
                    return .needsVerification(reason:
                        "workspace verification is stale, but shell/build execution is unavailable, so completion is unverified")
                }
                return .needsVerification(reason: invalidated.reason)
            }
        }

        // A build/fleet contract promises a state change. A zero-tool, read-only child, or merely
        // started background delegation must not fall
        // through the "no source mutation" branch and turn a model's `done` claim into success.
        let fulfilledMutationContract = trajectory.contains {
            $0.success && ($0.observedEffects.confirmsMutation
                || $0.observedEffects.progress == .delegatedMutation)
        }
        if expectedOutcome == .mutation, !fulfilledMutationContract {
            return .needsVerification(reason:
                "the turn expected a workspace mutation, but no successful mutation was recorded")
        }

        if expectedOutcome == .delegation,
           !trajectory.contains(where: {
               $0.success && ($0.observedEffects.progress == .delegation
                   || $0.observedEffects.progress == .delegatedMutation)
           }) {
            return .needsVerification(reason:
                "the turn expected a completed delegation, but only local work or a running handle was recorded")
        }

        // Research is complete only when a successful tool observation records gathered/synthesized
        // evidence. A fluent answer with an empty or failed trajectory is still an unsupported claim.
        if expectedOutcome == .evidence,
           !trajectory.contains(where: {
               $0.success && ($0.observedEffects.progress == .research
                   || $0.observedEffects.progress == .evidence)
           }) {
            return .needsVerification(reason:
                "the turn expected research evidence, but no successful research or evidence observation was recorded")
        }

        // Desktop intent promises an action in another application/system, not merely a description of
        // what should happen. Only a successful, argument-aware external-state observation satisfies it.
        if expectedOutcome == .externalAction,
           !trajectory.contains(where: {
               $0.success && $0.observedEffects.progress == .externalState
           }) {
            return .needsVerification(reason:
                "the turn expected an external action, but no successful external-state change was recorded")
        }

        // No SOURCE-CODE (or unknown-target) mutation ⇒ nothing needs execution verification.
        guard let lastSourceMutation = trajectory.lastIndex(where: {
            $0.observedEffects.requiresBuildVerification
        }) else {
            return .accept
        }
        // A later doc/config mutation does not erase a failed source change. Conversely, a later successful
        // source mutation supersedes an earlier failed attempt and may be verified normally.
        // Same EXTERNAL-ONLY excuse as gate 1 (sibling site — the per-site pin caught this one):
        // delivered-before AND external proof after. A later passing build/test deliberately cannot
        // excuse (planted-test laundering); a trivial later command cannot excuse anything.
        guard trajectory[lastSourceMutation].success else {
            let deliveredBefore = trajectory[..<lastSourceMutation].contains {
                $0.success && $0.observedEffects.mutation != .none
            }
            let externallyProvenAfter = expectedOutcome == .externalAction
                && trajectory[(lastSourceMutation + 1)...].contains {
                    $0.success && $0.observedEffects.progress == .externalState
                }
            if deliveredBefore && externallyProvenAfter { return .accept }
            return .needsVerification(reason:
                "the last source mutation failed — a later command cannot make an unsuccessful edit complete")
        }

        // Was there a SUCCESSFUL build/test AFTER the last code change? TEETH: a bare successful
        // run_command is NOT enough — `ls`/`echo`/`cat` "passing" proves nothing. The command must
        // actually be a build / test / typecheck / lint, as classified once in its recorded effect. Resume
        // inserts an unconfirmed workspace boundary after pre-pause proof, so only proof after that boundary
        // appears in this slice.
        let after = trajectory[(lastSourceMutation + 1)...]
        let verified = after.contains {
            $0.success && $0.observedEffects.verification == .buildOrTest
        }
        if verified { return .accept }

        // EXTERNAL-ACTION turns (dogfood 2026-08-06): the "source" the agent wrote is a script destined
        // for another system — a guest VM's BAT/VBS, an automation payload — and there is no host
        // build/test for it. Its execution IN that system is its verification: accept when a successful
        // external-state action was recorded AFTER the last source change (grounded tool evidence, not a
        // model claim; the win98 round had vm_type/vm_ocr proof of the app running and still failed on a
        // build demand nothing could satisfy). Build/answer/mutation turns keep the strict demand below.
        if expectedOutcome == .externalAction,
           after.contains(where: { $0.success && $0.observedEffects.progress == .externalState }) {
            return .accept
        }

        if let failedCheck = after.last(where: {
            !$0.success && $0.observedEffects.verification == .buildOrTest
        }) {
            return .needsVerification(reason:
                "fresh build/test failed after the last source mutation [\(Self.receiptLabel(failedCheck))]")
        }

        // Shell-off used to silently ACCEPT source changes because the verifier could not execute. That is
        // precisely an unverified result: disclose it rather than upgrading absence of evidence to success.
        guard canRunCommands else {
            return .needsVerification(reason:
                "source code changed, but shell/build execution is unavailable, so completion is unverified")
        }
        // Distinguish "ran nothing" from "ran a non-verifying command" so the steer is honest.
        let ranSomething = after.contains {
            $0.success && $0.observedEffects.verification == .nonVerifyingCommand
        }
        let reason = ranSomething
            ? "you changed code and ran a command, but it wasn't a build/test — a passing build or test must confirm the change before this is done"
            : "you changed code but ran no build/test after the last edit — a build/test must pass before this is done"
        return .needsVerification(reason: reason)
    }

    /// The steer injected when a "done" is unverified.
    public static func steering(reason: String) -> String {
        if reason.contains("verification became stale") {
            return """
            Not done yet: \(reason).
            Re-run the exact last passed build/test named above against the latest revision. Do not make
            another edit first, widen permissions, add accepted exit codes, skip checks, or weaken tests.
            Finish only after that fresh deterministic receipt passes.
            """
        }
        if reason.contains("expected a workspace mutation") {
            return """
            Not done yet: \(reason).
            Perform the requested workspace change now with the write/edit/patch tools (or, for fleet work,
            actually delegate the work). If source code changes, then run the project's real build/tests.
            Do not claim completion until the promised work exists and its required verification passes.
            """
        }
        if reason.contains("expected research evidence") {
            return """
            Not done yet: \(reason).
            Gather concrete evidence with the available read, search, fetch, or research tools, then answer
            from those observations. Do not claim the research is complete from unsupported model recall.
            """
        }
        if reason.contains("expected an external action") {
            return """
            Not done yet: \(reason).
            Perform the requested external action with an available desktop/control tool and confirm that
            the tool succeeded. Do not report an action as completed when it was only described or inspected.
            """
        }
        return """
        Not done yet: \(reason).
        Run the project's REAL build and/or test command now (run_command) — e.g. `swift build` / `swift test`,
        `npm test`, `pytest`, `cargo test`, `go test`, `make`. A trivial command like `ls` or `echo` does NOT
        count. If it passes, THEN finish and say exactly what you ran. If it fails, fix it and re-run. Do not
        claim completion on unverified code changes.
        """
    }
}
