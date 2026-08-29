import Foundation
import XCTest
@testable import AgentCore

/// Real-git proof that DGM ancestry is a byte-level branch relationship, not prompt metadata.
final class EvolutionLineageWorkspaceTests: XCTestCase {
    @discardableResult
    private func git(_ args: [String], cwd: URL) -> (Int32, String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = cwd
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return nil
        }
    }

    private func makeRepo() throws -> URL? {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("evolution-lineage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        guard git(["init"], cwd: repo)?.0 == 0 else { return nil }
        _ = git(["config", "user.email", "lineage@test.invalid"], cwd: repo)
        _ = git(["config", "user.name", "Lineage Test"], cwd: repo)
        try "root\n".write(to: repo.appendingPathComponent("ROOT.txt"), atomically: true, encoding: .utf8)
        _ = git(["add", "-A"], cwd: repo)
        guard git(["commit", "-m", "root seed"], cwd: repo)?.0 == 0 else { return nil }
        return repo
    }

    private func head(_ path: String) -> String {
        EvolutionLab.headSHA(worktreePath: path)
    }

    private func parentRecord(_ worktree: GitWorktree,
                              candidateID: String = "parent",
                              branch: String? = nil,
                              commitSHA: String? = nil,
                              status: EvolutionCandidateStatus = .passed) -> EvolutionCandidateRecord {
        let unsigned = EvolutionCandidateRecord(
            runID: "parent-run",
            candidateID: candidateID,
            parentID: nil,
            objective: "improve the agent",
            branch: branch ?? worktree.branch,
            worktreePath: worktree.path,
            baseSHA: worktree.base,
            commitSHA: commitSHA ?? head(worktree.path),
            status: status,
            score: 125,
            changedFiles: ["PARENT_ONLY.txt"],
            protectedFiles: [],
            benchmarks: [],
            summary: "synthetic eligible parent",
            createdAtEpoch: 1
        )
        return try! EvolutionArchiveStore(root: worktree.repo).append(
            EvolutionTestAuthority.authoritative(unsigned))
    }

    private func makeParent(in repo: URL, label: String = "evolve-parent",
                            content: String = "parent bytes\n") throws -> GitWorktree {
        let parent = try XCTUnwrap(
            GitIsolation.makeWorktree(repo: repo.path, label: label, nowEpoch: 1_700_000_000),
            "real git repo must yield an evolution parent worktree"
        )
        try content.write(
            to: URL(fileURLWithPath: parent.path).appendingPathComponent("PARENT_ONLY.txt"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(GitIsolation.commit(parent, message: "parent-only change"))
        return parent
    }

    private func branchNames(in repo: URL) -> Set<String> {
        let output = git(["branch", "--format=%(refname:short)"], cwd: repo)?.1 ?? ""
        return Set(output.split(separator: "\n").map(String.init))
    }

    private func assertInvalidParent(_ parent: EvolutionCandidateRecord,
                                     repo: URL,
                                     rootCommit: String,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        let branchesBefore = branchNames(in: repo)
        XCTAssertThrowsError(
            try EvolutionLineageWorkspace.createChild(
                repo: repo.path,
                label: "evolve-child",
                nowEpoch: 1_700_000_100,
                rootCommitSHA: rootCommit,
                selectedParent: parent
            ),
            file: file,
            line: line
        ) { error in
            guard let creationError = error as? EvolutionLineageWorkspace.CreationError,
                  case .invalidParentRef = creationError else {
                return XCTFail("expected invalidParentRef, got \(error)", file: file, line: line)
            }
        }
        XCTAssertEqual(branchNames(in: repo), branchesBefore,
                       "a refused parent must not leave a child branch", file: file, line: line)
    }

    func testInheritedChildStartsAtExactParentCommitAndContainsParentOnlyBytes() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let rootCommit = head(repo.path)
        let parent = try makeParent(in: repo)
        defer { _ = GitIsolation.discard(parent) }
        let parentCommit = head(parent.path)
        XCTAssertNotEqual(parentCommit, rootCommit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("PARENT_ONLY.txt").path),
                       "the parent-only change must not exist at repository HEAD")

        let child = try EvolutionLineageWorkspace.createChild(
            repo: repo.path,
            label: "evolve-child",
            nowEpoch: 1_700_000_100,
            rootCommitSHA: rootCommit,
            selectedParent: parentRecord(parent)
        )
        defer { _ = GitIsolation.discard(child.worktree) }

        XCTAssertEqual(child.parentID, "parent")
        XCTAssertEqual(child.worktree.base, parentCommit)
        XCTAssertEqual(head(child.worktree.path), parentCommit,
                       "the child must exist at the selected parent's exact commit before any edit")
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: child.worktree.path)
                .appendingPathComponent("PARENT_ONLY.txt"), encoding: .utf8),
            "parent bytes\n",
            "the child must inherit bytes that exist only on the parent branch"
        )

        try "child bytes\n".write(
            to: URL(fileURLWithPath: child.worktree.path).appendingPathComponent("CHILD_ONLY.txt"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(GitIsolation.commit(child.worktree, message: "child-only change"))
        XCTAssertEqual(GitIsolation.committedChangedPaths(child.worktree), ["CHILD_ONLY.txt"],
                       "base...HEAD must measure only the child's delta, not inherited parent bytes")
    }

    func testNoSelectedParentCreatesRootSeedWithoutInheritedLabel() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let rootCommit = head(repo.path)

        let child = try EvolutionLineageWorkspace.createChild(
            repo: repo.path,
            label: "evolve-root",
            nowEpoch: 1_700_000_101,
            rootCommitSHA: rootCommit,
            selectedParent: nil
        )
        defer { _ = GitIsolation.discard(child.worktree) }

        XCTAssertNil(child.parentID)
        XCTAssertEqual(child.worktree.base, rootCommit)
        XCTAssertEqual(head(child.worktree.path), rootCommit)
    }

    func testInvalidArchiveCannotMasqueradeAsEmptyRootSeed() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let rootCommit = head(repo.path)
        let store = EvolutionArchiveStore(root: repo.path)
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: store.archiveURL.path, contents: Data("{}\n".utf8),
            attributes: [.posixPermissions: 0o600]))

        XCTAssertThrowsError(try EvolutionLineageWorkspace.createChild(
            repo: repo.path, label: "evolve-root", nowEpoch: 1_700_000_104,
            rootCommitSHA: rootCommit, selectedParent: nil)) { error in
            XCTAssertEqual(error as? EvolutionLineageWorkspace.CreationError,
                           .rootSeedNoLongerAuthoritative)
        }
    }

    func testForgedArchiveCommitFailsClosed() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let rootCommit = head(repo.path)
        let parent = try makeParent(in: repo)
        defer { _ = GitIsolation.discard(parent) }
        let forged = parentRecord(parent, commitSHA: String(repeating: "a", count: 40))

        assertInvalidParent(forged, repo: repo, rootCommit: rootCommit)
    }

    func testStaleArchiveCommitFailsClosedAfterParentBranchAdvances() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let rootCommit = head(repo.path)
        let parent = try makeParent(in: repo)
        defer { _ = GitIsolation.discard(parent) }
        let stale = parentRecord(parent)

        try "new parent tip\n".write(
            to: URL(fileURLWithPath: parent.path).appendingPathComponent("PARENT_SECOND.txt"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(GitIsolation.commit(parent, message: "advance parent ref"))
        XCTAssertNotEqual(stale.commitSHA, head(parent.path))

        assertInvalidParent(stale, repo: repo, rootCommit: rootCommit)
    }

    func testCrossRefArchiveParentFailsClosed() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let rootCommit = head(repo.path)
        let parentA = try makeParent(in: repo, label: "evolve-parent-a", content: "parent A\n")
        defer { _ = GitIsolation.discard(parentA) }
        let parentB = try makeParent(in: repo, label: "evolve-parent-b", content: "parent B\n")
        defer { _ = GitIsolation.discard(parentB) }
        let crossRef = parentRecord(parentA, branch: parentB.branch, commitSHA: head(parentA.path))

        assertInvalidParent(crossRef, repo: repo, rootCommit: rootCommit)
    }

    func testMissingEvolutionBranchFailsClosed() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let rootCommit = head(repo.path)
        let parent = try makeParent(in: repo)
        let missing = parentRecord(parent)
        XCTAssertTrue(GitIsolation.discard(parent))

        assertInvalidParent(missing, repo: repo, rootCommit: rootCommit)
    }

    func testParentRemovedFromFullArchiveAuthorityBeforeCreationFailsClosed() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let rootCommit = head(repo.path)
        let parent = try makeParent(in: repo)
        defer { _ = GitIsolation.discard(parent) }
        let selected = parentRecord(parent)
        let store = EvolutionArchiveStore(root: repo.path)
        try FileManager.default.removeItem(at: store.archiveURL)
        try FileManager.default.removeItem(at: store.headURL)
        let branchesBefore = branchNames(in: repo)

        XCTAssertThrowsError(try EvolutionLineageWorkspace.createChild(
            repo: repo.path, label: "evolve-child", nowEpoch: 1_700_000_103,
            rootCommitSHA: rootCommit, selectedParent: selected)) { error in
            XCTAssertEqual(error as? EvolutionLineageWorkspace.CreationError,
                           .unauthoritativeParent(candidateID: "parent"))
        }
        XCTAssertEqual(branchNames(in: repo), branchesBefore)
    }

    func testIneligibleArchiveRecordCannotBypassTheSelectorBoundary() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let rootCommit = head(repo.path)
        let parent = try makeParent(in: repo)
        defer { _ = GitIsolation.discard(parent) }
        let blocked = parentRecord(parent, status: .blocked)
        let branchesBefore = branchNames(in: repo)

        XCTAssertThrowsError(
            try EvolutionLineageWorkspace.createChild(
                repo: repo.path,
                label: "evolve-child",
                nowEpoch: 1_700_000_102,
                rootCommitSHA: rootCommit,
                selectedParent: blocked
            )
        ) { error in
            XCTAssertEqual(error as? EvolutionLineageWorkspace.CreationError,
                           .ineligibleParent(candidateID: "parent"))
        }
        XCTAssertEqual(branchNames(in: repo), branchesBefore)
    }
}
