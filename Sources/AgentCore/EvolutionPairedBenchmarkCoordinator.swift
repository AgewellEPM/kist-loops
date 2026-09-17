import Foundation

/// Internal host service boundary. Implementations must freeze a private, agent-unreadable corpus and
/// both exact Git identities before either arm executes, deny corpus/key/host reads to every descendant,
/// and own containment and cleanup. There is intentionally no public registration or environment hook.
protocol EvolutionPairedBenchmarkBackend: Sendable {
    func prepare(candidate: GitIsolation.EvolutionCommitSnapshot, worktree: GitWorktree,
                 hostRoot: String, commands: [String], timeoutSeconds: Int) async throws
        -> EvolutionPairedBenchmarkPreparation
    func execute(arm: EvolutionCapabilityArm, plan: EvolutionCapabilityEvaluationPlan) async throws
        -> EvolutionHeldOutOracle.Arm
    func finish(candidate: GitIsolation.EvolutionCommitSnapshot,
                preparation: EvolutionPairedBenchmarkPreparation,
                report: EvolutionHeldOutOracleReport, hostStateDigest: String,
                commands: [String]) async throws -> EvolutionPairedBenchmarkCompletion
    /// Must work after partial preparation, cancellation, and any failed arm. True means verified empty.
    func cleanup() async -> Bool
}

struct EvolutionPairedBenchmarkPreparation: Sendable {
    let plan: EvolutionCapabilityEvaluationPlan
    let expectations: [EvolutionHeldOutOracle.Expectation]
}

struct EvolutionPairedBenchmarkCompletion: Sendable {
    let benchmarks: [EvolutionBenchmarkResult]
    /// Covers ordinary benchmarks AND both oracle arms and their exact report digest, after cleanup.
    let containment: ValidatedHardProcessContainment
}

enum EvolutionPairedBenchmarkCoordinator {
    /// Availability is code-owned: the backend TYPE is chosen here in source, never installed by a caller,
    /// fixture, or decoded receipt. On Linux, once an operator has provisioned a qualifying delegated
    /// cgroup-v2 subtree AND a private held-out corpus, the code-owned Linux backend runs each arm under
    /// the delegated-cgroup supervisor + bubblewrap + the seccomp escape-deny filter. Everywhere else, and
    /// whenever either operator resource is absent, this stays nil and evaluation refuses before any
    /// candidate runs. The env vars only point at operator paths; they cannot fabricate the kernel-backed
    /// cgroup qualification the availability probe requires.
    private static var productionBackend: (any EvolutionPairedBenchmarkBackend)? {
        #if os(Linux)
        guard let cgroupRoot = LinuxDelegatedCgroupProbe.configuredRoot,
              LinuxDelegatedCgroupProbe.qualifies(cgroupRoot),
              let corpusDir = ProcessInfo.processInfo.environment["KIST_EVOLUTION_HELDOUT_CORPUS"],
              !corpusDir.isEmpty, corpusDir.hasPrefix("/") else {
            return nil
        }
        return LinuxEvolutionPairedBenchmarkBackend(
            corpusDirectory: corpusDir, delegatedRoot: cgroupRoot,
            limits: HardProcessContainmentLimits(
                aggregateCPUTimeMicros: 120_000_000,
                aggregateMemoryBytes: 2 * 1_024 * 1_024 * 1_024,
                aggregateProcessCount: 256))
        #else
        return nil
        #endif
    }

