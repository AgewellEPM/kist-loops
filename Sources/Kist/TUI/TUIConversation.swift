import Foundation
import AgentCore

/// The conversation loop driven through the raw-mode TUI: persistent input box, single-keypress
/// approvals, line history, agent output streaming into the band above. PROTOTYPE scope — chat turns
/// plus the core slash commands (/exit /help /clear /model-info). Fleet/roles/media routing live in
/// the standard line REPL (run without --tui) until the TUI mechanics are verified on a live terminal.
struct TUIConversation {
    let ui: TerminalUI
    var loop: HeadlessAgentLoop
    var modelLabel: String
    var briefCompiler: ((_ input: String, _ mode: PromptCompiler.Mode) -> String)? = nil
    var clipboardText: () -> String? = { nil }
    var recorder: TrajectoryRecorder? = nil
    var lessonStore: LessonStore? = nil
    // Permission bar (shift+tab) config — mirrors the line REPL. In --tui the cycle skips bypass
    // (guards-off stays --yolo-launch-only) so no raw-mode y/N confirm is needed on this surface.
    var sensitiveTools: Set<String> = []
    var editTools: Set<String> = []
    var initialPermissionMode: PermissionMode = .normal

    private func c(_ code: String, _ s: String) -> String { TerminalANSI.color(code, s) }

    func run() async {
        var loop = self.loop   // mutable: the permission tier is applied per turn
        var perm = PermissionController(mode: initialPermissionMode, sensitive: sensitiveTools, edit: editTools)
        // shift+tab in --tui cycles the SAFE tiers only (normal → accept-edits → plan); skip bypass so
        // arming never needs a raw-mode confirm on this surface. Launched --yolo stays guards-off.
        // Skip ANY guards-off tier (policy check, not a mode-name check) so a future unsafe mode is
        // auto-excluded on --tui. Bounded by the cycle length so it can never spin, even if more than one
        // guards-off tier existed (MiMo M2).
        func cycleSafe() {
            for _ in 0..<PermissionMode.cycle.count {
                perm.cycle()
                if !perm.mode.armsGuardsOff { return }
            }
        }
        ui.setBar { PromptBar.hint(mode: perm.mode, includeInterrupt: true) }   // before setup() → reserves the row
        ui.setup()
        defer { ui.teardown() }
        banner()
        var transcript: [ChatMessage] = []

        while true {
            switch ui.readLine(onPaste: clipboardText, onCycle: cycleSafe) {
            case .eof:
                ui.appendTranscript("\r\n" + c("2", "bye.") + "\r\n"); return
            case .interrupt:
                ui.appendTranscript(c("2", "  (use /exit to quit)") + "\r\n"); continue
            case .line(let raw):
                let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if input.isEmpty { continue }

                // Only a command-shaped leading "/" is a command — a dragged-in path
                // falls through to the agent as a normal message (see KistREPL.isSlashCommand).
                if KistREPL.isSlashCommand(input) {
                    let (name, _) = split(input)
                    switch name.lowercased() {
                    case "exit", "quit", "q":
                        ui.appendTranscript(c("2", "bye.") + "\r\n"); return
                    case "clear":
                        transcript = []; ui.appendTranscript(c("2", "(context cleared)") + "\r\n"); continue
                    case "help":
                        help(); continue
                    case "model", "m":
                        ui.appendTranscript(c("2", "model · ") + c("36", modelLabel)
                            + c("2", "   (switch models in the standard REPL — run without --tui)") + "\r\n"); continue
                    default:
                        ui.appendTranscript(c("31", "unknown command /\(name)") + c("2", " — /help") + "\r\n"); continue
                    }
                }

                let prompt = briefCompiler?(input, perm.mode.isPlan ? .plan : .inline) ?? input
                recorder?.reset()
                loop = perm.arm(loop)          // apply the current tier (plan/approvals) before the turn
                ui.beginTurn()
                // esc-to-interrupt on --tui too: run under the keyboard watcher; transcript is inout so it
                // rides through a box across the escaping work closure. (Allowlisted turn-site.)
                let armed = loop
                let preTurnTranscript = transcript
                let tBox = MutableBox(transcript)
                // R1: same interject/cancel split as the line-mode REPL (multi-site sibling).
                let reasonBox = MutableBox<InterruptibleTurn.InterruptReason?>(nil)
                let outcome = await InterruptibleTurn.run(onInterrupt: { reason in
                    reasonBox.value = reason
                    ui.appendTranscript("\r\n" + c("33", reason == .cancel
                        ? "⎋⎋ cancelled — dropping this turn"
                        : "⎋ interrupted — stopping after the current step; your turn (progress saved)") + "\r\n")
                }) {
                    var t = tBox.value
                    let o = await armed.turn(transcript: &t, userInput: prompt)
                    tBox.value = t
                    return o
                }
                // "Dropping this turn" must MEAN dropped (review catch): restore pre-turn context.
                transcript = (reasonBox.value == .cancel) ? preTurnTranscript : tBox.value
                if reasonBox.value == .cancel, !outcome.success, !outcome.checkpointId.isEmpty {
                    LoopCheckpointStore().abandon(id: outcome.checkpointId)
                }
                ui.endTranscriptBlock()
                // An ESC'd turn is a user decision, not a reliability failure — don't learn from it.
                if reasonBox.value == nil {
                    selfMonitor(goal: input, success: outcome.success)
                }
            }
        }
    }

    private func selfMonitor(goal: String, success: Bool) {
        guard let recorder else { return }
        let report = TrajectoryAnalyzer.analyze(recorder.snapshot())
        if !report.healthy {
            let labels = report.issues.map { $0.kind.rawValue }.joined(separator: ", ")
            ui.appendTranscript(c("2", "self-check · \(labels)") + "\r\n")
        }
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

    private func split(_ input: String) -> (String, String) {
        let body = input.dropFirst()
        guard let sp = body.firstIndex(of: " ") else { return (String(body), "") }
        return (String(body[..<sp]), String(body[body.index(after: sp)...]).trimmingCharacters(in: .whitespaces))
    }

    private func banner() {
        ui.appendTranscript(c("36;1", "Mythos · kist") + c("2", " — TUI (PROTOTYPE)") + "\r\n")
        ui.appendTranscript(c("2", "model · ") + c("36", modelLabel) + "\r\n")
        ui.appendTranscript(c("2", "type to chat · Enter sends · approvals are single-key (y/n/a) · /help · /exit") + "\r\n")
    }

    private func help() {
        for line in [
            "/help            this help",
            "/clear           forget the conversation",
            "/model           show the current model",
            "/exit /quit /q   leave (or Ctrl-D)",
            "<anything else>  chat / build with the agent",
        ] { ui.appendTranscript(c("2", "  " + line) + "\r\n") }
    }
}
