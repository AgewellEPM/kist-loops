import Foundation
import XCTest
@testable import AgentCore

/// The known-inflated-candidate contract: a candidate whose visible benchmarks all pass but whose
/// held-out paired fitness is absent, replayed from another candidate, or bound to a different sealed
/// lineage parent must be rejected at EVERY enforcement site, not just the one that first caught it.
/// One assertion per site, named, so a regression tells you WHICH gate went soft.
final class EvolutionInflatedCandidateRejectionTests: XCTestCase {
    private let nowMillis: Int64 = 2_000_000_000_000
    private let hostDigest = String(repeating: "5", count: 64)

    override func setUp() {
        super.setUp()
        ForgeSeal.forceEphemeralKeyForTesting()
    }

    override func tearDown() {
        ForgeSeal.resetCacheForTesting()
        super.tearDown()
    }

    private func candidate(treeSHA: String = String(repeating: "3", count: 40))
        -> GitIsolation.EvolutionCommitSnapshot {
        GitIsolation.EvolutionCommitSnapshot(
            baseSHA: String(repeating: "1", count: 40),
            commitSHA: String(repeating: "2", count: 40),
            treeSHA: treeSHA,
            gitControlDigest: String(repeating: "4", count: 64),
            branch: "mythos/auto-evolve-inflation-test",
            changedFiles: ["Candidate.txt"],
            committedDiff: "diff --git a/Candidate.txt b/Candidate.txt\n+candidate\n")
    }

    private func validatedContainment(executionDigest: String)
        throws -> ValidatedHardProcessContainment {
        let scopeID = UUID().uuidString.lowercased()
        let limits = HardProcessContainmentLimits(
            aggregateCPUTimeMicros: 3_000_000,
            aggregateMemoryBytes: 256 * 1_024 * 1_024,
            aggregateProcessCount: 32)
        let mechanismDigest = String(repeating: "a", count: 64)
        let policyDigest = String(repeating: "b", count: 64)
        let requirement = HardProcessContainmentRequirement(
            scopeID: scopeID, mechanism: .linuxDelegatedCgroupV2, limits: limits,
            mechanismDigest: mechanismDigest, policyDigest: policyDigest,
            expectedExecutionDigest: executionDigest)
        let membership = HardProcessContainmentMembershipEvidence(
            scopeEstablishedBeforeExec: true, launcherJoinedBeforeExec: true,
            membershipEstablishedAtomically: true, descendantsInheritMembership: true,
            descendantEscapePrevented: true, aggregateCPUTimeEnforced: true,
            aggregateMemoryEnforced: true, aggregateProcessCountEnforced: true,
            scopeCreatedAtMillis: nowMillis - 1_000,
            membershipVerifiedAtMillis: nowMillis - 900,
            executionStartedAtMillis: nowMillis - 800)
        let cleanup = HardProcessContainmentCleanupEvidence(
            killAllIssued: true, killAllCompleted: true, scopeEmptyVerified: true,
            remainingProcessCount: 0, killAllIssuedAtMillis: nowMillis - 500,
            emptyVerifiedAtMillis: nowMillis - 300)
        let receipt = HardProcessContainmentReceipt(
            scopeID: scopeID, platform: .linux, mechanism: .linuxDelegatedCgroupV2,
            limits: limits, mechanismDigest: mechanismDigest, policyDigest: policyDigest,
            executionDigest: executionDigest, membership: membership, cleanup: cleanup,
            issuedAtMillis: nowMillis - 100, validUntilMillis: nowMillis + 60_000)
        return try HardProcessContainmentReplayGuard().consume(
            receipt, satisfying: requirement, hostPlatform: .linux, nowMillis: nowMillis)
    }

