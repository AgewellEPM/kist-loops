import Foundation

/// Agent tool: fetch a business-workflow playbook to follow. List the catalog, or get the structured
/// steps for a named workflow (data-report, security-review, media-brief, compare-data, research)
/// applied to the user's target. The agent then executes the playbook with its existing tools.
public struct WorkflowTool: AgentTool {
    public let name = "business_workflow"
    public let description = """
    Get a step-by-step playbook for a business task: data-report, compare-data, security-review, \
    media-brief, or research. Call with no `name` to list them; with `name` + `input` to get the \
    steps to follow for that target (a file, path, or topic).
    """
    public let parameters = [
        ToolParameter(name: "name", type: "string", description: "Workflow name (omit to list all).", required: false),
        ToolParameter(name: "input", type: "string", description: "The target: a file/path/topic the workflow runs on.", required: false),
    ]
    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        guard let name = (arguments["name"] as? String), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ToolResult(success: true, output: WorkflowLibrary.catalog())
        }
        guard let template = WorkflowLibrary.find(name) else {
            return .failure("unknown workflow '\(name)'. \(WorkflowLibrary.catalog())")
        }
        let input = (arguments["input"] as? String) ?? ""
        let out = "Workflow: \(template.name) — \(template.summary)\nTools: \(template.toolsUsed.joined(separator: ", "))\n\n"
            + template.expand(input: input)
        return ToolResult(success: true, output: out, metadata: ["workflow": template.name])
    }
}
