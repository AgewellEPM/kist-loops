import Foundation
import CoreFoundation

/// Agent tool: the native Plan/Action/Test/Review board. The agent uses this to break a big job into
/// a persisted runbook with acceptance criteria, verification, evidence, and owners — visible to the
/// human too (same `<root>/.kist/plan.json` the `/tasks` REPL command shows). Keeps long multi-step
/// work organized + reviewable instead of living only in the conversation.
public struct ManageTasksTool: AgentTool {
    public let name = "tasks"
    public let description = """
    Track a shared Plan/Action/Test/Review board. This is not a generic checklist: every serious \
    task should carry kind, acceptance, verification, evidence, and owner. Use PLAN/RESEARCH items \
    to digest and decide, ACTION items to build, TEST items to prove behavior, REVIEW items to audit, \
    and HANDOFF items when another role/model must take over. Before marking work done, add evidence \
    such as a test command, file path, review artifact, URL, screenshot, or log. Actions: list | map | add | \
    start | done | block | update | evidence | validate | clear. Example: {"action":"add","kind":"action",\
    "title":"Build model router","acceptance":"Grok 404 falls back automatically",\
    "verification":"swift test --filter ProviderHealthTests","owner":"coder"}.
    """
    public let parameters = [
        ToolParameter(name: "action", type: "string", description: "list | map | add | start | done | block | update | evidence | validate | clear"),
        ToolParameter(name: "title", type: "string", description: "Task title (for add).", required: false),
        ToolParameter(name: "detail", type: "string", description: "Detail / reason (add, block, update).", required: false),
        ToolParameter(name: "id", type: "number", description: "Positive whole task id (map/start/done/block/update/evidence). Omit for start-next or map overview.", required: false),
        ToolParameter(name: "owner", type: "string", description: "Who owns it, e.g. planner / coder / critic / researcher / luke.", required: false),
        ToolParameter(name: "kind", type: "string", description: "plan | action | test | review | research | decision | handoff.", required: false),
        ToolParameter(name: "acceptance", type: "string", description: "What must be true before this task can be done.", required: false),
        ToolParameter(name: "verification", type: "string", description: "How to prove acceptance: test command, review step, audit, screenshot, URL, etc.", required: false),
        ToolParameter(name: "evidence", type: "array", description: "Evidence strings to attach or replace (paths, URLs, logs, commands, screenshots).", required: false),
    ]

    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        // Confine the plan path: if `.kist` is a symlink escaping the project root, resolvedPath throws
        // and we refuse — the agent can't write outside the project via a planted symlink.
        let planPath: String
        do { planPath = try context.resolvedPath(".kist/plan.json", mustExist: false) }
        catch { return .failure("refused: .kist/plan.json escapes the project root (\(error))") }
        let store = PlanStore(path: planPath)
        let action = (arguments["action"] as? String ?? "list")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let id = Self.taskID(arguments["id"])
        if arguments.keys.contains("id") && id == nil {
            return .failure("id must be a positive whole task number — nothing changed")
        }