    /// A positive paired report whose parent identity is chosen by the test, so lineage
    /// agreement and disagreement with a sealed archive parent can both be constructed.
    private func report(parent: EvolutionCapabilitySubjectIdentity,
                        child: EvolutionCapabilitySubjectIdentity) throws
        -> EvolutionHeldOutOracleReport {
        let expectations = [try EvolutionHeldOutOracle.Expectation(
            caseID: "opaque-case-1", stdoutDigest: BuilderEvidenceDigest.sha256("42\n"),
            stderrDigest: BuilderEvidenceDigest.sha256(""))]
        let frozen = try EvolutionCapabilityFrozenInputs(
            corpusDigest: EvolutionHeldOutOracle.corpusDigest(expectations),
            harnessDigest: String(repeating: "6", count: 64),
            evaluatorDigest: String(repeating: "7", count: 64),
            providerDigest: String(repeating: "8", count: 64),
            modelDigest: String(repeating: "9", count: 64),
            toolsetDigest: String(repeating: "a", count: 64))
        let plan = try EvolutionCapabilityEvaluationPlan(
            parentIdentity: parent, childBaseIdentity: parent, childIdentity: child,
            frozenInputs: frozen)
        func arm(_ role: EvolutionCapabilityArm, stdout: String) -> EvolutionHeldOutOracle.Arm {
            var outcome = ProcessGroupRunner.Outcome(combined: stdout, exitCode: 0, timedOut: false)
            outcome.stdout = stdout
            outcome.stdoutByteCount = stdout.utf8.count
            outcome.stdoutDigest = BuilderEvidenceDigest.sha256(stdout)
            outcome.sandboxProfileDigest = String(repeating: "d", count: 64)
            return .init(identity: role == .parent ? parent : child, frozenInputs: frozen,
                         observations: [.init(caseID: "opaque-case-1", outcome: outcome)])
        }
        return try EvolutionHeldOutOracle.evaluate(
            plan: plan, expectations: expectations,
            parent: arm(.parent, stdout: "41\n"), child: arm(.child, stdout: "42\n"))
    }

    // MARK: Site 1 — EvolutionEvaluator (scoring)

    func testScorerBlocksInflatedCandidateWhoseFitnessBindsAnotherTree() throws {
        let honest = candidate()
        let benchmarks = [EvolutionTestAuthority.benchmark(
            command: "swift test", commitSHA: honest.commitSHA, treeSHA: honest.treeSHA,
            gitControlDigest: honest.gitControlDigest, hostStateDigest: hostDigest)]
        let oracle = try EvolutionHeldOutOracleTestFixture.report(candidate: honest)
        let diffDigest = EvolutionArchiveAuthorityCodec.sha256Hex(Data(honest.committedDiff.utf8))
        let expected = try EvolutionEvaluationAuthority.containmentExecutionDigest(
            baseSHA: honest.baseSHA, commitSHA: honest.commitSHA,
            treeSHA: honest.treeSHA, gitControlDigest: honest.gitControlDigest,
            branch: honest.branch, changedFiles: honest.changedFiles,
            committedDiffDigest: diffDigest, hostStateDigest: hostDigest,
            integrityDigest: EvolutionEvaluationAuthority.integrityDigest([]),
            requiredCommands: ["swift test"], benchmarks: benchmarks,
            capabilityFitness: oracle.fitness)
        let receipt = try EvolutionEvaluationAuthority.issue(
            candidate: honest, hostStateDigest: hostDigest,
            requiredCommands: ["swift test"], benchmarks: benchmarks,
            heldOutOracle: oracle,
            containment: validatedContainment(executionDigest: expected))

        func evaluate(treeSHA: String, benchmarks: [EvolutionBenchmarkResult],
                      receipt: EvolutionBenchmarkAuthorityReceipt?) -> EvolutionCandidateRecord {
            EvolutionEvaluator.evaluate(
                runID: "run", candidateID: "candidate", parentID: nil,
                objective: "improve", branch: honest.branch,
                worktreePath: "/tmp/candidate", baseSHA: honest.baseSHA,
                commitSHA: honest.commitSHA, treeSHA: treeSHA,
                gitControlDigest: honest.gitControlDigest,
                hostStateDigest: hostDigest, committedDiff: honest.committedDiff,
                benchmarkAuthority: receipt, capabilityFitness: oracle.fitness,
                changedFiles: honest.changedFiles, benchmarks: benchmarks,
                policy: EvolutionPolicy(requiredBenchmarkCommands: ["swift test"]),
                createdAtEpoch: 1)
        }
        // Differential proof: the exact same evidence passes for the bound tree…
        XCTAssertEqual(
            evaluate(treeSHA: honest.treeSHA, benchmarks: benchmarks, receipt: receipt).status,
            .passed)
        // …while an impostor tree with internally coherent benchmark evidence — the shape a
        // candidate inflating its score would need — is rejected FOR the paired-fitness binding.
        // No receipt can exist for this shape (the issuer site refuses it below), so the scorer
        // is exercised with the strongest evidence an inflated candidate could actually present.
        let impostorTree = String(repeating: "f", count: 40)
        let impostorBenchmarks = [EvolutionTestAuthority.benchmark(
            command: "swift test", commitSHA: honest.commitSHA, treeSHA: impostorTree,
            gitControlDigest: honest.gitControlDigest, hostStateDigest: hostDigest)]
        let inflated = evaluate(treeSHA: impostorTree, benchmarks: impostorBenchmarks,
                                receipt: nil)
        XCTAssertEqual(inflated.status, .blocked,
                       "scorer accepted held-out fitness bound to a different tree")
        XCTAssertEqual(inflated.score, 0)
        XCTAssertTrue(inflated.summary.contains("missing exact-parent positive held-out host fitness"),
                      "scorer must name the missing paired-fitness evidence: \(inflated.summary)")
    }

