import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
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

    public enum EvolutionParentRefValidation: Equatable, Sendable {
        case valid(commitSHA: String)
        case invalid(reason: String)
    }

    public struct EvolutionCommitSnapshot: Equatable, Sendable {
        public let baseSHA: String
        public let commitSHA: String
        public let treeSHA: String
        public let gitControlDigest: String
        public let branch: String
        public let changedFiles: [String]
        public let committedDiff: String

        public init(baseSHA: String, commitSHA: String, treeSHA: String,
                    gitControlDigest: String, branch: String,
                    changedFiles: [String], committedDiff: String) {
            self.baseSHA = baseSHA
            self.commitSHA = commitSHA
            self.treeSHA = treeSHA
            self.gitControlDigest = gitControlDigest
            self.branch = branch
            self.changedFiles = changedFiles
            self.committedDiff = committedDiff
        }
    }

    public enum EvolutionCommitError: Error, LocalizedError, Equatable, Sendable {
        case invalidWorktree
        case noChanges
        case addFailed
        case commitFailed
        case dirtyAfterCommit
        case invalidCommitSHA
        case baseCommitReused
        case branchMismatch
        case emptyCommittedChange
        case snapshotMismatch
        case unsafeGitControl
        case untrustedGitRuntime
        case nonLinearCandidate
        case objectBindingMismatch

        public var errorDescription: String? {
            switch self {
            case .invalidWorktree: return "evolution worktree is not a valid git worktree"
            case .noChanges: return "evolution candidate produced no committable change"
            case .addFailed: return "git add failed; refusing to evaluate non-durable bytes"
            case .commitFailed: return "git commit failed; refusing to evaluate non-durable bytes"
            case .dirtyAfterCommit: return "evolution worktree is not exactly clean after commit"
            case .invalidCommitSHA: return "evolution candidate HEAD is not a canonical commit"
            case .baseCommitReused: return "evolution candidate did not create a commit beyond its base"
            case .branchMismatch: return "evolution branch ref does not exactly match candidate HEAD"
            case .emptyCommittedChange: return "evolution commit has no durable parent-relative diff"
            case .snapshotMismatch: return "evolution candidate changed after its durable snapshot"
            case .unsafeGitControl: return "evolution git control/config/filter surface is unsafe"
            case .untrustedGitRuntime: return "bounded trusted git execution failed or exceeded limits"
            case .nonLinearCandidate: return "evolution commit is not one exact child of its selected base"
            case .objectBindingMismatch: return "evolution commit/tree object binding is invalid"
            }
        }
    }

    private struct EvolutionGitControlIdentity: Equatable {
        struct Node: Equatable {
            let path: String
            let device: UInt64
            let inode: UInt64
            let owner: UInt32
            let kind: UInt32
            let size: Int64
            let linkCount: UInt64
            let modifiedNanos: Int64
            let changedNanos: Int64
            let digest: String?
        }

        struct ConfigurationBinding: Equatable {
            let path: String
            let node: Node?
        }

        let gitFile: Node
        let gitDirectory: Node
        let commonDirectory: Node
        /// The common local config is mandatory and byte-bound. Worktree-local config files are
        /// deliberately required to remain absent: accepting them would add a second, easy-to-miss
        /// authority surface whose options Git automatically overlays on the common config.
        let configurations: [ConfigurationBinding]

        static func capture(worktreePath: String) throws -> Self {
            let root = ToolContext.canonicalize(worktreePath) ?? worktreePath
            let gitFilePath = (root as NSString).appendingPathComponent(".git")
            var gitStatus = stat()
            guard lstat(gitFilePath, &gitStatus) == 0 else {
                throw EvolutionCommitError.unsafeGitControl
            }
            let gitFile: Node
            let gitDirectory: Node
            let commonDirectory: Node
            if gitStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                let directory = try stableDirectoryNode(
                    path: ToolContext.canonicalize(gitFilePath) ?? gitFilePath,
                    expectedKind: mode_t(S_IFDIR))
                gitFile = directory
                gitDirectory = directory
                commonDirectory = directory
            } else {
                let capturedGitFile = try stableRegularNode(path: gitFilePath, maxBytes: 16_384)
                guard capturedGitFile.node.linkCount == 1,
                      let text = String(data: capturedGitFile.bytes, encoding: .utf8),
                      text.hasPrefix("gitdir: ") else {
                    throw EvolutionCommitError.unsafeGitControl
                }
                let rawGitDir = text.dropFirst("gitdir: ".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard rawGitDir.hasPrefix("/"), !rawGitDir.contains("\0"),
                      let gitDir = ToolContext.canonicalize(rawGitDir) else {
                    throw EvolutionCommitError.unsafeGitControl
                }
                let directory = try stableDirectoryNode(
                    path: gitDir, expectedKind: mode_t(S_IFDIR))
                let commondirFile = (gitDir as NSString).appendingPathComponent("commondir")
                let capturedCommonFile = try stableRegularNode(
                    path: commondirFile, maxBytes: 4_096)
                guard capturedCommonFile.node.linkCount == 1,
                      let commonText = String(data: capturedCommonFile.bytes, encoding: .utf8) else {
                    throw EvolutionCommitError.unsafeGitControl
                }
                let commonRaw = commonText.trimmingCharacters(in: .whitespacesAndNewlines)
                let commonCandidate = commonRaw.hasPrefix("/")
                    ? commonRaw
                    : URL(fileURLWithPath: gitDir, isDirectory: true)
                        .appendingPathComponent(commonRaw, isDirectory: true).standardizedFileURL.path
                guard let common = ToolContext.canonicalize(commonCandidate) else {
                    throw EvolutionCommitError.unsafeGitControl
                }
                gitFile = capturedGitFile.node
                gitDirectory = directory
                commonDirectory = try stableDirectoryNode(
                    path: common, expectedKind: mode_t(S_IFDIR))
            }

            let commonConfigPath = (commonDirectory.path as NSString)
                .appendingPathComponent("config")
            let commonConfig = try stableRegularNode(path: commonConfigPath, maxBytes: 1_048_576)
            guard commonConfig.node.linkCount == 1,
                  localConfigurationIsSafe(commonConfig.bytes) else {
                throw EvolutionCommitError.unsafeGitControl
            }
            var configurations = [
                ConfigurationBinding(path: commonConfigPath, node: commonConfig.node),
            ]
            let worktreeConfigPaths = Set([
                (commonDirectory.path as NSString).appendingPathComponent("config.worktree"),
                (gitDirectory.path as NSString).appendingPathComponent("config.worktree"),
            ])
            for path in worktreeConfigPaths.sorted() {
                var status = stat()
                guard lstat(path, &status) != 0, errno == ENOENT else {
                    // A worktree-specific overlay is not needed by the evolution command set and
                    // would make the accepted local policy depend on a second file.
                    throw EvolutionCommitError.unsafeGitControl
                }
                configurations.append(ConfigurationBinding(path: path, node: nil))
            }
            configurations.sort { $0.path < $1.path }
            return Self(gitFile: gitFile, gitDirectory: gitDirectory,
                        commonDirectory: commonDirectory, configurations: configurations)
        }

        func validate(worktreePath: String) -> Bool {
            (try? Self.capture(worktreePath: worktreePath)) == self
        }

        /// `git worktree add/remove` legitimately changes directory entry counts (and therefore the
        /// directory `st_size`) in the pinned common Git directory. Permit only that metadata delta:
        /// every path, inode, device, owner, kind, link count, and every regular control-file byte stays
        /// exact. A replacement gitdir/gitfile therefore still fails closed.
        func validatesExpectedWorktreeDirectoryMutation(worktreePath: String) -> Bool {
            guard let current = try? Self.capture(worktreePath: worktreePath) else { return false }
            return Self.sameNodeIdentity(gitFile, current.gitFile)
                && Self.sameNodeIdentity(gitDirectory, current.gitDirectory)
                && Self.sameNodeIdentity(commonDirectory, current.commonDirectory)
                && configurations == current.configurations
        }

        private static func sameNodeIdentity(_ lhs: Node, _ rhs: Node) -> Bool {
            guard lhs.path == rhs.path, lhs.device == rhs.device, lhs.inode == rhs.inode,
                  lhs.owner == rhs.owner, lhs.kind == rhs.kind else { return false }
            // Creating/removing the first linked worktree also creates/removes `.git/worktrees`,
            // legitimately changing the containing directory's link count as well as its size.
            if lhs.kind == UInt32(mode_t(S_IFDIR)) { return true }
            return lhs.size == rhs.size && lhs.linkCount == rhs.linkCount && lhs.digest == rhs.digest
        }

        var bindingDigest: String {
            var pieces: [String] = ["kist.evolution.git-control.v1"]
            for node in [gitFile, gitDirectory, commonDirectory] {
                Self.appendBinding(node, to: &pieces)
            }
            for config in configurations {
                pieces.append(config.path)
                if let node = config.node {
                    Self.appendBinding(node, to: &pieces)
                } else {
                    pieces.append("missing")
                }
            }
            return BuilderEvidenceDigest.sha256(pieces.joined(separator: "\u{0}"))
        }

        private static func appendBinding(_ node: Node, to pieces: inout [String]) {
            pieces.append(node.path)
            pieces.append(String(node.device))
            pieces.append(String(node.inode))
            pieces.append(String(node.owner))
            pieces.append(String(node.kind))
            pieces.append(String(node.size))
            pieces.append(String(node.linkCount))
            pieces.append(String(node.modifiedNanos))
            pieces.append(String(node.changedNanos))
            pieces.append(node.digest ?? "directory")
        }

        private static func stableDirectoryNode(path: String, expectedKind: mode_t) throws -> Node {
            var status = stat()
            guard lstat(path, &status) == 0,
                  status.st_mode & mode_t(S_IFMT) == expectedKind,
                  status.st_uid == geteuid() else { throw EvolutionCommitError.unsafeGitControl }
            return Node(path: path, device: UInt64(status.st_dev), inode: UInt64(status.st_ino),
                        owner: UInt32(status.st_uid), kind: UInt32(status.st_mode & mode_t(S_IFMT)),
                        size: Int64(status.st_size), linkCount: UInt64(status.st_nlink),
                        modifiedNanos: 0, changedNanos: 0, digest: nil)
        }

        private static func stableRegularNode(path: String, maxBytes: Int) throws
            -> (node: Node, bytes: Data) {
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw EvolutionCommitError.unsafeGitControl }
            defer { close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0,
                  before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  before.st_uid == geteuid(), before.st_nlink == 1,
                  before.st_size >= 0, before.st_size <= maxBytes else {
                throw EvolutionCommitError.unsafeGitControl
            }
            var data = Data(count: Int(before.st_size))
            var offset = 0
            let ok = data.withUnsafeMutableBytes { raw -> Bool in
                while offset < raw.count {
                    let count = read(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
            var after = stat()
            guard ok, fstat(fd, &after) == 0, before.st_dev == after.st_dev,
                  before.st_ino == after.st_ino, before.st_size == after.st_size,
                  before.st_nlink == after.st_nlink,
                  sameModificationTime(before, after), sameChangeTime(before, after) else {
                throw EvolutionCommitError.unsafeGitControl
            }
            let digest = MythosCrypto.sha256(data).map { String(format: "%02x", $0) }.joined()
            return (Node(
                path: path, device: UInt64(after.st_dev), inode: UInt64(after.st_ino),
                owner: UInt32(after.st_uid), kind: UInt32(after.st_mode & mode_t(S_IFMT)),
                size: Int64(after.st_size), linkCount: UInt64(after.st_nlink),
                modifiedNanos: modificationNanos(after), changedNanos: changeNanos(after),
                digest: digest), data)
        }

        private static func sameModificationTime(_ lhs: stat, _ rhs: stat) -> Bool {
            #if canImport(Darwin)
            return lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
                && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            #else
            return lhs.st_mtim.tv_sec == rhs.st_mtim.tv_sec
                && lhs.st_mtim.tv_nsec == rhs.st_mtim.tv_nsec
            #endif
        }

        private static func sameChangeTime(_ lhs: stat, _ rhs: stat) -> Bool {
            changeNanos(lhs) == changeNanos(rhs)
        }

        private static func modificationNanos(_ value: stat) -> Int64 {
            #if canImport(Darwin)
            return Int64(value.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(value.st_mtimespec.tv_nsec)
            #else
            return Int64(value.st_mtim.tv_sec) * 1_000_000_000
                + Int64(value.st_mtim.tv_nsec)
            #endif
        }

        private static func changeNanos(_ value: stat) -> Int64 {
            #if canImport(Darwin)
            return Int64(value.st_ctimespec.tv_sec) * 1_000_000_000
                + Int64(value.st_ctimespec.tv_nsec)
            #else
            return Int64(value.st_ctim.tv_sec) * 1_000_000_000
                + Int64(value.st_ctim.tv_nsec)
            #endif
        }

        /// Accept only the small local-config surface needed for local
        /// status/add/commit/worktree operations. Unknown sections/keys and
        /// every include mechanism fail closed; the accepted bytes are then
        /// bound into `bindingDigest` and revalidated around each Git child.
        private static func localConfigurationIsSafe(_ data: Data) -> Bool {
            guard data.count <= 1_048_576,
                  let text = String(data: data, encoding: .utf8),
                  !text.unicodeScalars.contains(where: { scalar in
                      CharacterSet.controlCharacters.contains(scalar)
                          && scalar != "\n" && scalar != "\r" && scalar != "\t"
                  }) else { return false }

            var section: String?
            var repositoryFormat: String?
            var objectFormat: String?
            for rawLine in text.split(
                omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }
            ) {
                let raw = String(rawLine)
                guard raw.utf8.count <= 4_096, !raw.hasSuffix("\\") else { return false }
                let line = raw.trimmingCharacters(in: CharacterSet.whitespaces)
                if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
                if line.hasPrefix("[") {
                    guard line.hasSuffix("]") else { return false }
                    let header = String(line.dropFirst().dropLast()).lowercased()
                    let simple = ["core", "user", "extensions"].contains(header)
                    let subsection = (header.hasPrefix("remote \"")
                        || header.hasPrefix("branch \""))
                        && header.hasSuffix("\"")
                        && header.count > (header.hasPrefix("remote") ? 9 : 9)
                        && !header.contains("\\")
                    guard simple || subsection else { return false }
                    section = header
                    continue
                }

                guard let section,
                      let equals = line.firstIndex(of: "=") else { return false }
                let key = line[..<equals]
                    .trimmingCharacters(in: CharacterSet.whitespaces).lowercased()
                let value = line[line.index(after: equals)...]
                    .trimmingCharacters(in: CharacterSet.whitespaces)
                guard !key.isEmpty, key.utf8.count <= 256,
                      value.utf8.count <= 3_584 else { return false }
                let lowerValue = value.lowercased()
                let boolean = lowerValue == "true" || lowerValue == "false"

                switch section {
                case "core":
                    switch key {
                    case "repositoryformatversion":
                        guard lowerValue == "0" || lowerValue == "1" else { return false }
                        repositoryFormat = lowerValue
                    case "bare":
                        guard lowerValue == "false" else { return false }
                    case "filemode", "logallrefupdates", "ignorecase", "precomposeunicode":
                        guard boolean else { return false }
                    default:
                        return false
                    }
                case "user":
                    if key == "name" || key == "email" { break }
                    guard key == "useconfigonly", boolean else { return false }
                case "extensions":
                    guard key == "objectformat", lowerValue == "sha256" else { return false }
                    objectFormat = lowerValue
                default:
                    if section.hasPrefix("remote \"") {
                        guard key == "url" || key == "fetch" else { return false }
                    } else if section.hasPrefix("branch \"") {
                        guard key == "remote" || key == "merge" else { return false }
                    } else {
                        return false
                    }
                }
            }
            guard let repositoryFormat else { return false }
            return repositoryFormat == "0" || objectFormat == "sha256"
        }
    }

    private struct EvolutionGitResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
        let truncated: Bool
        let controlStable: Bool
        var succeeded: Bool {
            exitCode == 0 && !timedOut && !truncated && controlStable
        }
    }

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

    /// Create an isolated branch from one exact commit rather than from the source checkout's HEAD.
    /// The commit must be a canonical full SHA that resolves to a commit in this repository. This is
    /// intentionally a separate overload so ordinary fleet callers retain their HEAD-seed behavior,
    /// while evolution descendants can inherit the selected parent's actual bytes.
    public static func makeWorktree(repo: String, label: String, nowEpoch: Double,
                                    baseCommit: String) -> GitWorktree? {
        guard isCanonicalCommitSHA(baseCommit), let canonicalRepo = ToolContext.canonicalize(repo),
              let control = try? EvolutionGitControlIdentity.capture(worktreePath: canonicalRepo) else {
            return nil
        }
        let resolved = runEvolutionGit(
            ["rev-parse", "--verify", "--quiet", "\(baseCommit)^{commit}"], cwd: canonicalRepo,
            control: control, worktreePath: canonicalRepo)
        let base = resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolved.succeeded, base == baseCommit else { return nil }

        let slug = sanitize(label)
        let uniq = UUID().uuidString.prefix(8)
        let branch = "mythos/auto-\(slug)-\(Int(nowEpoch))-\(uniq)"
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("mythos-wt-\(slug)-\(Int(nowEpoch))-\(uniq)")
        let added = runEvolutionGit(
            ["worktree", "add", "-b", branch, path, base], cwd: canonicalRepo,
            control: control, worktreePath: canonicalRepo,
            allowExpectedWorktreeDirectoryMutation: true)
        guard added.succeeded else { return nil }
        guard let canonicalPath = ToolContext.canonicalize(path),
              (try? EvolutionGitControlIdentity.capture(worktreePath: canonicalPath)) != nil else {
            if let refreshed = try? EvolutionGitControlIdentity.capture(worktreePath: canonicalRepo) {
                _ = runEvolutionGit(
                    ["worktree", "remove", "--force", path], cwd: canonicalRepo,
                    control: refreshed, worktreePath: canonicalRepo,
                    allowExpectedWorktreeDirectoryMutation: true)
            }
            return nil
        }
        return GitWorktree(repo: canonicalRepo, path: canonicalPath, branch: branch, base: base)
    }

    /// Bind an archived evolution parent to a live, local evolution branch in this exact repository.
    /// Archive metadata alone is untrusted: the branch must have Kist's evolution prefix, be a safe
    /// local ref name, and its current tip must exactly equal the archived full commit SHA. A deleted,
    /// advanced, forged, or cross-ref record therefore fails closed instead of becoming fake ancestry.
    public static func validateEvolutionParentRef(repo: String, branch: String,
                                                  expectedCommitSHA: String) -> EvolutionParentRefValidation {
        guard let control = try? EvolutionGitControlIdentity.capture(worktreePath: repo) else {
            return .invalid(reason: "source git control identity is invalid")
        }
        let candidateBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let evolutionPrefix = "mythos/auto-evolve-"
        guard candidateBranch == branch,
              candidateBranch.hasPrefix(evolutionPrefix), candidateBranch.count > evolutionPrefix.count,
              isSafeLocalBranchName(candidateBranch) else {
            return .invalid(reason: "archive branch is not a safe Kist evolution branch")
        }
        guard isCanonicalCommitSHA(expectedCommitSHA) else {
            return .invalid(reason: "archive commit is not a canonical full SHA")
        }

        let ref = "refs/heads/\(candidateBranch)^{commit}"
        let resolved = runEvolutionGit(
            ["rev-parse", "--verify", "--quiet", ref], cwd: repo,
            control: control, worktreePath: repo)
        let liveCommit = resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolved.succeeded, !liveCommit.isEmpty else {
            return .invalid(reason: "archive evolution branch is missing from this repository")
        }
        guard liveCommit == expectedCommitSHA else {
            return .invalid(reason: "archive commit does not match the live evolution branch tip")
        }
        return .valid(commitSHA: liveCommit)
    }

    /// Fixed-binary/config-free evolution HEAD resolution. This is the only entry-point the DGM uses;
    /// ambient PATH, HOME, Git config, replacements, hooks, filters, pagers, and fsmonitor are disabled.
    public static func evolutionHeadSHA(repo: String) -> String? {
        guard let canonical = ToolContext.canonicalize(repo),
              let control = try? EvolutionGitControlIdentity.capture(worktreePath: canonical) else {
            return nil
        }
        let result = runEvolutionGit(
            ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
            cwd: canonical, control: control, worktreePath: canonical)
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && isCanonicalCommitSHA(value) ? value : nil
    }

    /// Bounded exact output bindings for the protected-host snapshot. Callers receive digests/counts,
    /// never unbounded Git text, and every command runs through the hardened evolution launcher.
    static func evolutionProtectedGitBindings(repo: String, commands: [[String]]) throws -> [String] {
        guard commands.count <= 32,
              let canonical = ToolContext.canonicalize(repo), canonical == repo else {
            throw EvolutionCommitError.invalidWorktree
        }
        let control = try EvolutionGitControlIdentity.capture(worktreePath: repo)
        guard preflightEvolutionGit(
            GitWorktree(repo: repo, path: repo, branch: "", base: ""),
            control: control) else { throw EvolutionCommitError.unsafeGitControl }
        var pieces: [String] = []
        for command in commands {
            let result = runEvolutionGit(
                command, cwd: repo, control: control, worktreePath: repo)
            guard result.succeeded else { throw EvolutionCommitError.untrustedGitRuntime }
            pieces += [BuilderEvidenceDigest.sha256(result.stdout),
                       String(result.stdout.utf8.count),
                       BuilderEvidenceDigest.sha256(result.stderr),
                       String(result.stderr.utf8.count)]
        }
        return pieces
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

    /// Persist one evolution candidate and return the exact immutable bytes eligible for evaluation.
    /// Every git step is checked, the resulting worktree must be clean (including non-ignored untracked
    /// files), and both HEAD and the named branch must resolve to one new canonical commit.
    public static func commitEvolutionCandidate(_ wt: GitWorktree,
                                                message: String) throws -> EvolutionCommitSnapshot {
        guard isCanonicalCommitSHA(wt.base),
              isSafeLocalBranchName(wt.branch) else {
            throw EvolutionCommitError.invalidWorktree
        }
        let control = try EvolutionGitControlIdentity.capture(worktreePath: wt.path)
        guard preflightEvolutionGit(wt, control: control) else {
            throw EvolutionCommitError.unsafeGitControl
        }
        let before = runEvolutionGit([
            "status", "--porcelain=v1",
            "--untracked-files=all", "--ignore-submodules=none",
        ], cwd: wt.path, control: control, worktreePath: wt.path)
        guard before.succeeded else { throw EvolutionCommitError.untrustedGitRuntime }
        guard !before.stdout.isEmpty else { throw EvolutionCommitError.noChanges }
        guard runEvolutionGit(
            ["add", "--no-renormalize", "-A", "--"], cwd: wt.path,
            control: control, worktreePath: wt.path).succeeded else {
            throw EvolutionCommitError.addFailed
        }
        let commitControl = try EvolutionGitControlIdentity.capture(worktreePath: wt.path)
        guard preflightEvolutionGit(wt, control: commitControl) else {
            throw EvolutionCommitError.unsafeGitControl
        }
        guard runEvolutionGit(
            ["commit", "--no-verify", "--no-gpg-sign", "-m", message], cwd: wt.path,
            control: commitControl, worktreePath: wt.path,
            allowExpectedWorktreeDirectoryMutation: true).succeeded else {
            throw EvolutionCommitError.commitFailed
        }
        let finalControl = try EvolutionGitControlIdentity.capture(worktreePath: wt.path)
        return try captureEvolutionCandidate(wt, control: finalControl)
    }

    /// Re-attest the original candidate immediately before archive sealing. A benchmark, hook,
    /// lingering subprocess, or concurrent ref update that dirties or advances it invalidates the
    /// snapshot instead of laundering different bytes under the evaluated SHA.
    public static func validateEvolutionCandidate(
        _ wt: GitWorktree, expected: EvolutionCommitSnapshot
    ) throws {
        let control = try EvolutionGitControlIdentity.capture(worktreePath: wt.path)
        guard control.bindingDigest == expected.gitControlDigest else {
            throw EvolutionCommitError.snapshotMismatch
        }
        let current: EvolutionCommitSnapshot
        do { current = try captureEvolutionCandidate(wt, control: control) }
        catch { throw EvolutionCommitError.snapshotMismatch }
        guard current == expected else { throw EvolutionCommitError.snapshotMismatch }
    }

    /// Recompute the exact durable candidate from the live kept worktree. The archive calls this while
    /// holding its exclusive lock immediately before consuming the one-use evaluation receipt, so branch,
    /// commit, tree, control metadata, changed paths, and diff bytes are host-derived rather than caller data.
    public static func captureEvolutionArchiveCandidate(
        repo: String, worktreePath: String, branch: String, baseSHA: String
    ) throws -> EvolutionCommitSnapshot {
        guard isCanonicalCommitSHA(baseSHA), isSafeLocalBranchName(branch),
              let canonicalRepo = ToolContext.canonicalize(repo),
              let canonicalWorktree = ToolContext.canonicalize(worktreePath),
              canonicalRepo == repo, canonicalWorktree == worktreePath else {
            throw EvolutionCommitError.invalidWorktree
        }
        let wt = GitWorktree(repo: repo, path: worktreePath, branch: branch, base: baseSHA)
        let control = try EvolutionGitControlIdentity.capture(worktreePath: worktreePath)
        return try captureEvolutionCandidate(wt, control: control)
    }

    /// Verify a detached evaluator still points at the exact commit and has no staged, tracked, or
    /// unexpected untracked mutation. Only files below the host-created generated-output directory
    /// are tolerated; candidate source and control bytes remain immutable.
    public static func validateEvolutionVerificationWorkspace(
        _ wt: GitWorktree, expectedCommitSHA: String, expectedTreeSHA: String,
        generatedOutput: String = ".build"
    ) -> Bool {
        guard isCanonicalCommitSHA(expectedCommitSHA), isCanonicalCommitSHA(expectedTreeSHA),
              !generatedOutput.isEmpty, !generatedOutput.hasPrefix("-"),
              !generatedOutput.contains("/"), generatedOutput != ".", generatedOutput != ".." else {
            return false
        }
        guard let control = try? EvolutionGitControlIdentity.capture(worktreePath: wt.path),
              preflightEvolutionGit(wt, control: control) else { return false }
        let head = runEvolutionGit(
            ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], cwd: wt.path,
            control: control, worktreePath: wt.path)
        let tracked = runEvolutionGit(
            ["diff", "--quiet", "--no-ext-diff", "HEAD", "--"], cwd: wt.path,
            control: control, worktreePath: wt.path)
        let staged = runEvolutionGit(
            ["diff", "--cached", "--quiet", "--no-ext-diff", "HEAD", "--"], cwd: wt.path,
            control: control, worktreePath: wt.path)
        let tree = runEvolutionGit(
            ["rev-parse", "--verify", "--quiet", "HEAD^{tree}"], cwd: wt.path,
            control: control, worktreePath: wt.path)
        guard head.succeeded, tree.succeeded,
              head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == expectedCommitSHA,
              tree.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == expectedTreeSHA,
              tracked.succeeded, staged.succeeded else { return false }
        let untracked = runEvolutionGit(
            ["ls-files", "--others", "--exclude-standard", "-z", "--"], cwd: wt.path,
            control: control, worktreePath: wt.path)
        guard untracked.succeeded else { return false }
        return untracked.stdout.split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
            .allSatisfy { $0 == generatedOutput || $0.hasPrefix(generatedOutput + "/") }
    }

    private static func captureEvolutionCandidate(
        _ wt: GitWorktree, control: EvolutionGitControlIdentity
    ) throws -> EvolutionCommitSnapshot {
        guard preflightEvolutionGit(wt, control: control) else {
            throw EvolutionCommitError.unsafeGitControl
        }
        let clean = runEvolutionGit([
            "status", "--porcelain=v1",
            "--untracked-files=all", "--ignore-submodules=none",
        ], cwd: wt.path, control: control, worktreePath: wt.path)
        guard clean.succeeded else { throw EvolutionCommitError.untrustedGitRuntime }
        guard clean.stdout.isEmpty else { throw EvolutionCommitError.dirtyAfterCommit }

        let headResult = runEvolutionGit(
            ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], cwd: wt.path,
            control: control, worktreePath: wt.path)
        let head = headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard headResult.succeeded, isCanonicalCommitSHA(head) else {
            throw EvolutionCommitError.invalidCommitSHA
        }
        guard head != wt.base else { throw EvolutionCommitError.baseCommitReused }
        let ancestor = runEvolutionGit(
            ["merge-base", "--is-ancestor", wt.base, head], cwd: wt.path,
            control: control, worktreePath: wt.path)
        let parents = runEvolutionGit(
            ["rev-list", "--parents", "-n", "1", head], cwd: wt.path,
            control: control, worktreePath: wt.path)
        let parentFields = parents.stdout.split(whereSeparator: { $0 == " " || $0 == "\n" })
            .map(String.init)
        guard ancestor.succeeded, parents.succeeded, parentFields.count == 2,
              parentFields[0] == head, parentFields[1] == wt.base else {
            throw EvolutionCommitError.nonLinearCandidate
        }
        let treeResult = runEvolutionGit(
            ["rev-parse", "--verify", "--quiet", "\(head)^{tree}"], cwd: wt.path,
            control: control, worktreePath: wt.path)
        let tree = treeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let commitType = runEvolutionGit(
            ["cat-file", "-t", head], cwd: wt.path, control: control, worktreePath: wt.path)
        let treeType = runEvolutionGit(
            ["cat-file", "-t", tree], cwd: wt.path, control: control, worktreePath: wt.path)
        guard treeResult.succeeded, isCanonicalCommitSHA(tree), commitType.succeeded,
              commitType.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "commit",
              treeType.succeeded,
              treeType.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "tree" else {
            throw EvolutionCommitError.objectBindingMismatch
        }
        let symbolic = runEvolutionGit(
            ["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: wt.path,
            control: control, worktreePath: wt.path)
        let branch = symbolic.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = runEvolutionGit([
            "rev-parse", "--verify", "--quiet",
            "refs/heads/\(wt.branch)^{commit}",
        ], cwd: wt.repo, control: control, worktreePath: wt.path)
        guard symbolic.succeeded, branch == wt.branch, ref.succeeded,
              ref.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == head else {
            throw EvolutionCommitError.branchMismatch
        }

        let changedResult = runEvolutionGit([
            "diff", "--name-only", "\(wt.base)...\(head)",
        ], cwd: wt.path, control: control, worktreePath: wt.path)
        let diffResult = runEvolutionGit([
            "diff", "--text", "--no-ext-diff", "--no-textconv",
            "\(wt.base)...\(head)",
        ], cwd: wt.path, control: control, worktreePath: wt.path)
        guard changedResult.succeeded, diffResult.succeeded else {
            throw EvolutionCommitError.invalidWorktree
        }
        let changed = changedResult.stdout.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted()
        guard !changed.isEmpty,
              !diffResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EvolutionCommitError.emptyCommittedChange
        }
        return EvolutionCommitSnapshot(
            baseSHA: wt.base, commitSHA: head, treeSHA: tree,
            gitControlDigest: control.bindingDigest, branch: wt.branch,
            changedFiles: changed, committedDiff: diffResult.stdout)
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
        guard run(["git", "-C", wt.path, "add", "-A", "--"], cwd: wt.path).exitCode == 0 else {
            return false
        }
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

    /// Fresh detached verification copy at one exact durable commit. The source worktree is never
    /// benchmarked in place, so candidate tests/plugins cannot rewrite the bytes that will be sealed.
    public static func detachedWorktree(repo: String, commitSHA: String,
                                        baseSHA: String) -> GitWorktree? {
        guard isCanonicalCommitSHA(commitSHA), isCanonicalCommitSHA(baseSHA),
              let canonicalRepo = ToolContext.canonicalize(repo),
              let control = try? EvolutionGitControlIdentity.capture(worktreePath: canonicalRepo) else {
            return nil
        }
        let resolved = runEvolutionGit(
            ["rev-parse", "--verify", "--quiet", "\(commitSHA)^{commit}"], cwd: canonicalRepo,
            control: control, worktreePath: canonicalRepo)
        guard resolved.succeeded,
              resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == commitSHA else {
            return nil
        }
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("mythos-evolution-verify-\(UUID().uuidString.prefix(8))")
        let added = runEvolutionGit(
            ["worktree", "add", "--detach", dir, commitSHA], cwd: canonicalRepo,
            control: control, worktreePath: canonicalRepo,
            allowExpectedWorktreeDirectoryMutation: true)
        guard added.succeeded else { return nil }
        guard let canonicalDir = ToolContext.canonicalize(dir),
              (try? EvolutionGitControlIdentity.capture(worktreePath: canonicalDir)) != nil else {
            if let refreshed = try? EvolutionGitControlIdentity.capture(worktreePath: canonicalRepo) {
                _ = runEvolutionGit(
                    ["worktree", "remove", "--force", dir], cwd: canonicalRepo,
                    control: refreshed, worktreePath: canonicalRepo,
                    allowExpectedWorktreeDirectoryMutation: true)
            }
            return nil
        }
        return GitWorktree(repo: canonicalRepo, path: canonicalDir, branch: "", base: baseSHA)
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
    @discardableResult
    public static func removeWorktree(_ wt: GitWorktree) -> Bool {
        if wt.path.contains("mythos-evolution-verify-"),
           let control = try? EvolutionGitControlIdentity.capture(worktreePath: wt.repo) {
            return runEvolutionGit(
                ["worktree", "remove", "--force", wt.path], cwd: wt.repo,
                control: control, worktreePath: wt.repo,
                allowExpectedWorktreeDirectoryMutation: true).succeeded
        }
        return run(["git", "-C", wt.repo, "worktree", "remove", "--force", wt.path], cwd: wt.repo)
            .exitCode == 0
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

    /// Full, lowercase object IDs only. Kist-generated archive records use `git rev-parse HEAD`, so
    /// accepting abbreviations or revision syntax here would make the archive-to-ref equality ambiguous.
    /// Both Git SHA-1 and SHA-256 repository object formats are supported.
    private static func isCanonicalCommitSHA(_ value: String) -> Bool {
        guard value.count == 40 || value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
        }
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

    /// Evolution-only git launcher. It never consults PATH/global/system config, never runs hooks,
    /// signing, fsmonitor, or external diff, and every call is timeout/output/process-group bounded.
    /// The linked-worktree gitfile and gitdir/common-dir identities are checked immediately before and
    /// after the child so a candidate cannot redirect host git through a fake control directory.
    private static func runEvolutionGit(
        _ command: [String], cwd: String, control: EvolutionGitControlIdentity,
        worktreePath: String, timeoutSeconds: Int = 30,
        allowExpectedWorktreeDirectoryMutation: Bool = false
    ) -> EvolutionGitResult {
        guard control.validate(worktreePath: worktreePath),
              let git = trustedGitPath() else {
            return EvolutionGitResult(exitCode: -1, stdout: "", stderr: "untrusted git/control",
                                      timedOut: false, truncated: false, controlStable: false)
        }
        let privateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-evolution-git-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: privateRoot, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            guard chmod(privateRoot.path, 0o700) == 0 else { throw EvolutionCommitError.untrustedGitRuntime }
        } catch {
            return EvolutionGitResult(exitCode: -1, stdout: "", stderr: "private git env unavailable",
                                      timedOut: false, truncated: false, controlStable: false)
        }
        defer { try? FileManager.default.removeItem(at: privateRoot) }
        let env: [String: String] = [
            "PATH": "/usr/bin:/bin", "HOME": privateRoot.path,
            "XDG_CONFIG_HOME": privateRoot.path, "XDG_CACHE_HOME": privateRoot.path,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_ATTR_NOSYSTEM": "1", "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false",
            "GIT_PAGER": "cat", "GIT_EDITOR": "/usr/bin/true",
            "GIT_SEQUENCE_EDITOR": "/usr/bin/true", "LC_ALL": "C", "LANG": "C",
        ]
        let trustedOptions = [
            "--no-pager", "--no-replace-objects",
            "-c", "core.hooksPath=/dev/null",
            "-c", "commit.gpgSign=false", "-c", "tag.gpgSign=false",
            "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
            "-c", "core.attributesFile=/dev/null", "-c", "diff.external=",
            "-c", "core.pager=cat", "-c", "pager.status=false",
            "-c", "advice.detachedHead=false", "-C", cwd,
        ]
        let outcome = ProcessGroupRunner.run(
            launchPath: git, launchArgs: trustedOptions + command, cwd: cwd, env: env,
            timeoutSeconds: max(1, min(timeoutSeconds, 60)), capPerStream: 8 * 1_024 * 1_024,
            graceSeconds: 1)
        return EvolutionGitResult(
            exitCode: outcome.exitCode, stdout: outcome.stdout, stderr: outcome.stderr,
            timedOut: outcome.timedOut, truncated: outcome.outputTruncated,
            controlStable: allowExpectedWorktreeDirectoryMutation
                ? control.validatesExpectedWorktreeDirectoryMutation(worktreePath: worktreePath)
                : control.validate(worktreePath: worktreePath))
    }

    private static func trustedGitPath() -> String? {
        #if os(macOS)
        let candidates = ["/usr/bin/git"]
        #else
        let candidates = ["/usr/bin/git", "/bin/git"]
        #endif
        for path in candidates {
            var status = stat()
            if lstat(path, &status) == 0,
               status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
               status.st_uid == 0, (status.st_mode & mode_t(0o022)) == 0,
               FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func preflightEvolutionGit(
        _ wt: GitWorktree, control: EvolutionGitControlIdentity
    ) -> Bool {
        guard control.validate(worktreePath: wt.path) else { return false }
        do {
            let confined = try ConfinedRoot(root: wt.path)
            var unsafe = false
            try confined.walk(".", skipDirs: [".git", ".build"]) { path, _ in
                let basename = (path.precomposedStringWithCanonicalMapping.lowercased() as NSString)
                    .lastPathComponent
                if basename == ".gitattributes" || basename == ".gitmodules" { unsafe = true }
            }
            guard !unsafe else { return false }
        } catch { return false }

        for gitPath in ["info/attributes", "info/grafts", "objects/info/alternates"] {
            let resolved = runEvolutionGit(
                ["rev-parse", "--git-path", gitPath], cwd: wt.path,
                control: control, worktreePath: wt.path)
            guard resolved.succeeded else { return false }
            let raw = resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return false }
            let path = raw.hasPrefix("/") ? raw
                : URL(fileURLWithPath: wt.path, isDirectory: true)
                    .appendingPathComponent(raw).standardizedFileURL.path
            if FileManager.default.fileExists(atPath: path) { return false }
        }
        let filters = runEvolutionGit(
            ["config", "--local", "--name-only", "--get-regexp", "^filter\\."],
            cwd: wt.path, control: control, worktreePath: wt.path)
        guard filters.controlStable, !filters.timedOut, !filters.truncated,
              (filters.exitCode == 1 || (filters.exitCode == 0
                && filters.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) else {
            return false
        }
        let replacements = runEvolutionGit(
            ["for-each-ref", "--format=%(refname)", "refs/replace"], cwd: wt.path,
            control: control, worktreePath: wt.path)
        return replacements.succeeded
            && replacements.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && control.validate(worktreePath: wt.path)
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
