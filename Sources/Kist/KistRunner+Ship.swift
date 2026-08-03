import Foundation
import AgentCore

/// The `--ship` review, extracted from KistRunner (RED-zone modular split, behavior-preserving):
/// the build already ran hands-free in the autopilot sandbox; the council of minds reviews the ACTUAL
/// result (diff) and returns GO/NO-GO, and the human captain gate confirms any commit. Deploy stays manual.
extension KistRunner {

    /// `--ship`: the build already ran hands-free in the autopilot sandbox; now the council of minds
    /// reviews the actual result (changed-file manifest + goal) and returns GO/NO-GO. Deploy stays your call.
    static func runShipReview(goal: String, registry: ProviderRegistry, roles: RoleBindings, root: String) async {
        // Capture a REAL diff the council can judge — including NEW files' content (which `git diff`
        // alone omits until staged). Stage everything, drop kist's own run artifacts, read the staged
        // diff, then fully unstage to leave the working tree exactly as the build left it.
        _ = gitCapture(["-C", root, "add", "-A"])
        _ = gitCapture(["-C", root, "reset", "-q", "--", ".kist"])
        let statSummary = gitCapture(["-C", root, "diff", "--cached", "--stat"])
        let fullDiff = String(gitCapture(["-C", root, "diff", "--cached"]).prefix(14000))
        _ = gitCapture(["-C", root, "reset", "-q"])
        let hadChanges = !statSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let build = ShipPipeline.BuildResult(
            hadChanges: hadChanges,
            diffSummary: hadChanges ? (statSummary + "\n\n" + fullDiff) : "(no changes in the working tree)",
            testsPassed: false,
            testSummary: "no automated test suite was run for this fresh build — judge the CODE itself against the goal (this is a new build, not a regression to an existing tested codebase)",
            signoffSummary: "built hands-free in the autopilot OS sandbox",
            testsRan: false)   // no suite for a fresh build → the council judges the code (NOT a test failure)
        note("")
        note("ship · council of minds reviewing the build…")
        let decision = await ShipPipeline(council: CouncilPromotionJudge(providers: registry, roles: roles)).review(goal: goal, build: build)
        if let v = decision.verdict {
            for vote in v.votes {
                note("  \(vote.shipWorthy ? "\u{001B}[32m✓\u{001B}[0m" : "\u{001B}[31m✗\u{001B}[0m") \(vote.name): \(vote.reason.prefix(140))")
            }
        }
        guard decision.canDeploy else {
            note("ship · \u{001B}[31;1m✗ NO-GO\u{001B}[0m — \(decision.reason)")
            return
        }
        note("ship · \u{001B}[32;1m● GO\u{001B}[0m — the council blessed it. \(decision.reason)")
        // THE CAPTAIN GATE: you are the captain. The council can't deploy alone — it needs your sign-off.
        // (This is the human captain gate; the Ed25519 cryptographic captain in the codebase is for
        // unforgeable multi-party/CI sign-off — overkill for a local single user.) Non-TTY → never deploy.
        guard stdinIsTTY() else {
            note("ship · captain sign-off needed — re-run in your terminal, or commit the build yourself.")
            return
        }
        FileHandle.standardError.write(Data("ship · captain — deploy this build (commit it)? [y/N] ".utf8))
        let answer = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard answer == "y" || answer == "yes" else {
            note("ship · held by the captain — not committed. Ship it yourself when ready.")
            return
        }
        _ = gitCapture(["-C", root, "add", "-A"])
        _ = gitCapture(["-C", root, "reset", "-q", "--", ".kist"])   // don't commit kist's run artifacts
        let safeGoal = goal.replacingOccurrences(of: "\n", with: " ").prefix(72)
        let commit = gitCapture(["-C", root, "commit", "-m", "ship: \(safeGoal)"])
        note("ship · \u{001B}[32;1m● DEPLOYED\u{001B}[0m — committed the build. \(commit.split(separator: "\n").first.map(String.init) ?? "")")
        note("ship · push / host it with your deploy step when ready — kist won't push for you.")
    }

    /// Capture a git command's stdout (best-effort; "" on any failure).
    static func gitCapture(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
