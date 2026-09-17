import Foundation

/// The Linux production backend for paired capability evaluation.
///
/// Composes the proven containment stack — `LinuxDelegatedCgroupSession` (aggregate cgroup-v2 limits +
/// verified-empty cleanup) executing bubblewrap, which installs `EvolutionSeccompFilter` via `--seccomp`
/// before exec — to run the held-out corpus for each arm and the ordinary benchmarks, then mints one
/// `HardProcessContainmentReceipt` bound to the whole batch. It is host-owned: the corpus, keys, and host
/// are never readable by the candidate, and every containment fact comes from the kernel, not the child.
///
/// Corpus convention: each case's `argv` runs (via `/usr/bin/env`, so PATH resolves) with the working
/// directory set to the arm's detached git worktree — a self-contained capability probe. The child arm
/// earns fitness only by passing cases the parent fails, exactly as `EvolutionHeldOutOracle` grades.
///
/// Lives entirely under `#if os(Linux)`; there is no macOS construction path, so a non-Linux host can
/// never instantiate it. Even on Linux it is only reachable once `HardProcessContainmentRuntime`
/// reports a qualifying delegated cgroup-v2 subtree (see the availability probe), keeping the gate
/// fail-closed until an operator provisions one.
#if os(Linux)
import Glibc

final class LinuxEvolutionPairedBenchmarkBackend: EvolutionPairedBenchmarkBackend {
    private let corpusDirectory: String
    private let delegatedRoot: String
    private let scopeID: String
    private let limits: HardProcessContainmentLimits
    private let mechanismDigest: String
    private let policyDigest: String

    private var hostRoot: String = ""
    private var frozen: EvolutionHeldOutCorpus.Frozen?
    private var session: LinuxDelegatedCgroupSession?
    private var filterFD: Int32 = -1
    private var filterPath: String = ""

    /// `delegatedRoot` and `corpusDirectory` are operator-provisioned host paths (never candidate-visible).
    init(corpusDirectory: String, delegatedRoot: String,
         limits: HardProcessContainmentLimits) {
        self.corpusDirectory = corpusDirectory
        self.delegatedRoot = delegatedRoot
        self.limits = limits
        self.scopeID = UUID().uuidString.lowercased()
        // The mechanism digest binds the seccomp filter identity + bwrap policy shape; the policy digest
        // binds the aggregate limits. Both are host-owned and recomputed by the attestation.
        let seccompDigest = EvolutionSeccompFilter.programDigest()
        self.mechanismDigest = BuilderEvidenceDigest.sha256(
            "kist.evolution.linux-mechanism.v1\u{0}linux-delegated-cgroup-v2+bwrap+seccomp\u{0}\(seccompDigest)")
        self.policyDigest = BuilderEvidenceDigest.sha256(
            "kist.evolution.linux-policy.v1\u{0}\(limits.aggregateCPUTimeMicros)\u{0}\(limits.aggregateMemoryBytes)\u{0}\(limits.aggregateProcessCount)\u{0}\(seccompDigest)")
    }

    // MARK: EvolutionPairedBenchmarkBackend

    func prepare(candidate: GitIsolation.EvolutionCommitSnapshot, worktree: GitWorktree,
                 hostRoot: String, commands: [String], timeoutSeconds: Int) async throws
        -> EvolutionPairedBenchmarkPreparation {
        self.hostRoot = hostRoot
        // Load the private corpus, refusing any location a candidate could read.
        let corpus = try EvolutionHeldOutCorpus.load(
            directory: corpusDirectory, forbiddenRoots: [hostRoot, worktree.repo, worktree.path])
        self.frozen = corpus

        // Parent identity: the base commit, its real tree SHA (the coordinator re-derives and checks this),
        // and a deterministic host-owned control digest. Child identity is the candidate's exact triple.
        let parentTree = try gitTreeSHA(repo: hostRoot, commitSHA: candidate.baseSHA)
        let parentControl = BuilderEvidenceDigest.sha256(
            "kist.evolution.parent-control.v1\u{0}\(candidate.baseSHA)\u{0}\(parentTree)")
        let parentIdentity = try EvolutionCapabilitySubjectIdentity(
            commitSHA: candidate.baseSHA, treeSHA: parentTree, gitControlDigest: parentControl)
        let childIdentity = try EvolutionCapabilitySubjectIdentity(
            commitSHA: candidate.commitSHA, treeSHA: candidate.treeSHA,
            gitControlDigest: candidate.gitControlDigest)

        // Frozen inputs: corpus digest is the oracle's; the other five bind the harness/evaluator/provider/
        // model/toolset identity deterministically for this host lane (both arms must share them exactly).
        let frozenInputs = try EvolutionCapabilityFrozenInputs(
            corpusDigest: corpus.corpusDigest,
            harnessDigest: BuilderEvidenceDigest.sha256("kist.evolution.harness.linux-cgroup-bwrap-seccomp.v1"),
            evaluatorDigest: BuilderEvidenceDigest.sha256("kist.evolution.evaluator.held-out-oracle.v1"),
            providerDigest: BuilderEvidenceDigest.sha256("kist.evolution.provider.host-executor.v1"),
            modelDigest: BuilderEvidenceDigest.sha256("kist.evolution.model.none.v1"),
            toolsetDigest: mechanismDigest)
        let plan = try EvolutionCapabilityEvaluationPlan(
            parentIdentity: parentIdentity, childBaseIdentity: parentIdentity,
            childIdentity: childIdentity, frozenInputs: frozenInputs)
        return EvolutionPairedBenchmarkPreparation(plan: plan, expectations: corpus.expectations)
    }

