import Foundation
import XCTest
@testable import AgentCore

enum EvolutionHeldOutOracleTestFixture {
    static func preparation(candidate: GitIsolation.EvolutionCommitSnapshot) throws
        -> EvolutionPairedBenchmarkPreparation {
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
        let parent = try EvolutionCapabilitySubjectIdentity(
            commitSHA: candidate.baseSHA, treeSHA: String(repeating: "b", count: 40),
            gitControlDigest: String(repeating: "c", count: 64))
        let child = try EvolutionCapabilitySubjectIdentity(
            commitSHA: candidate.commitSHA, treeSHA: candidate.treeSHA,
            gitControlDigest: candidate.gitControlDigest)
        return EvolutionPairedBenchmarkPreparation(plan: try EvolutionCapabilityEvaluationPlan(
            parentIdentity: parent, childBaseIdentity: parent, childIdentity: child,
            frozenInputs: frozen), expectations: expectations)
    }

    static func outcome(_ stdout: String) -> ProcessGroupRunner.Outcome {
        var value = ProcessGroupRunner.Outcome(combined: stdout, exitCode: 0, timedOut: false)
        value.stdout = stdout
        value.stdoutByteCount = stdout.utf8.count
        value.stdoutDigest = BuilderEvidenceDigest.sha256(stdout)
        value.sandboxProfileDigest = String(repeating: "d", count: 64)
        return value
    }

    static func arm(_ role: EvolutionCapabilityArm, preparation: EvolutionPairedBenchmarkPreparation,
                    outcome: ProcessGroupRunner.Outcome? = nil) -> EvolutionHeldOutOracle.Arm {
        .init(identity: role == .parent ? preparation.plan.parentIdentity : preparation.plan.childIdentity,
              frozenInputs: preparation.plan.frozenInputs,
              observations: [.init(caseID: "opaque-case-1",
                                   outcome: outcome ?? self.outcome(role == .parent ? "41\n" : "42\n"))])
    }

    static func report(candidate: GitIsolation.EvolutionCommitSnapshot) throws
        -> EvolutionHeldOutOracleReport {
        let prepared = try preparation(candidate: candidate)
        return try EvolutionHeldOutOracle.evaluate(
            plan: prepared.plan, expectations: prepared.expectations,
            parent: arm(.parent, preparation: prepared), child: arm(.child, preparation: prepared))
    }
}

final class EvolutionHeldOutOracleTests: XCTestCase {
    private func candidate() -> GitIsolation.EvolutionCommitSnapshot {
        .init(baseSHA: String(repeating: "1", count: 40),
              commitSHA: String(repeating: "2", count: 40),
              treeSHA: String(repeating: "3", count: 40),
              gitControlDigest: String(repeating: "4", count: 64),
              branch: "mythos/auto-evolve-oracle", changedFiles: ["Candidate.txt"],
              committedDiff: "diff --git a/Candidate.txt b/Candidate.txt\n+42\n")
    }

    func testPairedCoordinatorGradesHostCapturedStreamsInExactParentThenChildOrder() async throws {
        let prepared = try EvolutionHeldOutOracleTestFixture.preparation(candidate: candidate())
        var observed: [EvolutionCapabilityArm] = []
        let report = try await EvolutionPairedBenchmarkCoordinator.evaluatePair(preparation: prepared) { role, plan in
            observed.append(role)
            XCTAssertEqual(plan, prepared.plan)
            return EvolutionHeldOutOracleTestFixture.arm(role, preparation: prepared)
        }
        XCTAssertEqual(observed, [.parent, .child])
        XCTAssertEqual(report.fitness.solvedCountDelta, 1)
        XCTAssertEqual(report.fitness.newlySolvedCaseIDs, ["opaque-case-1"])
        XCTAssertTrue(report.fitness.regressedCaseIDs.isEmpty)
        XCTAssertFalse(EvolutionAutonomyReadinessAssessment.current.ready)
    }

    func testForgedPassProseCannotReplaceExpectedStream() throws {
        let prepared = try EvolutionHeldOutOracleTestFixture.preparation(candidate: candidate())
        let forged = EvolutionHeldOutOracleTestFixture.outcome("{\"passed\":true,\"solvedCountDelta\":100}\n")
        XCTAssertThrowsError(try EvolutionHeldOutOracle.evaluate(
            plan: prepared.plan, expectations: prepared.expectations,
            parent: EvolutionHeldOutOracleTestFixture.arm(.parent, preparation: prepared),
            child: EvolutionHeldOutOracleTestFixture.arm(.child, preparation: prepared, outcome: forged))) {
                XCTAssertEqual($0 as? EvolutionCapabilityFitnessError, .noNewlySolvedCases)
            }
    }

