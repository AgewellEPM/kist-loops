import Foundation

/// Parser + applier for the V4A patch format (the `*** Begin Patch … *** End Patch` envelope Codex CLI
/// popularized and models are trained on). Pure + line-based so it's fully unit-testable without I/O; the
/// `ApplyPatchTool` wires it to the confined filesystem.
///
/// Hunks carry NO line numbers — each hunk is located in the file by matching its context+removed lines
/// (exact, then trailing-whitespace-insensitive). Supports Add / Update / Delete / Move-to across multiple
/// files in one atomic patch.
public enum ApplyPatch {

    public struct HunkLine: Equatable { public enum Kind { case context, add, remove }; public let kind: Kind; public let text: String }
    public enum Op: Equatable {
        case add(path: String, content: String)
        case delete(path: String)
        case update(path: String, moveTo: String?, hunks: [[HunkLine]])
    }
    public enum PatchError: Error, Equatable {
        case envelope(String)      // missing/garbled Begin/End
        case empty                 // no file operations
        case hunkNoMatch(path: String)
        case missingFile(path: String)
    }

    private static let begin = "*** Begin Patch"
    private static let end = "*** End Patch"

    // MARK: - parse

    public static func parse(_ patch: String) throws -> [Op] {
        var lines = patch.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // Tolerate leading/trailing blank lines and code fences around the envelope.
        while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty || f.hasPrefix("```") { lines.removeFirst() }
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty || l.hasPrefix("```") { lines.removeLast() }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == begin else {
            throw PatchError.envelope("patch must start with \"\(begin)\"")
        }
        lines.removeFirst()

        var ops: [Op] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix(end) { break }
            if let path = strip(line, "*** Add File: ") {
                i += 1
                var content: [String] = []
                while i < lines.count, lines[i].hasPrefix("+") { content.append(String(lines[i].dropFirst())); i += 1 }
                ops.append(.add(path: path, content: content.joined(separator: "\n")))
            } else if let path = strip(line, "*** Delete File: ") {
                ops.append(.delete(path: path)); i += 1
            } else if let path = strip(line, "*** Update File: ") {
                i += 1
                var moveTo: String?
                if i < lines.count, let m = strip(lines[i], "*** Move to: ") { moveTo = m; i += 1 }
                var hunks: [[HunkLine]] = []
                var current: [HunkLine] = []
                while i < lines.count, !lines[i].hasPrefix("*** ") {
                    let l = lines[i]
                    if l.hasPrefix("@@") {                     // hunk anchor — split, header itself ignored
                        if !current.isEmpty { hunks.append(current); current = [] }
                    } else if l.hasPrefix("+") {
                        current.append(HunkLine(kind: .add, text: String(l.dropFirst())))
                    } else if l.hasPrefix("-") {
                        current.append(HunkLine(kind: .remove, text: String(l.dropFirst())))
                    } else if l.hasPrefix(" ") {
                        current.append(HunkLine(kind: .context, text: String(l.dropFirst())))
                    } else if l.isEmpty {
                        current.append(HunkLine(kind: .context, text: ""))    // blank context line
                    }
                    i += 1
                }
                if !current.isEmpty { hunks.append(current) }
                ops.append(.update(path: path, moveTo: moveTo, hunks: hunks))
            } else {
                i += 1   // skip stray line (e.g. "*** End of File")
            }
        }
        guard !ops.isEmpty else { throw PatchError.empty }
        return ops
    }

    /// Conservative risk signal for the reversibility gate: does any file op target an absolute or
    /// `..`-escaping path? (Real enforcement is ConfinedRoot at write — this only colors the approval.)
    public static func touchesEscapingPath(_ patch: String, projectRoot: String) -> Bool {
        for line in patch.components(separatedBy: "\n") {
            for prefix in ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "] where line.hasPrefix(prefix) {
                let p = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if p.hasPrefix("/") || p.split(separator: "/").contains("..") { return true }
            }
        }
        return false
    }

    private static func strip(_ line: String, _ prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - apply (pure, against an in-memory file map for testing)

    /// Apply the parsed ops to a map of path→content. Returns the new map + a per-file change summary.
    /// `nil` content for a path = the file doesn't exist. Throws on a hunk that can't be located.
    public static func applyToMap(_ ops: [Op], files: [String: String]) throws -> (files: [String: String?], summary: [String]) {
        var out: [String: String?] = [:]
        var summary: [String] = []
        for op in ops {
            switch op {
            case .add(let path, let content):
                out[path] = content
                summary.append("add \(path) (+\(content.components(separatedBy: "\n").count))")
            case .delete(let path):
                out[path] = String?.none
                summary.append("delete \(path)")
            case .update(let path, let moveTo, let hunks):
                let current = out[path].flatMap { $0 } ?? files[path]
                guard let body = current else { throw PatchError.missingFile(path: path) }
                let updated = try applyHunks(hunks, to: body, path: path)
                let (plus, minus) = counts(hunks)
                if let moveTo {
                    out[path] = String?.none
                    out[moveTo] = updated
                    summary.append("move \(path) → \(moveTo) (+\(plus)/-\(minus))")
                } else {
                    out[path] = updated
                    summary.append("update \(path) (+\(plus)/-\(minus))")
                }
            }
        }
        return (out, summary)
    }

    static func counts(_ hunks: [[HunkLine]]) -> (Int, Int) {
        var plus = 0, minus = 0
        for h in hunks { for l in h { if l.kind == .add { plus += 1 } else if l.kind == .remove { minus += 1 } } }
        return (plus, minus)
    }

    public static func applyHunks(_ hunks: [[HunkLine]], to content: String, path: String) throws -> String {
        var fileLines = content.components(separatedBy: "\n")
        for hunk in hunks {
            let search = hunk.filter { $0.kind != .add }.map { $0.text }
            let replace = hunk.filter { $0.kind != .remove }.map { $0.text }
            guard let start = findRun(search, in: fileLines) else { throw PatchError.hunkNoMatch(path: path) }
            fileLines.replaceSubrange(start..<(start + search.count), with: replace)
        }
        return fileLines.joined(separator: "\n")
    }

    /// Locate a contiguous run of `needle` lines in `hay` — exact first, then trailing-whitespace-insensitive.
    static func findRun(_ needle: [String], in hay: [String]) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        let upper = hay.count - needle.count
        for s in 0...upper where Array(hay[s..<s + needle.count]) == needle { return s }
        let n = needle.map { $0.trimmingTrailing() }
        for s in 0...upper where Array(hay[s..<s + needle.count]).map({ $0.trimmingTrailing() }) == n { return s }
        return nil
    }
}

private extension String {
    func trimmingTrailing() -> String {
        var s = self[...]
        while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
        return String(s)
    }
}
