import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Rollback by construction. A fleet agent's edits run inside a dedicated git WORKTREE on a fresh
/// branch — never straight to main/prod. After a run the COMMITTED diff (`base...HEAD` = what will
/// actually merge) is measurable so a human (and the critic) can review; the worktree is kept on
/// accept, removed on discard. Worst case is "remove the worktree and the branch," and main was
/// never touched. Foundation-only (shells to `git` via `Process`) → macOS + Linux.
///
/// Ported from TinkySDR's Captain (Stage 0 of the fleet build): made `Sendable`/non-isolated, the
/// dirty-file helper inlined (was `LockTable`), branch prefix `mythos/`.
public struct GitWorktree: Equatable, Sendable {
    public let repo: String        // the source repo path
    public let path: String        // the worktree path (where the agent runs)
    public let branch: String      // the isolated branch
    /// The HEAD SHA this worktree branched from — the BASE for committed-diff measurement
    /// (`base...HEAD` = what the branch will actually merge). Empty ⇒ base unknown ⇒ measurement
    /// falls back to the working tree (back-compat).
    public var base: String

    public init(repo: String, path: String, branch: String, base: String = "") {
        self.repo = repo; self.path = path; self.branch = branch; self.base = base
    }
}

public enum GitIsolation {

    /// Create a worktree on a new branch off the repo's current HEAD. Returns nil if the repo isn't a
    /// git repo or the worktree add fails (surface it; never silently fall back to editing main).
    public static func makeWorktree(repo: String, label: String, nowEpoch: Double) -> GitWorktree? {
        guard isGitRepo(repo) else { return nil }
        let slug = sanitize(label)
        // Per-call UUID suffix makes a distinct branch + path even when two calls share the same slug
        // AND the same epoch-second (a fleet spawning several agents at once) — without it,
        // `git worktree add -b` fails on the 2nd with "branch already exists" and the agent silently
        // gets no worktree.
        let uniq = UUID().uuidString.prefix(8)
        let branch = "mythos/auto-\(slug)-\(Int(nowEpoch))-\(uniq)"
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("mythos-wt-\(slug)-\(Int(nowEpoch))-\(uniq)")
        // Capture the BASE SHA (current HEAD) BEFORE adding the worktree, so committed work can be
        // measured as `base...HEAD` (what merges), not the transient working tree. Empty on failure
        // ⇒ working-tree fallback.
        let base = run(["git", "-C", repo, "rev-parse", "HEAD"], cwd: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = run(["git", "-C", repo, "worktree", "add", "-b", branch, path], cwd: repo)
        guard r.exitCode == 0 else { return nil }
        return GitWorktree(repo: repo, path: path, branch: branch, base: base)
    }

    /// The diff of everything the run changed in the worktree (tracked + untracked names). Empty
    /// string = no changes (a no-op run — worth flagging).
    public static func diff(_ wt: GitWorktree) -> String {
        // `--text --no-ext-diff --no-textconv`: force TEXTUAL diff regardless of a candidate-supplied
        // .gitattributes (e.g. `Tests/** -diff`/`binary`) — otherwise git emits "Binary files differ"
        // and the CIIntegrityGuard goes blind to a deleted/weakened test (Codex CRITICAL).
        let tracked = run(["git", "-C", wt.path, "diff", "--text", "--no-ext-diff", "--no-textconv", "HEAD"], cwd: wt.path).stdout
        let untracked = run(["git", "-C", wt.path, "status", "--porcelain"], cwd: wt.path).stdout
        return [untracked.isEmpty ? "" : "STATUS:\n\(untracked)", tracked].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Repo-relative paths the branch CHANGED relative to its base commit — the COMMITTED work that
    /// will actually MERGE, not the transient working tree (empty once the agent commits).
    /// `base...HEAD` is the changes introduced on the branch. We UNION the still-dirty working-tree
    /// set so an escape left uncommitted can't hide from the lease (defense-in-depth). Falls back to
    /// the working-tree set when no base is known (back-compat).
    public static func committedChangedPaths(_ wt: GitWorktree) -> [String] {
        let base = wt.base.trimmingCharacters(in: .whitespacesAndNewlines)
        let dirty = dirtyFiles(repo: wt.path)
        guard !base.isEmpty else { return dirty }
        let out = run(["git", "-C", wt.path, "diff", "--name-only", "\(base)...HEAD"], cwd: wt.path).stdout
        let committed = out.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(committed).union(dirty)).sorted()
    }

    /// The harness/manifest paths (from `candidates`) that are TRUSTED to source the verifier's test
    /// COMMAND because they are, provably: (a) present in the branch's base commit, (b) UNCHANGED since
    /// base (not in `base...HEAD` and not dirty — case-insensitively, so a case-folded rename can't slip
    /// past on a case-insensitive FS), (c) TRACKED (so a `.gitignore`'d decoy left on disk is excluded),
    /// and (d) NOT a symlink on disk (so it can't redirect the read to an agent-controlled target).
    ///
    /// This is the allow-list the verifier's command resolver consults. An agent CANNOT get a harness
    /// into this set by adding it, modifying it, ignoring-then-planting it, symlinking it, or
    /// case-folding it — the four trust-bypass classes a naive "is it in the agent's diff?" check missed.
    /// Empty base ⇒ empty set (FAIL CLOSED: with no trusted base, nothing in the worktree is trusted).
    public static func baseTrustedFiles(_ wt: GitWorktree, candidates: [String]) -> Set<String> {
        let base = wt.base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return [] }
        let changedLower = Set(committedChangedPaths(wt).map { $0.lowercased() })   // added/modified (any case)
        let tracked = Set(trackedFiles(repo: wt.path))                              // respects .gitignore
        var trusted = Set<String>()
        for rel in candidates {
            guard tracked.contains(rel) else { continue }              // ignored/untracked decoy ⇒ reject
            guard !changedLower.contains(rel.lowercased()) else { continue }  // agent-added/modified ⇒ reject
            // Must exist at base as a real object (not just any name the agent introduced later).
            guard run(["git", "-C", wt.path, "cat-file", "-e", "\(base):\(rel)"], cwd: wt.path).exitCode == 0
            else { continue }
            // A symlink on disk would redirect the trusted read to an agent-controlled target ⇒ reject.
            let full = (wt.path as NSString).appendingPathComponent(rel)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
               (attrs[.type] as? FileAttributeType) == .typeSymbolicLink { continue }
            trusted.insert(rel)
        }
        return trusted
    }

