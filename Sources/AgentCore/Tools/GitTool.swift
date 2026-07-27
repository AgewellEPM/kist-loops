import Foundation

// Read-only structured git inspection. A coding agent constantly needs repo state
// (what changed, history, blame) — today that only comes through raw run_command,
// which needs shell ON and approval. This exposes the READ subcommands as a first-class
// tool: spawned directly (works with shell OFF, like search_code), argv-only (no shell to
// reinterpret tokens), confined to the project root, and NOT approval-gated because none
// of these subcommands mutate the repo.
//
// Deliberately read-only: commit/checkout/reset/push/clean are NOT reachable here — those
// remain behind run_command (shell + approval). A `rev` that starts with `-` is refused so
// it can never smuggle a git flag; file paths go through ConfinedRoot + a `--` terminator.
public struct GitTool: AgentTool {
    public let name = "git"
    public let description = "Inspect git repo state (READ-ONLY): status, diff, log, show, blame. Works without shell. Never mutates the repo — use run_command for commit/checkout/etc."
    public let parameters = [
        ToolParameter(name: "subcommand", type: "string", description: "One of: status | diff | log | show | blame", required: true),
        ToolParameter(name: "path", type: "string", description: "File path (relative to project root) to scope the command; required for blame", required: false),
        ToolParameter(name: "rev", type: "string", description: "Revision/ref (e.g. HEAD, a branch, a SHA, or HEAD~3). Must not start with '-'.", required: false),
        ToolParameter(name: "max", type: "integer", description: "Max entries for log (default 30)", required: false),
    ]
    public var usageExamples: [String] {
        ["git(subcommand=\"status\")",
         "git(subcommand=\"diff\", rev=\"HEAD~1\", path=\"Sources/App.swift\")",
         "git(subcommand=\"log\", max=10, path=\"Sources\")",
         "git(subcommand=\"blame\", path=\"Sources/App.swift\")"]
    }
    public init() {}

    /// The only subcommands this tool will ever run — all read-only.
    static let allowedSubcommands: Set<String> = ["status", "diff", "log", "show", "blame"]

    static func gitPath() -> String? {
        for dir in ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin", "/bin"] {
            let p = dir + "/git"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let sub = try requireString("subcommand", from: arguments).lowercased()
        guard Self.allowedSubcommands.contains(sub) else {
            return .failure("git: unsupported subcommand '\(sub)'. Read-only subcommands: \(Self.allowedSubcommands.sorted().joined(separator: ", ")). For commit/checkout/etc. use run_command.")
        }
        let confined = try context.confinedRoot()

        // Validate optional path under the root; keep the relative form for the git `--` arg.
        var relPath: String?
        if let raw = arguments["path"] as? String, !raw.isEmpty {
            let comps = try confined.relativeComponents(raw)   // throws pathEscape on ../ or absolute escape
            relPath = comps.isEmpty ? "." : comps.joined(separator: "/")
        }
        // A rev must never begin with '-' (would smuggle a git flag); allow normal ref chars only.
        var rev: String?
        if let raw = arguments["rev"] as? String, !raw.isEmpty {
            guard !raw.hasPrefix("-") else { return .failure("git: rev must not start with '-'") }
            rev = raw
        }
        let max = self.clampedMax(optionalInt("max", from: arguments))

        let args = try Self.buildArgs(sub: sub, rev: rev, relPath: relPath, max: max)
        guard let git = Self.gitPath() else { return .failure("git is not installed") }
        let (out, timedOut) = SearchCodeTool.runProcess(git, args, cwd: confined.rootPath, maxBytes: 300_000, timeout: 30)
        let body = out.isEmpty ? "(no output)" : out
        return ToolResult(success: true,
                          output: timedOut ? body + "\n… (git timed out; scope it with path/max)" : body,
                          metadata: ["engine": "git", "subcommand": sub])
    }

    func clampedMax(_ v: Int?) -> Int { min(max(v ?? 30, 1), 500) }

    /// Global flags prepended to EVERY invocation to neutralize git's code-execution
    /// surfaces even in a hostile repo: `--no-pager` (no `core.pager`/GIT_PAGER program),
    /// and `-c` overrides that disable fsmonitor hooks and external diff/textconv drivers
    /// that `.git/config` + `.gitattributes` could otherwise make git run on diff/log/show/blame.
    static let hardeningGlobals: [String] = [
        "--no-pager",
        "-c", "core.fsmonitor=false",
        "-c", "diff.external=",
        "-c", "core.hooksPath=/dev/null",
    ]

    /// Pure argv builder — unit-tested without spawning. Every subcommand is read-only; a
    /// file path always follows a `--` terminator so it can't be read as a flag. Diff-bearing
    /// subcommands also pass `--no-ext-diff --no-textconv` as belt-and-suspenders.
    static func buildArgs(sub: String, rev: String?, relPath: String?, max: Int) throws -> [String] {
        var a = hardeningGlobals
        switch sub {
        case "status":
            a += ["status", "--porcelain=v1", "-b"]
        case "diff":
            a += ["diff", "--no-ext-diff", "--no-textconv", "--stat", "-p"]
            if let rev { a.append(rev) }
            if let relPath { a += ["--", relPath] }
        case "log":
            a += ["log", "--no-ext-diff", "--no-textconv", "--oneline", "--decorate", "-n", String(max)]
            if let rev { a.append(rev) }
            if let relPath { a += ["--", relPath] }
        case "show":
            a += ["show", "--no-ext-diff", "--no-textconv", "--stat", "-p", rev ?? "HEAD"]
            if let relPath { a += ["--", relPath] }
        case "blame":
            guard let relPath else { throw ToolError.missingParameter("path (required for blame)") }
            a += ["blame", "--no-textconv", "--", relPath]
        default:
            throw ToolError.configuration("unreachable subcommand \(sub)")
        }
        return a
    }
}
