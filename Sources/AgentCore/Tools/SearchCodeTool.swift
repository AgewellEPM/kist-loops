import Foundation

/// Search file contents by regex. RIPGREP-BACKED when `rg` is on the system (output modes, context lines,
/// multiline, type/glob filters, .gitignore-aware) — spawned DIRECTLY (read-only), so it works even when
/// shell is disabled, exactly like Claude Code's Grep. Falls back to a pure-Foundation walk when `rg` is
/// absent, so it never hard-fails. Confined to the project root: the search dir is canonicalized and
/// verified under the root before `rg` is given it (the pure walk uses O_NOFOLLOW openat).
public struct SearchCodeTool: AgentTool {
    public let name = "search_code"
    public let description = "Search file contents by regex (ripgrep-backed when available; .gitignore-aware). Works WITHOUT shell. Returns path:line: text by default."
    public let parameters = [
        ToolParameter(name: "pattern", type: "string", description: "Regular expression to search for", required: true),
        ToolParameter(name: "path", type: "string", description: "Directory to search from (default: project root). Absolute paths under a session-armed read-only root (--allow-read) also work.", required: false),
        ToolParameter(name: "glob", type: "string", description: "Filename glob filter, e.g. *.swift", required: false),
        ToolParameter(name: "type", type: "string", description: "Ripgrep file type filter, e.g. swift, js, py (rg only)", required: false),
        ToolParameter(name: "output_mode", type: "string", description: "content (default, path:line:text) | files (paths only) | count (matches per file)", required: false),
        ToolParameter(name: "context", type: "integer", description: "Lines of context before+after each match (content mode, rg only)", required: false),
        ToolParameter(name: "case_insensitive", type: "boolean", description: "Case-insensitive match", required: false),
        ToolParameter(name: "multiline", type: "boolean", description: "Allow patterns to span lines (rg only)", required: false),
        ToolParameter(name: "limit", type: "integer", description: "Max output lines (default 200)", required: false),
    ]
    public var usageExamples: [String] {
        ["search_code(pattern=\"func \\\\w+\", type=\"swift\", output_mode=\"content\", context=2)",
         "search_code(pattern=\"TODO\", output_mode=\"files\")"]
    }
    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let pattern = try requireString("pattern", from: arguments)
        let base = (arguments["path"] as? String) ?? "."
        let limit = max(1, optionalInt("limit", from: arguments) ?? 200)
        let mode = ((arguments["output_mode"] as? String)?.lowercased()).map(Mode.init) ?? .content

        // Validate + canonicalize the search dir UNDER the root (throws pathEscape on `..`/symlink escape).
        // The READING resolver also admits absolute bases under an armed external read root (--allow-read).
        let (confined, searchBase) = try context.confinedRootForReading(base)
        let baseComps = try confined.relativeComponents(searchBase)
        let relDir = baseComps.isEmpty ? "." : baseComps.joined(separator: "/")
        // External base → emit ABSOLUTE paths (searchDir) so follow-up read_file calls resolve to
        // the right root — a root-relative path would silently resolve against the PROJECT root
        // (wrong-file on a name collision). Project base keeps the historical relative contract.
        let searchDir = confined.readOnly
            ? (relDir == "." ? confined.rootPath : confined.rootPath + "/" + relDir)
            : relDir

        // Single-file target → search ONLY that file (engine-independent, works with or without ripgrep),
        // honoring an optional filename glob. Without this, walk()/rg treat a regular file as a dir → ENOTDIR.
        if !baseComps.isEmpty, (try? confined.fileMetadata(searchBase).isRegular) == true {
            return try searchSingleFile(pattern: pattern, rootRel: searchDir, glob: arguments["glob"] as? String,
                                        caseInsensitive: optionalBool("case_insensitive", from: arguments) ?? false,
                                        mode: mode, limit: limit, confined: confined)
        }

