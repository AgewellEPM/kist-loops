import Foundation

/// Agent tool: emit the runtime's governance posture mapped to the OWASP Top-10 for Agentic
/// Applications (2026), with evidence and honest gaps. For "is this agent safe to deploy / what
/// controls do we satisfy" questions from a buyer or auditor.
public struct GovernanceReportTool: AgentTool {
    public let name = "governance_report"
    public let description = """
    Report this agent runtime's security/governance posture against the OWASP Top-10 for Agentic \
    Applications — which controls are satisfied/partial/gap, with evidence and residual risks.
    """
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "format", type: "string", description: "text (default) or json.", required: false)
    ]
    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        if (arguments["format"] as? String)?.lowercased() == "json" {
            let data = try JSONEncoder().encode(ComplianceMapper.controls)
            return ToolResult(success: true, output: String(decoding: data, as: UTF8.self))
        }
        return ToolResult(success: true, output: ComplianceMapper.report())
    }
}
