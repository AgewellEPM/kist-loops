import Foundation
import AgentCore

/// Routes the agent loop's events into the TUI's transcript band (raw mode needs CR+LF line ends).
/// `@unchecked Sendable`: it only ever calls `appendTranscript`, which is a plain stdout write — no
/// shared mutable UI state is touched, and the TUI is turn-based so there's no concurrent input loop.
final class TUIEventSink: RuntimeEventSink, @unchecked Sendable {
    private let ui: TerminalUI
    private let showReasoning: Bool
    // Same double-print guard as TerminalEventSink: if the answer already streamed inline via tokenDelta,
    // don't reprint it as the "done · <summary>" tail. Reset at each terminal event. (Bug fix 2026-07-29.)
    private var textWasStreamed = false
    init(ui: TerminalUI, showReasoning: Bool = false) { self.ui = ui; self.showReasoning = showReasoning }

    private func c(_ code: String, _ s: String) -> String { TerminalANSI.color(code, s) }

    func emit(_ event: RuntimeEvent) {
        switch event {
        case .tokenDelta(let t):
            textWasStreamed = true
            ui.appendTranscript(t.replacingOccurrences(of: "\n", with: "\r\n"))
        case .reasoningDelta(let r):
            if showReasoning { ui.appendTranscript(c("2;3", r.replacingOccurrences(of: "\n", with: "\r\n"))) }
        case .actionStarted(_, let tool, let desc):
            let label = tool ?? "action"
            let detail = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            var line = "\r\n" + c("36", "│ ") + c("36;1", label)
            if !detail.isEmpty, detail != label { line += c("2", "  " + String(detail.prefix(110))) }
            ui.appendTranscript(line + "\r\n")
        case .actionFinished(_, let ok, let output, let error):
            if ok {
                let preview = output.split(separator: "\n").prefix(4).joined(separator: "\r\n" + c("36", "│ ") + "  ")
                ui.appendTranscript(c("36", "│ ") + c("32;1", "✓ ") + (preview.isEmpty ? c("2", "(no output)") : preview) + "\r\n")
            } else {
                ui.appendTranscript(c("36", "│ ") + c("31;1", "✗ ") + c("31", String((error ?? output).prefix(200))) + "\r\n")
            }
        case .completed(let summary):
            let tail = (textWasStreamed || summary.isEmpty) ? "" : c("2", " · " + summary)
            ui.appendTranscript("\r\n" + c("32;1", "● ") + c("32", "done") + tail + "\r\n")
            textWasStreamed = false
        case .failed(let reason):
            ui.appendTranscript("\r\n" + c("31;1", "● ") + c("31", "failed") + c("2", " · " + reason) + "\r\n")
            textWasStreamed = false
        case .cancelled:
            ui.appendTranscript("\r\n" + c("33;1", "● ") + c("33", "stopped") + "\r\n")
            textWasStreamed = false
        default:
            break
        }
    }
}

/// Approvals via single keypress through the TUI (Enter/y = run, n = skip, a = allow all). Holds the
/// "allow all" bit for the session, like the line-mode interactor. `@unchecked Sendable` for the same
/// reason as the sink: turn-based, no concurrent UI access.
final class TUIInteractor: RuntimeInteractor, @unchecked Sendable {
    private let ui: TerminalUI
    private var approveAll = false
    init(ui: TerminalUI) { self.ui = ui }

    func requestApproval(planSummary: String) async -> Bool {
        await requestApproval(planSummary: planSummary, dangerous: false)
    }

    func requestApproval(planSummary: String, dangerous: Bool) async -> Bool {
        // "allow all" covers routine mutations, NOT irreversible ones — a dangerous action ALWAYS asks
        // and never latches allow-all (mirrors TerminalInteractor; Codex HIGH: TUI allow-all bypass).
        if approveAll && !dangerous { return true }
        let prompt = dangerous ? "⚠ IRREVERSIBLE — " + planSummary : planSummary
        // Take stdin from the esc-interrupt watcher for this single-key read (restores the TUI's own raw
        // mode while it reads, so the watcher doesn't steal the key or mis-set VMIN/VTIME). See StdinArbiter.
        switch StdinArbiter.shared.withStdin({ ui.readApproval(summary: prompt) }) {
        case .yes: return true
        case .all:
            if dangerous { return true }   // run once, do not latch on a dangerous action
            approveAll = true
            ui.appendTranscript(TerminalANSI.color("36", "  ✓ auto-approving the rest of this session") + "\r\n")
            return true
        case .no: return false
        }
    }

    func requestInput(question: String) async -> String {
        ui.appendTranscript("\r\n" + TerminalANSI.color("36;1", "  ▸ ") + question + " ")
        if case .line(let s) = StdinArbiter.shared.withStdin({ ui.readLine() }) { return s }
        return ""
    }
}
