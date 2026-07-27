import Foundation

/// Phase 3.1 execution — the SAFE git backing for best-of-N. Runs up to N independent attempts, each in its
/// OWN worktree (the live tree is never touched during attempts), takes the first that VERIFIES, and applies
/// ONLY that winner's diff to the live tree — after a dry-run `git apply --check`, so a patch that wouldn't
/// apply cleanly is refused and the tree is left exactly as it was. Every failure path leaves the live tree
/// untouched, and all worktrees are torn down. Gated on a CLEAN live tree (else the caller falls back to a
/// single in-tree cycle) so a verified winner's diff can never collide with pre-existing uncommitted work.
public enum WorktreeBestOfN {

    /// True when the repo has NO uncommitted changes (safe to apply a winner's diff without collision).
    public static func isCleanTree(_ root: String) -> Bool {
        guard GitIsolation.isGitRepo(root) else { return false }
        let out = git(["-C", root, "status", "--porcelain"], cwd: root)
        return out?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false
    }

    /// Run best-of-N. `attempt(worktreePath, index)` runs the agent IN the worktree and returns whether that
    /// attempt verified (+ a quality score, currently informational). Returns true iff a verified winner's
    /// diff was applied to the live tree; false otherwise (tree untouched → caller runs a normal cycle).
    @discardableResult
    public static func run(root: String, width: Int, nowEpoch: Double,
                           attempt: @Sendable (_ worktreePath: String, _ index: Int) async -> (verified: Bool, quality: Int)) async -> Bool {
        guard width > 1, isCleanTree(root) else { return false }   // fail-safe: only clean git repos
        var worktrees: [GitWorktree] = []
        defer { for wt in worktrees { GitIsolation.discard(wt) } }   // ALWAYS tear down

        for i in 0..<width {
            guard let wt = GitIsolation.makeWorktree(repo: root, label: "bestofn-\(i)", nowEpoch: nowEpoch) else { continue }
            worktrees.append(wt)
            let verdict = await attempt(wt.path, i)
            guard verdict.verified else { continue }
            // Winner: capture ALL its changes — stage first so NEW/untracked files (a plain `git diff`
            // misses them) are included — then transfer to the (still clean) live tree, but only if the
            // patch applies cleanly (dry-run first). Otherwise refuse; the tree stays untouched.
            _ = git(["-C", wt.path, "add", "-A"], cwd: wt.path)
            let diff = git(["-C", wt.path, "diff", "--cached"], cwd: wt.path) ?? ""
            if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            return applyToRoot(diff: diff, root: root)
        }
        return false
    }

    /// Apply `diff` to `root`'s working tree, guarded by `git apply --check` (dry run). Clean-only:
    /// on any check/apply failure the tree is left as-is (no --reject, no partial application).
    static func applyToRoot(diff: String, root: String) -> Bool {
        guard check(diff: diff, root: root) else { return false }
        return apply(diff: diff, root: root, check: false)
    }
    private static func check(diff: String, root: String) -> Bool { apply(diff: diff, root: root, check: true) }

    private static func apply(diff: String, root: String, check: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", root, "apply"] + (check ? ["--check"] : []) + ["-"]
        let inPipe = Pipe(); p.standardInput = inPipe
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        inPipe.fileHandleForWriting.write(Data(diff.utf8))
        try? inPipe.fileHandleForWriting.close()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    @discardableResult
    private static func git(_ args: [String], cwd: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

extension WorktreeBestOfN {
    /// Is git usable here (for tests to skip cleanly on a git-less box).
    public static func isGitRepoAvailable() -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git","--version"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit(); return p.terminationStatus == 0
    }
}