        switch action {
        case "list":
            return ToolResult(success: true, output: store.load().render())
        case "map":
            do {
                let plan = try PlanGoalMap.load(projectRoot: context.projectRoot)
                return ToolResult(success: true, output: PlanGoalMap.render(
                    plan, projectRoot: context.projectRoot, taskID: id))
            } catch { return .failure("Goal map unavailable: \(error). The board was not changed.") }
        case "validate", "check":
            return ToolResult(success: true, output: PlanContractValidator.render(PlanContractValidator.validate(store.load())))
        case "add":
            guard let title = (arguments["title"] as? String), !title.isEmpty else {
                return .failure("add needs a title")
            }
            let t = store.add(title: title, detail: arguments["detail"] as? String ?? "",
                              owner: arguments["owner"] as? String,
                              link: arguments["link"] as? String,
                              kind: parseKind(arguments["kind"] as? String),
                              acceptance: arguments["acceptance"] as? String ?? "",
                              verification: arguments["verification"] as? String ?? "",
                              evidence: evidenceStrings(from: arguments["evidence"]))
            return ToolResult(success: true, output: "added [\(t.id)] \(t.title)\n\n" + store.load().render())
        case "start":
            let task: PlanTask?
            if let id { task = store.update(id: id, status: .inProgress) }
            else { task = store.startNext() }
            guard let task else { return .failure(id == nil ? "no todo tasks to start" : "no task with id \(id!)") }
            return ToolResult(success: true, output: "started [\(task.id)] \(task.title)\n\n" + store.load().render())
        case "done", "complete":
            guard let id else { return .failure("done needs an id") }
            // Self-advancing loop: mark done AND promote the next actionable todo to active, so the board
            // moves itself to the next request instead of stalling on the completed one.
            let (completed, nowActive, didAdvance) = store.completeAndAdvance(id: id)
            guard let t = completed else { return .failure("no task with id \(id)") }
            let plan = store.load()
            let issues = PlanContractValidator.validate(plan).filter { $0.taskId == t.id }
            let warning = issues.isEmpty ? "" : "\n\n" + PlanContractValidator.render(issues)
            let advance: String
            if didAdvance, let nowActive {
                advance = "\n▶ advanced to [\(nowActive.id)] \(nowActive.boardTitle)"
            } else if let nowActive {
                advance = "\n▶ active remains [\(nowActive.id)] \(nowActive.boardTitle)"
            } else if let next = plan.nextActionable {
                advance = "\n→ next remains [\(next.id)] \(next.boardTitle)"
            } else if plan.buildQueue().contains(where: { $0.status == .blocked }) {
                advance = "\n⚠ no actionable task — blocked work remains"
            } else {
                advance = "\n✓ build queue clear — no actionable task left"
            }
            return ToolResult(success: true, output: "done [\(t.id)] \(t.title)\(advance)\n\n" + plan.render() + warning)
        case "block":
            guard let id, let t = store.update(id: id, status: .blocked, detail: arguments["detail"] as? String) else {
                return .failure("no task with id \(id ?? -1)")
            }
            return ToolResult(success: true, output: "blocked [\(t.id)] \(t.title)\n\n" + store.load().render())
        case "update":
            guard let id else { return .failure("update needs an id") }
            let status = parseStatus(arguments["status"] as? String)
            let evidence = arguments.keys.contains("evidence") ? evidenceStrings(from: arguments["evidence"]) : nil
            guard let t = store.update(id: id, status: status, detail: arguments["detail"] as? String,
                                       kind: parseKind(arguments["kind"] as? String),
                                       acceptance: arguments["acceptance"] as? String,
                                       verification: arguments["verification"] as? String,
                                       evidence: evidence) else {
                return .failure("no task with id \(id)")
            }
            return ToolResult(success: true, output: "updated [\(t.id)] \(t.title)\n\n" + store.load().render())
        case "evidence":
            guard let id else { return .failure("evidence needs an id") }
            let evidence = evidenceStrings(from: arguments["evidence"])
            guard !evidence.isEmpty else { return .failure("evidence needs at least one evidence string") }
            guard let t = store.update(id: id, appendEvidence: evidence) else { return .failure("no task with id \(id)") }
            return ToolResult(success: true, output: "evidence added [\(t.id)] \(t.title)\n\n" + store.load().render())
        case "clear":
            store.clear()
            return ToolResult(success: true, output: "plan cleared")
        default:
            return .failure("unknown action '\(action)' — use list|map|add|start|done|block|update|evidence|validate|clear")
        }
    }

    /// JSON booleans, fractional/overflowing numbers, and malformed explicit IDs must never
    /// be converted to a different task or mistaken for an omitted "start next" request.
    private static func taskID(_ raw: Any?) -> Int? {
        let id: Int?
        if let text = raw as? String { id = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        else if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            id = Int(number.stringValue) ?? Int(exactly: number.doubleValue)
        } else { id = nil }
        return id.flatMap { $0 > 0 ? $0 : nil }
    }

    private func parseKind(_ raw: String?) -> PlanTask.Kind? {
        raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap(PlanTask.Kind.init(rawValue:))
    }

    private func parseStatus(_ raw: String?) -> PlanTask.Status? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "todo", "ready", "open": return .todo
        case "inprogress", "in_progress", "in-progress", "doing", "active": return .inProgress
        case "done", "complete", "completed": return .done
        case "blocked", "block", "waiting": return .blocked
        default: return PlanTask.Status(rawValue: raw)
        }
    }

    private func evidenceStrings(from raw: Any?) -> [String] {
        if let s = raw as? String {
            return s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let arr = raw as? [String] {
            return arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        if let arr = raw as? [Any] {
            return arr.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        return []
    }
}
