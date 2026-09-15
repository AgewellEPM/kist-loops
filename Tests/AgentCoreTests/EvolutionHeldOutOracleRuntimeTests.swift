import Foundation
import XCTest
@testable import AgentCore

#if DEBUG && os(macOS)
import Darwin

/// Fixture evidence for the existing paired referee, never production capability evidence.
/// Only host-owned /bin/cat executes; the two measured revisions contain fixed answer data.
/// No model, candidate-authored executable, evaluation seal, or hard-containment authority is used.
final class EvolutionHeldOutOracleRuntimeTests: XCTestCase {
    func testActualParentAndChildCapturesProducePositiveDataFixtureDeltaWithoutArchiveAuthority() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let readinessBefore = EvolutionAutonomyReadinessAssessment.current
        let report = try await EvolutionPairedBenchmarkCoordinator.evaluatePair(preparation: fixture.preparation) { role, plan in
            XCTAssertEqual(plan, fixture.preparation.plan)
            return try await fixture.capture(role)
        }
        XCTAssertEqual(fixture.capturedRoles, [.parent, .child])
        XCTAssertEqual(report.fitness.plan.parentIdentity.commitSHA, fixture.childSnapshot.baseSHA)
        XCTAssertEqual(report.fitness.plan.childBaseIdentity, report.fitness.plan.parentIdentity)
        XCTAssertEqual(report.fitness.solvedCountDelta, 1)
        XCTAssertEqual(report.fitness.newlySolvedCaseIDs, ["fixture-answer"])
        XCTAssertTrue(report.fitness.regressedCaseIDs.isEmpty)
        XCTAssertTrue(EvolutionHeldOutOracle.validate(report.fitness,
            baseSHA: fixture.childSnapshot.baseSHA, commitSHA: fixture.childSnapshot.commitSHA,
            treeSHA: fixture.childSnapshot.treeSHA, gitControlDigest: fixture.childSnapshot.gitControlDigest))
        XCTAssertFalse(EvolutionHeldOutOracle.validate(report.fitness,
            baseSHA: fixture.parentSnapshot.baseSHA, commitSHA: fixture.childSnapshot.commitSHA,
            treeSHA: fixture.childSnapshot.treeSHA, gitControlDigest: fixture.childSnapshot.gitControlDigest))

