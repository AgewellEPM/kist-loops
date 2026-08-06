import Foundation
import AgentCore

// `/fix` — the Captain drives the PROVEN /build worker in a force-retry loop, and refuses to stop
// until there's a VERIFIED, non-monolith artifact. This is the user-facing button for putting the
// symbolic Captain back on top: it plans → forces action → builds → the deterministic judge rules
// "done", never the model. It reuses `planExecute` (which routes through `runPlanExecute`, so it
// inherits the CaptainSimulationEnforcer preflight + mutation gate + critic + real verification — no
// safety bypass), and adds the anti-analysis teeth via `CaptainController` (AgentCore).
extension KistREPL {

    /// Run `/fix`: assemble the decider (always build, escalate when the Captain forces it), the
    /// performer (one `planExecute` build per move), and the SymbolicCaptain-backed judge; then drive.
    /// Returns a HeavyRouteResult so the turn is finalized honestly (analysis-only => .failed, never .passed).
    func runCaptainFix(goal: String) async -> HeavyRouteResult {
        guard let planExecute else {
            return HeavyRouteResult(exitCode: 2, interruption: nil,
                                    review: .notApplicable("plan-execute worker unavailable in this mode"),
                                    verification: .unavailable("no worker to drive"))
        }
        let root = projectRoot
        let interrupted = MutableBox<InterruptibleTurn.InterruptReason?>(nil)

        // The Captain decides the model: strongest reachable, never a known-weak/dead one. nil ⇒ the
        // session is already on the strongest, so keep it (no needless switch). Global routing untouched.
        let fixRoles: RoleBindings
        if let strong = captainStrongRoles?() {
            fixRoles = strong
            print("\u{001B}[36m⚓ Captain routing → \(TeamLanguage.displayName(strong.fallback.providerId))\u{001B}[0m\u{001B}[2m · picked the strongest reachable model for this fix (no roulette)\u{001B}[0m")
        } else {
            fixRoles = roleSelection.bindings
        }

        let performer = FixBuildPerformer(planExecute: planExecute,
                                          roles: fixRoles,
                                          projectRoot: root,
                                          onInterrupt: { reason in interrupted.value = reason })
        let decider = FixBuildDecider()
        // Files already dirty BEFORE this fix — excluded from the monolith gate so a pre-existing large
        // dirty file can't falsely block a small correct fix (review finding, 2026-08-05).
        let baselineChanged = Set(KistREPL.workingTreeChangedFiles(projectRoot: root))
        let judge = Self.makeFixJudge(projectRoot: root, baselineChanged: baselineChanged)

        // maxTicks 3 = at most three build attempts (bounded, honest — not an infinite hammer).
        // analysisPatience 1 = the FIRST build that produces no verified artifact triggers an escalated,
        // Captain-forced retry. The judge (SymbolicCaptain) is the sole authority on "done".
        let captain = CaptainController(maxTicks: 3, analysisPatience: 1, judge: judge,
                                        isKilled: { interrupted.value != nil })

        print("\u{001B}[36;1m🛠  /fix\u{001B}[0m\u{001B}[2m · Captain drives the build worker until there's a verified, non-monolith artifact — analysis-only is rejected\u{001B}[0m")
        let outcome = await captain.drive(objective: goal, requiresArtifact: true,
                                          decider: decider, performer: performer)

        switch outcome {
        case .completed(let ticks):
            // "…then review it all" — the last step of the /fix vision: once the Captain has a verified
            // artifact, a skeptical reviewer busts its balls (advisory; it proposes changes, never auto-applies).
            print("\u{001B}[32;1m✓ /fix produced a verified artifact in \(ticks) attempt(s)\u{001B}[0m\u{001B}[2m — now reviewing it…\u{001B}[0m")
            await runBallbusting(args: "")
            return HeavyRouteResult(exitCode: 0, interruption: nil,
                                    review: .handledInternally("the Captain owned the drive loop; the model proposed, the symbolic judge decided, then a skeptical reviewer critiqued the result"),
                                    verification: .passed("verified artifact produced in \(ticks) build attempt(s)"))
        case .exhausted(let ticks):
            return HeavyRouteResult(exitCode: 1, interruption: nil,
                                    review: .handledInternally("the Captain drove \(ticks) attempts"),
                                    verification: .failed("no verified build after \(ticks) attempt(s) — the worker produced analysis/plans, not a passing build"))
        case .killed:
            return HeavyRouteResult(exitCode: 130, interruption: interrupted.value ?? .cancel,
                                    review: .notApplicable("interrupted"),
                                    verification: .unavailable("the /fix drive was interrupted"))
        case .handedBack(let reason, _):
            return HeavyRouteResult(exitCode: 1, interruption: nil,
                                    review: .handledInternally("handed back: \(reason)"),
                                    verification: .unavailable("handed back: \(reason)"))
        }
    }