    /// The content of `rel` AT THE BASE COMMIT, read straight from the git object with `git cat-file blob`
    /// (which — unlike `git show` — does NOT run clean/smudge filters, so a committed `.gitattributes`
    /// filter can't inject code during the read), but ONLY when the base TREE ENTRY is a REGULAR FILE
    /// (mode `100644`/`100755`). A symlink entry (`120000`) or tree (`040000`) ⇒ nil, so a trusted read
    /// can never be redirected to an agent-controlled target. nil on empty base / absent / non-regular /
    /// git failure (fail closed). This is the FROZEN verifier content — executing THIS (never the mutable
    /// worktree path) closes the check→execute TOCTOU window (a same-user watcher can't swap it mid-run).
    public static func baseFileContent(_ wt: GitWorktree, rel: String) -> String? {
        let base = wt.base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        let mode = run(["git", "-C", wt.path, "ls-tree", base, "--", rel], cwd: wt.path).stdout
            .split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard mode == "100644" || mode == "100755" else { return nil }   // regular file only
        let r = run(["git", "-C", wt.path, "cat-file", "blob", "\(base):\(rel)"], cwd: wt.path)
        guard r.exitCode == 0 else { return nil }
        let content = r.stdout
        // FAIL CLOSED on empty / whitespace-only / non-UTF-8: `run` decodes utf8-or-"" (all-or-nothing), so
        // an empty blob AND an undecodable binary blob both yield "". A whitespace-only blob is likewise no
        // verifier — each would run as an exit-0 no-op (a false green).
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // FAIL CLOSED on binary/control content: the harness runs as an `sh -c <argv>` string, and a NUL
        // TRUNCATES the argv at exec (`strdup`) → `sh -c ""` silently exits 0 = false green. Non-printable
        // control bytes are never a legitimate shell harness. Allow only printable text + ordinary
        // whitespace (tab/newline/CR).
        for u in content.unicodeScalars {
            if u.value == 0 { return nil }
            if u.value < 0x20, u != "\t", u != "\n", u != "\r" { return nil }
        }
        // FAIL CLOSED above a sane size: an `sh -c <argv>` string over ARG_MAX (~1 MB on macOS) E2BIGs at
        // spawn; a real verifier harness is tiny, so refuse well under the limit rather than fail obscurely.
        guard content.utf8.count <= 262_144 else { return nil }
        return content
    }

