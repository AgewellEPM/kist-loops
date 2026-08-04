import Foundation

/// R3 (2026-07-28): the unit-of-work contract — a LUMPY PLAN NEVER EXECUTES unrepaired. Every step
/// must be SINGULAR: one tool, one intent, one visible unit of progress. The lint runs in
/// `obtainPlan` after structural validation; findings go back to the planner as repair feedback
/// (bounded by `maxPlanRepairs`), so a bundled plan is re-split before execution. Lint findings are
/// ADVISORY at exhaustion: a structurally-valid plan that still lints executes with a visible
/// warning rather than failing the goal (a lint false positive must never brick a mission).
public enum PlanLint {
    /// Human-readable contract violations; empty = the plan may execute.
    public static func findings(for plan: ExecutablePlan) -> [String] {
        var out: [String] = []
        for step in plan.steps {
            if step.intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append("step \(step.id) has an empty intent — every micro-task states its ONE purpose")
            }
            if step.tool == "run_command" {
                let cmd = commandString(argumentsJSON: step.argumentsJSON)
                let segments = max(chainedSegments(cmd), shellPayloadSegments(cmd) ?? 0)
                if segments > 2 {
                    out.append("step \(step.id) chains \(segments) shell commands — split into singular steps (at most two chained commands per step, e.g. `cd X && make`)")
                }
                if installsLegacyEmulator(cmd) {
                    out.append("step \(step.id) installs a legacy emulator/toolchain on the host — forbidden; route DOS/Win9x work through Perslis (perslis__vm_launch → perslis__vm_write_file → perslis__win98_run_command, or the `perslis`/`perslis-play`/`legacy-fetch` host CLIs)")
                }
            }
        }
        if plan.steps.count > 24 {
            out.append("plan has \(plan.steps.count) steps — over-decomposed; merge trivial neighbors (target ≤ 24)")
        }
        return out
    }

    /// A run_command that package-installs a retro emulator/assembler on the HOST — the shape that
    /// burned the DOS-clock run (2026-08-03: brew-install NASM/DOSBox steps, all doomed). Legacy
    /// work routes through Perslis; findings feed the planner's bounded repair loop, forcing a
    /// re-plan onto the perslis tools. The verb→target span excludes `;`/`&` so an ALLOWED
    /// two-command chain (`brew install jq && nasm clock.asm`) can't cross-match, and the
    /// word-boundary keeps `qemu-img convert` (a non-install command) clean.
    static func installsLegacyEmulator(_ command: String) -> Bool {
        command.range(
            of: #"\b(brew|apt(-get)?|port|dnf|yum)\b(\s+\S+)*?\s+(install|reinstall|upgrade)\b[^;&]*\b(dosbox(-x)?|nasm|qemu|wine|86box|pcem|vice|freedos|masm)\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Count chained command segments, QUOTE-AWARE: `&&`, `||`, `;`, and newlines split units of
    /// work, but not inside single/double quotes or after a backslash (`find -exec rm {} \;`).
    /// A single `&` (background) or `|` (pipe) does not split — a pipeline is one unit. Crude
    /// beyond that on purpose: this catches the "do five things in one step" shape, it is not a
    /// shell parser, and a false positive must stay cheap (advisory at exhaustion).
    static func chainedSegments(_ command: String) -> Int {
        var segments: [String] = []
        var current = ""
        var inSingle = false, inDouble = false, escaped = false
        var i = command.startIndex
        while i < command.endIndex {
            let ch = command[i]
            if escaped {
                current.append(ch); escaped = false
            } else if ch == "\\" {
                escaped = true; current.append(ch)
            } else if ch == "'" && !inDouble {
                inSingle.toggle(); current.append(ch)
            } else if ch == "\"" && !inSingle {
                inDouble.toggle(); current.append(ch)
            } else if !inSingle && !inDouble && (ch == ";" || ch == "\n") {
                segments.append(current); current = ""
            } else if !inSingle && !inDouble && (ch == "&" || ch == "|") {
                let next = command.index(after: i)
                if next < command.endIndex, command[next] == ch {
                    segments.append(current); current = ""; i = next
                } else {
                    current.append(ch)
                }
            } else {
                current.append(ch)
            }
            i = command.index(after: i)
        }
        segments.append(current)
        return segments.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    /// `sh -c '<payload>'` is one process but may bundle several units of work — lint the payload
    /// too. EXCEPTION: a payload that IS a control structure (for/while/until/if/case) counts as
    /// one unit; its internal `;` separators are syntax, not chained work. nil = not a shell -c
    /// invocation.
    static func shellPayloadSegments(_ command: String) -> Int? {
        guard let re = try? NSRegularExpression(
                  pattern: #"^\s*(?:sh|bash|zsh)\s+(?:-\S+\s+)*-\S*c\s+(['"])(.*)\1\s*$"#,   // -c and combined -lc
                  options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let payloadRange = Range(m.range(at: 2), in: command) else { return nil }
        let payload = String(command[payloadRange])
        if payload.range(of: #"^\s*(for|while|until|if|case)\b"#, options: .regularExpression) != nil {
            return 1
        }
        return chainedSegments(payload)
    }

    static func commandString(argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["command"] as? String else { return "" }
        return cmd
    }
}