        // The actual child process cannot read the host's expectation file outside either revision.
        let denied = try await fixture.runCat(.child, argument: fixture.expectationsPath)
        XCTAssertNotEqual(denied.exitCode, 0, denied.combined)
        XCTAssertEqual(denied.stdoutByteCount, 0, denied.combined)
        XCTAssertFalse(denied.timedOut || denied.cancelled || denied.outputTruncated)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.expectationsPath)), fixture.expectationBytes)

        let child = fixture.childSnapshot
        let record = EvolutionCandidateRecord(
            runID: "real-capture-fixture", candidateID: "fixture-child", parentID: nil,
            objective: "test the host referee with fixed data only", branch: child.branch,
            worktreePath: fixture.child.path, baseSHA: child.baseSHA, commitSHA: child.commitSHA,
            status: .blocked, score: 0, changedFiles: child.changedFiles, protectedFiles: [],
            benchmarks: [], summary: "fixture report has no production authority", createdAtEpoch: 1,
            requiredBenchmarkCommands: ["/bin/cat answer.txt"], treeSHA: child.treeSHA,
            gitControlDigest: child.gitControlDigest,
            hostStateDigest: BuilderEvidenceDigest.sha256("fixture-only, no host attestation"),
            committedDiffDigest: BuilderEvidenceDigest.sha256(child.committedDiff),
            integrityDigest: EvolutionEvaluationAuthority.integrityDigest([]), capabilityFitness: report.fitness)
        let expectedError = EvolutionArchiveError.invalidRecord(
            "paired capability fitness lacks its complete host evaluation envelope")
        XCTAssertEqual(EvolutionRecordAuthority.validationError(record), expectedError)
        let store = EvolutionArchiveStore(root: fixture.repo)
        // An empty fixture archive refuses before minting or consuming any ForgeSeal authority.
        XCTAssertThrowsError(try store.append(record)) { XCTAssertEqual($0 as? EvolutionArchiveError, expectedError) }
        XCTAssertTrue(try Data(contentsOf: store.archiveURL).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.headURL.path))
        XCTAssertEqual(EvolutionAutonomyReadinessAssessment.current, readinessBefore)
        XCTAssertFalse(readinessBefore.ready)
        XCTAssertEqual(Set(readinessBefore.blockers.map(\.gate)), Set(EvolutionAutonomyGate.allCases))
        XCTAssertFalse(HardProcessContainmentRuntime.currentAvailability.available)
    }

    func testActualTruncatedParentCaptureStopsBeforeChildAndCannotBecomeFitness() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        do {
            _ = try await EvolutionPairedBenchmarkCoordinator.evaluatePair(preparation: fixture.preparation) { role, _ in
                // Three real bytes with a two-byte output cap cause an observed infrastructure failure.
                let arm = try await fixture.capture(role, cap: 2)
                XCTAssertTrue(try XCTUnwrap(arm.observations.first).outcome.outputTruncated)
                return arm
            }
            XCTFail("Truncated parent output must not produce fitness")
        } catch {
            XCTAssertEqual(error as? EvolutionCapabilityFitnessError, .infrastructureFailed(arm: .parent))
        }
        XCTAssertEqual(fixture.capturedRoles, [.parent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.repo + "/.mythos/evolution/archive.jsonl"))
        XCTAssertFalse(EvolutionAutonomyReadinessAssessment.current.ready)
    }

    func testActualCaptureWithWrongParentIdentityStopsBeforeChild() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        do {
            _ = try await EvolutionPairedBenchmarkCoordinator.evaluatePair(preparation: fixture.preparation) { role, _ in
                let captured = try await fixture.capture(role)
                return EvolutionHeldOutOracle.Arm(identity: fixture.preparation.plan.childIdentity,
                    frozenInputs: captured.frozenInputs, observations: captured.observations)
            }
            XCTFail("Real output does not authorize a different parent identity")
        } catch {
            XCTAssertEqual(error as? EvolutionCapabilityFitnessError, .armIdentityMismatch(arm: .parent))
        }
        XCTAssertEqual(fixture.capturedRoles, [.parent])
        XCTAssertFalse(EvolutionAutonomyReadinessAssessment.current.ready)
    }

    func testChangedCommittedDataRefusesBeforeFixedReaderStarts() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        try Data("changed after snapshot\n".utf8)
            .write(to: URL(fileURLWithPath: fixture.parent.path + "/answer.txt"))
        do {
            _ = try await EvolutionPairedBenchmarkCoordinator.evaluatePair(preparation: fixture.preparation) { role, _ in
                try await fixture.capture(role)
            }
            XCTFail("A dirty revision cannot supply the frozen parent observation")
        } catch {
            XCTAssertEqual(error as? GitIsolation.EvolutionCommitError, .snapshotMismatch)
        }
        XCTAssertTrue(fixture.capturedRoles.isEmpty)
        XCTAssertFalse(EvolutionAutonomyReadinessAssessment.current.ready)
    }

    private final class Fixture {
        let base: String
        let repo: String
        let oracleDirectory: String
        let expectationsPath: String
        let expectationBytes: Data
        let parent: GitWorktree
        let child: GitWorktree
        let parentSnapshot: GitIsolation.EvolutionCommitSnapshot
        let childSnapshot: GitIsolation.EvolutionCommitSnapshot
        let preparation: EvolutionPairedBenchmarkPreparation
        var capturedRoles: [EvolutionCapabilityArm] = []

        private init(base: String, repo: String, oracleDirectory: String, expectationBytes: Data,
                     parent: GitWorktree, child: GitWorktree,
                     parentSnapshot: GitIsolation.EvolutionCommitSnapshot,
                     childSnapshot: GitIsolation.EvolutionCommitSnapshot,
                     preparation: EvolutionPairedBenchmarkPreparation) {
            self.base = base; self.repo = repo; self.oracleDirectory = oracleDirectory
            expectationsPath = oracleDirectory + "/expectations.json"
            self.expectationBytes = expectationBytes; self.parent = parent; self.child = child
            self.parentSnapshot = parentSnapshot; self.childSnapshot = childSnapshot
            self.preparation = preparation
        }

        static func make() async throws -> Fixture {
            let rawBase = NSHomeDirectory() + "/.kist-oracle-capture-" + UUID().uuidString
            try FileManager.default.createDirectory(atPath: rawBase, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            do {
                let base = try XCTUnwrap(ToolContext.canonicalize(rawBase))
                let repo = base + "/Repository", oracle = base + "/PrivateOracle"
                for path in [repo, oracle] {
                    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700])
                }
                try await git(["init", "--quiet", "--template=", "--initial-branch=fixture-anchor"], cwd: repo)
                try await git(["config", "user.name", "Oracle Runtime Fixture"], cwd: repo)
                try await git(["config", "user.email", "oracle-fixture@test.invalid"], cwd: repo)
                try await git(["commit", "--quiet", "--allow-empty", "-m", "empty fixture anchor"], cwd: repo)
                let anchor = try await git(["rev-parse", "HEAD"], cwd: repo).trimmingCharacters(in: .whitespacesAndNewlines)
                let parent = GitWorktree(repo: repo, path: base + "/Parent",
                    branch: "mythos/auto-evolve-fixture-parent", base: anchor)
                try await git(["worktree", "add", "--quiet", "-b", parent.branch, parent.path, anchor], cwd: repo)
                try Data("41\n".utf8).write(to: URL(fileURLWithPath: parent.path + "/answer.txt"))
                let firstParent = try GitIsolation.commitEvolutionCandidate(parent, message: "fixed parent answer data")
                let child = GitWorktree(repo: repo, path: base + "/Child",
                    branch: "mythos/auto-evolve-fixture-child", base: firstParent.commitSHA)
                try await git(["worktree", "add", "--quiet", "-b", child.branch, child.path, child.base], cwd: repo)
                try Data("42\n".utf8).write(to: URL(fileURLWithPath: child.path + "/answer.txt"))
                _ = try GitIsolation.commitEvolutionCandidate(child, message: "fixed child answer data")
                // Worktree registration can change Git directory metadata. Freeze both subjects
                // only after setup is complete, then revalidate around every actual capture.
                let parentSnapshot = try GitIsolation.captureEvolutionArchiveCandidate(
                    repo: repo, worktreePath: parent.path, branch: parent.branch, baseSHA: parent.base)
                let childSnapshot = try GitIsolation.captureEvolutionArchiveCandidate(
                    repo: repo, worktreePath: child.path, branch: child.branch, baseSHA: child.base)
                XCTAssertEqual(childSnapshot.baseSHA, parentSnapshot.commitSHA)
                XCTAssertEqual(parentSnapshot.changedFiles, ["answer.txt"])
                XCTAssertEqual(childSnapshot.changedFiles, ["answer.txt"])
                let expectations = [try EvolutionHeldOutOracle.Expectation(caseID: "fixture-answer",
                    stdoutDigest: BuilderEvidenceDigest.sha256("42\n"), stderrDigest: BuilderEvidenceDigest.sha256(""))]
                let expectationBytes = try EvolutionArchiveAuthorityCodec.canonicalEncoder().encode(expectations)
                try expectationBytes.write(to: URL(fileURLWithPath: oracle + "/expectations.json"))
                guard chmod(oracle + "/expectations.json", 0o600) == 0 else { throw FixtureError.storage }
                // These are fixture identities, not a claim to attest a compiled production evaluator.
                // The complete host fixture source binds stimuli and recipe; the real tool bytes bind cat.
                let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
                var evaluatorBytes = try boundedData(sourceRoot.appendingPathComponent("Sources/AgentCore/EvolutionHeldOutOracle.swift"), limit: 128 * 1024)
                evaluatorBytes.append(try boundedData(sourceRoot.appendingPathComponent("Sources/AgentCore/EvolutionCapabilityFitness.swift"), limit: 128 * 1024))
                let frozen = try EvolutionCapabilityFrozenInputs(
                    corpusDigest: EvolutionHeldOutOracle.corpusDigest(expectations),
                    harnessDigest: EvolutionArchiveAuthorityCodec.sha256Hex(try boundedData(URL(fileURLWithPath: #filePath), limit: 128 * 1024)),
                    evaluatorDigest: EvolutionArchiveAuthorityCodec.sha256Hex(evaluatorBytes),
                    providerDigest: BuilderEvidenceDigest.sha256("fixture-only/no-provider"),
                    modelDigest: BuilderEvidenceDigest.sha256("fixture-only/no-model"),
                    toolsetDigest: EvolutionArchiveAuthorityCodec.sha256Hex(try boundedData(URL(fileURLWithPath: "/bin/cat"), limit: 4 * 1024 * 1024)))
                let parentIdentity = try subject(parentSnapshot), childIdentity = try subject(childSnapshot)
                let preparation = EvolutionPairedBenchmarkPreparation(plan: try EvolutionCapabilityEvaluationPlan(
                    parentIdentity: parentIdentity, childBaseIdentity: parentIdentity,
                    childIdentity: childIdentity, frozenInputs: frozen), expectations: expectations)
                return Fixture(base: base, repo: repo, oracleDirectory: oracle, expectationBytes: expectationBytes,
                    parent: parent, child: child, parentSnapshot: parentSnapshot,
                    childSnapshot: childSnapshot, preparation: preparation)
            } catch {
                try? FileManager.default.removeItem(atPath: rawBase)
                throw error
            }
        }

        func capture(_ role: EvolutionCapabilityArm, cap: Int = 1024) async throws -> EvolutionHeldOutOracle.Arm {
            let outcome = try await runCat(role, argument: "answer.txt", cap: cap)
            XCTAssertEqual(outcome.stdoutDigest.count, 64)
            XCTAssertEqual(outcome.stderrDigest.count, 64)
            XCTAssertEqual(outcome.effectiveLauncherDigest.count, 64)
            XCTAssertEqual(outcome.effectiveEnvironmentDigest.count, 64)
            XCTAssertEqual(outcome.sandboxProfileDigest?.count, 64)
            if cap > 3 {
                XCTAssertEqual(outcome.exitCode, 0, outcome.combined)
                XCTAssertEqual(outcome.stdout, role == .parent ? "41\n" : "42\n", outcome.combined)
                XCTAssertEqual(outcome.stdoutByteCount, 3)
                XCTAssertEqual(outcome.stderrByteCount, 0)
            }
            return .init(identity: role == .parent ? preparation.plan.parentIdentity : preparation.plan.childIdentity,
                frozenInputs: preparation.plan.frozenInputs,
                observations: [.init(caseID: "fixture-answer", outcome: outcome)])
        }

        func runCat(_ role: EvolutionCapabilityArm, argument: String, cap: Int = 1024) async throws -> ProcessGroupRunner.Outcome {
            let worktree = role == .parent ? parent : child
            let snapshot = role == .parent ? parentSnapshot : childSnapshot
            try GitIsolation.validateEvolutionCandidate(worktree, expected: snapshot)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: expectationsPath)), expectationBytes)
            let invocation = OperatorActionHost.CheckInvocation(executable: "/bin/cat", arguments: [argument],
                workspace: worktree.path, authorityRoot: oracleDirectory, projectRoot: repo, timeoutSeconds: 5)
            // This is the existing advisory operator wrapper for a fixed trusted reader. It is
            // intentionally not passed off as evolution's unavailable hard-containment backend.
            guard case .wrapped(let executable, let arguments) = OperatorActionHost.wrapped(invocation),
                  executable == "/usr/bin/sandbox-exec", arguments.count >= 3, arguments[0] == "-p" else {
                throw FixtureError.sandboxUnavailable
            }
            XCTAssertTrue(arguments[1].contains("(deny network*)"))
            XCTAssertTrue(arguments[1].contains("(deny file-link)"))
            capturedRoles.append(role)
            let outcome = await ProcessGroupRunner.runAsync(launchPath: executable, launchArgs: arguments,
                cwd: worktree.path, env: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "HOME": worktree.path, "TMPDIR": worktree.path + "/", "LANG": "C", "LC_ALL": "C"],
                timeoutSeconds: 5, capPerStream: cap, graceSeconds: 1)
            try GitIsolation.validateEvolutionCandidate(worktree, expected: snapshot)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: expectationsPath)), expectationBytes)
            // The runner fills this metadata only inside a registered Builder attestation scope.
            // This DEBUG fixture instead records the exact profile bytes it supplied to the real
            // sandbox-exec launch. Copying the outcome preserves every observed stream, count,
            // digest, exit, cancellation, timeout, signal and truncation field unchanged. This
            // configuration digest is not a Builder attestation or hard-containment authority;
            // the positive test still requires the unsigned report to be refused by the archive.
            let suppliedProfileDigest = BuilderEvidenceDigest.sha256(arguments[1])
            if let existingDigest = outcome.sandboxProfileDigest, existingDigest != suppliedProfileDigest {
                throw FixtureError.profileMismatch
            }
            var fixtureOutcome = outcome
            fixtureOutcome.sandboxProfileDigest = suppliedProfileDigest
            return fixtureOutcome
        }

        func remove() {
            do { try FileManager.default.removeItem(atPath: base) }
            catch { XCTFail("Could not remove disposable oracle fixture: \(error)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: base))
        }

        @discardableResult
        private static func git(_ arguments: [String], cwd: String) async throws -> String {
            let result = await ProcessGroupRunner.runAsync(launchPath: "/usr/bin/git",
                launchArgs: ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments,
                cwd: cwd, env: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": cwd,
                    "LANG": "C", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"],
                timeoutSeconds: 10, capPerStream: 16 * 1024, graceSeconds: 1)
            guard result.exitCode == 0, !result.timedOut, !result.cancelled,
                  !result.wasSignalled, !result.outputTruncated else {
                throw FixtureError.git(result.combined)
            }
            return result.stdout
        }

        private static func subject(_ snapshot: GitIsolation.EvolutionCommitSnapshot) throws -> EvolutionCapabilitySubjectIdentity {
            try .init(commitSHA: snapshot.commitSHA, treeSHA: snapshot.treeSHA, gitControlDigest: snapshot.gitControlDigest)
        }

        private static func boundedData(_ url: URL, limit: Int) throws -> Data {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            while let part = try handle.read(upToCount: min(16 * 1024, limit + 1 - data.count)), !part.isEmpty {
                data.append(part)
                guard data.count <= limit else { throw FixtureError.storage }
            }
            guard !data.isEmpty else { throw FixtureError.storage }
            return data
        }

        private enum FixtureError: Error { case storage, sandboxUnavailable, profileMismatch, git(String) }
    }
}
#endif
