import Foundation
import XCTest
@testable import AgentCore

/// Production archive fitness must bottom out in exact hard-containment authority. Advisory benchmark data
/// and DEBUG fixture receipts remain useful for regression tests, but neither may cross that boundary.
final class EvolutionContainmentAuthorityTests: XCTestCase {
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

    private func candidate() -> GitIsolation.EvolutionCommitSnapshot {
        GitIsolation.EvolutionCommitSnapshot(
            baseSHA: String(repeating: "1", count: 40),
            commitSHA: String(repeating: "2", count: 40),
            treeSHA: String(repeating: "3", count: 40),
            gitControlDigest: String(repeating: "4", count: 64),
            branch: "mythos/auto-evolve-containment-test",
            changedFiles: ["Candidate.txt"],
            committedDiff: "diff --git a/Candidate.txt b/Candidate.txt\n+candidate\n")
    }

    private func benchmark(for candidate: GitIsolation.EvolutionCommitSnapshot)
        -> EvolutionBenchmarkResult {
        EvolutionTestAuthority.benchmark(
            command: "swift test", commitSHA: candidate.commitSHA,
            treeSHA: candidate.treeSHA,
            gitControlDigest: candidate.gitControlDigest,
            hostStateDigest: hostDigest)
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

    func testProductionIssuerRequiresAndBindsExactContainedBatchDigest() throws {
        let candidate = candidate()
        let benchmarks = [benchmark(for: candidate)]
        let oracle = try EvolutionHeldOutOracleTestFixture.report(candidate: candidate)
        let diffDigest = EvolutionArchiveAuthorityCodec.sha256Hex(
            Data(candidate.committedDiff.utf8))
        let expected = try EvolutionEvaluationAuthority.containmentExecutionDigest(
            baseSHA: candidate.baseSHA, commitSHA: candidate.commitSHA,
            treeSHA: candidate.treeSHA, gitControlDigest: candidate.gitControlDigest,
            branch: candidate.branch, changedFiles: candidate.changedFiles,
            committedDiffDigest: diffDigest, hostStateDigest: hostDigest,
            integrityDigest: EvolutionEvaluationAuthority.integrityDigest([]),
            requiredCommands: ["swift test"], benchmarks: benchmarks,
            capabilityFitness: oracle.fitness)
        let receipt = try EvolutionEvaluationAuthority.issue(
            candidate: candidate, hostStateDigest: hostDigest,
            requiredCommands: ["swift test"], benchmarks: benchmarks,
            heldOutOracle: oracle,
            containment: validatedContainment(executionDigest: expected))

        XCTAssertEqual(receipt.containmentExecutionDigest, expected)
        let record = EvolutionEvaluator.evaluate(
            runID: "run", candidateID: "candidate", parentID: nil,
            objective: "improve", branch: candidate.branch,
            worktreePath: "/tmp/candidate", baseSHA: candidate.baseSHA,
            commitSHA: candidate.commitSHA, treeSHA: candidate.treeSHA,
            gitControlDigest: candidate.gitControlDigest,
            hostStateDigest: hostDigest, committedDiff: candidate.committedDiff,
            benchmarkAuthority: receipt, capabilityFitness: oracle.fitness,
            changedFiles: candidate.changedFiles,
            benchmarks: benchmarks,
            policy: EvolutionPolicy(requiredBenchmarkCommands: ["swift test"]),
            createdAtEpoch: 1)
        XCTAssertEqual(record.status, .passed)
        XCTAssertEqual(record.evaluationContainmentExecutionDigest, expected)
        XCTAssertNil(EvolutionEvaluationAuthority.validationError(
            record, allowTestAuthority: false))
        let sealed = try EvolutionArchiveAuthorityCodec.seal(
            record, projectIdentity: String(repeating: "a", count: 64),
            sequence: 0, previousHash: EvolutionArchiveAuthorityCodec.zeroHash)
        XCTAssertEqual(sealed.capabilityFitness, oracle.fitness)
        XCTAssertEqual(EvolutionArchiveAuthorityCodec.withoutAuthority(sealed).capabilityFitness,
                       oracle.fitness)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(record)) as? [String: Any])
        var fitnessJSON = try XCTUnwrap(encoded["capabilityFitness"] as? [String: Any])
        var planJSON = try XCTUnwrap(fitnessJSON["plan"] as? [String: Any])
        var frozenJSON = try XCTUnwrap(planJSON["frozenInputs"] as? [String: Any])
        frozenJSON["corpusDigest"] = String(repeating: "e", count: 64)
        planJSON["frozenInputs"] = frozenJSON
        fitnessJSON["plan"] = planJSON
        encoded["capabilityFitness"] = fitnessJSON
        let tampered = try JSONDecoder().decode(
            EvolutionCandidateRecord.self, from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertNotNil(EvolutionEvaluationAuthority.validationError(tampered, allowTestAuthority: false),
                        "valid but replaced paired data must invalidate the execution receipt")

        let withoutFitness = EvolutionEvaluator.evaluate(
            runID: "run", candidateID: "missing-oracle", parentID: nil,
            objective: "improve", branch: candidate.branch,
            worktreePath: "/tmp/candidate", baseSHA: candidate.baseSHA,
            commitSHA: candidate.commitSHA, treeSHA: candidate.treeSHA,
            gitControlDigest: candidate.gitControlDigest,
            hostStateDigest: hostDigest, committedDiff: candidate.committedDiff,
            benchmarkAuthority: receipt, changedFiles: candidate.changedFiles,
            benchmarks: benchmarks,
            policy: EvolutionPolicy(requiredBenchmarkCommands: ["swift test"]), createdAtEpoch: 1)
        XCTAssertEqual(withoutFitness.status, .blocked,
                       "a benchmark receipt alone cannot supply paired capability fitness")
        XCTAssertFalse(EvolutionAutonomyReadinessAssessment.current.ready,
                       "fixture execution never arms the production readiness gates")

        XCTAssertThrowsError(try EvolutionEvaluationAuthority.issue(
            candidate: candidate, hostStateDigest: hostDigest,
            requiredCommands: ["swift test"], benchmarks: benchmarks,
            heldOutOracle: oracle,
            containment: validatedContainment(
                executionDigest: String(repeating: "e", count: 64))))
    }