    static func run(commands: [String], candidate: GitIsolation.EvolutionCommitSnapshot,
                    worktree: GitWorktree, hostRoot: String,
                    expectedHostState: EvolutionBenchmarkRunner.ProtectedHostState,
                    timeoutSeconds: Int) async throws -> EvolutionBenchmarkBatch {
        let availability = HardProcessContainmentRuntime.currentAvailability
        guard availability.available else {
            throw EvolutionBenchmarkRunner.ExecutionError.hardContainmentUnavailable(availability.reason)
        }
        guard let backend = productionBackend else {
            throw EvolutionBenchmarkRunner.ExecutionError.sandboxUnavailable(
                EvolutionHeldOutOracle.unavailableReason)
        }
        do {
            try GitIsolation.validateEvolutionCandidate(worktree, expected: candidate)
            try EvolutionBenchmarkRunner.validateProtectedHostState(expectedHostState)
            let preparation = try await backend.prepare(
                candidate: candidate, worktree: worktree, hostRoot: hostRoot,
                commands: commands, timeoutSeconds: timeoutSeconds)
            let plan = preparation.plan
            guard plan.parentIdentity.commitSHA == candidate.baseSHA,
                  plan.childIdentity.commitSHA == candidate.commitSHA,
                  plan.childIdentity.treeSHA == candidate.treeSHA,
                  plan.childIdentity.gitControlDigest == candidate.gitControlDigest else {
                throw EvolutionHeldOutOracle.Error.candidateMismatch
            }
            let parentTreeBinding = try GitIsolation.evolutionProtectedGitBindings(
                repo: hostRoot, commands: [["rev-parse", "--verify", "--quiet", "\(candidate.baseSHA)^{tree}"]])
            let expectedParentTree = plan.parentIdentity.treeSHA + "\n"
            guard parentTreeBinding == [BuilderEvidenceDigest.sha256(expectedParentTree),
                                        String(expectedParentTree.utf8.count),
                                        BuilderEvidenceDigest.sha256(""), "0"] else {
                throw EvolutionHeldOutOracle.Error.candidateMismatch
            }
            let report = try await evaluatePair(preparation: preparation) { arm, plan in
                try await backend.execute(arm: arm, plan: plan)
            }
            let completion = try await backend.finish(
                candidate: candidate, preparation: preparation, report: report,
                hostStateDigest: expectedHostState.evidenceDigest, commands: commands)
            guard await backend.cleanup() else {
                throw EvolutionBenchmarkRunner.ExecutionError.cleanupFailed
            }
            try Task.checkCancellation()
            try GitIsolation.validateEvolutionCandidate(worktree, expected: candidate)
            try EvolutionBenchmarkRunner.validateProtectedHostState(expectedHostState)
            let authority = try EvolutionEvaluationAuthority.issue(
                candidate: candidate, hostStateDigest: expectedHostState.evidenceDigest,
                requiredCommands: commands, benchmarks: completion.benchmarks,
                heldOutOracle: report, containment: completion.containment)
            return EvolutionBenchmarkBatch(results: completion.benchmarks,
                                           authorityReceipt: authority,
                                           capabilityFitness: report.fitness)
        } catch {
            // A cleanup failure supersedes an assertion/infra failure and can never become fitness.
            guard await backend.cleanup() else {
                throw EvolutionBenchmarkRunner.ExecutionError.cleanupFailed
            }
            throw error
        }
    }

    /// Shared sequential orchestration. Callback is internal host code; no caller-controlled readiness
    /// or process backend enters the public runner. The result carries no execution/seal authority.
    static func evaluatePair(
        preparation: EvolutionPairedBenchmarkPreparation,
        execute: (EvolutionCapabilityArm, EvolutionCapabilityEvaluationPlan) async throws
            -> EvolutionHeldOutOracle.Arm
    ) async throws -> EvolutionHeldOutOracleReport {
        let plan = preparation.plan
        guard try EvolutionHeldOutOracle.corpusDigest(preparation.expectations)
                == plan.frozenInputs.corpusDigest else {
            throw EvolutionHeldOutOracle.Error.corpusMismatch
        }
        try Task.checkCancellation()
        let parent = try await execute(.parent, plan)
        // Reject a wrong parent immediately, before paying for or launching the child arm.
        guard parent.identity == plan.parentIdentity else {
            throw EvolutionCapabilityFitnessError.armIdentityMismatch(arm: .parent)
        }
        guard parent.frozenInputs == plan.frozenInputs else {
            throw EvolutionCapabilityFitnessError.frozenInputsMismatch(arm: .parent)
        }
        let parentGrade = try EvolutionHeldOutOracle.grade(
            .parent, arm: parent, expectations: preparation.expectations)
        guard parentGrade.infrastructureSucceeded else {
            throw EvolutionCapabilityFitnessError.infrastructureFailed(arm: .parent)
        }
        try Task.checkCancellation()
        let child = try await execute(.child, plan)
        try Task.checkCancellation()
        return try EvolutionHeldOutOracle.evaluate(
            plan: plan, expectations: preparation.expectations, parent: parent, child: child)
    }
}