    func execute(arm: EvolutionCapabilityArm,
                 plan: EvolutionCapabilityEvaluationPlan) async throws -> EvolutionHeldOutOracle.Arm {
        guard let frozen else { throw Error.notPrepared }
        let identity = arm == .parent ? plan.parentIdentity : plan.childIdentity
        let baseSHA = plan.parentIdentity.commitSHA
        guard let wt = GitIsolation.detachedWorktree(
            repo: hostRoot, commitSHA: identity.commitSHA, baseSHA: baseSHA) else {
            throw Error.worktreeUnavailable(arm)
        }
        defer { GitIsolation.removeWorktree(wt) }
        guard GitIsolation.validateEvolutionVerificationWorkspace(
            wt, expectedCommitSHA: identity.commitSHA, expectedTreeSHA: identity.treeSHA) else {
            throw Error.worktreeMismatch(arm)
        }
        let session = try ensureSession()

        var observations: [EvolutionHeldOutOracle.Observation] = []
        for invocation in frozen.invocations {
            let outcome = try runContained(
                session: session, worktreePath: wt.path, argv: invocation.argv,
                stdin: Data(invocation.stdin.utf8), timeoutSeconds: invocation.timeoutSeconds)
            observations.append(EvolutionHeldOutOracle.Observation(
                caseID: invocation.caseID, outcome: outcome))
        }
        return EvolutionHeldOutOracle.Arm(
            identity: identity, frozenInputs: plan.frozenInputs, observations: observations)
    }

    func finish(candidate: GitIsolation.EvolutionCommitSnapshot,
                preparation: EvolutionPairedBenchmarkPreparation,
                report: EvolutionHeldOutOracleReport, hostStateDigest: String,
                commands: [String]) async throws -> EvolutionPairedBenchmarkCompletion {
        let session = try ensureSession()
        guard let wt = GitIsolation.detachedWorktree(
            repo: hostRoot, commitSHA: candidate.commitSHA, baseSHA: candidate.baseSHA) else {
            throw Error.worktreeUnavailable(.child)
        }
        defer { GitIsolation.removeWorktree(wt) }
        guard GitIsolation.validateEvolutionVerificationWorkspace(
            wt, expectedCommitSHA: candidate.commitSHA, expectedTreeSHA: candidate.treeSHA) else {
            throw Error.worktreeMismatch(.child)
        }

        var benchmarks: [EvolutionBenchmarkResult] = []
        for command in commands {
            let outcome = try runContained(
                session: session, worktreePath: wt.path,
                argv: ["/bin/sh", "-c", command], stdin: Data(), timeoutSeconds: 600,
                launchOverride: "/bin/sh")
            benchmarks.append(makeBenchmarkResult(
                command: command, outcome: outcome, candidate: candidate, hostStateDigest: hostStateDigest))
        }

        // The receipt's executionDigest MUST equal what EvolutionEvaluationAuthority.issue recomputes from
        // the exact batch (candidate + host state + commands + benchmarks + fitness), so the containment
        // authority is inseparable from this evaluation.
        let diffDigest = BuilderEvidenceDigest.sha256(candidate.committedDiff)
        let executionDigest = try EvolutionEvaluationAuthority.containmentExecutionDigest(
            baseSHA: candidate.baseSHA, commitSHA: candidate.commitSHA, treeSHA: candidate.treeSHA,
            gitControlDigest: candidate.gitControlDigest, branch: candidate.branch,
            changedFiles: candidate.changedFiles, committedDiffDigest: diffDigest,
            hostStateDigest: hostStateDigest,
            integrityDigest: EvolutionEvaluationAuthority.integrityDigest([]),
            requiredCommands: commands, benchmarks: benchmarks, capabilityFitness: report.fitness)

        let receipt = try session.finalize(
            mechanismDigest: mechanismDigest, policyDigest: policyDigest, executionDigest: executionDigest)
        self.session = nil
        closeFilter()

        let requirement = HardProcessContainmentRequirement(
            scopeID: scopeID, mechanism: .linuxDelegatedCgroupV2, limits: limits,
            mechanismDigest: mechanismDigest, policyDigest: policyDigest,
            expectedExecutionDigest: executionDigest)
        let validated = try HardProcessContainmentReplayGuard.shared.consume(
            receipt, satisfying: requirement)
        return EvolutionPairedBenchmarkCompletion(benchmarks: benchmarks, containment: validated)
    }

