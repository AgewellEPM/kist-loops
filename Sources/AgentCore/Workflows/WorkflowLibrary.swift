import Foundation

/// Named business workflows that compose the runtime's tools into an outcome — the verticalized
/// knowledge-work flows the market actually buys (data analysis/reporting led 38% of enterprise
/// agent use). Each template is a structured PLAYBOOK the agent follows with its existing tools
/// (read_spreadsheet, query_data, analyze_media, security_audit, web_search, write_file).
public struct WorkflowTemplate: Sendable, Equatable {
    public let name: String
    public let summary: String
    public let toolsUsed: [String]
    /// The playbook, with a `{input}` slot for the user's target (a file, topic, or path).
    public let playbook: String

    public func expand(input: String) -> String {
        let target = input.trimmingCharacters(in: .whitespaces)
        return playbook.replacingOccurrences(of: "{input}", with: target.isEmpty ? "the target the user named" : target)
    }
}

public enum WorkflowLibrary {
    public static let templates: [WorkflowTemplate] = [
        .init(name: "data-report", summary: "Turn a spreadsheet/CSV into an analyzed written report",
              toolsUsed: ["read_spreadsheet", "query_data", "write_file"],
              playbook: """
              Produce a data report on {input}.
              1. read_spreadsheet {input} to learn its shape, sheets, and columns.
              2. Form the 3–5 questions that matter for this data; answer each with query_data (SQL).
              3. Note trends, outliers, and anything that needs a human decision — cite the numbers.
              4. write_file a clear Markdown report: summary, key findings (with figures), recommendations.
              """),
        .init(name: "compare-data", summary: "Cross-compare two datasets/graphs and explain the difference",
              toolsUsed: ["read_spreadsheet", "query_data", "analyze_media"],
              playbook: """
              Compare the two sources in {input} and explain the differences.
              1. Load each (read_spreadsheet for sheets/CSV; if they're chart IMAGES, describe each first).
              2. Align them on common keys/metrics; compute the deltas with query_data where possible.
              3. State what changed, by how much, and the likely 'so what' — back every claim with numbers.
              """),
        .init(name: "security-review", summary: "Audit a codebase and deliver a prioritized, verified report",
              toolsUsed: ["security_audit", "read_file", "write_file"],
              playbook: """
              Security-review {input}.
              1. Run security_audit on {input}. Treat every finding as grounded (it has file:line + evidence).
              2. For the top findings, read_file the surrounding code to confirm exploitability and impact.
              3. write_file a report ordered by severity: what, where (file:line), why it matters, the fix,
                 and the OWASP mapping. Do NOT invent findings beyond what the scanner grounded.
              """),
        .init(name: "media-brief", summary: "Summarize a video/audio into a navigable brief with timestamps",
              toolsUsed: ["analyze_media", "extract_clip", "write_file"],
              playbook: """
              Brief me on {input}.
              1. analyze_media {input} for summary, scene timeline, transcript, and key moments.
              2. Call out the 3–5 moments worth watching with their MM:SS; if useful, extract_clip them.
              3. write_file a one-page brief: what it's about, the timeline, the must-watch moments, quotes.
              """),
        .init(name: "research", summary: "Research a topic across the web and synthesize a cited memo",
              toolsUsed: ["web_search", "fetch_url", "write_file"],
              playbook: """
              Research {input} and write a memo.
              1. web_search several angles of {input}; pick the most credible, recent sources.
              2. fetch_url the best ones; extract the concrete facts/numbers (not vibes).
              3. write_file a memo: the answer up top, supporting findings, open questions, and sources.
              """),
    ]

    public static func find(_ name: String) -> WorkflowTemplate? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return templates.first { $0.name == n }
    }

    public static func catalog() -> String {
        "Available workflows:\n" + templates.map { "  \($0.name) — \($0.summary)" }.joined(separator: "\n")
    }
}
