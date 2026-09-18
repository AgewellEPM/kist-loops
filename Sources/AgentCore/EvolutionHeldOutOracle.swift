import Foundation

/// A paired host-referee result. Deliberately not Codable and without a public initializer: decoded
/// case booleans and the pure fitness contract cannot be substituted for host comparison. This result
/// still needs a one-use, hard-contained execution receipt before it can authorize archive fitness.
public struct EvolutionHeldOutOracleReport: Sendable, Equatable {
    public let fitness: EvolutionCapabilityFitnessReceiptInput

    fileprivate init(fitness: EvolutionCapabilityFitnessReceiptInput) { self.fitness = fitness }
}

/// Host-side comparison of full captured streams against private expectations. Neither expected bytes
/// nor expected digests should enter candidate prompts, tool roots, argv, environment, or archive text.
/// Provisioning and running that private suite in qualifying containment remains unavailable; these
/// internal entry points do not load a corpus, spawn a process, mint a receipt, or change readiness.
enum EvolutionHeldOutOracle {
    struct Expectation: Codable, Sendable, Equatable {
        let caseID: String
        let expectedExitCode: Int32
        let stdoutDigest: String
        let stderrDigest: String

        init(caseID: String, expectedExitCode: Int32 = 0,
             stdoutDigest: String, stderrDigest: String) throws {
            _ = try EvolutionCapabilityCaseResult(
                caseID: caseID, passed: false, evidenceDigest: stdoutDigest)
            guard (0..<125).contains(expectedExitCode),
                  EvolutionArchiveAuthorityCodec.isDigest(stderrDigest) else {
                throw Error.invalidCorpus
            }
            self.caseID = caseID
            self.expectedExitCode = expectedExitCode
            self.stdoutDigest = stdoutDigest
            self.stderrDigest = stderrDigest
        }
    }

    /// Constructed inside the host executor from its captured process outcome, never child JSON.
    struct Observation: Sendable {
        let caseID: String
        let outcome: ProcessGroupRunner.Outcome

        init(caseID: String, outcome: ProcessGroupRunner.Outcome) {
            self.caseID = caseID
            self.outcome = outcome
        }
    }

    struct Arm: Sendable {
        let identity: EvolutionCapabilitySubjectIdentity
        let frozenInputs: EvolutionCapabilityFrozenInputs
        let observations: [Observation]
    }

    enum Error: Swift.Error, LocalizedError, Equatable {
        case invalidCorpus
        case corpusMismatch
        case caseSetMismatch(EvolutionCapabilityArm)
        case invalidObservation(EvolutionCapabilityArm)
        case candidateMismatch

        var errorDescription: String? {
            switch self {
            case .invalidCorpus: return "held-out corpus is empty, duplicated, oversized, or invalid"
            case .corpusMismatch: return "private held-out corpus differs from the frozen evaluation plan"
            case .caseSetMismatch(let arm): return "\(arm.rawValue) did not execute exactly the private held-out case set"
            case .invalidObservation(let arm): return "\(arm.rawValue) lacks complete host-captured execution evidence"
            case .candidateMismatch: return "held-out fitness is not bound to this child's exact parent, commit, tree, and Git control state"
            }
        }
    }

    static let unavailableReason = "host held-out referee is connected to benchmark authority, but private-suite execution in qualifying hard containment is not available"

    /// The caller must freeze this digest before either arm. Ordering cannot change corpus identity.
    static func corpusDigest(_ expectations: [Expectation]) throws -> String {
        guard !expectations.isEmpty, expectations.count <= 4_096,
              Set(expectations.map(\.caseID)).count == expectations.count else {
            throw Error.invalidCorpus
        }
        // Revalidate even if a future internal loader uses synthesized Codable decoding.
        for item in expectations {
            _ = try Expectation(caseID: item.caseID, expectedExitCode: item.expectedExitCode,
                                stdoutDigest: item.stdoutDigest, stderrDigest: item.stderrDigest)
        }
        let data = try EvolutionArchiveAuthorityCodec.canonicalEncoder().encode(
            expectations.sorted { $0.caseID < $1.caseID })
        return EvolutionArchiveAuthorityCodec.sha256Hex(data)
    }

