import Foundation

/// Deterministic bridge from "council of minds" prose into Kist's shared task board.
/// The model is asked for a Kanban table, but the runtime still owns the parse and
/// fallback behavior: a messy council result becomes a small safe board instead of
/// silently leaving the project manager empty.
public enum CouncilBoardCompiler {
    public static func compile(goal: String, finalPlan: String, artifactPath: String? = nil) -> Plan {
        var tasks = kanbanTasks(from: finalPlan, artifactPath: artifactPath)
        if tasks.isEmpty {
            tasks = fallbackTasks(from: finalPlan, artifactPath: artifactPath)
            let title = "AI Council: " + concise(goal, max: 72)
            return Plan(title: title, tasks: tasks, nextId: (tasks.map(\.id).max() ?? 0) + 1)
        }
        let hasTest = tasks.contains { $0.title.lowercased().hasPrefix("test:") }
        if !hasTest {
            tasks.append(contentsOf: testTasks(from: finalPlan, nextId: tasks.count + 1, artifactPath: artifactPath))
        }
        let title = "AI Council: " + concise(goal, max: 72)
        return Plan(title: title, tasks: tasks, nextId: (tasks.map(\.id).max() ?? 0) + 1)
    }

    public static func kanbanTasks(from finalPlan: String, artifactPath: String? = nil) -> [PlanTask] {
        let lines = finalPlan.components(separatedBy: .newlines)
        guard let headerIndex = lines.firstIndex(where: { isKanbanHeader($0) }) else { return [] }

        var tasks: [PlanTask] = []
        for line in lines.dropFirst(headerIndex + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if !trimmed.hasPrefix("|") { break }
            let cells = tableCells(trimmed)
            guard cells.count >= 4, !isSeparatorRow(cells) else { continue }
            let statusText = cells[0]
            let taskText = cells[1]
            let owner = cells[2].isEmpty ? nil : cells[2]
            let acceptance = cells[3]
            guard !taskText.isEmpty, !taskText.lowercased().contains("task") else { continue }
            let normalized = normalizedTitle(taskText, status: statusText)

            tasks.append(PlanTask(id: tasks.count + 1,
                                  title: normalized,
                                  detail: detail(status: statusText, acceptance: acceptance, artifactPath: artifactPath),
                                  status: taskStatus(statusText),
                                  kind: kind(for: normalized, status: statusText),
                                  acceptance: acceptance,
                                  verification: verification(for: normalized, acceptance: acceptance, status: statusText),
                                  evidence: artifactPath.map { [$0] } ?? [],
                                  owner: owner,
                                  link: artifactPath))
        }
        return tasks
    }

    static func testTasks(from finalPlan: String, nextId: Int, artifactPath: String? = nil) -> [PlanTask] {
        let lines = section(named: "Test plan", in: finalPlan)
        let tests = lines.compactMap { bulletText($0) }.filter { !$0.isEmpty }
        guard !tests.isEmpty else {
            return [PlanTask(id: nextId,
                             title: "TEST: Run focused regression for the council-selected slice",
                             detail: detail(status: "Test", acceptance: "Focused tests pass before any merge", artifactPath: artifactPath),
                             kind: .test,
                             acceptance: "Focused tests pass before any merge",
                             verification: "Run the narrowest relevant regression command and attach output",
                             evidence: artifactPath.map { [$0] } ?? [],
                             owner: "critic",
                             link: artifactPath)]
        }
        return tests.enumerated().map { idx, text in
            PlanTask(id: nextId + idx,
                     title: text.lowercased().hasPrefix("test:") ? text : "TEST: \(text)",
                     detail: detail(status: "Test", acceptance: text, artifactPath: artifactPath),
                     kind: .test,
                     acceptance: text,
                     verification: text,
                     evidence: artifactPath.map { [$0] } ?? [],
                     owner: "critic",
                     link: artifactPath)
        }
    }

