import Foundation
import AgentCore

/// The `--ship` review, extracted from KistRunner (RED-zone modular split, behavior-preserving):
/// the build already ran hands-free in the autopilot sandbox; the council of minds reviews the ACTUAL
/// result (diff) and returns GO/NO-GO, and the human captain gate confirms any commit. Deploy stays manual.
extension KistRunner {

    /// `--ship`: the build already ran hands-free in the autopilot sandbox; now the council of minds
    /// reviews the actual result (changed-file manifest + goal) and returns GO/NO-GO. Deploy stays your call.
    @discardableResult
    static func runShipReview(goal: String, registry: ProviderRegistry, roles: RoleBindings, root: String,
                              verifiedExecution: Bool? = nil,
                              evidenceOverride: String? = nil,
                              allowVerifiedReadOnly: Bool = false,
                              verificationSubject: String? = nil,
                              verificationDigest: String? = nil,
                              completionEvidence: PromotionCompletionEvidence? = nil,
                              confirmDeployment: Bool = true) async -> ShipPipeline.Decision {
        // Git is optional reviewer context, never Builder completion evidence. Prepublication
        // transaction workspaces intentionally have no .git directory. Only successful git output is
        // admissible as advisory text; launch failures and nonzero stderr are never shown as build facts.
        let gitAdd = gitCaptureResult(["-C", root, "add", "-A"])
        var gitStat = GitCaptureResult(exitCode: nil, output: "")
        var gitDiff = GitCaptureResult(exitCode: nil, output: "")
        if gitAdd.succeeded {
            _ = gitCaptureResult(["-C", root, "reset", "-q", "--", ".kist"])
            gitStat = gitCaptureResult(["-C", root, "diff", "--cached", "--stat"])
            gitDiff = gitCaptureResult(["-C", root, "diff", "--cached"])
            _ = gitCaptureResult(["-C", root, "reset", "-q"])
        }
        let gitAdvisoryAvailable = gitAdd.succeeded && gitStat.succeeded && gitDiff.succeeded
        let statSummary = gitAdvisoryAvailable ? gitStat.output : ""
        let fullDiff = gitAdvisoryAvailable ? String(gitDiff.output.prefix(14000)) : ""
        let advisoryGitHadChanges = gitAdvisoryAvailable
            && !statSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let readOnlyEvidence: String? = {
            guard allowVerifiedReadOnly, let verificationSubject, let verificationDigest else { return nil }
            return "verified subject: \(verificationSubject)\ngoverned digest: \(verificationDigest)"
        }()
        let evidenceMutation = completionEvidence?.baselineDigest != completionEvidence?.verifiedDigest
        // Builder mutation truth comes only from the sealed transaction packet. Git is advisory:
        // staged prepublication workspaces intentionally do not contain the source repository's .git.
        let runHadChanges = completionEvidence?.hadChanges
            ?? (completionEvidence?.completionMode == .verificationOnly
                ? evidenceMutation : advisoryGitHadChanges)
        let changedPaths = completionEvidence?.changedPaths
            ?? (runHadChanges ? KistREPL.workingTreeChangedFiles(projectRoot: root).sorted() : [])
        var observedMutationLines: [String] = []
        for receipt in completionEvidence?.mutationReceipts ?? [] {
            for operation in receipt.operations {
                let images = "[\(operation.preimageSHA256 ?? "absent") -> "
                    + "\(operation.postimageSHA256 ?? "absent")]"
                observedMutationLines.append(
                    "\(operation.kind.rawValue) \(operation.path) \(images) "
                        + "transactionWorkspace=\(receipt.workspaceDigest) "
                        + "verifierSubject=\(receipt.verifierSubjectDigest ?? "unavailable") "
                        + "receipt=\(receipt.receiptDigest)")
            }
        }
        let observedMutationSummary = observedMutationLines.joined(separator: "\n")
        let gitAdvisory = advisoryGitHadChanges
            ? "git advisory (non-authoritative):\n\(statSummary)\n\n\(fullDiff)"
            : "git advisory unavailable (the verified subject is not a git worktree or the git probe did not succeed)"
        let reviewDiff: String
        if completionEvidence != nil {
            let authoritative: String
            if completionEvidence?.completionMode == .verificationOnly && !runHadChanges {
                authoritative = readOnlyEvidence
                    ?? "authoritative host result: verification-only run made no governed changes"
            } else if !observedMutationSummary.isEmpty {
                authoritative = "AUTHORITATIVE SEALED BUILDER MUTATIONS:\n\(observedMutationSummary)"
            } else {
                authoritative = "AUTHORITATIVE SEALED BUILDER MUTATIONS: unavailable"
            }
            reviewDiff = authoritative + "\n\n" + gitAdvisory
        } else if advisoryGitHadChanges {
            reviewDiff = statSummary + "\n\n" + fullDiff
        } else {
            reviewDiff = "(no successful git diff was available)"
        }
        let finalReviewSummary: String
        if let evidenceOverride, !evidenceOverride.isEmpty {
            finalReviewSummary = completionEvidence == nil
                ? evidenceOverride
                : reviewDiff + "\n\nADDITIONAL TYPED ROUTE EVIDENCE:\n" + evidenceOverride
        } else {
            finalReviewSummary = reviewDiff
        }
        let completedEvidence = completionEvidence?.withChanges(
            hadChanges: completionEvidence?.hadChanges ?? runHadChanges,
            changedPaths: completionEvidence?.changedPaths ?? changedPaths,
            diffSummary: finalReviewSummary)
        let build = ShipPipeline.BuildResult(
            hadChanges: completedEvidence?.hadChanges
                ?? (evidenceOverride != nil || runHadChanges),
            diffSummary: finalReviewSummary,
            testsPassed: verifiedExecution ?? false,
            testSummary: verifiedExecution == true && completionEvidence != nil
                ? "deterministic host verification PASSED against the exact staged subject; every required host check reports PASS"
                : (verifiedExecution == true
                    ? "the Great Loop completed with its deterministic done-and-verified verdict"
                    : "no automated test suite was run for this fresh build — judge the CODE itself against the goal (this is a new build, not a regression to an existing tested codebase)"),
            signoffSummary: completionEvidence == nil
                ? "built hands-free in the autopilot OS sandbox"
                : "typed transaction mutation and deterministic host-verification receipts validated; generic worker/model self-verdicts are non-authoritative",
            testsRan: verifiedExecution != nil,
            verificationSubject: verificationSubject,
            verificationDigest: verificationDigest,
            completionEvidence: completedEvidence)
        note("")
        note("ship · council of minds reviewing the build…")
        let decision = await ShipPipeline(council: CouncilPromotionJudge(providers: registry, roles: roles))
            .review(goal: goal, build: build, allowVerifiedReadOnly: allowVerifiedReadOnly)
        if let v = decision.verdict {
            for vote in v.votes {
                note("  \(vote.shipWorthy ? "\u{001B}[32m✓\u{001B}[0m" : "\u{001B}[31m✗\u{001B}[0m") \(vote.name): \(vote.reason.prefix(140))")
            }
        }
        guard decision.canDeploy else {
            note("ship · \u{001B}[31;1m✗ NO-GO\u{001B}[0m — \(decision.reason)")
            return decision
        }
        note("ship · \u{001B}[32;1m● GO\u{001B}[0m — the council blessed it. \(decision.reason)")
        // BuilderRun consumes the pure review decision as its completion gate. Deployment remains a
        // separate, explicitly armed --ship action and must never be triggered by canonical review.
        guard confirmDeployment else { return decision }
        // THE CAPTAIN GATE: you are the captain. The council can't deploy alone — it needs your sign-off.
        // (This is the human captain gate; the Ed25519 cryptographic captain in the codebase is for
        // unforgeable multi-party/CI sign-off — overkill for a local single user.) Non-TTY → never deploy.
        guard stdinIsTTY() else {
            note("ship · captain sign-off needed — re-run in your terminal, or commit the build yourself.")
            return decision
        }
        FileHandle.standardError.write(Data("ship · captain — deploy this build (commit it)? [y/N] ".utf8))
        let answer = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard answer == "y" || answer == "yes" else {
            note("ship · held by the captain — not committed. Ship it yourself when ready.")
            return decision
        }
        _ = gitCapture(["-C", root, "add", "-A"])
        _ = gitCapture(["-C", root, "reset", "-q", "--", ".kist"])   // don't commit kist's run artifacts
        let safeGoal = goal.replacingOccurrences(of: "\n", with: " ").prefix(72)
        let commit = gitCapture(["-C", root, "commit", "-m", "ship: \(safeGoal)"])
        note("ship · \u{001B}[32;1m● DEPLOYED\u{001B}[0m — committed the build. \(commit.split(separator: "\n").first.map(String.init) ?? "")")
        note("ship · push / host it with your deploy step when ready — kist won't push for you.")
        return decision
    }

    struct GitCaptureResult: Sendable, Equatable {
        let exitCode: Int32?
        let output: String
        var succeeded: Bool { exitCode == 0 }
    }

    /// Capture git stdout with an explicit process status. Stderr is intentionally discarded: a git
    /// diagnostic is never evidence that the governed build failed.
    static func gitCaptureResult(_ args: [String]) -> GitCaptureResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return GitCaptureResult(exitCode: nil, output: "") }
        // Drain while the child runs so a large diff cannot fill the pipe and deadlock waitUntilExit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return GitCaptureResult(exitCode: p.terminationStatus, output: output)
    }

    /// Compatibility wrapper for explicit deployment commands.
    static func gitCapture(_ args: [String]) -> String {
        gitCaptureResult(args).output
    }
}