        if let rg = Self.ripgrepPath() {
            return Self.runRipgrep(rg: rg, pattern: pattern, cwd: confined.rootPath, relDir: searchDir, mode: mode,
                                   context: optionalInt("context", from: arguments),
                                   caseInsensitive: optionalBool("case_insensitive", from: arguments),
                                   multiline: optionalBool("multiline", from: arguments),
                                   type: arguments["type"] as? String, glob: arguments["glob"] as? String, limit: limit)
        }
        // No ripgrep → pure-Foundation fallback (content mode only; modes degrade gracefully).
        return try swiftWalkSearch(pattern: pattern, base: searchBase, glob: arguments["glob"] as? String,
                                   caseInsensitive: optionalBool("case_insensitive", from: arguments) ?? false,
                                   limit: limit, confined: confined)
    }

    enum Mode { case content, files, count
        init(_ s: String) { switch s { case "files": self = .files; case "count": self = .count; default: self = .content } }
    }

    // MARK: - ripgrep path

    static func runRipgrep(rg: String, pattern: String, cwd: String, relDir: String, mode: Mode,
                           context: Int?, caseInsensitive: Bool?, multiline: Bool?, type: String?,
                           glob: String?, limit: Int) -> ToolResult {
        var args = ["--color=never"]
        switch mode {
        case .files: args.append("--files-with-matches")
        case .count: args.append("--count")
        case .content: args += ["--line-number", "--no-heading", "--with-filename"]
        }
        if caseInsensitive == true { args.append("-i") }
        if multiline == true { args += ["--multiline", "--multiline-dotall"] }
        if let context, mode == .content { args += ["--context", String(min(max(context, 0), 10))] }
        if let type, !type.isEmpty { args += ["--type", type] }
        if let glob, !glob.isEmpty { args += ["--glob", glob] }
        args += ["--", pattern, relDir]   // `--` stops flag parsing; pattern/dir are argv, never shell-interpreted

        let (out, timedOut) = runProcess(rg, args, cwd: cwd, maxBytes: 200_000, timeout: 20)
        var lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let last = lines.last, last.isEmpty { lines.removeLast() }
        let truncated = lines.count > limit || timedOut
        if lines.count > limit { lines = Array(lines.prefix(limit)) }
        let body = lines.isEmpty ? "(no matches)" : lines.joined(separator: "\n")
        return ToolResult(success: true, output: timedOut ? body + "\n… (search timed out; narrow it)" : body,
                          metadata: ["engine": "ripgrep", "lines": String(lines.count), "truncated": String(truncated)])
    }

    static func ripgrepPath() -> String? {
        let candidates = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg", "/bin/rg"]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) { return p }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let p = String(dir) + "/rg"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    /// Bounded, timed process run. stderr → /dev/null (no pipe-fill deadlock); stdout read to EOF on a
    /// background queue with a timeout that terminates a hung child. Read-only by construction (only `rg`).
    static func runProcess(_ launch: String, _ args: [String], cwd: String, maxBytes: Int, timeout: TimeInterval) -> (out: String, timedOut: Bool) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launch)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return ("", false) }
        let sem = DispatchSemaphore(value: 0)
        let box = DataBox()
        DispatchQueue.global().async {
            box.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            sem.signal()
        }
        let timedOut = sem.wait(timeout: .now() + timeout) == .timedOut
        if timedOut { proc.terminate() }
        proc.waitUntilExit()
        let data = box.data
        let capped = data.count > maxBytes ? data.prefix(maxBytes) : data
        return (String(data: Data(capped), encoding: .utf8) ?? "", timedOut)
    }
    private final class DataBox: @unchecked Sendable { var data = Data() }

    // MARK: - single-file search (engine-independent)

    /// Search ONE regular file. Honors a filename glob (a non-matching file → zero scanned, "(no matches)").
    /// Same glob/leaf + metadata semantics as the directory walk, so single-file and dir results are uniform.
    func searchSingleFile(pattern: String, rootRel: String, glob: String?, caseInsensitive: Bool,
                          mode: Mode, limit: Int, confined: ConfinedRoot) throws -> ToolResult {
        if let glob, !glob.isEmpty {
            let nameFilter = try GlobFilesTool.globToRegex(glob)
            let leaf = (rootRel as NSString).lastPathComponent
            if nameFilter.firstMatch(in: leaf, range: NSRange(leaf.startIndex..., in: leaf)) == nil {
                return ToolResult(success: true, output: "(no matches)",
                                  metadata: ["engine": "single-file", "matches": "0",
                                             "files_scanned": "0", "truncated": "false"])
            }
        }
        let opts: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        let regex: NSRegularExpression
        do { regex = try NSRegularExpression(pattern: pattern, options: opts) }
        catch { return .failure("invalid regex: \(error.localizedDescription)") }
        guard let content = try? confined.readString(rootRel) else { return .failure("could not read file: \(rootRel)") }
        var hits: [String] = []
        var truncated = false
        for (idx, line) in content.components(separatedBy: "\n").enumerated() {
            if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                let trimmed = line.count > 300 ? String(line.prefix(300)) + "…" : line
                hits.append("\(rootRel):\(idx + 1): \(trimmed)")
                if hits.count >= limit { truncated = true; break }
            }
        }
        let output: String
        switch mode {
        case .files:   output = hits.isEmpty ? "(no matches)" : rootRel
        case .count:   output = hits.isEmpty ? "(no matches)" : "\(rootRel):\(hits.count)"
        case .content: output = hits.isEmpty ? "(no matches)" : hits.joined(separator: "\n")
        }
        return ToolResult(success: true, output: output,
                          metadata: ["engine": "single-file", "matches": String(hits.count),
                                     "files_scanned": "1", "truncated": String(truncated)])
    }

    // MARK: - pure-Foundation fallback (no ripgrep on the system)

    func swiftWalkSearch(pattern: String, base: String, glob: String?, caseInsensitive: Bool,
                         limit: Int, confined: ConfinedRoot) throws -> ToolResult {
        let opts: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        let regex: NSRegularExpression
        do { regex = try NSRegularExpression(pattern: pattern, options: opts) }
        catch { return .failure("invalid regex: \(error.localizedDescription)") }
        let nameFilter = try glob.map { try GlobFilesTool.globToRegex($0) }
        let baseComps = try confined.relativeComponents(base)
        let relPrefix = baseComps.isEmpty ? "" : baseComps.joined(separator: "/") + "/"
        // External root → absolute output paths (see execute); readString accepts them under its root.
        let basePrefix = confined.readOnly ? confined.rootPath + "/" + relPrefix : relPrefix
        var hits: [String] = []
        var filesScanned = 0
        struct StopSearch: Error {}
        do {
            try confined.walk(base, skipDirs: [".git", ".build", "node_modules"]) { rel, isDir in
                if isDir { return }
                if let nameFilter {
                    let leaf = (rel as NSString).lastPathComponent
                    if nameFilter.firstMatch(in: leaf, range: NSRange(leaf.startIndex..., in: leaf)) == nil { return }
                }
                let rootRel = basePrefix + rel
                guard let content = try? confined.readString(rootRel) else { return }
                filesScanned += 1
                for (idx, line) in content.components(separatedBy: "\n").enumerated() {
                    if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                        let trimmed = line.count > 300 ? String(line.prefix(300)) + "…" : line
                        hits.append("\(rootRel):\(idx + 1): \(trimmed)")
                        if hits.count >= limit { throw StopSearch() }
                    }
                }
            }
        } catch is StopSearch { /* hit the cap */ }
        return ToolResult(success: true, output: hits.isEmpty ? "(no matches)" : hits.joined(separator: "\n"),
                          metadata: ["engine": "foundation", "matches": String(hits.count),
                                     "files_scanned": String(filesScanned), "truncated": String(hits.count >= limit)])
    }
}
