import Foundation
import AgentCore

// Shared Plan/Action/Test/Review board: /tasks handlers, board-reference resolution,
// execution briefs, the task-contract parser, and the simple turn summary.
// Extracted verbatim from KistREPL.swift (Pass-1 modularization; no behavior change).
extension KistREPL {

    /// Tools whose SUCCESSFUL use means the turn actually CHANGED state — a broader set than the copilot
    /// review trigger (which is only file-diff mutations). Restored across the origin/main merge: the
    /// turn-summary dashboard uses this to decide compact-vs-full, so a `run_command`/`apply_patch` turn
    /// (real work, no file-write) still renders the full dashboard. Do NOT narrow to Copilot.mutatingTools.
    static let summaryMutatingTools: Set<String> = [
        "edit_file", "write_file", "apply_patch", "notebook_edit",
        "run_command", "move_file", "create_directory", "make_dir",
    ]

    /// True when a turn did real mutating work (any `summaryMutatingTools` call that succeeded).
    static func turnHasMutatingWork(_ trajectory: [ActionRecord]) -> Bool {
        trajectory.contains { summaryMutatingTools.contains($0.tool) && $0.success }
    }

    static func handleTasks(_ args: String, projectRoot: String) -> String {
        let store = PlanStore(projectRoot: projectRoot)
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let sub = parts.first?.lowercased() else { return store.load().render() }
        let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch sub {
        case "add":
            guard !rest.isEmpty else { return "usage: /tasks add <title>" }
            let contract = parseTaskContract(rest, defaultOwner: "luke")
            let t = store.add(title: contract.title, detail: contract.detail, owner: contract.owner,
                              link: contract.link, kind: contract.kind,
                              acceptance: contract.acceptance,
                              verification: contract.verification,
                              evidence: contract.evidence)
            return "added [\(t.id)] \(t.title)\n" + store.load().render()
        case "start":
            let task = Int(rest).flatMap { store.update(id: $0, status: .inProgress) } ?? store.startNext()
            return task.map { "started [\($0.id)] \($0.title)\n" } ?? "no task to start\n" + store.load().render()
        case "done", "complete":
            guard let id = Int(rest) else { return "usage: /tasks done <id>" }
            let (completed, nowActive, didAdvance) = store.completeAndAdvance(id: id)
            guard let t = completed else { return "usage: /tasks done <id>" }
            let plan = store.load()
            let advance: String
            if didAdvance, let nowActive {
                advance = "▶ advanced to [\(nowActive.id)] \(nowActive.boardTitle)\n"
            } else if let nowActive {
                advance = "▶ active remains [\(nowActive.id)] \(nowActive.boardTitle)\n"
            } else if let next = plan.nextActionable {
                advance = "→ next remains [\(next.id)] \(next.boardTitle)\n"
            } else if plan.buildQueue().contains(where: { $0.status == .blocked }) {
                advance = "⚠ no actionable task — blocked work remains\n"
            } else {
                advance = "✓ build queue clear\n"
            }
            return "done [\(t.id)] \(t.title)\n" + advance + plan.render()
        case "block":
            let bits = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard let id = bits.first.flatMap(Int.init),
                  let t = store.update(id: id, status: .blocked, detail: bits.count > 1 ? bits[1] : "") else {
                return "usage: /tasks block <id> <why>"
            }
            return "blocked [\(t.id)] \(t.title)\n" + store.load().render()
        case "evidence", "proof":
            let bits = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard let id = bits.first.flatMap(Int.init), bits.count > 1 else {
                return "usage: /tasks evidence <id> <proof>"
            }
            guard let t = store.update(id: id, appendEvidence: [bits[1]]) else { return "no task with id \(id)" }
            return "evidence added [\(t.id)] \(t.title)\n" + store.load().render()
        case "validate", "check":
            return PlanContractValidator.render(PlanContractValidator.validate(store.load()))
        case "clear":
            store.clear(); return "plan cleared"
        default:
            return store.load().render()
        }
    }


