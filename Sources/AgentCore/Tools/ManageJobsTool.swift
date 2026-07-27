import Foundation

/// Poll and control BACKGROUND jobs started by `run_command(background:true)` — the equivalent of Claude
/// Code's `BashOutput` (read new output) + `KillShell` (stop) + a `list`. Read-only against the store; it
/// never spawns, so it needs no approval.
public struct ManageJobsTool: AgentTool {
    public let name = "job"
    public let description = "Inspect background jobs started by run_command(background:true). action=output reads NEW output since your last read; action=kill stops a job; action=list shows all jobs."
    public let parameters = [
        ToolParameter(name: "action", type: "string", description: "output | kill | list", required: true),
        ToolParameter(name: "id", type: "string", description: "Job id (required for output/kill), e.g. job_1", required: false),
    ]
    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let action = (try requireString("action", from: arguments)).lowercased()
        let store = BackgroundJobStore.shared
        // Scope every operation to THIS workspace — an agent can only see/kill jobs it launched, not
        // another fleet agent's (jobs are owned by the projectRoot that started them).
        let owner = context.projectRoot

        switch action {
        case "list":
            let jobs = store.list(owner: owner)
            return ToolResult(success: true, output: jobs.isEmpty ? "(no background jobs)" : jobs.joined(separator: "\n"))

        case "output", "read", "logs":
            let id = try requireString("id", from: arguments)
            guard let job = store.job(id, owner: owner) else { return .failure("no such job: \(id) (try job action=list)") }
            let newOutput = job.readNew()
            let status = job.isRunning ? "running" : "exited (code \(job.exitCode ?? -1))"
            let body = newOutput.isEmpty ? "(no new output) · \(status)" : newOutput + "\n— \(status)"
            return ToolResult(success: true, output: body, metadata: ["job_id": id, "running": String(job.isRunning)])

        case "kill", "stop", "terminate":
            let id = try requireString("id", from: arguments)
            guard store.kill(id, owner: owner) else { return .failure("no such job: \(id)") }
            return ToolResult(success: true, output: "killed \(id)", metadata: ["job_id": id])

        default:
            return .failure("unknown action '\(action)' — use output | kill | list")
        }
    }
}
