import Foundation
import CoreXLSX

/// Agent tool: read a spreadsheet (.xlsx/.xlsm or .csv) into text the model can reason about — sheet
/// list, shape, headers, and a row preview — so the agent can converse about the DATA, not just code.
/// Confined to the project root. Big sheets are previewed (capped rows) with the true totals reported.
public struct ReadSpreadsheetTool: AgentTool {
    public let name = "read_spreadsheet"
    public let description = """
    Read a spreadsheet (.xlsx, .xlsm, or .csv): lists sheets, row/column counts, header row, and a \
    preview of the data so you can answer questions about the contents, compare columns, and build on \
    the figures. Use when the user drops or references a spreadsheet/CSV.
    """
    public let parameters = [
        ToolParameter(name: "path", type: "string", description: "Project-relative path to the spreadsheet or CSV."),
        ToolParameter(name: "sheet", type: "string", description: "Optional sheet name/number for xlsx (default: all sheets).", required: false),
        ToolParameter(name: "max_rows", type: "number", description: "Max rows to preview per sheet (default 50).", required: false),
    ]

    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let path = try requireString("path", from: arguments)
        let resolved = try context.resolvedPath(path, mustExist: true)
        let maxRows = optionalInt("max_rows", from: arguments) ?? 50
        let ext = (resolved as NSString).pathExtension.lowercased()
        let name = (resolved as NSString).lastPathComponent

        switch ext {
        case "csv", "tsv":
            return readCSV(resolved, name: name, maxRows: maxRows, delimiter: ext == "tsv" ? "\t" : ",")
        case "xlsx", "xlsm", "xlsb":
            return try readXLSX(resolved, name: name, maxRows: maxRows, wantSheet: arguments["sheet"] as? String)
        default:
            return .failure("read_spreadsheet handles .xlsx/.xlsm/.csv/.tsv; '\(path)' isn't one")
        }
    }

    // MARK: CSV

    private func readCSV(_ path: String, name: String, maxRows: Int, delimiter: Character) -> ToolResult {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .failure("couldn't read \(name) as UTF-8 text")
        }
        let rows = Self.parseCSV(text, delimiter: delimiter)
        guard !rows.isEmpty else { return ToolResult(success: true, output: "\(name): empty") }
        let cols = rows.map(\.count).max() ?? 0
        var out = "\(name) · \(rows.count) rows × \(cols) cols (CSV)\n"
        out += Self.renderTable(rows, maxRows: maxRows)
        return ToolResult(success: true, output: out, metadata: ["rows": "\(rows.count)", "cols": "\(cols)"])
    }

    /// Minimal RFC-4180-ish parser: quoted fields, embedded delimiters/newlines, "" escapes.
    static func parseCSV(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []; var row: [String] = []; var field = ""
        var inQuotes = false; var it = text.makeIterator(); var pending: Character? = nil
        func next() -> Character? { if let p = pending { pending = nil; return p }; return it.next() }
        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = next() { if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n } }
                    else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case delimiter: row.append(field); field = ""
                case "\n": row.append(field); field = ""; rows.append(row); row = []
                case "\r": break
                default: field.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    // MARK: XLSX

    private func readXLSX(_ path: String, name: String, maxRows: Int, wantSheet: String?) throws -> ToolResult {
        guard let file = XLSXFile(filepath: path) else { return .failure("couldn't open \(name) as an xlsx workbook") }
        let shared = try? file.parseSharedStrings()
        var pathsAndNames: [(name: String?, path: String)] = []
        if let workbooks = try? file.parseWorkbooks() {
            for wb in workbooks {
                if let pn = try? file.parseWorksheetPathsAndNames(workbook: wb) { pathsAndNames.append(contentsOf: pn) }
            }
        }
        if pathsAndNames.isEmpty {
            pathsAndNames = (try file.parseWorksheetPaths()).map { (nil, $0) }
        }
        guard !pathsAndNames.isEmpty else { return .failure("\(name): no worksheets") }

        var out = "\(name) · \(pathsAndNames.count) sheet(s) (xlsx)\n"
        for (idx, entry) in pathsAndNames.enumerated() {
            let sheetName = entry.name ?? "Sheet\(idx + 1)"
            if let wantSheet, wantSheet != sheetName, wantSheet != "\(idx + 1)" { continue }
            let ws = try file.parseWorksheet(at: entry.path)
            let rows: [[String]] = (ws.data?.rows ?? []).map { row in
                row.cells.map { cell -> String in
                    if let shared, let s = cell.stringValue(shared) { return s }
                    return cell.value ?? ""
                }
            }
            let cols = rows.map(\.count).max() ?? 0
            out += "\n── \(sheetName) · \(rows.count) rows × \(cols) cols ──\n"
            out += rows.isEmpty ? "(empty)\n" : Self.renderTable(rows, maxRows: maxRows)
        }
        return ToolResult(success: true, output: out, metadata: ["sheets": "\(pathsAndNames.count)"])
    }

    // MARK: rendering

    static func renderTable(_ rows: [[String]], maxRows: Int) -> String {
        let shown = rows.prefix(maxRows)
        var s = shown.map { $0.map { cell in cell.count > 40 ? String(cell.prefix(40)) + "…" : cell }.joined(separator: " | ") }
            .joined(separator: "\n")
        if rows.count > maxRows { s += "\n… +\(rows.count - maxRows) more rows" }
        return s + "\n"
    }
}
