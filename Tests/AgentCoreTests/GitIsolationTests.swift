import XCTest
import Foundation
@testable import AgentCore

/// Proves the worktree isolation the fleet relies on actually produces a SEPARATE branch + directory
/// off a real repo, the `base...HEAD` committed-diff measures what merges, and merge-into-integration
/// never touches main + cleans up on conflict. Real-git; XCTSkip if `git` is absent (CI has it).
final class GitIsolationTests: XCTestCase {

    @discardableResult
    private func git(_ args: [String], cwd: URL) -> (Int32, String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = cwd
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch { return nil }
    }

    /// A real, committed temp git repo. nil if git can't run here.
    private func makeRepo() throws -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitiso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let (rc, _) = git(["init"], cwd: dir), rc == 0 else { return nil }
        _ = git(["config", "user.email", "t@t.test"], cwd: dir)
        _ = git(["config", "user.name", "Test"], cwd: dir)
        try "hello\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = git(["add", "-A"], cwd: dir)
        guard let (crc, _) = git(["commit", "-m", "init"], cwd: dir), crc == 0 else { return nil }
        return dir
    }

    func testMakeWorktreeCreatesIsolatedBranchAndDirThenDiscardCleansUp() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available in this environment") }
        defer { try? FileManager.default.removeItem(at: repo) }

        let wt = GitIsolation.makeWorktree(repo: repo.path, label: "Build a Clock!", nowEpoch: 1_700_000_000)
        let unwrapped = try XCTUnwrap(wt, "a committed git repo must yield a worktree")

        XCTAssertTrue(unwrapped.branch.hasPrefix("mythos/auto-build-a-clock-"),
                      "branch must be a unique, sanitized auto branch — got \(unwrapped.branch)")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: unwrapped.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "the worktree path must be a directory")
        XCTAssertNotEqual(unwrapped.path, repo.path, "isolation: the worktree must be a SEPARATE dir")
        XCTAssertTrue(GitIsolation.isGitRepo(unwrapped.path), "the worktree must itself be a git work tree")

        GitIsolation.discard(unwrapped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unwrapped.path),
                       "discard must remove the worktree directory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.path),
                      "discard must NOT touch the source repo")
    }

    func testSameLabelAndEpochYieldDistinctWorktrees() throws {
        // A fleet can spawn several agents with the same subtask slug in the same second. Each must
        // get a DISTINCT branch + dir, or `git worktree add -b` fails on the 2nd.
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let a = try XCTUnwrap(GitIsolation.makeWorktree(repo: repo.path, label: "same", nowEpoch: 1_700_000_000))
        let b = try XCTUnwrap(GitIsolation.makeWorktree(repo: repo.path, label: "same", nowEpoch: 1_700_000_000),
                              "second worktree with the SAME label+epoch must still succeed")
        XCTAssertNotEqual(a.branch, b.branch, "same label+epoch must yield DISTINCT branches")
        XCTAssertNotEqual(a.path, b.path, "same label+epoch must yield DISTINCT worktree dirs")
        XCTAssertTrue(GitIsolation.isGitRepo(b.path), "the second worktree must be real")
        GitIsolation.discard(a); GitIsolation.discard(b)
    }

    // MARK: - Committed-diff measurement (gives the lease real teeth)

    func testCommittedChangedPathsMeasuresCommittedWorkNotWorkingTree() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let wt = try XCTUnwrap(GitIsolation.makeWorktree(repo: repo.path, label: "lease", nowEpoch: 1_700_000_000))
        defer { GitIsolation.discard(wt) }

        XCTAssertFalse(wt.base.isEmpty, "makeWorktree must capture the base HEAD SHA")

        let wtURL = URL(fileURLWithPath: wt.path)
        let coreDir = wtURL.appendingPathComponent("Core")
        try FileManager.default.createDirectory(at: coreDir, withIntermediateDirectories: true)
        try "// x\n".write(to: coreDir.appendingPathComponent("Foo.swift"), atomically: true, encoding: .utf8)
        _ = git(["add", "-A"], cwd: wtURL)
        _ = git(["commit", "-m", "add Core/Foo.swift"], cwd: wtURL)

        // PRECONDITION: the working tree is now clean — a working-tree-only measure sees nothing.
        let porcelain = (git(["status", "--porcelain"], cwd: wtURL)?.1 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(porcelain.isEmpty, "after commit the working tree is clean")
        // THE FIX: committed measurement (base...HEAD) surfaces the COMMITTED file — what will MERGE.
        XCTAssertEqual(GitIsolation.committedChangedPaths(wt), ["Core/Foo.swift"],
                       "committed measurement must surface the committed file, not the clean working tree")
        XCTAssertFalse(GitIsolation.committedDiff(wt).isEmpty,
                       "committedDiff must be non-empty for a committed change")
    }

    func testCommittedMeasurementUnionsStillDirtyEscape() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let wt = try XCTUnwrap(GitIsolation.makeWorktree(repo: repo.path, label: "dirty", nowEpoch: 1_700_000_000))
        defer { GitIsolation.discard(wt) }
        let wtURL = URL(fileURLWithPath: wt.path)
        try "// a\n".write(to: wtURL.appendingPathComponent("Committed.swift"), atomically: true, encoding: .utf8)
        _ = git(["add", "-A"], cwd: wtURL); _ = git(["commit", "-m", "c"], cwd: wtURL)
        try "// b\n".write(to: wtURL.appendingPathComponent("Dirty.swift"), atomically: true, encoding: .utf8)
        let changed = Set(GitIsolation.committedChangedPaths(wt))
        XCTAssertTrue(changed.contains("Committed.swift") && changed.contains("Dirty.swift"),
                      "committed measurement unions the still-dirty set (no escape hides uncommitted)")
    }

    func testCommittedMeasurementFallsBackToWorkingTreeWhenNoBase() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let wt = GitWorktree(repo: repo.path, path: repo.path, branch: "main", base: "")
        try "dirty\n".write(to: repo.appendingPathComponent("NEW.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(GitIsolation.committedChangedPaths(wt).contains("NEW.txt"),
                      "with no base, committed measurement falls back to the working-tree set (back-compat)")
    }

    func testCommittedOnlyFailsClosedWhenBaseUnknown() {
        // Claim evidence must NOT fall back to the working tree when base is unknown — empty so an
        // uncommitted edit can't satisfy a claim (fail closed).
        let wt = GitWorktree(repo: "/repo", path: "/tmp/whatever", branch: "b", base: "")
        XCTAssertEqual(GitIsolation.committedOnlyChangedPaths(wt), [],
                       "no base ⇒ no committed evidence (fail closed, not working-tree)")
        XCTAssertEqual(GitIsolation.committedOnlyDiff(wt), "")
    }

    func testTrackedDirtyFilesReportsTrackedMutationsButIgnoresUntrackedArtifacts() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let wt = try XCTUnwrap(GitIsolation.makeWorktree(repo: repo.path, label: "tracked-dirty",
                                                         nowEpoch: 1_700_000_000))
        defer { GitIsolation.discard(wt) }

        let wtURL = URL(fileURLWithPath: wt.path)
        try "changed\n".write(to: wtURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "artifact\n".write(to: wtURL.appendingPathComponent("test-output.log"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GitIsolation.trackedDirtyFiles(wt), ["README.md"],
                       "post-test integrity checks tracked source mutations, not untracked build artifacts")
    }

    func testDetachedHeldOutWorktreeUsesAgentWorktreeWhenRepoFieldIsEmptyAndCheckoutIsReadOnly() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let wt = try XCTUnwrap(GitIsolation.makeWorktree(repo: repo.path, label: "heldout",
                                                         nowEpoch: 1_700_000_000))
        defer { GitIsolation.discard(wt) }

        let wtURL = URL(fileURLWithPath: wt.path)
        try "agent\n".write(to: wtURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = git(["add", "-A"], cwd: wtURL)
        _ = git(["commit", "-m", "agent changes readme"], cwd: wtURL)

        let foremanStyle = GitWorktree(repo: "", path: wt.path, branch: wt.branch, base: wt.base)
        let copy = try XCTUnwrap(GitIsolation.detachedWorktreeAtHead(of: foremanStyle),
                                 "Foreman passes repo:\"\"; held-out must still create a detached copy from wt.path")
        defer { GitIsolation.removeWorktree(copy) }

        XCTAssertNotEqual(copy.path, wt.path)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: copy.path).appendingPathComponent("README.md")),
                       "agent\n")
        XCTAssertTrue(GitIsolation.checkoutPaths(copy, ref: wt.base, paths: ["README.md"]))
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: copy.path).appendingPathComponent("README.md")),
                       "hello\n",
                       "checkout to base happens inside the detached copy")
        XCTAssertEqual(try String(contentsOf: wtURL.appendingPathComponent("README.md")),
                       "agent\n",
                       "agent worktree must not be mutated by held-out checkout")
    }

    // MARK: - mergeIntoIntegration

    private func makeBranch(_ name: String, file: String, content: String, in repo: URL) -> String {
        _ = git(["branch", name, "HEAD"], cwd: repo)
        let wtDir = repo.deletingLastPathComponent().appendingPathComponent("wt-\(UUID().uuidString)")
        _ = git(["worktree", "add", wtDir.path, name], cwd: repo)
        try? content.write(to: wtDir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        _ = git(["add", "-A"], cwd: wtDir)
        _ = git(["commit", "-m", "add \(file)"], cwd: wtDir)
        _ = git(["worktree", "remove", "--force", wtDir.path], cwd: repo)
        return name
    }

    func testMergeIntoIntegrationMergesSignedBranches() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let a = makeBranch("mythos/a", file: "a.swift", content: "// a", in: repo)
        let b = makeBranch("mythos/b", file: "b.swift", content: "// b", in: repo)

        let result = GitIsolation.mergeIntoIntegration(repo: repo.path, base: "HEAD",
                                                       branches: [a, b], integrationBranch: "integration",
                                                       nowEpoch: 1_700_000_000)
        guard case let .merged(branch, wtPath, merged) = result else {
            return XCTFail("expected .merged, got \(result)")
        }
        XCTAssertEqual(branch, "integration")
        XCTAssertEqual(merged, [a, b], "both signed branches merged, in order")
        XCTAssertTrue(FileManager.default.fileExists(atPath: (wtPath as NSString).appendingPathComponent("a.swift")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (wtPath as NSString).appendingPathComponent("b.swift")))
        _ = git(["worktree", "remove", "--force", wtPath], cwd: repo)
    }

    func testMergeIntoIntegrationRefusesMain() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        // Case + whitespace variants must ALSO be refused — a guard matching exact "main" would let
        // "Main"/" HEAD "/"MASTER" through.
        for protected in ["main", "master", "HEAD", "Main", "MASTER", "Head", " main ", " HEAD", "master "] {
            let r = GitIsolation.mergeIntoIntegration(repo: repo.path, base: "HEAD",
                                                      branches: ["mythos/x"], integrationBranch: protected,
                                                      nowEpoch: 1)
            guard case .failed = r else { return XCTFail("must REFUSE to merge into \(protected), got \(r)") }
            XCTAssertFalse(GitIsolation.branchHasCommits(repo: repo.path, branch: protected, base: "HEAD"),
                           "refused branch \(protected) must never be created")
        }
    }

    func testSafeLocalBranchNameRejectsOptionRefsAndSpecialRevSyntax() {
        XCTAssertTrue(GitIsolation.isSafeLocalBranchName("mythos/auto-feature-123"))
        XCTAssertTrue(GitIsolation.isSafeLocalBranchName("integration/fleet-1"))

        for unsafe in [
            "", "--abort", "/bad", "bad/", "bad//name", "bad..name", "bad name",
            "refs/heads/main", "bad@{1}", "bad.lock", "bad~name", "bad^name",
            "bad:name", "bad?name", "bad*name", "bad[name", "bad\\name", "@",
            ".hidden", "bad/.hidden", "bad.",
        ] {
            XCTAssertFalse(GitIsolation.isSafeLocalBranchName(unsafe), "must reject \(unsafe)")
        }
    }

    func testMergeIntoIntegrationRefusesUnsafeIntegrationAndSourceBranchesBeforeCreatingArtifact() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }

        for unsafeIntegration in ["--abort", "refs/heads/main", "bad name", "bad..name", "bad@{1}", "bad.lock"] {
            let r = GitIsolation.mergeIntoIntegration(repo: repo.path, base: "HEAD",
                                                      branches: ["mythos/x"], integrationBranch: unsafeIntegration,
                                                      nowEpoch: 10)
            guard case .failed = r else { return XCTFail("unsafe integration \(unsafeIntegration) must fail, got \(r)") }
            XCTAssertFalse(GitIsolation.branchExists(repo: repo.path, branch: unsafeIntegration),
                           "refused integration branch must never be created")
        }

        for unsafeSource in ["--abort", "main", "HEAD", "refs/heads/x", "bad name", "bad..name"] {
            let integration = "integration-\(UUID().uuidString.prefix(8))"
            let r = GitIsolation.mergeIntoIntegration(repo: repo.path, base: "HEAD",
                                                      branches: [unsafeSource], integrationBranch: integration,
                                                      nowEpoch: 11)
            guard case .failed = r else { return XCTFail("unsafe source \(unsafeSource) must fail, got \(r)") }
            XCTAssertFalse(GitIsolation.branchExists(repo: repo.path, branch: integration),
                           "unsafe source branch must be refused before integration branch creation")
        }
    }

    func testMergeIntoIntegrationConflictAbortsAndStops() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let a = makeBranch("mythos/ca", file: "clash.swift", content: "// version A", in: repo)
        let b = makeBranch("mythos/cb", file: "clash.swift", content: "// version B", in: repo)
        let r = GitIsolation.mergeIntoIntegration(repo: repo.path, base: "HEAD",
                                                  branches: [a, b], integrationBranch: "integration", nowEpoch: 2)
        guard case let .conflict(onBranch, mergedBefore) = r else { return XCTFail("expected .conflict, got \(r)") }
        XCTAssertEqual(onBranch, b, "conflict reported on the 2nd branch")
        XCTAssertEqual(mergedBefore, [a], "the 1st merged before the conflict; stops there (no force)")
        // A conflict must NOT leave a half-merged integration branch behind — it's torn down.
        let branches = git(["branch", "--list", "integration"], cwd: repo)?.1 ?? ""
        XCTAssertFalse(branches.contains("integration"),
                       "conflict must delete the incomplete integration branch — found: \(branches)")
        XCTAssertTrue(GitIsolation.branchHasCommits(repo: repo.path, branch: a, base: "HEAD"))
        XCTAssertTrue(GitIsolation.branchHasCommits(repo: repo.path, branch: b, base: "HEAD"))
    }

    func testMergeIntoIntegrationSuccessLeavesReviewableArtifact() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let a = makeBranch("mythos/sa", file: "sa.swift", content: "// sa", in: repo)
        let r = GitIsolation.mergeIntoIntegration(repo: repo.path, base: "HEAD",
                                                  branches: [a], integrationBranch: "integration",
                                                  nowEpoch: 1_700_000_001)
        guard case let .merged(_, wtPath, _) = r else { return XCTFail("expected .merged, got \(r)") }
        // On SUCCESS the integration branch + worktree are KEPT — the deliverable a human reviews.
        let branches = git(["branch", "--list", "integration"], cwd: repo)?.1 ?? ""
        XCTAssertTrue(branches.contains("integration"), "success must keep the integration branch as the artifact")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wtPath), "success keeps the worktree for review")

        // A SECOND join over the kept integration branch must be a clean idempotency signal, not a
        // cryptic "branch already exists" failure.
        let again = GitIsolation.mergeIntoIntegration(repo: repo.path, base: "HEAD",
                                                      branches: [a], integrationBranch: "integration",
                                                      nowEpoch: 1_700_000_002)
        XCTAssertEqual(again, .alreadyIntegrated(integrationBranch: "integration"),
                       "second join over a kept integration branch is idempotent, not a failure")
        _ = git(["worktree", "remove", "--force", wtPath], cwd: repo)
    }

    func testMergeIntoIntegrationNothingToMerge() throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }
        let r = GitIsolation.mergeIntoIntegration(repo: repo.path, base: "HEAD",
                                                  branches: [], integrationBranch: "integration", nowEpoch: 3)
        XCTAssertEqual(r, .nothingToMerge)
    }

    func testMakeWorktreeReturnsNilForNonRepo() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notarepo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(GitIsolation.makeWorktree(repo: dir.path, label: "x", nowEpoch: 1),
                     "a non-git directory must NOT yield a worktree (never silently edit main)")
    }
}
