import Foundation
import AgentCore

/// Prompts the human at the terminal for approvals + answers. Used by the REPL so sensitive
/// tools (shell, file writes) show what they'll do and wait for consent — the Claude-Code feel.
///
/// An `actor` (not a struct) so it can hold ONE piece of session state: "approve everything from
/// here on". That flag is what turns an endless `[y/N]` gauntlet into a single decision — the user
/// hits `a` once and the agent stops interrupting. It also fixes the trap that made the shell feel
/// broken: a bare Enter now APPROVES (the highlighted default), instead of silently declining and
/// sending the agent back into a retry loop.
actor TerminalInteractor: RuntimeInteractor {
    private var approveAll = false
    private var autopilot = false        // runtime /auto toggle: approve everything (incl. dangerous)
    private var deferredInputs: [String] = []
    private let color: Bool
    private let autoApproveRoutine: Bool
    private let autoApproveDangerous: Bool

    /// Flip hands-free autopilot on/off mid-session (the REPL `/auto` command).
    func setAutopilot(_ on: Bool) { autopilot = on }
    var isAutopilot: Bool { autopilot }

    init(color: Bool = TerminalCapabilities.stdoutIsInteractive,
         autoApproveRoutine: Bool = false,
         autoApproveDangerous: Bool = false) {
        self.color = color
        self.autoApproveRoutine = autoApproveRoutine
        self.autoApproveDangerous = autoApproveDangerous
    }

    private func c(_ code: String, _ s: String) -> String { color ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }

    func takeDeferredInput() -> String? {
        guard !deferredInputs.isEmpty else { return nil }
        return deferredInputs.removeFirst()
    }

    func requestApproval(planSummary: String) async -> Bool {
        await requestApproval(planSummary: planSummary, dangerous: false)
    }

    func requestApproval(planSummary: String, dangerous: Bool) async -> Bool {
        if autopilot || autoApproveDangerous || (autoApproveRoutine && !dangerous) {
            let detail = planSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            FileHandle.standardOutput.write(Data((c("2", "  ✓ autopilot approved ") + c("36", detail.prefix(140).description) + "\n").utf8))
            return true
        }
        // "allow all" covers routine mutations, NOT irreversible ones — a dangerous action ALWAYS asks.
        if approveAll && !dangerous { return true }

        let detail = planSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = "\n"
        out += dangerous
            ? c("41;1", "  ⚠  IRREVERSIBLE — confirm (not covered by ‘allow all’)") + "\n"
            : c("33;1", "  ⚠  permission needed") + "\n"
        out += c("2", "  └ ") + detail + "\n"
        // A dangerous action defaults to run-once, but offers an EXPLICIT, clearly-labelled YOLO latch —
        // "[a] allow ALL incl. irreversible" arms autopilot for the rest of the session (Luke's ask: "need
        // a YOLO allow-all — once I see this I can ok it"). The wording spells out that it covers irreversible
        // so it's a deliberate choice, not a fat-finger.
        if dangerous {
            out += "  " + c("32;1", "[Enter] run once") + c("2", "   ")
                         + c("31", "[n] skip") + c("2", "   ")
                         + c("41;1", "[a] allow ALL incl. irreversible (rest of session)") + "\n"
        } else {
            out += "  " + c("32;1", "[Enter] run") + c("2", "   ")
                         + c("31", "[n] skip") + c("2", "   ")
                         + c("36", "[a] run everything from now") + "\n"
        }
        out += c("36;1", "  ▸ ")
        FileHandle.standardOutput.write(Data(out.utf8))

        // Take stdin from the esc-interrupt watcher (if any) for this cooked read, so the watcher neither
        // steals the keypress nor leaves stdin in raw mode (no echo). See StdinArbiter.
        guard let raw = StdinArbiter.shared.withStdin({ readLine(strippingNewline: true) }) else { return false }   // Ctrl-D = decline
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "", "y", "yes", "ok", "run":
            return true                                   // Enter / yes → approve (the default)
        case "a", "all", "always", "yolo":
            if dangerous {
                // Explicit YOLO on an irreversible prompt: arm full autopilot — approve EVERYTHING (incl.
                // irreversible) for the rest of the session. This is the user's deliberate override of the
                // "never latch dangerous" default (the option is spelled out on the prompt).
                autopilot = true
                FileHandle.standardOutput.write(Data((c("41;1", "  ⚠ GUARDS OFF — approving everything (incl. irreversible) for this session") + "\n").utf8))
            } else {
                approveAll = true
                FileHandle.standardOutput.write(Data((c("36", "  ✓ auto-approving the rest of this session") + "\n").utf8))
            }
            return true
        case "n", "no", "skip":
            return false
        default:
            if let deferred = Self.deferredPrompt(fromRejectedApproval: trimmed) {
                deferredInputs.append(deferred)
                FileHandle.standardOutput.write(Data((c("37", "  ↳ skipped this action; queued your text as the next prompt") + "\n").utf8))
            }
            return false                                  // n / no / anything else → skip
        }
    }

    func requestInput(question: String) async -> String {
        FileHandle.standardOutput.write(Data((c("36;1", "  ▸ ") + question + " ").utf8))
        return StdinArbiter.shared.withStdin { readLine(strippingNewline: true) } ?? ""
    }

    static func deferredPrompt(fromRejectedApproval raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        for prefix in ["n ", "no ", "skip "] {
            if lower.hasPrefix(prefix) {
                let rest = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return rest.isEmpty ? nil : rest
            }
        }
        if ["n", "no", "skip"].contains(lower) { return nil }
        // A stray punctuation keystroke ("$", ";") typed at an approval must NOT become the next turn's
        // prompt — that ran a garbage `ask_user` turn instead of the user's real question. Require real
        // (alphanumeric) content, same gate as the type-ahead queue.
        guard TurnInputQueue.isQueueableInstruction(trimmed) else { return nil }
        return trimmed
    }
}