    func testAdvisoryBatchCarriesNoReceiptAndCannotCreateFitnessAuthority() {
        let candidate = candidate()
        let advisory = EvolutionAdvisoryBenchmarkBatchForTesting(
            results: [benchmark(for: candidate)])
        XCTAssertEqual(Mirror(reflecting: advisory).children.compactMap(\.label), ["results"])

        let record = EvolutionEvaluator.evaluate(
            runID: "run", candidateID: "advisory", parentID: nil,
            objective: "improve", branch: candidate.branch,
            worktreePath: "/tmp/candidate", baseSHA: candidate.baseSHA,
            commitSHA: candidate.commitSHA, treeSHA: candidate.treeSHA,
            gitControlDigest: candidate.gitControlDigest,
            hostStateDigest: hostDigest, committedDiff: candidate.committedDiff,
            benchmarkAuthority: nil, changedFiles: candidate.changedFiles,
            benchmarks: advisory.results,
            policy: EvolutionPolicy(requiredBenchmarkCommands: ["swift test"]),
            createdAtEpoch: 1)
        XCTAssertEqual(record.status, .blocked)
        XCTAssertNil(record.evaluationReceiptID)
        XCTAssertNil(record.evaluationContainmentExecutionDigest)
    }

    func testDebugFixtureReceiptCannotValidateAsProductionAuthority() {
        let unsigned = EvolutionCandidateRecord(
            runID: "run", candidateID: "fixture", parentID: nil,
            objective: "fixture", branch: "mythos/auto-evolve-fixture",
            worktreePath: "/tmp/fixture",
            baseSHA: String(repeating: "1", count: 40),
            commitSHA: String(repeating: "2", count: 40),
            status: .passed, score: 1, changedFiles: ["Candidate.txt"],
            protectedFiles: [], benchmarks: [], summary: "fixture",
            createdAtEpoch: 1)
        let fixture = EvolutionTestAuthority.authoritative(unsigned)

        XCTAssertEqual(
            fixture.evaluationContainmentExecutionDigest,
            EvolutionEvaluationAuthority.testOnlyContainmentDigest)
        XCTAssertNil(EvolutionEvaluationAuthority.validationError(
            fixture, allowTestAuthority: true))
        XCTAssertNotNil(EvolutionEvaluationAuthority.validationError(
            fixture, allowTestAuthority: false),
            "a serialized DEBUG fixture receipt must be sterile in a production authority check")
    }
}