    /// The done-gate: cheap artifact/failure guards FIRST (so it is never LOOSER than the controller's
    /// default), then the deterministic SymbolicCaptain verdict — which ADDS the monolith gate with a
    /// REAL per-file line count over the actually-changed files. `Foreman.fleetCaptain` drops
    /// `done_needs_codex` (there is no per-turn review signal for a live /fix, and forging one is a lie).
    static func makeFixJudge(projectRoot root: String,
                             baselineChanged: Set<String> = []) -> @Sendable (String, [MoveOutcome]) -> CaptainVerdict {
        return { objective, history in
            guard history.contains(where: { $0.success && $0.producedArtifact }) else {
                return .notDone(reason: "no verified artifact yet — analysis/planning is not completion")
            }
            if let last = history.last, !last.success {
                return .notDone(reason: "the last build attempt failed")
            }
            // Symbolic pass: an artifact EXISTS and built (the performer ANDs verification-passed into
            // producedArtifact), so the added authority here is the NO-MONOLITHS gate on real bytes.
            // Only files THIS drive touched — files already dirty at baseline (pre-existing, unrelated dirt,
            // e.g. an 1800-line file someone left modified) must NOT falsely block a small correct fix.
            let touched = KistREPL.workingTreeChangedFiles(projectRoot: root).filter { !baselineChanged.contains($0) }
            let maxLines = touched
                .map { KistREPL.fileLineCount((root as NSString).appendingPathComponent($0)) }
                .max() ?? 0
            let facts = CaptainFacts(
                build: BuildFacts(
                    buildID: Foreman.buildID(goalID: objective, agentID: UUID(), turnNumber: 0, claimHash: 0),
                    claimedDone: true,
                    tests: TestRunEvidence(exitCode: 0),                 // artifact ⇒ the worker's build passed
                    diff: DiffEvidence(changedLines: touched.isEmpty ? 0 : 1, maxFileLines: maxLines),
                    codex: CodexEvidence(reviewed: false),
                    stepCapHit: false, runIncomplete: false),
                world: WorldFacts.fromMeasuredTest(exitCode: 0))
            let judgment = Foreman.fleetCaptain.judge(facts)
            switch judgment.verdict {
            case .green:        return .done
            case .blocked:      return .notDone(reason: judgment.failedBlockers.first ?? "a structural invariant failed")
            case .driftFlagged: return .notDone(reason: judgment.driftReason ?? "the world has not confirmed this build")
            }
        }
    }

    /// Line count of a file (best-effort, 0 if unreadable). Used only for the monolith gate's evidence.
    static func fileLineCount(_ path: String) -> Int {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return content.reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } }
    }
}

/// Always proposes a BUILD (the worker plans internally; the Captain's job is to make it ACT and to
/// gate done). When the Captain forces action after a non-productive attempt, it escalates the order.
struct FixBuildDecider: CaptainDecider {
    func propose(objective: String, history: [MoveOutcome], forcedAction: Bool) async -> CaptainMove {
        if forcedAction {
            return .build(step:
                "Your previous attempt did NOT produce a verified build. BUILD IT NOW: write the real "
                + "files/edits and make the project's build/tests pass. No more analysis, no plan-only "
                + "output. Objective: \(objective)")
        }
        return .build(step: objective)
    }
}

/// One Captain build move == one run of the proven `planExecute` worker. `producedArtifact` is the
/// honest signal the judge keys on: the worker's own verification PASSED and the working tree actually
/// changed. Serial by construction (the drive awaits each move), so `@unchecked Sendable` is safe.
final class FixBuildPerformer: CaptainPerformer, @unchecked Sendable {
    private let planExecute: (String, RoleBindings) async -> HeavyRouteResult
    private let roles: RoleBindings
    private let projectRoot: String
    private let onInterrupt: (InterruptibleTurn.InterruptReason) -> Void

    init(planExecute: @escaping (String, RoleBindings) async -> HeavyRouteResult,
         roles: RoleBindings, projectRoot: String,
         onInterrupt: @escaping (InterruptibleTurn.InterruptReason) -> Void) {
        self.planExecute = planExecute
        self.roles = roles
        self.projectRoot = projectRoot
        self.onInterrupt = onInterrupt
    }

    func perform(_ move: CaptainMove, objective: String) async -> MoveOutcome {
        let step: String
        switch move {
        case .build(let s):       step = s
        case .investigate(let s): step = s          // controller shouldn't send these for /fix, but be safe
        default:
            return MoveOutcome(success: true, producedArtifact: false, summary: "no-op move")
        }
        // BASELINE the working tree BEFORE this attempt. Codex P2: comparing to "any dirty file" false-
        // completes on an already-dirty repo (a move that built nothing still looks like it produced an
        // artifact). Diff the full working tree before vs after so `changed` means THIS move mutated it —
        // catches new files AND edits to already-dirty files, and is not fooled by pre-existing dirt.
        let diffBefore = KistREPL.workingTreeDiff(projectRoot: projectRoot)
        let result = await planExecute(step, roles)     // inherits preflight + mutation gate + critic + verification
        if let reason = result.interruption {
            onInterrupt(reason)
            return MoveOutcome(success: false, producedArtifact: false, summary: "interrupted")
        }
        let built = result.verification.proofSuccess == true
        let diffAfter = KistREPL.workingTreeDiff(projectRoot: projectRoot)
        let changed = diffAfter != diffBefore && !diffAfter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let artifact = built && changed          // the monolith authority lives in the judge, not here
        let summary = artifact
            ? "built + verified — \(result.verification.proofText)"
            : "no verified artifact — \(result.verification.proofText)\(changed ? "" : " (this attempt changed nothing)")"
        return MoveOutcome(success: result.succeeded, producedArtifact: artifact, summary: summary)
    }
}