    private static func fallbackTasks(from finalPlan: String, artifactPath: String?) -> [PlanTask] {
        [
            PlanTask(id: 1,
                     title: "ACTION: Review council result and choose the first implementation slice",
                     detail: detail(status: "Ready", acceptance: "A narrow first task is selected", artifactPath: artifactPath),
                     kind: .review,
                     acceptance: "A narrow first task is selected",
                     verification: "Human or critic confirms the first slice is scoped",
                     evidence: artifactPath.map { [$0] } ?? [],
                     owner: "planner", link: artifactPath),
            PlanTask(id: 2,
                     title: "ACTION: Convert council findings into scoped build tasks",
                     detail: detail(status: "Backlog", acceptance: "Tasks have owners and acceptance criteria", artifactPath: artifactPath),
                     kind: .plan,
                     acceptance: "Tasks have owners and acceptance criteria",
                     verification: "Shared task board shows owner, acceptance, and verification for each item",
                     evidence: artifactPath.map { [$0] } ?? [],
                     owner: "builder", link: artifactPath),
            PlanTask(id: 3,
                     title: "TEST: Run focused regression for the chosen slice",
                     detail: detail(status: "Test", acceptance: "Focused tests pass", artifactPath: artifactPath),
                     kind: .test,
                     acceptance: "Focused tests pass",
                     verification: "Run focused tests and attach output",
                     evidence: artifactPath.map { [$0] } ?? [],
                     owner: "critic", link: artifactPath),
        ]
    }

    private static func isKanbanHeader(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard cells.count >= 4 else { return false }
        return cells[0].lowercased() == "status"
            && cells[1].lowercased() == "task"
            && cells[2].lowercased() == "owner"
            && cells[3].lowercased() == "acceptance"
    }

    private static func tableCells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func isSeparatorRow(_ cells: [String]) -> Bool {
        cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0 == "-" || $0 == ":" } }
    }

    private static func taskStatus(_ raw: String) -> PlanTask.Status {
        let s = raw.lowercased()
        if s.contains("done") || s.contains("complete") { return .done }
        if s.contains("progress") || s.contains("doing") || s.contains("active") { return .inProgress }
        if s.contains("block") || s.contains("hold") || s.contains("wait") { return .blocked }
        return .todo
    }

    private static func normalizedTitle(_ raw: String, status: String) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = clean.lowercased()
        if lower.hasPrefix("action:") || lower.hasPrefix("test:") || lower.hasPrefix("backlog:") {
            return clean
        }
        let statusLower = status.lowercased()
        if statusLower.contains("test") { return "TEST: \(clean)" }
        if statusLower.contains("backlog") { return "BACKLOG: \(clean)" }
        return "ACTION: \(clean)"
    }

    private static func kind(for title: String, status: String) -> PlanTask.Kind {
        let lowerTitle = title.lowercased()
        let lowerStatus = status.lowercased()
        if lowerTitle.hasPrefix("test:") || lowerStatus.contains("test") { return .test }
        if lowerTitle.hasPrefix("review:") || lowerStatus.contains("review") { return .review }
        if lowerTitle.hasPrefix("research:") || lowerStatus.contains("research") { return .research }
        if lowerTitle.hasPrefix("decision:") || lowerStatus.contains("decision") { return .decision }
        if lowerTitle.hasPrefix("handoff:") || lowerStatus.contains("handoff") { return .handoff }
        if lowerTitle.hasPrefix("plan:") || lowerTitle.hasPrefix("backlog:") || lowerStatus.contains("backlog") { return .plan }
        return .action
    }

    private static func verification(for title: String, acceptance: String, status: String) -> String {
        if title.lowercased().hasPrefix("test:") { return acceptance.isEmpty ? title : acceptance }
        if status.lowercased().contains("review") { return "Reviewer confirms acceptance and attaches findings" }
        if acceptance.lowercased().contains("swift test") { return acceptance }
        return acceptance.isEmpty ? "Attach evidence before marking done" : acceptance
    }

    private static func detail(status: String, acceptance: String, artifactPath: String?) -> String {
        var parts = ["Council lane: \(status)"]
        if !acceptance.isEmpty { parts.append("Acceptance: \(acceptance)") }
        if let artifactPath, !artifactPath.isEmpty { parts.append("Council artifact: \(artifactPath)") }
        return parts.joined(separator: "\n")
    }

    private static func section(named name: String, in text: String) -> [String] {
        let target = name.lowercased()
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { line in
            let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "#:* "))
            return lower == target
        }) else { return [] }

        var out: [String] = []
        for line in lines.dropFirst(start + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") { break }
            if trimmed.lowercased().hasPrefix("next builder brief") { break }
            if trimmed.lowercased().hasPrefix("decision:") { break }
            if trimmed.lowercased().hasPrefix("kanban board:") { break }
            out.append(line)
        }
        return out
    }

    private static func bulletText(_ line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.first == "-" || text.first == "*" || text.first == "•" {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let first = text.first, first.isNumber, let dot = text.firstIndex(of: ".") {
            text = String(text[text.index(after: dot)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    private static func concise(_ text: String, max: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > max ? String(trimmed.prefix(max - 1)) + "…" : trimmed
    }
}