    // MARK: Site 2 — EvolutionEvaluationAuthority.issue (host receipt minting)

    func testIssuerRefusesOracleReportMintedForAnotherCandidate() throws {
        let honest = candidate()
        let oracle = try EvolutionHeldOutOracleTestFixture.report(candidate: honest)
        let impostor = candidate(treeSHA: String(repeating: "f", count: 40))
        let containment = try validatedContainment(
            executionDigest: String(repeating: "e", count: 64))
        XCTAssertThrowsError(try EvolutionEvaluationAuthority.issue(
            candidate: impostor, hostStateDigest: hostDigest,
            requiredCommands: ["swift test"],
            benchmarks: [EvolutionTestAuthority.benchmark(
                command: "swift test", commitSHA: impostor.commitSHA,
                treeSHA: impostor.treeSHA, gitControlDigest: impostor.gitControlDigest,
                hostStateDigest: hostDigest)],
            heldOutOracle: oracle, containment: containment),
            "authority minting accepted a paired report for a different candidate") {
                XCTAssertEqual($0 as? EvolutionHeldOutOracle.Error, .candidateMismatch)
            }
    }

    // MARK: Site 3 — EvolutionArchiveStore.append (sealed lineage)

    func testArchiveAppendRefusesFitnessBoundToADifferentSealedParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evolution-inflation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EvolutionArchiveStore(root: root.path)

        let parentCommit = String(repeating: "2", count: 40)
        let parentTree = String(repeating: "3", count: 40)
        let control = String(repeating: "4", count: 64)
        try store.append(EvolutionTestAuthority.authoritative(EvolutionCandidateRecord(
            runID: "run", candidateID: "parent", parentID: nil, objective: "improve",
            branch: "mythos/auto-evolve-parent", worktreePath: "/wt/parent",
            baseSHA: String(repeating: "1", count: 40), commitSHA: parentCommit,
            status: .passed, score: 110, changedFiles: ["Candidate.txt"],
            protectedFiles: [], benchmarks: [], summary: "parent", createdAtEpoch: 1,
            treeSHA: parentTree, gitControlDigest: control)))

        let childCommit = String(repeating: "e", count: 40)
        let childTree = String(repeating: "f", count: 40)
        func childRecord(fitness: EvolutionCapabilityFitnessReceiptInput)
            -> EvolutionCandidateRecord {
            EvolutionTestAuthority.authoritative(EvolutionCandidateRecord(
                runID: "run", candidateID: "child", parentID: "parent", objective: "improve",
                branch: "mythos/auto-evolve-child", worktreePath: "/wt/child",
                baseSHA: parentCommit, commitSHA: childCommit,
                status: .passed, score: 120, changedFiles: ["Candidate.txt"],
                protectedFiles: [], benchmarks: [], summary: "child", createdAtEpoch: 2,
                treeSHA: childTree, gitControlDigest: control,
                capabilityFitness: fitness))
        }
        let child = try EvolutionCapabilitySubjectIdentity(
            commitSHA: childCommit, treeSHA: childTree, gitControlDigest: control)
        let foreignParent = try EvolutionCapabilitySubjectIdentity(
            commitSHA: parentCommit, treeSHA: String(repeating: "b", count: 40),
            gitControlDigest: control)
        let inflated = try report(parent: foreignParent, child: child)
        XCTAssertThrowsError(
            try store.append(childRecord(fitness: inflated.fitness)),
            "archive sealed fitness whose parent identity is not the sealed lineage parent") {
                XCTAssertEqual(
                    $0 as? EvolutionArchiveError,
                    .invalidRecord("held-out parent identity differs from the sealed lineage parent"))
            }

        // Control: identical record whose fitness names the true sealed parent appends cleanly.
        let sealedParent = try EvolutionCapabilitySubjectIdentity(
            commitSHA: parentCommit, treeSHA: parentTree, gitControlDigest: control)
        let honest = try report(parent: sealedParent, child: child)
        XCTAssertNoThrow(try store.append(childRecord(fitness: honest.fitness)))
        XCTAssertEqual(store.records().map(\.candidateID), ["parent", "child"])
    }
}
