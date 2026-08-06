import Foundation
import AgentCore

// Glanceable turn dashboard: assemble live minds/board/research/confidence, plus the
// research/knowledge-debt de-dup mergers. Extracted verbatim from KistREPL.swift.
extension KistREPL {
    /// Launch the canonical Fallout/Pip-Boy GUI dashboard for the REPL. The `/dashboard` command was
    /// dropped when kist-loops was re-homed as the captain; this restores it. The full GUI (talent/tech
    /// tree, history, arch/builds/cortex/sessions/vms views) lives under `~/.kist`; the deployed
    /// `~/bin/kist-dashboard` launcher owns the server start, provenance validation, browser open, and
    /// readiness probe, so we just invoke it and surface its output (the ready URL, or an error).
    ///
    /// FIRE-AND-FORGET launch: the REPL must NEVER block on the launcher (Codex P2 — the launcher may hold
    /// the readiness probe or foreground the local server, which `waitUntilExit()` would freeze the REPL
    /// on). We spawn detached, discard output, and reap on a background task; the launcher opens the browser
    /// itself. `command` is only the display label.
    func launchDashboard(command: String, args: String) async {
        let launcher = (NSHomeDirectory() as NSString).appendingPathComponent("bin/kist-dashboard")
        guard FileManager.default.isExecutableFile(atPath: launcher) else {
            print("\u{001B}[31m/dashboard: launcher not installed at \(launcher) — run `kist-rebuild` to install it\u{001B}[0m")
            return
        }
        let view = args.trimmingCharacters(in: .whitespaces).lowercased()
        let root = projectRoot
        print("\u{001B}[36m↳ launching Kist dashboard\(view.isEmpty ? "" : " · \(view)") — opening in your browser…\u{001B}[0m")
        print("\u{001B}[2m  (if it doesn't appear, run `~/bin/kist-dashboard` directly to see the error)\u{001B}[0m")
        // Detached + non-blocking: run(), then reap in the background. The REPL returns immediately.
        Task.detached(priority: .utility) {
            var procArgs: [String] = []
            if !view.isEmpty { procArgs.append(view) }              // the launcher validates the view name
            procArgs += ["--project-root", root]
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launcher)
            p.arguments = procArgs
            p.standardOutput = FileHandle.nullDevice                // no pipe → no fill-and-block, no capture
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return }
            p.waitUntilExit()                                       // reap here, off the REPL thread
        }
    }

    /// Build the glanceable turn dashboard from live session state: the active model/team, the board, a
    /// derived confidence, and what's next. Pure over its inputs → the REPL just feeds it.
    static func buildDashboard(roles: RoleSelection, projectRoot: String,
                               trajectory: [ActionRecord], grounded: Bool,
                               sessionStartedAt: Date? = nil) -> StatusDashboard {
        // Active Minds — the Captain is the orchestration process; models are workers it can assign.
        let fb = roles.fallback
        var minds: [StatusDashboard.Mind] = [
            .init(name: "Kist", role: "Captain"),
            .init(name: TeamLanguage.displayName(fb.providerId), role: "Default model")
        ]
        let bindings = roles.bindings
        for (role, label) in [(AgentRole.worker, "Research"), (.coder, "Builder"), (.critic, "Review")] {
            let b = bindings.binding(for: role)
            if b.providerId != fb.providerId {
                minds.append(.init(name: TeamLanguage.displayName(b.providerId), role: label))
            }
        }
        // Build Queue — actionable items only. Completed tasks drop away so the
        // board advances instead of repeating the same finished work each turn.
        let plan = PlanStore(projectRoot: projectRoot).load()
        let tasks = plan.buildQueue(limit: 6).map { t -> StatusDashboard.Item in
            let st: StatusDashboard.Item.State
            switch t.status { case .done: st = .done; case .blocked: st = .blocked; default: st = .pending }
            return .init(title: t.boardTitle, state: st)
        }
        let insights = DashboardResearchPlanner.build(for: plan, projectRoot: projectRoot,
                                                       trajectory: trajectory)
        let learning = OrganizationalLearningStore(projectRoot: projectRoot)
        let debts = learning.openKnowledgeDebt(limit: 8)
        let latestCapsule = learning.latestCapsule()
        let persistedResearch = debts.map { debt -> StatusDashboard.ResearchItem in
            .init(title: debt.topic,
                  priority: debt.priority == .high ? .high : .medium,
                  reason: debt.reason,
                  visit: debt.visit,
                  impact: debt.impact,
                  estimatedLearning: debt.estimatedLearning,
                  expectedBenefit: debt.expectedBenefit)
        }
        let persistedKnowledge = debts.map { debt -> StatusDashboard.KnowledgeDebt in
            .init(need: "Need to research", topic: debt.topic,
                  impact: debt.expectedBenefit.first ?? debt.reason,
                  severity: debt.impact)
        }
        // Confidence — grounded, healthy, low-failure ⇒ high. The ConfidenceReport keeps the FACTORS
        // (reliability/health/grounding) so the panel shows a battery gauge + the top drag and
        // `/confidence` can explain why. nil when there were no actions (a plain answer).
        let confidenceReport = ConfidenceReport.compute(report: TrajectoryAnalyzer.analyze(trajectory),
                                                        grounded: grounded)
        // "Next" must not FREEZE on a stale board task when the user just asked a QUESTION that never
        // touched the board (Luke's "I asked something and Next never changed" bug — a task stuck
        // inProgress made plan.active return it forever). Only surface a specific board Next when THIS
        // turn actually worked the board (a file mutation or state-changing `tasks` action); otherwise
        // "Continue". Listing/validating tasks is inspection, not board movement.
        let workedBoard = turnWorkedBoard(trajectory)
        let currentActive = sessionStartedAt.map { plan.active(since: $0) } ?? plan.active
        let next = workedBoard
            ? (currentActive?.boardTitle ?? plan.nextActionable?.boardTitle ?? plan.next?.boardTitle ?? "Continue")
            : "Continue"
        return StatusDashboard(minds: minds,
                               tasks: Array(tasks),
                               learned: latestCapsule?.learned ?? [],
                               research: Self.mergeResearch(insights.research + persistedResearch),
                               knowledgeDebt: Self.mergeKnowledgeDebt(insights.knowledgeDebt + persistedKnowledge),
                               questions: insights.questions,
                               futureEvolution: latestCapsule.map {
                                   .init(capability: $0.futureEvolution,
                                         estimatedImpact: "High")
                               },
                               observation: insights.observation,
                               confidenceReport: confidenceReport,
                               next: next)
    }

    static func mergeResearch(_ items: [StatusDashboard.ResearchItem]) -> [StatusDashboard.ResearchItem] {
        var seen = Set<String>()
        var out: [StatusDashboard.ResearchItem] = []
        for item in items {
            let key = item.title.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(item)
            if out.count == 6 { break }
        }
        return out
    }

    static func mergeKnowledgeDebt(_ items: [StatusDashboard.KnowledgeDebt]) -> [StatusDashboard.KnowledgeDebt] {
        var seen = Set<String>()
        var out: [StatusDashboard.KnowledgeDebt] = []
        for item in items {
            let key = item.topic.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(item)
            if out.count == 5 { break }
        }
        return out
    }
}