    static func evaluate(plan: EvolutionCapabilityEvaluationPlan,
                         expectations: [Expectation], parent: Arm, child: Arm) throws
        -> EvolutionHeldOutOracleReport {
        guard try corpusDigest(expectations) == plan.frozenInputs.corpusDigest else {
            throw Error.corpusMismatch
        }
        let parentResult = try grade(.parent, arm: parent, expectations: expectations)
        let childResult = try grade(.child, arm: child, expectations: expectations)
        return EvolutionHeldOutOracleReport(fitness: try EvolutionCapabilityFitnessEvaluator.evaluate(
            plan: plan, parent: parentResult, child: childResult))
    }

    static func validate(_ fitness: EvolutionCapabilityFitnessReceiptInput?,
                         baseSHA: String, commitSHA: String, treeSHA: String,
                         gitControlDigest: String) -> Bool {
        guard let fitness else { return false }
        let plan = fitness.plan
        return plan.parentIdentity.commitSHA == baseSHA
            && plan.childBaseIdentity == plan.parentIdentity
            && plan.childIdentity.commitSHA == commitSHA
            && plan.childIdentity.treeSHA == treeSHA
            && plan.childIdentity.gitControlDigest == gitControlDigest
            && fitness.solvedCountDelta > 0
            && !fitness.newlySolvedCaseIDs.isEmpty
            && fitness.regressedCaseIDs.isEmpty
            && fitness.parentInfrastructureSucceeded && fitness.childInfrastructureSucceeded
    }

    static func grade(_ role: EvolutionCapabilityArm, arm: Arm,
                              expectations: [Expectation]) throws -> EvolutionCapabilityArmResult {
        let expectedIDs = Set(expectations.map(\.caseID))
        let actualIDs = arm.observations.map(\.caseID)
        guard actualIDs.count == expectedIDs.count, Set(actualIDs) == expectedIDs else {
            throw Error.caseSetMismatch(role)
        }
        let expectedByID = Dictionary(uniqueKeysWithValues: expectations.map { ($0.caseID, $0) })
        var results: [EvolutionCapabilityCaseResult] = []
        var infrastructureSucceeded = true
        for observation in arm.observations.sorted(by: { $0.caseID < $1.caseID }) {
            let outcome = observation.outcome
            let digests = [outcome.stdoutDigest, outcome.stderrDigest,
                           outcome.effectiveLauncherDigest, outcome.effectiveEnvironmentDigest,
                           outcome.sandboxProfileDigest ?? ""]
            guard outcome.stdoutByteCount >= 0, outcome.stderrByteCount >= 0,
                  digests.allSatisfy(EvolutionArchiveAuthorityCodec.isDigest) else {
                throw Error.invalidObservation(role)
            }
            let infrastructureOK = !outcome.timedOut && !outcome.wasSignalled
                && !outcome.outputTruncated && !outcome.stdoutTruncated
                && !outcome.stderrTruncated && !outcome.cancelled
                && (0..<125).contains(outcome.exitCode)
            infrastructureSucceeded = infrastructureSucceeded && infrastructureOK
            let expected = expectedByID[observation.caseID]!
            let passed = infrastructureOK && outcome.exitCode == expected.expectedExitCode
                && outcome.stdoutDigest == expected.stdoutDigest
                && outcome.stderrDigest == expected.stderrDigest
            // Only observed data enters evidence. Keeping expectations out of the archive avoids
            // disclosing the private answer through candidate-visible benchmark output.
            let evidence = BuilderEvidenceDigest.sha256(([
                "kist.evolution.held-out-observation.v1", role.rawValue, observation.caseID,
                String(outcome.exitCode), String(outcome.stdoutByteCount), String(outcome.stderrByteCount),
                String(outcome.timedOut), String(outcome.wasSignalled), String(outcome.outputTruncated),
                String(outcome.stdoutTruncated), String(outcome.stderrTruncated), String(outcome.cancelled),
            ] + digests).joined(separator: "\u{0}"))
            results.append(try EvolutionCapabilityCaseResult(
                caseID: observation.caseID, passed: passed, evidenceDigest: evidence))
        }
        return try EvolutionCapabilityArmResult(
            arm: role, identity: arm.identity, frozenInputs: arm.frozenInputs,
            infrastructureSucceeded: infrastructureSucceeded,
            infrastructureEvidenceDigest: BuilderEvidenceDigest.sha256(
                (["kist.evolution.held-out-arm.v1", role.rawValue]
                 + results.map(\.evidenceDigest)).joined(separator: "\u{0}")),
            cases: results)
    }
}
