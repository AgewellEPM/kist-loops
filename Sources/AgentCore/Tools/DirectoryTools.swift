import Foundation

// Directory inspection tools. Both confine traversal via `context.confinedRoot()` — the
// `openat`/`O_NOFOLLOW` layer — so a symlinked directory is never descended and listing
// cannot escape the project root. (Trade-off: in-repo symlinked dirs are not followed.)

/// List the immediate entries of a directory.
public struct ListFilesTool: AgentTool {
    public let name = "list_files"
    public let description = "List files and directories directly inside a directory (non-recursive)."
    public let parameters = [
        ToolParameter(name: "path", type: "string", description: "Directory relative to the project root (default: root)", required: false),
    ]
    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let path = (arguments["path"] as? String) ?? "."
        // entries() opens with O_NOFOLLOW and tags each child dir/not via fstatat(NOFOLLOW);
        // a non-directory or escape attempt throws → normalized to a failure by the registry.
        let entries = try context.confinedRoot().entries(path)
        let lines = entries.map { $0.isDir ? "\($0.name)/" : $0.name }
        return ToolResult(success: true, output: lines.joined(separator: "\n"), metadata: [
            "path": path, "count": String(entries.count),
        ])
    }
}

/// Recursively find files matching a glob pattern (e.g. `**/*.swift`).
public struct GlobFilesTool: AgentTool {
    public let name = "glob_files"
    public let description = "Recursively find files whose path matches a glob pattern like **/*.swift."
    public let parameters = [
        ToolParameter(name: "pattern", type: "string", description: "Glob pattern, e.g. **/*.swift or src/*.ts", required: true),
        ToolParameter(name: "path", type: "string", description: "Directory to search from (default: root)", required: false),
        ToolParameter(name: "limit", type: "integer", description: "Max results (default 500)", required: false),
    ]
    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let pattern = try requireString("pattern", from: arguments)
        let base = (arguments["path"] as? String) ?? "."
        let limit = optionalInt("limit", from: arguments) ?? 500

        let regex = try Self.globToRegex(pattern)
        var matches: [String] = []
        // walk() confines traversal (O_NOFOLLOW; never descends a symlinked dir) and skips
        // noise dirs by name. relPath is relative to `base` — same as the old enumerator.
        struct StopGlob: Error {}
        do {
            try context.confinedRoot().walk(base, skipDirs: [".git", ".build", "node_modules"]) { rel, _ in
                if regex.firstMatch(in: rel, range: NSRange(rel.startIndex..., in: rel)) != nil {
                    matches.append(rel)
                    if matches.count >= limit { throw StopGlob() }
                }
            }
        } catch is StopGlob { /* hit the cap */ }
        let truncated = matches.count >= limit
        return ToolResult(
            success: true,
            output: matches.sorted().joined(separator: "\n"),
            metadata: ["count": String(matches.count), "truncated": String(truncated)]
        )
    }

    /// Translate a glob to an anchored regex. `**` matches across path separators,
    /// `*` matches within a segment, `?` matches one non-separator char.
    static func globToRegex(_ glob: String) throws -> NSRegularExpression {
        var out = "^"
        var i = glob.startIndex
        while i < glob.endIndex {
            let c = glob[i]
            switch c {
            case "*":
                let next = glob.index(after: i)
                if next < glob.endIndex && glob[next] == "*" {
                    // `**` matches any chars incl. "/". For the common `**/` form, make the slash OPTIONAL
                    // so it matches ZERO directories too — i.e. `**/x` matches a ROOT-level `x` (both MiMo
                    // and DeepSeek hit this live: `**/test.sh` missed a root test.sh and had to fall back).
                    let afterStars = glob.index(after: next)
                    if afterStars < glob.endIndex && glob[afterStars] == "/" {
                        out += "(?:.*/)?"           // **/  → zero or more directory segments
                        i = glob.index(after: afterStars)
                    } else {
                        out += ".*"                 // bare ** → any chars incl. "/"
                        i = glob.index(after: next)
                    }
                    continue
                } else {
                    out += "[^/]*"                 // * → within a segment
                }
            case "?":
                out += "[^/]"
            case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\":
                out += "\\\(c)"                    // escape regex metachars
            default:
                out.append(c)
            }
            i = glob.index(after: i)
        }
        out += "$"
        return try NSRegularExpression(pattern: out)
    }
}
