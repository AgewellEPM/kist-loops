import Foundation
import AgentCore

/// A per-project working directory backed by a real git repo. Stage commits and
/// committed-diff measurement are delegated to the kist fleet engine's
/// `GitIsolation` primitives (the same code the fleet uses to decide what will
/// merge), so there is ONE trust/git layer, not a DesignFlow-local copy.
///
/// Each workspace is its own repo with a base commit, so `GitIsolation`'s
/// `base...HEAD` measurement (`committedOnly…`) is well-defined and the
/// `ClaimReconciler` can reconcile a stage's artifact against what actually
/// committed.
public struct GitWorkspace: Sendable {
    public let root: URL
    private let log: Log

    public init(root: URL, log: Log = Log("git")) {
        self.root = root
        self.log = log
    }

    public enum GitError: Error, CustomStringConvertible {
        case commandFailed(String, Int32, String)
        case noBase
        public var description: String {
            switch self {
            case let .commandFailed(cmd, code, out): return "git \(cmd) failed (\(code)): \(out.prefix(300))"
            case .noBase: return "workspace has no base commit — committed-diff measurement impossible"
            }
        }
    }

    /// Create the directory, initialise git, and lay down a base commit. The base
    /// commit is what makes `GitIsolation` committed-diff measurement work. Idempotent.
    public func initialize() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else { return }
        try git(["init", "-q"])
        try git(["config", "user.name", "designflow-loop"])
        try git(["config", "user.email", "loop@designflow.local"])
        // Base commit: gives GitIsolation a real `base` (root commit) to diff against.
        try ".designflow workspace root\n".write(
            to: root.appendingPathComponent(".designflow-root"), atomically: true, encoding: .utf8)
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "designflow: workspace root"])
    }

    /// Write a file (creating parent dirs) relative to the workspace root.
    public func write(_ contents: String, to relativePath: String) throws {
        let fileURL = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Stage everything and commit via the fleet primitive. Returns the short SHA,
    /// or nil if nothing changed (a no-op — the caller decides whether that's fatal).
    @discardableResult
    public func commit(_ message: String) throws -> String? {
        try git(["add", "-A"])
        let status = try git(["status", "--porcelain"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !status.isEmpty else { return nil }
        let full = "\(message)\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
        guard let wt = worktree() else { throw GitError.noBase }
        guard GitIsolation.commit(wt, message: full) else {
            throw GitError.commandFailed("commit", -1, "GitIsolation.commit returned false")
        }
        return try git(["rev-parse", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Repo-relative paths committed since the base (`base...HEAD`) — exactly what
    /// would MERGE. Fail-closed: no base ⇒ empty (a claim can't be verified).
    public func committedPaths() -> [String] {
        guard let wt = worktree() else { return [] }
        return GitIsolation.committedOnlyChangedPaths(wt)
    }

    /// The committed diff text since base (`base...HEAD`). No base ⇒ "".
    public func committedDiff() -> String {
        guard let wt = worktree() else { return "" }
        return GitIsolation.committedOnlyDiff(wt)
    }

    /// Repo-relative paths committed since an EXPLICIT base SHA (`base...HEAD`) — used
    /// to scope reconciliation to a single stage's diff (preStageHead...HEAD). Empty
    /// base ⇒ fail-closed empty.
    public func committedPaths(since baseSHA: String) -> [String] {
        let base = baseSHA.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return [] }
        return GitIsolation.committedOnlyChangedPaths(
            GitWorktree(repo: root.path, path: root.path, branch: "", base: base))
    }

    /// The committed diff text since an EXPLICIT base SHA. Empty base ⇒ "".
    public func committedDiff(since baseSHA: String) -> String {
        let base = baseSHA.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "" }
        return GitIsolation.committedOnlyDiff(
            GitWorktree(repo: root.path, path: root.path, branch: "", base: base))
    }

    /// SHA-256 (base64) of a workspace file's current bytes — binds a signoff seal to
    /// the actual artifact content, not just its path. nil if unreadable.
    public func contentHash(of relativePath: String) -> String? {
        let url = root.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return FleetSignoffEntry.computeHash(prevHash: "", canonical: text)
    }

    /// The repo's current HEAD SHA — the TRUSTED build identity for the promotion
    /// gate (read from git, never a user string). nil if not a repo / no commits.
    public func headSHA() -> String? {
        guard let out = try? git(["rev-parse", "HEAD"]) else { return nil }
        let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// A `GitWorktree` view of this repo for GitIsolation. repo == path (this is a
    /// standalone project, not an agent worktree of a larger repo); base is the
    /// repo's root commit so `base...HEAD` = all work since initialize().
    private func worktree() -> GitWorktree? {
        guard let out = try? git(["rev-list", "--max-parents=0", "HEAD"]) else { return nil }
        let base = out.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard !base.isEmpty else { return nil }
        return GitWorktree(repo: root.path, path: root.path, branch: "", base: base)
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw GitError.commandFailed(args.first ?? "?", process.terminationStatus, output)
        }
        return output
    }
}
