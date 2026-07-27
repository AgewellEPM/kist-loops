import Foundation

/// Agent tool: run a deterministic security audit (secrets, SAST-lite, dependency hygiene) over the
/// project (or a subpath) and return a grounded report. Every finding has a file:line + evidence, so
/// the agent can triage/explain but cannot invent vulnerabilities — trustworthy by construction.
public struct SecurityAuditTool: AgentTool {
    public let name = "security_audit"
    public let description = """
    Audit the project for security issues: committed secrets/credentials, dangerous code patterns \
    (injection, disabled TLS, weak crypto), and dependency-hygiene risks (unpinned versions). Returns \
    findings with file:line + evidence and OWASP mappings. Deterministic — no invented findings.
    """
    public let parameters = [
        ToolParameter(name: "path", type: "string", description: "Project-relative subpath to audit (default: whole project).", required: false),
        ToolParameter(name: "min_severity", type: "string", description: "info|low|medium|high|critical — only report at/above this (default low).", required: false),
        ToolParameter(name: "format", type: "string", description: "text (default) or json.", required: false),
    ]

    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let sub = (arguments["path"] as? String) ?? "."
        let root = try context.resolvedPath(sub, mustExist: true)
        let minSeverity = SecurityFinding.Severity(rawValue: (arguments["min_severity"] as? String ?? "low").lowercased()) ?? .low

        var report = SecurityAuditor.audit(root: root)
        if minSeverity != .info {
            report = AuditReport(findings: report.findings.filter { $0.severity >= minSeverity },
                                 filesScanned: report.filesScanned, root: report.root)
        }

        if (arguments["format"] as? String)?.lowercased() == "json" {
            let data = try JSONEncoder().encode(report)
            return ToolResult(success: true, output: String(decoding: data, as: UTF8.self),
                              metadata: ["findings": "\(report.findings.count)"])
        }
        let critical = report.counts[.critical] ?? 0
        let high = report.counts[.high] ?? 0
        return ToolResult(success: true, output: report.render(),
                          metadata: ["findings": "\(report.findings.count)", "critical": "\(critical)", "high": "\(high)"])
    }
}