    static func taskSelectedByUser(_ input: String, projectRoot: String) -> PlanTask? {
        let plan = PlanStore(projectRoot: projectRoot).load()
        guard !plan.tasks.isEmpty else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if let id = explicitTaskID(in: lower) {
            return plan.tasks.first { $0.id == id && $0.status != .done }
        }

        let nextPhrases = [
            "next", "next task", "run next", "start next", "do next", "execute next",
            "run the next task", "start the next task", "do the next task",
            "continue", "keep going", "go", "go next"
        ]
        // Prefer a genuinely-active task, then the next ACTIONABLE (non-research) todo, and only then a
        // bare research todo — so a stuck .inProgress research task cannot hijack 'next' while build work
        // remains, and `active` still wins for real in-flight multi-turn work.
        if nextPhrases.contains(lower) { return plan.active ?? plan.nextActionable ?? plan.next }
        return nil
    }


    static func expandBoardReference(_ input: String, projectRoot: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let task = taskSelectedByUser(trimmed, projectRoot: projectRoot) {
            _ = PlanStore(projectRoot: projectRoot).update(id: task.id, status: .inProgress)
            return executionBrief(for: task, userInput: trimmed)
        }

        let lower = trimmed.lowercased()
        let boardWords = [" this", " it", " all", " next", " task", " action", " board item"]
        let startsGeneric = ["this", "it", "all", "next", "task", "action"].contains { lower == $0 || lower.hasPrefix($0 + " ") }
        guard startsGeneric || boardWords.contains(where: { lower.contains($0) }) else { return trimmed }

        let meaningful = lower
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !boardReferenceGlue.contains($0) }
        guard meaningful.isEmpty else { return trimmed }
        let plan = PlanStore(projectRoot: projectRoot).load()
        guard let task = plan.active ?? plan.nextActionable ?? plan.next else { return trimmed }
        _ = PlanStore(projectRoot: projectRoot).update(id: task.id, status: .inProgress)
        return executionBrief(for: task, userInput: trimmed)
    }


    static func executionBrief(for task: PlanTask, userInput: String) -> String {
        var lines = [
            "Execute shared task [\(task.id)] \(task.kind.label): \(task.boardTitle).",
            "User instruction: \(userInput)",
            "Task board: .kist/plan.json",
            "Start by updating task [\(task.id)] to in-progress if it is not already active.",
            "Do the implementation with the available tools. Do not ask the user to manually perform the step unless the tool surface is genuinely unavailable.",
            "Before final answer, add evidence to task [\(task.id)] and mark it done only after verification passes.",
        ]
        if !task.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Detail: \(task.detail)")
        }
        if !task.acceptance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Acceptance: \(task.acceptance)")
        }
        if !task.verificationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Verification: \(task.verificationText)")
        }
        if !task.evidence.isEmpty {
            lines.append("Existing evidence: \(task.evidence.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }


    private static let boardReferenceGlue: Set<String> = [
        "build", "code", "implement", "write", "create", "make", "run", "execute", "do", "start",
        "continue", "finish", "ship", "all", "this", "it", "next", "task", "action", "item", "board",
        "now", "please", "pls", "the", "a", "an", "to", "for", "with", "on", "in", "through", "using"
    ]


    private static func explicitTaskID(in lower: String) -> Int? {
        let patterns = [
            #"^\s*(\d{1,4})\s*$"#,
            #"^\s*\[(\d{1,4})\]\s*$"#,
            #"^\s*#(\d{1,4})\s*$"#,
            #"^\s*(?:task|action|item|step)\s+#?\[?(\d{1,4})\]?\s*$"#,
            #"^\s*(?:run|start|do|execute|build|work on|continue)\s+(?:task|action|item|step)?\s*#?\[?(\d{1,4})\]?\s*$"#,
        ]
        let ns = lower as NSString
        let range = NSRange(location: 0, length: ns.length)
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            guard let match = re.firstMatch(in: lower, range: range), match.numberOfRanges > 1 else { continue }
            if let id = Int(ns.substring(with: match.range(at: 1))) { return id }
        }
        return nil
    }


    struct ParsedTaskContract: Equatable {
        var title: String
        var detail: String = ""
        var owner: String? = nil
        var link: String? = nil
        var kind: PlanTask.Kind? = nil
        var acceptance: String = ""
        var verification: String = ""
        var evidence: [String] = []
    }


    /// Human-friendly contract parser:
    ///   ACTION: build router | acceptance: fallback works | verify: swift test | evidence: Tests/...
    static func parseTaskContract(_ raw: String, defaultOwner: String? = nil) -> ParsedTaskContract {
        let chunks = raw.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var out = ParsedTaskContract(title: chunks.first ?? raw.trimmingCharacters(in: .whitespacesAndNewlines),
                                     owner: defaultOwner)
        for chunk in chunks.dropFirst() {
            guard let colon = chunk.firstIndex(of: ":") else {
                out.detail = out.detail.isEmpty ? chunk : out.detail + "\n" + chunk
                continue
            }
            let key = chunk[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = chunk[chunk.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "detail", "notes", "note":
                out.detail = out.detail.isEmpty ? value : out.detail + "\n" + value
            case "owner":
                out.owner = value
            case "link", "source", "url":
                out.link = value
                if key == "source" { out.evidence.append(value) }
            case "kind", "type":
                out.kind = PlanTask.Kind(rawValue: value.lowercased())
            case "accept", "acceptance", "done", "definition of done":
                out.acceptance = value
            case "verify", "verification", "test", "prove":
                out.verification = value
            case "evidence", "proof":
                out.evidence.append(value)
            default:
                out.detail = out.detail.isEmpty ? chunk : out.detail + "\n" + chunk
            }
        }
        if out.kind == nil { out.kind = PlanTask.Kind.infer(from: out.title) }
        return out
    }


    static func renderSimpleSummary(projectRoot: String, spans: [AgentSpan], trajectory: [ActionRecord]) -> String {
        let plan = PlanStore(projectRoot: projectRoot).load()
        let toolCalls = trajectory.count
        let modelCalls = spans.filter { $0.kind == .llmCall }.count
        let usage = UsageCost.summarize(spans: spans).render(label: "usage")
        // Mirror the selectors: prefer a real active task, then the next ACTIONABLE todo, so a stuck
        // research task doesn't dominate the "next" nudge while build work remains.
        let next = plan.active ?? plan.nextActionable ?? plan.next
        // Only NUDGE toward the board when THIS turn actually worked it — a successful file mutation
        // (a build) or a `tasks` tool call. A pure chat / research / Q&A turn must NOT push the board's
        // next item: otherwise a stale objective hijacks every unrelated turn and the user feels the
        // Captain "re-ran the original loop and lost my thread" (2026-07-29 loop-restart bug). The board
        // is still visible via /goals and the status panel — this only stops the actionable "type N" push.
        let workedBoard = trajectory.contains { ($0.success && Copilot.mutatingTools.contains($0.tool)) || $0.tool == "tasks" }
        let nextLine: String
        if let next, workedBoard {
            nextLine = "[\(next.id)] \(next.title) — type \(next.id) to run it"
        } else if next != nil {
            nextLine = "this turn didn't touch the board — ask for the next step, or `/goals` to see it"
        } else {
            nextLine = "set a goal with /goals add <step> or ask the agent for the next action"
        }

        return """
        Summary
        What happened: \(modelCalls) model call(s), \(toolCalls) tool call(s), \(usage).
        What changed: check the task board and `git diff`; Kist does not infer correctness from edits.
        Tool errors: \(toolErrorSummary(trajectory)).
        What to do next: \(nextLine)
        """
    }

    /// Summarize tool-call errors WITHOUT implying the run failed. A single tool error
    /// (e.g. a `run_command` that returned non-zero) is often recovered by a later step,
    /// so the old "What failed: run_command" line read as a run verdict when it wasn't —
    /// contradicting Kist's "does not infer correctness" stance. This reports the raw
    /// counts per tool and stays silent on whether the run as a whole succeeded.
    static func toolErrorSummary(_ trajectory: [ActionRecord]) -> String {
        let failed = trajectory.filter { !$0.success }
        guard !failed.isEmpty else { return "none recorded" }
        // Stable count-desc, then name-asc ordering so the line is deterministic.
        let counts = Dictionary(grouping: failed, by: { $0.tool }).mapValues { $0.count }
        let parts = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) ×\($0.value)" }
        return parts.joined(separator: ", ") + " (tool-call errors, not a run verdict — recovery not inferred)"
    }
}
