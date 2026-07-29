import Foundation
import AgentCore

/// `/copilot` — turn on an automatic second-AI review after every coding turn. You assign the LEAD (the
/// model that writes the code — defaults to the session model) and the CO (the model that reviews the
/// diff). When on, any turn that mutated files is followed by the co-model's review of the actual `git
/// diff`. It's advisory only — it prints findings, never edits or reverts on its own.
///
/// This holds the session state + the pure parsing/prompt logic (unit-tested without a terminal); the
/// REPL owns the git-diff read and the model call.
struct CopilotConfig: Equatable {
    var enabled = false
    var lead: ProviderBinding? = nil   // who writes the code (nil ⇒ the session default model)
    var co: ProviderBinding? = nil     // who reviews the diff (nil ⇒ the session default model)
    /// R4: close the loop — when the co-reviewer flags blocking issues, the lead runs a FIX turn to
    /// address them (a real coder↔reviewer partnership, not an advisory print). Armed by team mode.
    var autoFix = false
    /// Bounded fix rounds so a stubborn review can't loop the team forever.
    var maxFixRounds = 1

    /// One-line status for `/copilot` and `/copilot status`.
    func statusLine(render: (ProviderBinding) -> String) -> String {
        let leadTxt = lead.map(render) ?? "session model"
        let coTxt = co.map(render) ?? "session model"
        let state = enabled ? "\u{001B}[32mon\u{001B}[0m" : "off"
        return "copilot · \(state) · lead: \(leadTxt) · co-reviewer: \(coTxt)"
    }
}

enum CopilotCommand: Equatable {
    case on
    case off
    case status
    case setLead(String)   // raw "<provider[:model]>" spec — the REPL resolves it against its catalog
    case setCo(String)
    case invalid
}

enum Copilot {
    /// Parse a `/copilot` subcommand. `""`/`status` → status; `on`/`off` → toggle; `lead <spec>` /
    /// `co <spec>` (also `reviewer`) → assign a role; anything else → invalid (REPL prints usage).
    static func parseCommand(_ args: String) -> CopilotCommand {
        let trimmed = args.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if lower.isEmpty || lower == "status" { return .status }
        if lower == "on" || lower == "true" || lower == "1" { return .on }
        if lower == "off" || lower == "false" || lower == "0" { return .off }
        for (kw, make): (String, (String) -> CopilotCommand) in
            [("lead ", CopilotCommand.setLead), ("co ", CopilotCommand.setCo), ("reviewer ", CopilotCommand.setCo)] {
            if lower.hasPrefix(kw) {
                let spec = String(trimmed.dropFirst(kw.count)).trimmingCharacters(in: .whitespaces)
                return spec.isEmpty ? .invalid : make(spec)
            }
        }
        return .invalid
    }

    /// The tools whose presence in a turn's trajectory means "code/files changed" → worth a review.
    static let mutatingTools: Set<String> = ["write_file", "edit_file", "make_dir", "move_file"]

    /// True when this turn's trajectory contains a *successful* file mutation. A read-only or failed turn
    /// isn't reviewed (nothing changed to review).
    static func shouldReview(trajectory: [ActionRecord]) -> Bool {
        trajectory.contains { mutatingTools.contains($0.tool) && $0.success }
    }

    static let reviewSystemPrompt = """
    You are a senior code reviewer acting as a co-pilot. You are handed the git diff a teammate just \
    produced. Review it critically and concisely. Report only what matters: correctness bugs, security \
    issues, missing error handling, broken edge cases, and anything that contradicts the stated task. If \
    the diff is clean, say so in one line. Do not restate the diff. Do not praise. Be specific — name the \
    file and the concern. If you find nothing actionable, reply exactly: LGTM — no blocking issues.
    """

    /// Build the review user-prompt from the diff, bounded so a huge diff can't blow the context.
    static func reviewPrompt(task: String, diff: String, maxChars: Int = 12_000) -> String {
        let clipped = diff.count > maxChars
            ? String(diff.prefix(maxChars)) + "\n… [diff truncated — reviewing the first \(maxChars) chars]"
            : diff
        return """
        Task the teammate was working on:
        \(task.isEmpty ? "(not specified)" : task)

        The diff they produced:
        ```diff
        \(clipped)
        ```

        Review it.
        """
    }

    /// R4: the "clean" sentinel the reviewer emits when there is nothing to fix. When the review is NOT
    /// clean, the team loop runs a fix round (the lead addresses the findings) — a real coder↔reviewer
    /// partnership instead of an advisory print. Matched leniently: any LGTM / "no blocking" phrasing.
    static func reviewIsClean(_ review: String) -> Bool {
        let l = review.lowercased()
        if l.contains("lgtm") { return true }
        if l.contains("no blocking") || l.contains("nothing actionable")
            || l.contains("no actionable") || l.contains("no issues") { return true }
        return false
    }

    /// The fix ask handed BACK to the lead (coder) so the reviewer's findings get addressed in the same
    /// working tree — closes the loop Luke asked for ("review, catch errors, THEN fix it").
    static func fixPrompt(task: String, review: String) -> String {
        """
        Your teammate reviewed the code you just wrote for this task:
        \(task.isEmpty ? "(not specified)" : task)

        Their review findings:
        \(review.trimmingCharacters(in: .whitespacesAndNewlines))

        Address the ACTIONABLE findings above by editing the files. Fix real correctness/security/\
        edge-case issues; skip anything that's a matter of taste or that you can justify keeping. Make \
        the minimal edits that resolve the findings — do not rewrite unrelated code. If a finding is \
        wrong, briefly say why instead of changing the code.
        """
    }
}