    func cleanup() async -> Bool {
        closeFilter()
        guard let session else { return true }
        let empty = session.cleanupVerified()
        self.session = nil
        return empty
    }

    // MARK: - containment plumbing

    private func ensureSession() throws -> LinuxDelegatedCgroupSession {
        if let session { return session }
        // Emit the seccomp filter and open it WITHOUT close-on-exec so bubblewrap inherits it.
        let path = NSTemporaryDirectory() + "kist-evolution-seccomp-\(scopeID).bpf"
        guard FileManager.default.createFile(
            atPath: path, contents: Data(EvolutionSeccompFilter.programBytes()),
            attributes: [.posixPermissions: 0o600]) else {
            throw Error.filterUnavailable
        }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw Error.filterUnavailable }
        self.filterPath = path
        self.filterFD = fd
        let session = try LinuxDelegatedCgroupSession(
            delegatedRoot: delegatedRoot, scopeID: scopeID, limits: limits)
        self.session = session
        return session
    }

    private func closeFilter() {
        if filterFD >= 0 { close(filterFD); filterFD = -1 }
        if !filterPath.isEmpty { try? FileManager.default.removeItem(atPath: filterPath); filterPath = "" }
    }

    /// Run one command inside the shared scope, wrapped by bubblewrap + the seccomp filter, capturing
    /// output and mapping it to a `ProcessGroupRunner.Outcome` with the sandbox attestation digests the
    /// oracle and archive authority require.
    private func runContained(session: LinuxDelegatedCgroupSession, worktreePath: String,
                              argv: [String], stdin: Data, timeoutSeconds: Int,
                              launchOverride: String? = nil) throws -> ProcessGroupRunner.Outcome {
        let inner: [String] = launchOverride == nil ? (["/usr/bin/env"] + argv) : argv
        let bwrapArgs = buildBwrapArgs(worktreePath: worktreePath, inner: inner)
        let outcome = try session.run(
            launchPath: "/usr/bin/bwrap", argv: bwrapArgs,
            environment: ["PATH": "/usr/bin:/bin"], cwd: "/", stdin: stdin, timeoutSeconds: timeoutSeconds)

        let stdoutDigest = BuilderEvidenceDigest.sha256Bytes(outcome.stdout)
        let stderrDigest = BuilderEvidenceDigest.sha256Bytes(outcome.stderr)
        let launcherDigest = BuilderEvidenceDigest.sha256(
            (["/usr/bin/bwrap"] + bwrapArgs).joined(separator: "\u{0}"))
        let envDigest = BuilderEvidenceDigest.sha256("PATH=/usr/bin:/bin")
        let combined = String(decoding: outcome.stdout, as: UTF8.self)
            + String(decoding: outcome.stderr, as: UTF8.self)
        var built = ProcessGroupRunner.Outcome(
            combined: combined, exitCode: outcome.exitCode, timedOut: outcome.timedOut)
        built.stdout = String(decoding: outcome.stdout, as: UTF8.self)
        built.stderr = String(decoding: outcome.stderr, as: UTF8.self)
        built.stdoutByteCount = outcome.stdoutByteCount
        built.stderrByteCount = outcome.stderrByteCount
        built.wasSignalled = outcome.wasSignalled
        built.stdoutTruncated = outcome.stdoutTruncated
        built.stderrTruncated = outcome.stderrTruncated
        built.outputTruncated = outcome.stdoutTruncated || outcome.stderrTruncated
        built.stdoutDigest = stdoutDigest
        built.stderrDigest = stderrDigest
        built.effectiveLauncherDigest = launcherDigest
        built.effectiveEnvironmentDigest = envDigest
        built.sandboxProfileDigest = policyDigest
        return built
    }

    private func buildBwrapArgs(worktreePath: String, inner: [String]) -> [String] {
        [
            "--die-with-parent", "--unshare-all", "--clearenv",
            "--setenv", "PATH", "/usr/bin:/bin",
            "--ro-bind", "/usr", "/usr", "--ro-bind", "/bin", "/bin",
            "--ro-bind", "/lib", "/lib", "--dev", "/dev", "--proc", "/proc",
            "--tmpfs", "/tmp", "--ro-bind", worktreePath, worktreePath,
            "--chdir", worktreePath, "--seccomp", String(filterFD), "--",
        ] + inner
    }

    private func makeBenchmarkResult(command: String, outcome: ProcessGroupRunner.Outcome,
                                     candidate: GitIsolation.EvolutionCommitSnapshot,
                                     hostStateDigest: String) -> EvolutionBenchmarkResult {
        let outputDigest = BuilderEvidenceDigest.sha256([
            outcome.stdoutDigest, String(outcome.stdoutByteCount),
            outcome.stderrDigest, String(outcome.stderrByteCount),
        ].joined(separator: "\u{0}"))
        let failureClass = EvolutionBenchmarkResult.classifiedFailure(
            exitCode: outcome.exitCode, timedOut: outcome.timedOut,
            wasSignalled: outcome.wasSignalled, outputTruncated: outcome.outputTruncated)
        let evidence = EvolutionBenchmarkResult.executionEvidence(
            command: command, commitSHA: candidate.commitSHA, treeSHA: candidate.treeSHA,
            gitControlDigest: candidate.gitControlDigest,
            launcherDigest: outcome.effectiveLauncherDigest,
            environmentDigest: outcome.effectiveEnvironmentDigest,
            profileDigest: policyDigest, sandboxAttestationDigest: mechanismDigest,
            outputDigest: outputDigest, preHostStateDigest: hostStateDigest,
            postHostStateDigest: hostStateDigest, exitCode: outcome.exitCode,
            timedOut: outcome.timedOut, wasSignalled: outcome.wasSignalled,
            outputTruncated: outcome.outputTruncated, failureClass: failureClass)
        let combined = outcome.combined
        return EvolutionBenchmarkResult(
            command: command, exitCode: outcome.exitCode, timedOut: outcome.timedOut,
            output: String("\(combined)".prefix(8_000)),
            evaluatedCommitSHA: candidate.commitSHA, evaluatedTreeSHA: candidate.treeSHA,
            gitControlDigest: candidate.gitControlDigest,
            effectiveLauncherDigest: outcome.effectiveLauncherDigest,
            effectiveEnvironmentDigest: outcome.effectiveEnvironmentDigest,
            sandboxProfileDigest: policyDigest, outputDigest: outputDigest,
            sandboxAttestationDigest: mechanismDigest,
            preHostStateDigest: hostStateDigest, postHostStateDigest: hostStateDigest,
            wasSignalled: outcome.wasSignalled, outputTruncated: outcome.outputTruncated,
            failureClass: failureClass, executionEvidenceDigest: evidence)
    }

    private func gitTreeSHA(repo: String, commitSHA: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repo, "rev-parse", "--verify", "--quiet", "\(commitSHA)^{tree}"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let tree = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, tree.count == commitSHA.count else {
            throw Error.parentTreeUnresolved
        }
        return tree
    }

    enum Error: Swift.Error, LocalizedError {
        case notPrepared
        case worktreeUnavailable(EvolutionCapabilityArm)
        case worktreeMismatch(EvolutionCapabilityArm)
        case filterUnavailable
        case parentTreeUnresolved

        var errorDescription: String? {
            switch self {
            case .notPrepared: return "backend.execute called before prepare"
            case .worktreeUnavailable(let a): return "could not create detached worktree for \(a.rawValue)"
            case .worktreeMismatch(let a): return "detached worktree bytes do not match \(a.rawValue) identity"
            case .filterUnavailable: return "could not materialize the seccomp filter for the sandbox"
            case .parentTreeUnresolved: return "could not resolve the parent commit's tree SHA"
            }
        }
    }
}
#endif
