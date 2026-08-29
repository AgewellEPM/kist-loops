import Foundation

/// Creates the filesystem side of one DGM lineage edge. Parent metadata is not ancestry until the
/// host proves that it names a live Kist evolution ref at the archived commit and creates the child
/// from that exact object. A rejected parent never degrades into an unlabeled HEAD-based child.
public enum EvolutionLineageWorkspace {
    public struct Child: Equatable, Sendable {
        public let worktree: GitWorktree
        public let parentID: String?

        public init(worktree: GitWorktree, parentID: String?) {
            self.worktree = worktree
            self.parentID = parentID
        }
    }

    public enum CreationError: Error, Equatable, LocalizedError, Sendable {
        case ineligibleParent(candidateID: String)
        case unauthoritativeParent(candidateID: String)
        case crossProjectParent(candidateID: String)
        case rootSeedNoLongerAuthoritative
        case invalidParentRef(candidateID: String, reason: String)
        case worktreeCreationFailed(baseCommitSHA: String)
        case worktreeBaseMismatch(expected: String, actual: String)

        public var errorDescription: String? {
            switch self {
            case .ineligibleParent(let candidateID):
                return "archive parent \(candidateID) is no longer eligible for evolution"
            case .unauthoritativeParent(let candidateID):
                return "archive parent \(candidateID) has no valid host-minted archive authority"
            case .crossProjectParent(let candidateID):
                return "archive parent \(candidateID) belongs to a different project"
            case .rootSeedNoLongerAuthoritative:
                return "evolution archive no longer authorizes a root seed"
            case .invalidParentRef(let candidateID, let reason):
                return "archive parent \(candidateID) failed ref validation: \(reason)"
            case .worktreeCreationFailed(let baseCommitSHA):
                return "could not create an isolated evolution worktree at \(baseCommitSHA)"
            case .worktreeBaseMismatch(let expected, let actual):
                return "evolution worktree base mismatch: expected \(expected), got \(actual)"
            }
        }
    }

    /// `selectedParent == nil` is the only root-seed path. When a parent was selected, every failure
    /// throws and the caller must skip the candidate; silently falling back to the root would fabricate
    /// an inherited lineage edge. The ref is checked both before and after worktree creation so a branch
    /// that moves during setup is rejected and the partial child is discarded.
    public static func createChild(repo: String,
                                   label: String,
                                   nowEpoch: Double,
                                   rootCommitSHA: String,
                                   selectedParent: EvolutionCandidateRecord?) throws -> Child {
        guard let selectedParent else {
            guard isCurrentRootSeed(repo: repo) else {
                throw CreationError.rootSeedNoLongerAuthoritative
            }
            let worktree = try makePinnedWorktree(repo: repo, label: label, nowEpoch: nowEpoch,
                                                  baseCommitSHA: rootCommitSHA)
            guard isCurrentRootSeed(repo: repo) else {
                _ = GitIsolation.discard(worktree)
                throw CreationError.rootSeedNoLongerAuthoritative
            }
            return Child(worktree: worktree, parentID: nil)
        }

        guard selectedParent.hasValidArchiveAuthority else {
            throw CreationError.unauthoritativeParent(candidateID: selectedParent.candidateID)
        }
        let projectIdentity: String
        do { projectIdentity = try AcceptedRunReceipt.computeProjectIdentity(projectRoot: repo) }
        catch { throw CreationError.crossProjectParent(candidateID: selectedParent.candidateID) }
        guard selectedParent.projectIdentity == projectIdentity else {
            throw CreationError.crossProjectParent(candidateID: selectedParent.candidateID)
        }
        guard isCurrentAuthoritativeMember(selectedParent, repo: repo) else {
            throw CreationError.unauthoritativeParent(candidateID: selectedParent.candidateID)
        }
        guard EvolutionParentSelector.eligibleParents([selectedParent]) == [selectedParent] else {
            throw CreationError.ineligibleParent(candidateID: selectedParent.candidateID)
        }

        let parentCommit: String
        switch GitIsolation.validateEvolutionParentRef(repo: repo, branch: selectedParent.branch,
                                                       expectedCommitSHA: selectedParent.commitSHA) {
        case .valid(let commitSHA):
            parentCommit = commitSHA
        case .invalid(let reason):
            throw CreationError.invalidParentRef(candidateID: selectedParent.candidateID, reason: reason)
        }

        let worktree = try makePinnedWorktree(repo: repo, label: label, nowEpoch: nowEpoch,
                                              baseCommitSHA: parentCommit)
        switch GitIsolation.validateEvolutionParentRef(repo: repo, branch: selectedParent.branch,
                                                       expectedCommitSHA: parentCommit) {
        case .valid:
            guard isCurrentAuthoritativeMember(selectedParent, repo: repo) else {
                _ = GitIsolation.discard(worktree)
                throw CreationError.unauthoritativeParent(candidateID: selectedParent.candidateID)
            }
            return Child(worktree: worktree, parentID: selectedParent.candidateID)
        case .invalid(let reason):
            _ = GitIsolation.discard(worktree)
            throw CreationError.invalidParentRef(candidateID: selectedParent.candidateID, reason: reason)
        }
    }

    private static func isCurrentAuthoritativeMember(_ parent: EvolutionCandidateRecord,
                                                     repo: String) -> Bool {
        let snapshot = EvolutionArchiveStore(root: repo).snapshot()
        guard !snapshot.state.isInvalid else { return false }
        return snapshot.authoritativeRecords.contains(parent)
    }

    private static func isCurrentRootSeed(repo: String) -> Bool {
        let snapshot = EvolutionArchiveStore(root: repo).snapshot()
        guard !snapshot.state.isInvalid else { return false }
        return EvolutionParentSelector.eligibleParents(snapshot.authoritativeRecords).isEmpty
    }

    private static func makePinnedWorktree(repo: String,
                                           label: String,
                                           nowEpoch: Double,
                                           baseCommitSHA: String) throws -> GitWorktree {
        guard let worktree = GitIsolation.makeWorktree(repo: repo, label: label, nowEpoch: nowEpoch,
                                                       baseCommit: baseCommitSHA) else {
            throw CreationError.worktreeCreationFailed(baseCommitSHA: baseCommitSHA)
        }
        let actualHead = EvolutionLab.headSHA(worktreePath: worktree.path)
        guard worktree.base == baseCommitSHA, actualHead == baseCommitSHA else {
            _ = GitIsolation.discard(worktree)
            throw CreationError.worktreeBaseMismatch(expected: baseCommitSHA, actual: actualHead)
        }
        return worktree
    }
}