    /// The branch's COMMITTED diff vs its base (what merges), with any still-dirty working-tree diff
    /// appended so a no-op commit + dirty tree still surfaces. Empty ⇒ truly no change. Falls back to
    /// the working-tree diff when no base.
    public static func committedDiff(_ wt: GitWorktree) -> String {
        let base = wt.base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return diff(wt) }
        // `--text --no-ext-diff --no-textconv`: see GitIsolation.diff — force textual hunks so a
        // .gitattributes diff-suppression trick can't hide a removed test from the integrity guard.
        let committed = run(["git", "-C", wt.path, "diff", "--text", "--no-ext-diff", "--no-textconv", "\(base)...HEAD"], cwd: wt.path).stdout
        let working = diff(wt)
        return [committed, working]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    /// Repo-relative paths of all TRACKED files (`git ls-files`) — the source for the planner's
    /// directory-tree context + the scope validator's known-dir set. Tracked-only (respects
    /// .gitignore). Empty on any failure.
    public static func trackedFiles(repo: String) -> [String] {
        run(["git", "-C", repo, "ls-files"], cwd: repo).stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// COMMITTED-ONLY changed paths (`git diff --name-only base...HEAD`) with NO working-tree union —
    /// exactly what will MERGE. The lease uses the dirty-union variant (stricter); CLAIM
    /// reconciliation must check against what actually merges, so a claim about an uncommitted edit
    /// (which will never land) can't pass. Empty base ⇒ FAIL CLOSED (empty), NOT a working-tree fallback.
    public static func committedOnlyChangedPaths(_ wt: GitWorktree) -> [String] {
        let base = wt.base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return [] }
        return run(["git", "-C", wt.path, "diff", "--name-only", "\(base)...HEAD"], cwd: wt.path).stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// COMMITTED-ONLY diff (`git diff base...HEAD`), no working-tree append — the claim-reconciliation
    /// counterpart to committedDiff. No base ⇒ "" (fail closed: no committed evidence ⇒ a claim can't
    /// be verified → refused).
    public static func committedOnlyDiff(_ wt: GitWorktree) -> String {
        let base = wt.base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "" }
        return run(["git", "-C", wt.path, "diff", "\(base)...HEAD"], cwd: wt.path).stdout
    }

