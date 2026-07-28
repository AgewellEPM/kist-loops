import Foundation

/// Agent tool: run a read-only SQL query over a data file (CSV/Parquet/JSON) using DuckDB — million-row
/// scale from the terminal. The file is exposed as the view `data`; the model writes SQL against it.
/// Uses the local `duckdb` binary through the shell policy (needs shell enabled). Read-only: external
/// file access is disabled so a query can't write or exfiltrate.
public struct QueryDataTool: AgentTool {
    public let name = "query_data"
    public let description = """
    Run a read-only SQL query over a CSV/Parquet/JSON file with DuckDB (handles millions of rows). The \
    file is available as the view `data` (e.g. SELECT region, sum(sales) FROM data GROUP BY region). \
    Requires the duckdb binary and shell access.
    """
    public let parameters = [
        ToolParameter(name: "path", type: "string", description: "Project-relative path to the data file (.csv/.parquet/.json). Absolute paths under a session-armed read-only root (--allow-read, e.g. /Volumes) also work."),
        ToolParameter(name: "sql", type: "string", description: "SQL querying the view `data`. SELECT-only."),
    ]

    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let path = try requireString("path", from: arguments)
        let sql = try requireString("sql", from: arguments)
        guard Self.isReadOnly(sql) else {
            return .failure("query_data is read-only — only a single SELECT/WITH/SHOW/DESCRIBE statement is allowed")
        }
        // Read-only by construction (SELECT-only gate + duckdb -readonly + external access off),
        // so absolute paths under an armed external read root (--allow-read) also resolve.
        let input = try context.resolvedPathForReading(path, mustExist: true)

        guard let duckdb = RunCommandTool.resolveExecutable("duckdb", env: ProcessInfo.processInfo.environment) else {
            return .failure("duckdb not found on PATH — install it (brew install duckdb) to query data at scale")
        }
        // Lock down: read-only external access disabled, then expose the file as `data` and run the query.
        let reader = Self.readerFor(input)
        let script = """
        SET enable_external_access=false;
        CREATE OR REPLACE VIEW data AS SELECT * FROM \(reader);
        \(sql);
        """
        let args = ["-readonly", "-markdown", ":memory:", "-c", script]
        if let reason = await context.shell.binaryRefusalReason(resolvedPath: duckdb, args: args) {
            return .failure("duckdb blocked by shell policy: \(reason) (try --allow-shell)")
        }
        // NOTE: enable_external_access=false still allows reading the single file we name; it blocks the
        // query from reaching OTHER files / the network.
        let run = await RunCommandTool.spawnAndCollect(launchPath: duckdb, launchArgs: args, cwd: context.projectRoot, timeout: 120)
        return run
    }

    /// The DuckDB reader function for a file by extension. `read_csv_auto` etc. with a quoted literal —
    /// the path is already confined; we single-quote-escape to keep it a literal.
    static func readerFor(_ path: String) -> String {
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "''") + "'"
        switch (path as NSString).pathExtension.lowercased() {
        case "parquet": return "read_parquet(\(quoted))"
        case "json", "ndjson": return "read_json_auto(\(quoted))"
        default: return "read_csv_auto(\(quoted))"
        }
    }

    /// Allow only a single read-only statement: must start with SELECT/WITH/SHOW/DESCRIBE/PRAGMA and
    /// contain no obviously mutating/IO keyword. Defense-in-depth alongside DuckDB -readonly.
    static func isReadOnly(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        let lower = trimmed.lowercased()
        guard ["select", "with", "show", "describe", "pragma", "summarize"].contains(where: { lower.hasPrefix($0) }) else { return false }
        // No statement separators (single statement) and no write/IO verbs.
        if trimmed.contains(";") { return false }
        let banned = ["insert", "update", "delete", "drop", "create", "alter", "copy", "attach",
                      "install", "load", "export", " into ", "pragma enable", "set "]
        return !banned.contains { lower.contains($0) }
    }
}