    func testTimeoutTruncationCancellationAndMissingSandboxAreSterile() throws {
        let prepared = try EvolutionHeldOutOracleTestFixture.preparation(candidate: candidate())
        for mutation in [
            { (outcome: inout ProcessGroupRunner.Outcome) in outcome.outputTruncated = true },
            { (outcome: inout ProcessGroupRunner.Outcome) in outcome.stdoutTruncated = true },
            { (outcome: inout ProcessGroupRunner.Outcome) in outcome.stderrTruncated = true },
            { (outcome: inout ProcessGroupRunner.Outcome) in outcome.wasSignalled = true },
            { (outcome: inout ProcessGroupRunner.Outcome) in outcome.cancelled = true },
            { (outcome: inout ProcessGroupRunner.Outcome) in outcome.sandboxProfileDigest = nil },
        ] {
            var outcome = EvolutionHeldOutOracleTestFixture.outcome("42\n")
            mutation(&outcome)
            XCTAssertThrowsError(try EvolutionHeldOutOracle.evaluate(
                plan: prepared.plan, expectations: prepared.expectations,
                parent: EvolutionHeldOutOracleTestFixture.arm(.parent, preparation: prepared),
                child: EvolutionHeldOutOracleTestFixture.arm(.child, preparation: prepared, outcome: outcome)))
        }
        var timedOut = ProcessGroupRunner.Outcome(combined: "42\n", exitCode: 0, timedOut: true)
        timedOut.stdoutDigest = BuilderEvidenceDigest.sha256("42\n")
        timedOut.stdoutByteCount = 3
        timedOut.sandboxProfileDigest = String(repeating: "d", count: 64)
        XCTAssertThrowsError(try EvolutionHeldOutOracle.evaluate(
            plan: prepared.plan, expectations: prepared.expectations,
            parent: EvolutionHeldOutOracleTestFixture.arm(.parent, preparation: prepared),
            child: EvolutionHeldOutOracleTestFixture.arm(.child, preparation: prepared, outcome: timedOut))) {
                XCTAssertEqual($0 as? EvolutionCapabilityFitnessError, .infrastructureFailed(arm: .child))
            }
    }

    func testParentInfrastructureFailureStopsBeforeChildAndCannotBecomeAnImprovement() async throws {
        let prepared = try EvolutionHeldOutOracleTestFixture.preparation(candidate: candidate())
        var calls = 0
        var failedParent = EvolutionHeldOutOracleTestFixture.outcome("41\n")
        failedParent.cancelled = true
        do {
            _ = try await EvolutionPairedBenchmarkCoordinator.evaluatePair(preparation: prepared) { role, _ in
                calls += 1
                return EvolutionHeldOutOracleTestFixture.arm(role, preparation: prepared, outcome: failedParent)
            }
            XCTFail("infrastructure failure must refuse")
        } catch {
            XCTAssertEqual(error as? EvolutionCapabilityFitnessError, .infrastructureFailed(arm: .parent))
        }
        XCTAssertEqual(calls, 1)
    }

    func testUnexpectedStderrIsAnAssertionFailureEvenWhenStdoutMatches() throws {
        let prepared = try EvolutionHeldOutOracleTestFixture.preparation(candidate: candidate())
        var outcome = EvolutionHeldOutOracleTestFixture.outcome("42\n")
        outcome.stderr = "unhandled error"
        outcome.stderrByteCount = outcome.stderr.utf8.count
        outcome.stderrDigest = BuilderEvidenceDigest.sha256(outcome.stderr)
        XCTAssertThrowsError(try EvolutionHeldOutOracle.evaluate(
            plan: prepared.plan, expectations: prepared.expectations,
            parent: EvolutionHeldOutOracleTestFixture.arm(.parent, preparation: prepared),
            child: EvolutionHeldOutOracleTestFixture.arm(.child, preparation: prepared, outcome: outcome))) {
                XCTAssertEqual($0 as? EvolutionCapabilityFitnessError, .noNewlySolvedCases)
            }
    }

    func testChangedPrivateCorpusFailsBeforeEitherArmStarts() async throws {
        let original = try EvolutionHeldOutOracleTestFixture.preparation(candidate: candidate())
        let poisoned = EvolutionPairedBenchmarkPreparation(plan: original.plan, expectations: [
            try .init(caseID: "opaque-case-1", stdoutDigest: BuilderEvidenceDigest.sha256("forged"),
                      stderrDigest: BuilderEvidenceDigest.sha256(""))])
        var calls = 0
        do {
            _ = try await EvolutionPairedBenchmarkCoordinator.evaluatePair(preparation: poisoned) { role, _ in
                calls += 1
                return EvolutionHeldOutOracleTestFixture.arm(role, preparation: original)
            }
            XCTFail("changed corpus must refuse")
        } catch { XCTAssertEqual(error as? EvolutionHeldOutOracle.Error, .corpusMismatch) }
        XCTAssertEqual(calls, 0)
    }

