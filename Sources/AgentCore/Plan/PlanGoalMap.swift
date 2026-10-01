import Foundation

/// A bounded, read-only view of the shared board. Board labels and attached references are
/// coordination data; this view neither evaluates receipts nor certifies completion.
public enum PlanGoalMap {
    public static let maxPlanBytes = 4 * 1024 * 1024

    public static func load(projectRoot: String) throws -> Plan {
        let root = try ConfinedRoot(root: projectRoot, readOnly: true)
        let data: Data
        do { data = try root.readStableData(".kist/plan.json", maxBytes: maxPlanBytes) }
        catch ToolError.notFound { return Plan() }
        let plan = try JSONDecoder().decode(Plan.self, from: data)
        guard plan.tasks.count <= 10_000,
              plan.tasks.allSatisfy({ $0.id > 0 }),
              Set(plan.tasks.map(\.id)).count == plan.tasks.count else {
            throw ToolError.execution("board has invalid/duplicate task IDs or more than 10,000 tasks")
        }
        return plan
    }

    public static func render(_ plan: Plan, projectRoot: String,
                              sessionStartedAt: Date? = nil, taskID: Int? = nil) -> String {
        let ordered = plan.tasks.sorted { $0.id < $1.id }
        let next = plan.nextForExecution(since: sessionStartedAt)
        var lines = ["Goal map · \(short(plan.title))",
                     "Workspace: \(short(projectRoot, limit: 300))",
                     "Local board inspection · no model call",
                     "Board: \(plan.done)/\(ordered.count) marked done · \(ordered.filter { $0.status == .blocked }.count) blocked"]
        if ordered.isEmpty {
            lines.append("No tasks yet. Add one with /goals add <step> | acceptance: <result> | verify: <check>.")
            return lines.joined(separator: "\n")
        }
        let noNext = plan.done == ordered.count
            ? "none — all tasks marked done; verification still requires evidence"
            : "none — blocked or stale work needs attention"
        lines.append("Next execution: " + (next.map(label) ?? noNext))

        let focus: PlanTask?
        if let taskID {
            focus = ordered.first { $0.id == taskID }
            if focus == nil { lines.append("No task with id \(taskID).") }
        } else { focus = next }
        if let focus {
            lines.append("Task \(label(focus)) · \(focus.kind.label) · \(focus.status.rawValue)")
            lines.append("  Acceptance: \(short(focus.acceptance, fallback: "missing"))")
            lines.append("  Verify: \(short(focus.verificationText, fallback: "missing"))")
            if focus.status == .blocked {
                lines.append("  Blocker: \(short(focus.detail, fallback: "reason missing"))")
            }
            lines.append("  Evidence references: \(focus.evidence.count) attached; not validated here")
            for reference in focus.evidence.prefix(3) { lines.append("    \(short(reference))") }
        }

        func group(_ title: String, _ tasks: [PlanTask], detail: (PlanTask) -> String = { _ in "" }) {
            guard !tasks.isEmpty else { return }
            lines.append("\(title) (\(tasks.count)):")
            for task in tasks.prefix(4) { lines.append("  \(label(task))\(detail(task))") }
            if tasks.count > 4 { lines.append("  … \(tasks.count - 4) more; /goalmap <id> for a task") }
        }
        group("Blocked", ordered.filter { $0.status == .blocked }) {
            " — " + short($0.detail, fallback: "reason missing")
        }
        group("Earlier session — select an ID to resume", ordered.filter {
            guard let sessionStartedAt else { return false }
            return $0.status == .inProgress && !$0.isActive(since: sessionStartedAt)
        })
        group("Queued", ordered.filter { $0.status == .todo })
        group("Missing acceptance or verification", ordered.filter {
            $0.acceptance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.verificationText.isEmpty
        })
        group("Marked done without evidence references", ordered.filter {
            $0.status == .done && $0.evidence.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        })
        lines.append("Board status is not verified completion. /logs shows the last turn's evidence; /usage shows cost.")
        return lines.joined(separator: "\n")
    }

    private static func label(_ task: PlanTask) -> String { "[\(task.id)] \(short(task.boardTitle))" }

    private static func short(_ value: String, limit: Int = 160, fallback: String = "") -> String {
        let cleaned = String(String.UnicodeScalarView(value.prefix(limit * 2).unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        })).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let text = SecretScanner.redactSecrets(in: cleaned)
        if text.isEmpty { return fallback }
        return String(text.prefix(limit)) + (value.count > limit ? "…" : "")
    }
}
