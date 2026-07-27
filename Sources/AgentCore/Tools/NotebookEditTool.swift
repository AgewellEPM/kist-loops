import Foundation

/// Edit a Jupyter notebook (.ipynb) cell — the Claude-Code `NotebookEdit` parity tool. A notebook is
/// JSON with a `cells` array; each cell has a `cell_type` and a `source` (array of lines or a string).
/// This replaces, inserts, or deletes a cell by index and writes the notebook back, preserving the rest
/// of the document. Confined to the project root; no shell.
public struct NotebookEditTool: AgentTool {
    public let name = "notebook_edit"
    public let description = "Edit a Jupyter .ipynb cell by index. edit_mode=replace (default) overwrites cell N; insert adds a new cell after N (or at 0 with cell_number=0); delete removes cell N."
    public let parameters = [
        ToolParameter(name: "path", type: "string", description: "Path to the .ipynb file, relative to the project root", required: true),
        ToolParameter(name: "cell_number", type: "integer", description: "0-based cell index to replace/delete, or the anchor for insert", required: true),
        ToolParameter(name: "new_source", type: "string", description: "New cell source (for replace/insert)", required: false),
        ToolParameter(name: "cell_type", type: "string", description: "code | markdown (for insert; defaults to code)", required: false),
        ToolParameter(name: "edit_mode", type: "string", description: "replace | insert | delete (default replace)", required: false),
    ]
    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let path = try requireString("path", from: arguments)
        guard path.hasSuffix(".ipynb") else { return .failure("notebook_edit only edits .ipynb files") }
        let index = optionalInt("cell_number", from: arguments) ?? -1
        guard index >= 0 else { return .failure("cell_number must be a non-negative integer") }
        let mode = ((arguments["edit_mode"] as? String) ?? "replace").lowercased()
        let confined = try context.confinedRoot()

        let raw = try confined.readString(path)
        guard let data = raw.data(using: .utf8),
              var nb = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var cells = nb["cells"] as? [[String: Any]] else {
            return .failure("could not parse \(path) as a Jupyter notebook (no cells array)")
        }

        switch mode {
        case "delete":
            guard index < cells.count else { return .failure("cell_number \(index) out of range (\(cells.count) cells)") }
            cells.remove(at: index)
        case "insert":
            let source = (arguments["new_source"] as? String) ?? ""
            let type = ((arguments["cell_type"] as? String) ?? "code").lowercased()
            let cell = Self.makeCell(type: type, source: source)
            let at = min(index, cells.count)   // insert AT the index (0 = top), clamp to end
            cells.insert(cell, at: at)
        case "replace", "edit":
            guard index < cells.count else { return .failure("cell_number \(index) out of range (\(cells.count) cells)") }
            let source = (arguments["new_source"] as? String) ?? ""
            cells[index]["source"] = Self.splitSource(source)
            if let type = (arguments["cell_type"] as? String)?.lowercased() { cells[index]["cell_type"] = type }
            cells[index]["outputs"] = cells[index]["cell_type"] as? String == "code" ? [] : nil
            cells[index]["execution_count"] = NSNull()
        default:
            return .failure("unknown edit_mode '\(mode)' — use replace | insert | delete")
        }

        nb["cells"] = cells
        let out = try JSONSerialization.data(withJSONObject: nb, options: [.prettyPrinted, .sortedKeys])
        try confined.writeString(path, String(decoding: out, as: UTF8.self), createParents: false)
        return ToolResult(success: true, output: "\(mode) cell \(index) in \(path) (\(cells.count) cells)",
                          metadata: ["path": path, "cells": String(cells.count)])
    }

    /// Jupyter stores source as an array of lines each ending in \n (except the last). Match that.
    static func splitSource(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        let lines = s.components(separatedBy: "\n")
        return lines.enumerated().map { $0.offset == lines.count - 1 ? $0.element : $0.element + "\n" }
    }

    static func makeCell(type: String, source: String) -> [String: Any] {
        var cell: [String: Any] = ["cell_type": type, "metadata": [:], "source": splitSource(source)]
        if type == "code" { cell["outputs"] = []; cell["execution_count"] = NSNull() }
        return cell
    }
}