    func testWrongParentRefusesBeforeChildStarts() async throws {
        let prepared = try EvolutionHeldOutOracleTestFixture.preparation(candidate: candidate())
        var calls = 0
        do {
            _ = try await EvolutionPairedBenchmarkCoordinator.evaluatePair(preparation: prepared) { _, _ in
                calls += 1
                return EvolutionHeldOutOracleTestFixture.arm(.child, preparation: prepared)
            }
            XCTFail("wrong parent must refuse")
        } catch {
            XCTAssertEqual(error as? EvolutionCapabilityFitnessError, .armIdentityMismatch(arm: .parent))
        }
        XCTAssertEqual(calls, 1)
    }

    func testOmittedDuplicatedOrRenamedCasesRefuse() throws {
        let prepared = try EvolutionHeldOutOracleTestFixture.preparation(candidate: candidate())
        let good = EvolutionHeldOutOracleTestFixture.arm(.child, preparation: prepared)
        let renamed = EvolutionHeldOutOracle.Observation(
            caseID: "candidate-chosen-easy-case", outcome: EvolutionHeldOutOracleTestFixture.outcome("42\n"))
        for observations in [[], good.observations + good.observations, [renamed]] {
            let child = EvolutionHeldOutOracle.Arm(
                identity: good.identity, frozenInputs: good.frozenInputs, observations: observations)
            XCTAssertThrowsError(try EvolutionHeldOutOracle.evaluate(
                plan: prepared.plan, expectations: prepared.expectations,
                parent: EvolutionHeldOutOracleTestFixture.arm(.parent, preparation: prepared), child: child)) {
                    XCTAssertEqual($0 as? EvolutionHeldOutOracle.Error, .caseSetMismatch(.child))
                }
        }
    }

    func testFitnessCannotBeReplayedAgainstAnotherCandidateOrParent() throws {
        let snapshot = candidate()
        let report = try EvolutionHeldOutOracleTestFixture.report(candidate: snapshot)
        XCTAssertTrue(EvolutionHeldOutOracle.validate(
            report.fitness, baseSHA: snapshot.baseSHA, commitSHA: snapshot.commitSHA,
            treeSHA: snapshot.treeSHA, gitControlDigest: snapshot.gitControlDigest))
        XCTAssertFalse(EvolutionHeldOutOracle.validate(
            report.fitness, baseSHA: String(repeating: "e", count: 40), commitSHA: snapshot.commitSHA,
            treeSHA: snapshot.treeSHA, gitControlDigest: snapshot.gitControlDigest))
        XCTAssertFalse(EvolutionHeldOutOracle.validate(
            report.fitness, baseSHA: snapshot.baseSHA, commitSHA: snapshot.commitSHA,
            treeSHA: String(repeating: "f", count: 40), gitControlDigest: snapshot.gitControlDigest))
    }

    func testNewHostOracleAndCoordinatorAreProtected() {
        let paths = ["Sources/AgentCore/EvolutionHeldOutOracle.swift",
                     "Sources/AgentCore/EvolutionPairedBenchmarkCoordinator.swift"]
        XCTAssertEqual(EvolutionPolicy().protectedFiles(in: paths), paths.sorted())
    }

    func testBlockedArchiveRowCannotLaunderUnsignedPositiveFitness() throws {
        let snapshot = candidate()
        let oracle = try EvolutionHeldOutOracleTestFixture.report(candidate: snapshot)
        let record = EvolutionCandidateRecord(
            runID: "run", candidateID: "candidate", parentID: nil, objective: "improve",
            branch: snapshot.branch, worktreePath: "/tmp/candidate",
            baseSHA: snapshot.baseSHA, commitSHA: snapshot.commitSHA,
            status: .blocked, score: 0, changedFiles: snapshot.changedFiles,
            protectedFiles: [], benchmarks: [], summary: "blocked", createdAtEpoch: 1,
            requiredBenchmarkCommands: ["swift test"], treeSHA: snapshot.treeSHA,
            gitControlDigest: snapshot.gitControlDigest,
            hostStateDigest: String(repeating: "5", count: 64),
            committedDiffDigest: BuilderEvidenceDigest.sha256(snapshot.committedDiff),
            integrityDigest: EvolutionEvaluationAuthority.integrityDigest([]),
            capabilityFitness: oracle.fitness)
        XCTAssertEqual(EvolutionRecordAuthority.validationError(record),
                       .invalidRecord("paired capability fitness lacks its complete host evaluation envelope"))
    }
}
