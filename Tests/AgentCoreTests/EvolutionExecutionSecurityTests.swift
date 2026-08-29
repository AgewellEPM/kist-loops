import Foundation
import XCTest
@testable import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class EvolutionExecutionSecurityTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let worktree: GitWorktree
    }

    func testDurableCommitDisablesHostileHooksAndDoesNotRunTheirBody() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let hook = fixture.root.appendingPathComponent(".git/hooks/pre-commit")
        let marker = fixture.root.appendingPathComponent("HOOK-RAN")
        try "#!/bin/sh\nprintf pwned > \(shellQuote(marker.path))\nsleep 30\nyes noisy\nexit 19\n"
            .write(to: hook, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(hook.path, 0o700), 0)
        try write("candidate\n", relative: "Candidate.txt", root: fixture.worktree.path)

        let started = Date()
        let durable = try GitIsolation.commitEvolutionCandidate(
            fixture.worktree, message: "hook-free commit")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertNotEqual(durable.commitSHA, durable.baseSHA)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: EvolutionArchiveStore(root: fixture.root.path).archiveURL.path))
    }

    func testCommitFailureAndHostileFilterOrFsmonitorCannotMintFitness() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let marker = fixture.root.appendingPathComponent("GIT-HELPER-RAN")
        let helper = "!/bin/sh; printf pwned > \(shellQuote(marker.path)); sleep 30"
        _ = git(["config", "core.fsmonitor", helper], cwd: fixture.root)
        _ = git(["config", "filter.evil.clean", helper], cwd: fixture.root)
        try write("candidate\n", relative: "Candidate.txt", root: fixture.worktree.path)

        XCTAssertThrowsError(try GitIsolation.commitEvolutionCandidate(
            fixture.worktree, message: "must refuse hostile config")) { error in
            XCTAssertEqual(error as? GitIsolation.EvolutionCommitError, .unsafeGitControl)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: EvolutionArchiveStore(root: fixture.root.path).archiveURL.path))

        _ = git(["config", "--unset-all", "filter.evil.clean"], cwd: fixture.root)
        _ = git(["config", "--unset-all", "core.fsmonitor"], cwd: fixture.root)
        _ = git(["config", "--unset-all", "user.email"], cwd: fixture.root)
        _ = git(["config", "--unset-all", "user.name"], cwd: fixture.root)
        _ = git(["config", "user.useConfigOnly", "true"], cwd: fixture.root)
        XCTAssertThrowsError(try GitIsolation.commitEvolutionCandidate(
            fixture.worktree, message: "missing identity")) { error in
            XCTAssertEqual(error as? GitIsolation.EvolutionCommitError, .commitFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: EvolutionArchiveStore(root: fixture.root.path).archiveURL.path))
    }

    func testDurableCommitRejectsLocalWorktreeRedirectAndConfigInclude() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("evolution-config-outside-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(
            at: outside, withIntermediateDirectories: true)
        try write("candidate\n", relative: "Candidate.txt", root: fixture.worktree.path)

        _ = git(["config", "core.worktree", outside.path], cwd: fixture.root)
        XCTAssertThrowsError(try GitIsolation.commitEvolutionCandidate(
            fixture.worktree, message: "reject redirected worktree")) { error in
            XCTAssertEqual(error as? GitIsolation.EvolutionCommitError, .unsafeGitControl)
        }
        _ = git(["config", "--unset-all", "core.worktree"], cwd: fixture.root)

        let included = outside.appendingPathComponent("included.gitconfig")
        try "[core]\n\tworktree = \(outside.path)\n".write(
            to: included, atomically: true, encoding: .utf8)
        _ = git(["config", "include.path", included.path], cwd: fixture.root)
        XCTAssertThrowsError(try GitIsolation.commitEvolutionCandidate(
            fixture.worktree, message: "reject config include")) { error in
            XCTAssertEqual(error as? GitIsolation.EvolutionCommitError, .unsafeGitControl)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: EvolutionArchiveStore(root: fixture.root.path).archiveURL.path))
    }

    func testPostCommitDirtAndSHAMismatchInvalidateSnapshotWithoutSeal() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        try write("candidate one\n", relative: "Candidate.txt", root: fixture.worktree.path)
        let durable = try GitIsolation.commitEvolutionCandidate(
            fixture.worktree, message: "candidate one")
        XCTAssertNotEqual(durable.commitSHA, durable.baseSHA)

        try write("dirty after commit\n", relative: "Candidate.txt", root: fixture.worktree.path)
        XCTAssertThrowsError(try GitIsolation.validateEvolutionCandidate(
            fixture.worktree, expected: durable)) { error in
            XCTAssertEqual(error as? GitIsolation.EvolutionCommitError, .snapshotMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: EvolutionArchiveStore(root: fixture.root.path).archiveURL.path))

        XCTAssertTrue(GitIsolation.commit(fixture.worktree, message: "unexpected second commit"))
        XCTAssertThrowsError(try GitIsolation.validateEvolutionCandidate(
            fixture.worktree, expected: durable)) { error in
            XCTAssertEqual(error as? GitIsolation.EvolutionCommitError, .snapshotMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: EvolutionArchiveStore(root: fixture.root.path).archiveURL.path))
    }

    #if os(macOS)
    func testProductionBenchmarkRefusesBeforeCandidateCodeWithoutHardContainment() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        ForgeSeal.forceEphemeralKeyForTesting()
        defer { ForgeSeal.resetCacheForTesting() }

        try write("candidate\n", relative: "Candidate.txt", root: fixture.worktree.path)
        let durable = try GitIsolation.commitEvolutionCandidate(
            fixture.worktree, message: "candidate")
        let state = try EvolutionBenchmarkRunner.captureProtectedHostState(
            repoRoot: fixture.root.path)
        let marker = fixture.root.appendingPathComponent("MUST-NOT-RUN")

        await XCTAssertThrowsErrorAsync(try await EvolutionBenchmarkRunner.run(
            commands: ["printf ran > \(shellQuote(marker.path))"],
            candidate: durable, worktree: fixture.worktree,
            hostRoot: fixture.root.path, expectedHostState: state,
            timeoutSeconds: 20
        )) { error in
            guard let executionError = error as? EvolutionBenchmarkRunner.ExecutionError,
                  case .hardContainmentUnavailable(let reason) = executionError else {
                return XCTFail("expected hard-containment refusal, got \(error)")
            }
            XCTAssertTrue(reason.contains("hard containment unavailable"), reason)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "production refusal must occur before candidate code starts")
    }

    func testAttestedBenchmarkCannotReadForgeKeyOrMutateHostRepoAndArchive() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        let keyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("evolution-secret-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: keyDirectory) }
        ForgeSeal.resetCacheForTesting()
        ForgeSeal.keyDirectoryOverrideForTesting = keyDirectory.path
        defer { ForgeSeal.resetCacheForTesting() }

        try write("candidate\n", relative: "Candidate.txt", root: fixture.worktree.path)
        let durable = try GitIsolation.commitEvolutionCandidate(
            fixture.worktree, message: "candidate")
        let store = EvolutionArchiveStore(root: fixture.root.path)
        _ = try store.append(record(fixture: fixture, durable: durable))
        let keyURL = keyDirectory.appendingPathComponent("forgeseal-v1.key")
        let secret = try Data(contentsOf: keyURL)
        let hostFile = fixture.root.appendingPathComponent("HOST.txt")
        let hostBefore = try Data(contentsOf: hostFile)
        let archiveBefore = try Data(contentsOf: store.archiveURL)
        let state = try EvolutionBenchmarkRunner.captureProtectedHostState(
            repoRoot: fixture.root.path)

        let commands = [
            "cat \(shellQuote(keyURL.path))",
            "printf hacked > \(shellQuote(hostFile.path))",
            "printf hacked >> \(shellQuote(store.archiveURL.path))",
        ]
        let batch = try await EvolutionBenchmarkRunner.runAdvisoryForTesting(
            commands: commands, candidate: durable, worktree: fixture.worktree,
            hostRoot: fixture.root.path, expectedHostState: state, timeoutSeconds: 20)
        let results = batch.results

        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { !$0.success })
        XCTAssertTrue(results.allSatisfy { $0.failureClass == .infrastructure },
                      "host/key/archive denials are sterile security failures, not stepping-stones")
        XCTAssertTrue(results.allSatisfy { $0.evaluatedCommitSHA == durable.commitSHA })
        XCTAssertTrue(results.allSatisfy { $0.sandboxProfileDigest?.count == 64 })
        XCTAssertTrue(results.allSatisfy { $0.effectiveEnvironmentDigest?.count == 64 })
        XCTAssertTrue(results.allSatisfy { $0.executionEvidenceDigest?.count == 64 })
        XCTAssertFalse(results.contains { Data($0.output.utf8).range(of: secret) != nil })
        XCTAssertEqual(try Data(contentsOf: hostFile), hostBefore)
        XCTAssertEqual(try Data(contentsOf: store.archiveURL), archiveBefore)
        XCTAssertNoThrow(try EvolutionBenchmarkRunner.validateProtectedHostState(state))
        XCTAssertNoThrow(try GitIsolation.validateEvolutionCandidate(
            fixture.worktree, expected: durable))
    }

    func testSymlinkAndHardlinkEscapesCannotReachHostFile() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        ForgeSeal.forceEphemeralKeyForTesting()
        defer { ForgeSeal.resetCacheForTesting() }
        try write("candidate\n", relative: "Candidate.txt", root: fixture.worktree.path)
        let durable = try GitIsolation.commitEvolutionCandidate(
            fixture.worktree, message: "candidate")
        let host = fixture.root.appendingPathComponent("HOST.txt")
        let before = try Data(contentsOf: host)
        let state = try EvolutionBenchmarkRunner.captureProtectedHostState(
            repoRoot: fixture.root.path)
        let commands = [
            "ln -s \(shellQuote(host.path)) .build/host-link && printf pwned > .build/host-link",
            "ln \(shellQuote(host.path)) .build/host-hardlink && printf pwned > .build/host-hardlink",
        ]
        let batch = try await EvolutionBenchmarkRunner.runAdvisoryForTesting(
            commands: commands, candidate: durable, worktree: fixture.worktree,
            hostRoot: fixture.root.path, expectedHostState: state, timeoutSeconds: 20)
        let results = batch.results

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { !$0.success })
        XCTAssertEqual(try Data(contentsOf: host), before)
        XCTAssertNoThrow(try EvolutionBenchmarkRunner.validateProtectedHostState(state))
    }

    func testDetachedSourceCannotBeHardlinkedOrSymlinkMutatedThroughBuildOutput() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        ForgeSeal.forceEphemeralKeyForTesting()
        defer { ForgeSeal.resetCacheForTesting() }
        try write("candidate\n", relative: "Candidate.txt", root: fixture.worktree.path)
        let durable = try GitIsolation.commitEvolutionCandidate(
            fixture.worktree, message: "candidate")
        let state = try EvolutionBenchmarkRunner.captureProtectedHostState(
            repoRoot: fixture.root.path)

        let batch = try await EvolutionBenchmarkRunner.runAdvisoryForTesting(
            commands: [
                "ln Candidate.txt .build/source-hardlink && printf pwned > .build/source-hardlink",
                "ln -s ../Candidate.txt .build/source-symlink && printf pwned > .build/source-symlink",
            ],
            candidate: durable, worktree: fixture.worktree,
            hostRoot: fixture.root.path, expectedHostState: state, timeoutSeconds: 20)

        XCTAssertEqual(batch.results.count, 2)
        XCTAssertTrue(batch.results.allSatisfy { !$0.success })
        XCTAssertTrue(batch.results.allSatisfy { $0.failureClass == .infrastructure })
        XCTAssertNoThrow(try GitIsolation.validateEvolutionCandidate(
            fixture.worktree, expected: durable))
        XCTAssertNoThrow(try EvolutionBenchmarkRunner.validateProtectedHostState(state))
    }

    func testBuildPluginCannotEscapeDetachedVerificationWorkspace() async throws {
        let hostMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("evolution-plugin-host-\(UUID().uuidString)")
        try "host-safe\n".write(to: hostMarker, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: hostMarker) }
        let package = """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "EscapeFixture", targets: [
            .plugin(name: "EscapePlugin", capability: .buildTool()),
            .target(name: "EscapeLib", plugins: [.plugin(name: "EscapePlugin")]),
            .testTarget(name: "EscapeLibTests", dependencies: ["EscapeLib"]),
        ])
        """
        let benignPlugin = """
        import PackagePlugin
        @main struct EscapePlugin: BuildToolPlugin {
            func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] { [] }
        }
        """
        let fixture = try makeFixture(additionalBaseFiles: [
            "Package.swift": package,
            "Sources/EscapeLib/EscapeLib.swift": "public func answer() -> Int { 42 }\n",
            "Tests/EscapeLibTests/EscapeLibTests.swift":
                "import XCTest\n@testable import EscapeLib\nfinal class T: XCTestCase { func testIt() { XCTAssertEqual(answer(), 42) } }\n",
            "Plugins/EscapePlugin/plugin.swift": benignPlugin,
        ])
        defer { cleanup(fixture) }
        ForgeSeal.forceEphemeralKeyForTesting()
        defer { ForgeSeal.resetCacheForTesting() }
        let maliciousPlugin = """
        import Foundation
        import PackagePlugin
        @main struct EscapePlugin: BuildToolPlugin {
            func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
                try Data("pwned".utf8).write(to: URL(fileURLWithPath: \(String(reflecting: hostMarker.path))))
                return []
            }
        }
        """
        try write(maliciousPlugin, relative: "Plugins/EscapePlugin/plugin.swift",
                  root: fixture.worktree.path)
        let durable = try GitIsolation.commitEvolutionCandidate(
            fixture.worktree, message: "malicious plugin")
        let state = try EvolutionBenchmarkRunner.captureProtectedHostState(
            repoRoot: fixture.root.path)
        let batch = try await EvolutionBenchmarkRunner.runAdvisoryForTesting(
            commands: ["swift test"], candidate: durable, worktree: fixture.worktree,
            hostRoot: fixture.root.path, expectedHostState: state, timeoutSeconds: 120)
        let results = batch.results

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].success)
        XCTAssertEqual(try String(contentsOf: hostMarker, encoding: .utf8), "host-safe\n")
        XCTAssertEqual(results[0].evaluatedCommitSHA, durable.commitSHA)
        XCTAssertNoThrow(try EvolutionBenchmarkRunner.validateProtectedHostState(state))
    }

    func testDetachedWorkspaceSandboxPrivateStateAndBackgroundChildAreCleaned() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        ForgeSeal.forceEphemeralKeyForTesting()
        defer { ForgeSeal.resetCacheForTesting() }
        try write("candidate\n", relative: "Candidate.txt", root: fixture.worktree.path)
        let durable = try GitIsolation.commitEvolutionCandidate(
            fixture.worktree, message: "candidate")
        let state = try EvolutionBenchmarkRunner.captureProtectedHostState(
            repoRoot: fixture.root.path)
        let beforeWorktrees = temporaryEntries(prefix: "mythos-evolution-verify-")
        let sandboxNamespace = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-builder-sandbox-v1", isDirectory: true)
        let beforeSandboxes = directoryEntries(sandboxNamespace)

        let batch = try await EvolutionBenchmarkRunner.runAdvisoryForTesting(
            commands: ["(exec >/dev/null 2>&1; sleep 30) & echo $!"],
            candidate: durable, worktree: fixture.worktree,
            hostRoot: fixture.root.path, expectedHostState: state, timeoutSeconds: 15)
        let results = batch.results
        let pid = results.first?.output.split(separator: "\n").first.flatMap {
            pid_t(String($0).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        XCTAssertEqual(temporaryEntries(prefix: "mythos-evolution-verify-"), beforeWorktrees)
        XCTAssertEqual(directoryEntries(sandboxNamespace), beforeSandboxes)
        if let pid {
            XCTAssertNotEqual(kill(pid, 0), 0, "background child must not survive process-group cleanup")
        } else {
            // Strict Seatbelt currently kills this background-fork attempt with SIGTRAP before it can
            // publish a PID. That is the stronger fail-closed outcome; if the backend later permits the
            // fork, the PID branch above proves ProcessGroupRunner still reaps it.
            XCTAssertEqual(results.first?.failureClass, .infrastructure)
            XCTAssertEqual(results.first?.wasSignalled, true)
            XCTAssertGreaterThanOrEqual(results.first?.exitCode ?? -1, 128)
        }
    }
    #endif

    func testProtectedHostMismatchRefusesBenchmarkBeforeCandidateCode() async throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }
        ForgeSeal.forceEphemeralKeyForTesting()
        defer { ForgeSeal.resetCacheForTesting() }
        try write("candidate\n", relative: "Candidate.txt", root: fixture.worktree.path)
        let durable = try GitIsolation.commitEvolutionCandidate(
            fixture.worktree, message: "candidate")
        let state = try EvolutionBenchmarkRunner.captureProtectedHostState(
            repoRoot: fixture.root.path)
        try "host changed\n".write(
            to: fixture.root.appendingPathComponent("HOST.txt"), atomically: true, encoding: .utf8)

        await XCTAssertThrowsErrorAsync(try await EvolutionBenchmarkRunner.runAdvisoryForTesting(
            commands: ["printf ran > SHOULD_NOT_EXIST"], candidate: durable,
            worktree: fixture.worktree, hostRoot: fixture.root.path,
            expectedHostState: state, timeoutSeconds: 10)) { error in
            XCTAssertEqual(error as? EvolutionBenchmarkRunner.ExecutionError, .protectedHostChanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: fixture.worktree.path)
                .appendingPathComponent("SHOULD_NOT_EXIST").path))
    }

    private func makeFixture(additionalBaseFiles: [String: String] = [:]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evolution-execution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard git(["init"], cwd: root).0 == 0 else { throw XCTSkip("git unavailable") }
        _ = git(["config", "user.email", "evolution@test.invalid"], cwd: root)
        _ = git(["config", "user.name", "Evolution Test"], cwd: root)
        try write("host-safe\n", relative: "HOST.txt", root: root.path)
        for (path, contents) in additionalBaseFiles {
            try write(contents, relative: path, root: root.path)
        }
        _ = git(["add", "-A"], cwd: root)
        XCTAssertEqual(git(["commit", "-m", "base"], cwd: root).0, 0)
        let worktree = try XCTUnwrap(GitIsolation.makeWorktree(
            repo: root.path, label: "evolve-execution", nowEpoch: 1_700_000_000))
        return Fixture(root: root, worktree: worktree)
    }

    private func cleanup(_ fixture: Fixture) {
        _ = GitIsolation.discard(fixture.worktree)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private func write(_ contents: String, relative: String, root: String) throws {
        let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func record(fixture: Fixture,
                        durable: GitIsolation.EvolutionCommitSnapshot) -> EvolutionCandidateRecord {
        EvolutionTestAuthority.authoritative(EvolutionCandidateRecord(
            runID: "security-run", candidateID: "security-candidate", parentID: nil,
            objective: "security", branch: fixture.worktree.branch,
            worktreePath: fixture.worktree.path, baseSHA: durable.baseSHA,
            commitSHA: durable.commitSHA, status: .failed, score: 1,
            changedFiles: durable.changedFiles, protectedFiles: [], benchmarks: [],
            summary: "security fixture", createdAtEpoch: 1))
    }

    private func git(_ args: [String], cwd: URL) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = cwd
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch { return (-1, error.localizedDescription) }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func temporaryEntries(prefix: String) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path))?.filter {
                $0.hasPrefix(prefix)
            } ?? [])
    }

    private func directoryEntries(_ url: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch { handler(error) }
}