    /// TRACKED files modified vs HEAD (`git diff --name-only HEAD`) — the worktree's uncommitted edits to
    /// already-committed files. Untracked NEW files (build artifacts) do NOT appear (only `git status`
    /// shows those), so a hermetic test that drops artifacts is tolerated; a test that REWRITES a tracked
    /// source file is caught. Used by the Foreman's post-test tree-integrity gate (a green must attest the
    /// COMMITTED snapshot, not a snapshot the test mutated). Empty on any failure (fail-soft).
    public static func trackedDirtyFiles(_ wt: GitWorktree) -> [String] {
        run(["git", "-C", wt.path, "diff", "--name-only", "HEAD"], cwd: wt.path).stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Commit the worktree's changes (so the branch holds them for review/merge).
    @discardableResult
    public static func commit(_ wt: GitWorktree, message: String) -> Bool {
        _ = run(["git", "-C", wt.path, "add", "-A"], cwd: wt.path)
        return run(["git", "-C", wt.path, "commit", "-m", message], cwd: wt.path).exitCode == 0
    }

    /// Discard: remove the worktree and delete its branch. Main is untouched.
    @discardableResult
    public static func discard(_ wt: GitWorktree) -> Bool {
        let worktree = run(["git", "-C", wt.repo, "worktree", "remove", "--force", wt.path], cwd: wt.repo)
        let branch = run(["git", "-C", wt.repo, "branch", "-D", wt.branch], cwd: wt.repo)
        return worktree.exitCode == 0 && branch.exitCode == 0
    }

    // MARK: - Held-out (reward-hacking) support — a THROWAWAY DETACHED copy, never the agent's worktree.

    /// A throwaway DETACHED worktree at `wt`'s current HEAD (its committed code + tests). Detached = no
    /// branch, so it can't collide with the agent's checked-out branch. nil on any failure (caller abstains).
    public static func detachedWorktreeAtHead(of wt: GitWorktree) -> GitWorktree? {
        let head = run(["git", "-C", wt.path, "rev-parse", "HEAD"], cwd: wt.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty, !head.hasPrefix("-") else { return nil }
        let repo = run(["git", "-C", wt.path, "rev-parse", "--show-toplevel"], cwd: wt.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else { return nil }
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("mythos-heldout-\(UUID().uuidString.prefix(8))")
        guard run(["git", "-C", repo, "worktree", "add", "--detach", dir, head], cwd: repo).exitCode == 0
        else { return nil }
        return GitWorktree(repo: repo, path: dir, branch: "", base: wt.base)   // branch "" = detached
    }

    /// Restore `paths` to their version at `ref` inside `wt` (`git checkout <ref> -- <paths>`). Defense:
    /// refuses a ref or any path that looks like an option (`-…`) or is empty. Returns true iff it succeeded.
    public static func checkoutPaths(_ wt: GitWorktree, ref: String, paths: [String]) -> Bool {
        let r = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty, !r.hasPrefix("-"), !paths.isEmpty,
              paths.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else { return false }
        return run(["git", "-C", wt.path, "checkout", r, "--"] + paths, cwd: wt.path).exitCode == 0
    }

    /// Remove a throwaway worktree (no branch to delete — it's detached). Best-effort cleanup.
    public static func removeWorktree(_ wt: GitWorktree) {
        _ = run(["git", "-C", wt.repo, "worktree", "remove", "--force", wt.path], cwd: wt.repo)
    }

    // MARK: - Auto-join of signed branches

    /// The outcome of merging signed fleet branches into a fresh integration branch.
    public enum MergeResult: Equatable, Sendable {
        case merged(integrationBranch: String, worktreePath: String, branches: [String])
        case conflict(onBranch: String, mergedBefore: [String])
        case nothingToMerge
        /// A PRIOR successful run's integration branch still exists — the kept, reviewable artifact
        /// awaiting human promotion/removal. We refuse to clobber it: a graceful idempotency signal,
        /// NOT a retryable failure.
        case alreadyIntegrated(integrationBranch: String)
        case failed(reason: String)
    }

    /// Merge `branches` (in signoff order) onto a FRESH `integrationBranch` created off `base`, in its
    /// OWN worktree. Safety: REFUSES main/master/HEAD (case-insensitive + trimmed); never touches the
    /// repo's working checkout; a conflict aborts (no force), tears down the throwaway worktree +
    /// partial branch, and STOPS (honest mergedBefore). On SUCCESS the integration worktree+branch are
    /// LEFT for human review + manual promotion to main (never auto-promoted).
    public static func mergeIntoIntegration(repo: String, base: String, branches: [String],
                                            integrationBranch: String, nowEpoch: Double) -> MergeResult {
        guard isGitRepo(repo) else { return .failed(reason: "not a git repo") }
        let integration = integrationBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = integration.lowercased()
        let protected: Set<String> = ["main", "master", "head"]
        guard !protected.contains(normalized) else {
            return .failed(reason: "refuses to merge into protected branch \(integrationBranch)")
        }
        guard isSafeLocalBranchName(integration) else {
            return .failed(reason: "refuses unsafe integration branch name \(integrationBranch)")
        }

        let toMerge = branches.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !toMerge.isEmpty else { return .nothingToMerge }
        for branch in toMerge {
            let source = branch.lowercased()
            guard !protected.contains(source) else {
                return .failed(reason: "refuses to merge protected source branch \(branch)")
            }
            guard isSafeLocalBranchName(branch) else {
                return .failed(reason: "refuses unsafe source branch name \(branch)")
            }
        }

        // Idempotency: a prior successful run's KEPT integration branch must not make
        // `worktree add -b` hard-fail with "branch already exists".
        if branchExists(repo: repo, branch: integration) {
            return .alreadyIntegrated(integrationBranch: integration)
        }

        // Fresh integration branch off `base`, in its own worktree (HEAD untouched).
        let intDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("mythos-integration-\(Int(nowEpoch))-\(UUID().uuidString.prefix(6))")
        let add = run(["git", "-C", repo, "worktree", "add", "-b", integration, intDir, base], cwd: repo)
        guard add.exitCode == 0 else {
            return .failed(reason: "couldn't create integration worktree off \(base): \(add.stdout)")
        }
        var merged: [String] = []
        for b in toMerge {
            let m = run(["git", "-C", intDir, "merge", "--no-ff", "-m", "fleet-merge \(b)", b], cwd: intDir)
            if m.exitCode != 0 {
                let abort = run(["git", "-C", intDir, "merge", "--abort"], cwd: intDir)   // no force
                let removed = removeIntegrationWorktree(repo: repo, dir: intDir, branch: integration)
                // A failed abort OR cleanup leaves the repo dirty → report .failed (with the orphan
                // path) rather than a clean-looking .conflict the caller would treat as a clean slate.
                if abort.exitCode != 0 || !removed {
                    return .failed(reason: "conflict on \(b): "
                                 + (abort.exitCode != 0 ? "merge --abort FAILED" : "abort ok")
                                 + ", " + (removed ? "cleanup ok" : "cleanup FAILED — orphan left at \(intDir) / branch \(integrationBranch)")
                                 + "; merged before: \(merged)")
                }
                return .conflict(onBranch: b, mergedBefore: merged)
            }
            merged.append(b)
        }
        return .merged(integrationBranch: integration, worktreePath: intDir, branches: merged)
    }

    /// Conservative local branch-name gate for merge inputs. This is defense-in-depth around `git`
    /// argv parsing: branch names that could be options, fully-qualified refs, path traversal-ish refs,
    /// or ambiguous/special rev syntax are refused before `git worktree add` / `git merge`.
    public static func isSafeLocalBranchName(_ branch: String) -> Bool {
        let b = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty, b != "@", !b.hasPrefix("-"), !b.hasPrefix("/"), !b.hasSuffix("/") else { return false }
        guard !b.hasPrefix("refs/"), !b.contains("//"), !b.contains(".."), !b.contains("@{") else { return false }
        guard !b.hasSuffix(".lock") else { return false }
        if b.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return false }
        let illegal = CharacterSet(charactersIn: "~^:?*[\\")
        if b.rangeOfCharacter(from: illegal) != nil { return false }
        if b.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) { return false }
        return b.split(separator: "/").allSatisfy { part in
            !part.isEmpty && !part.hasPrefix(".") && !part.hasSuffix(".")
        }
    }

    /// Remove a throwaway integration worktree and delete its branch. True iff BOTH succeeded.
    @discardableResult
    private static func removeIntegrationWorktree(repo: String, dir: String, branch: String) -> Bool {
        let wt = run(["git", "-C", repo, "worktree", "remove", "--force", dir], cwd: repo)
        let br = run(["git", "-C", repo, "branch", "-D", branch], cwd: repo)
        return wt.exitCode == 0 && br.exitCode == 0
    }

    /// True iff a local `branch` already exists in `repo`.
    public static func branchExists(repo: String, branch: String) -> Bool {
        run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], cwd: repo)
            .exitCode == 0
    }

    /// True iff `branch` has at least one commit not already in `base`.
    public static func branchHasCommits(repo: String, branch: String, base: String) -> Bool {
        let r = run(["git", "-C", repo, "rev-list", "--count", "\(base)..\(branch)"], cwd: repo)
        return (Int(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
    }

    // MARK: - Helpers

    public static func isGitRepo(_ path: String) -> Bool {
        run(["git", "-C", path, "rev-parse", "--is-inside-work-tree"], cwd: path).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Branch-name-safe slug. Lowercase, alnum + dashes, bounded.
    public static func sanitize(_ s: String) -> String {
        let lowered = s.lowercased()
        let mapped = lowered.map { ch -> Character in (ch.isLetter || ch.isNumber) ? ch : "-" }
        var out = String(mapped)
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if out.isEmpty { out = "task" }
        return String(out.prefix(40))
    }

    /// Still-dirty (uncommitted) repo-relative paths via `git status --porcelain`. Inlined here (was
    /// the Captain's LockTable) so GitIsolation is self-contained. Handles the rename `old -> new` form.
    private static func dirtyFiles(repo: String) -> [String] {
        run(["git", "-C", repo, "status", "--porcelain"], cwd: repo).stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> String? in
                let s = String(line)
                guard s.count > 3 else { return nil }     // "XY path"
                var path = String(s.dropFirst(3))
                if let r = path.range(of: " -> ") { path = String(path[r.upperBound...]) }  // rename → new name
                let trimmed = path.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
    }

    @discardableResult
    private static func run(_ argv: [String], cwd: String) -> (exitCode: Int32, stdout: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch { return (-1, "") }
    }
}
