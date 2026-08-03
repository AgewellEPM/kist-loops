import Foundation
import AgentCore

/// Pure session/cycle helpers, extracted from KistRunner (RED-zone modular split, behavior-preserving):
/// memory refresh/injection, per-cycle budgeting, cross-cycle continuity, last-failure carry-forward,
/// the coding-loop tool filter, the cortex journal writer, and runtime-lesson recording. All small and
/// side-effect-light — the reusable primitives the run routes lean on.
extension KistRunner {

    /// On --resume, surface the CURRENT cortex memory so the agent starts the resumed turn already
    /// knowing (its toolset includes `cortex` too, so this is a convenience, not the only path).
    /// GUARDED: append only after an ASSISTANT turn so provider message-alternation stays valid;
    /// no-op when memory is off or empty. Pure → unit-tested.
    static func withMemoryRefresh(_ cp: LoopCheckpoint, memory: String, enabled: Bool) -> LoopCheckpoint {
        guard enabled, !memory.isEmpty, cp.messages.last?.role == .assistant else { return cp }
        var out = cp
        out.messages.append(ChatMessage(role: .user, content: "MEMORY REFRESH — what kist knows about you now:\n" + memory))
        return out
    }

    /// The full session memory injected into a run's brief: the Cortex (who Luke is + this project +
    /// recent journal) folded with ProjectMemory (this repo's planning notes). Used by the one-shot
    /// and TUI paths so cortex is injected in EVERY mode, not only the interactive REPL.
    /// Per-cycle token budget: an even share of what REMAINS across the cycles LEFT, floored so a cycle is
    /// never starved below a unit of real work, and capped at the full remaining (the last cycle can use it
    /// all). Adaptive (uses the live remaining), so budget unspent by cheap early cycles flows forward to
    /// finish the task — instead of a rigid total/maxCycles that dies mid-work and forces a fresh restart.
    static func perCycleBudget(remaining: Int, cycleIndex: Int, maxCycles: Int, floor: Int = 60_000) -> Int {
        guard remaining > 0 else { return 0 }
        let cyclesLeft = max(1, maxCycles - cycleIndex)
        let evenShare = remaining / cyclesLeft
        return min(remaining, max(floor, evenShare))
    }

    /// Cross-cycle CONTINUITY note. Each great-loop cycle is a fresh conversation, so without a reminder the
    /// model has amnesia and re-creates work a prior cycle already did (dogfood: built the package at ./ then
    /// re-created it under ./MathKit/ → duplication, never converged). From cycle 1 on, if prior cycles
    /// changed files, tell the model to CONTINUE that work (not restart) and list the files. nil on cycle 0
    /// (nothing done yet) or when no files changed (a read-only/analysis task).
    static func continuityNote(cycleIndex: Int, changedFiles: [String]) -> String? {
        guard cycleIndex > 0, !changedFiles.isEmpty else { return nil }
        return "WORK ALREADY IN PROGRESS (prior cycles) — CONTINUE it; do NOT recreate the project from "
            + "scratch or under a new subdirectory. If a build/manifest file already exists, build and TEST "
            + "what's here. Files changed so far:\n"
            + changedFiles.prefix(60).map { "  - \($0)" }.joined(separator: "\n")
    }

    /// The failure detail of the LAST failed `run_command` in a cycle's trajectory — the concrete
    /// build/test/compiler error to carry into the next cycle. nil when the last run_command succeeded or
    /// none failed (so a cycle that ended green doesn't push a stale error forward).
    static func lastCommandFailure(in trajectory: [ActionRecord]) -> String? {
        guard let last = trajectory.last(where: { $0.tool == "run_command" }) else { return nil }
        guard !last.success, let detail = last.failureDetail else { return nil }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Tools irrelevant to an autonomous CODING loop — dropped so their schemas don't inflate EVERY model
    /// call. Dogfood: the full set was ~70 tools / ~25k schema chars (~6.5k tokens/call), and a coding cycle
    /// spent ~half its budget re-sending schemas for media / app-UI-testing / desktop-control / pentest /
    /// enterprise-reporting tools it never uses — so cycles couldn't converge to a verified done. Kept:
    /// file/shell/edit/lsp/memory/tasks/web/research/symbols (everything a build+test+fix loop needs).
    static func isLoopIrrelevantTool(_ name: String) -> Bool {
        if name.hasPrefix("isolated-tester__") { return true }   // app UI-testing MCP — not code building
        let drop: Set<String> = [
            "computer_control", "desktop_control", "tap", "locate", "look", "wait_for_screen", "watch_screen", "computer_use_check", "computer_use_selftest", "ui_elements", "ax_press",   // desktop/GUI control — not code building
            "pentest", "security_audit", "business_workflow", "governance_report",
            "edit_image", "generate_audio", "analyze_media", "watch_video", "extract_clip", "view_image",
        ]
        return drop.contains(name)
    }

    static func sessionMemory(root: String, opts: KistOptions) -> String? {
        guard !opts.noMemory else { return nil }
        let projectName = (root as NSString).lastPathComponent
        let parts = [CortexMemory().context(projectName: projectName), ProjectMemory(root: root).planningContext()]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Auto-log a completed goal run to the cortex JOURNAL, so the work log fills itself instead of
    /// only when the model remembers to call the cortex tool. One bounded line; no-op under
    /// --no-memory; best-effort (a journal write must never fail the run). Secrets in the goal are
    /// redacted at CortexMemory's write choke point.
    static func autoJournalRun(goal: String, success: Bool, root: String, enabled: Bool) {
        guard enabled, !goal.isEmpty else { return }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = .current
        df.locale = Locale(identifier: "en_US_POSIX")
        let g = goal.split(separator: "\n").first.map(String.init) ?? goal
        try? CortexMemory().logWork("[\(success ? "done" : "paused")] \(g.prefix(100)) · \((root as NSString).lastPathComponent)",
                                    date: df.string(from: Date()))
    }

    static func recordRuntimeLessons(goal: String, success: Bool, recorder: TrajectoryRecorder,
                                             lessonStore: LessonStore?, maxIterations: Int,
                                             mode: PromptCompiler.Mode) {
        let intent = PromptCompiler.compile(goal, mode: mode).intent
        let report = TrajectoryAnalyzer.analyze(recorder.snapshot(), maxIterations: maxIterations,
                                                taskIntent: intent)
        if !report.healthy { note("⚙ self-check · " + report.issues.map { $0.kind.rawValue }.joined(separator: ", ")) }
        guard let lessonStore else { return }
        let at = Date().timeIntervalSince1970
        for issue in report.issues {
            lessonStore.record(Lesson(kind: .obstacle,
                                      text: "\(issue.kind.rawValue): \(issue.detail) [goal: \(goal.prefix(80))]",
                                      source: nil, at: at))
        }
        if !success {
            lessonStore.record(Lesson(kind: .obstacle, text: "task failed: \(goal.prefix(120))", source: nil, at: at))
        }
    }
}
