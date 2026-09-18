import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Guardrails for the DGM-style evolution lab.
///
/// The lab may evolve prompts, routing, tools, and agent behavior, but it may not award itself a
/// "winner" by weakening the trust spine. Protected files can still be changed in an isolated branch
/// for human review; the automatic evaluator marks that candidate blocked.
public struct EvolutionPolicy: Sendable, Codable, Equatable {
    public let protectedGlobs: [String]
    public let requiredBenchmarkCommands: [String]

    public init(protectedGlobs: [String] = EvolutionPolicy.defaultProtectedGlobs,
                requiredBenchmarkCommands: [String] = []) {
        self.protectedGlobs = protectedGlobs
        self.requiredBenchmarkCommands = requiredBenchmarkCommands
    }

    public static let defaultProtectedGlobs: [String] = [
        "Sources/AgentCore/ForgeSeal.swift",
        "Sources/AgentCore/MythosCrypto.swift",
        "Sources/AgentCore/AcceptedRunReceipt.swift",
        "Sources/AgentCore/FleetSignoffLedger.swift",
        "Sources/AgentCore/Foreman.swift",
        "Sources/AgentCore/GitIsolation.swift",
        "Sources/AgentCore/EvolutionLab.swift",
        "Sources/AgentCore/EvolutionAutonomyReadiness.swift",
        "Sources/AgentCore/EvolutionCapabilityFitness.swift",
        "Sources/AgentCore/EvolutionHeldOutOracle.swift",
        "Sources/AgentCore/EvolutionPairedBenchmarkCoordinator.swift",
        "Sources/AgentCore/EvolutionRollbackAnchor.swift",
        "Sources/AgentCore/HardProcessContainment.swift",
        "Sources/AgentCore/EvolutionArchiveAuthority.swift",
        "Sources/AgentCore/EvolutionArchiveStore.swift",
        "Sources/AgentCore/EvolutionParentSelector.swift",
        "Sources/AgentCore/EvolutionLineage.swift",
        "Sources/AgentCore/EvolutionLineageWorkspace.swift",
        "Sources/AgentCore/EvolutionRunProgress.swift",
        "Sources/AgentCore/EvolutionStatusReport.swift",
        "Sources/AgentCore/EvolutionAutopilot.swift",
        "Sources/Kist/KistEvolutionCommand.swift",
        "Sources/AgentCore/FleetPromotionGate.swift",
        "Sources/AgentCore/PromotionAttestation.swift",
        "Sources/AgentCore/SelfEvolution/AdversarialPromoteGate.swift",
        "Sources/AgentCore/SelfEvolution/ClosedEvolutionLoop.swift",
        "Sources/AgentCore/SelfEvolution/EvolutionReview.swift",
        "Sources/AgentCore/SelfEvolution/SelfAuthoredTool.swift",
        "Sources/AgentCore/SelfEvolution/SelfAuthoredToolStore.swift",
        "Sources/AgentCore/SecretMasker.swift",
        "Sources/AgentCore/Tools/ConfinedRoot.swift",
        "Sources/AgentCore/Tools/ProcessGroupRunner.swift",
        "Sources/AgentCore/Tools/RunCommandTool.swift",
        "Sources/AgentCore/Tools/SeatbeltSandbox.swift",
        "Sources/AgentCore/Tools/BubblewrapSandbox.swift",
        "Sources/AgentCore/Tools/SandboxedProcessRunner.swift",
        "Sources/AgentCore/Tools/ToolRegistry.swift",
        "Sources/AgentCore/Builder/BuilderOSProcessSandboxAttestor.swift",
        "Sources/AgentCore/Builder/BuilderTransactionalObservation.swift",
        "Sources/AgentCore/Builder/BuilderWorkspaceManifest.swift",
        "Sources/AgentCore/Builder/BuilderTypes.swift",
        "Sources/AgentCore/Builder/BuilderExecutionContract.swift",
        "Sources/AgentCore/Builder/BuilderTrustedTelemetry.swift",
        "Sources/AgentCore/Fleet/CIIntegrityGuard.swift",   // a candidate may not weaken its own conscience
        "Sources/AgentCore/SECURITY.md",
        "Tests/AgentCoreTests/Evolution*Tests.swift",
        "Tests/AgentCoreTests/HardProcessContainmentTests.swift",
        "Tests/AgentCoreTests/ClosedEvolutionLoopTests.swift",
        "Tests/AgentCoreTests/SelfAuthoredStoreGateTests.swift",
        "Tests/AgentCoreTests/GitIsolationTests.swift",
        "Tests/AgentCoreTests/BuilderOSProcessSandboxAttestorTests.swift",
        "Tests/AgentCoreTests/SeatbeltSandboxTests.swift",
        "Tests/AgentCoreTests/BubblewrapSandboxTests.swift",
        "Tests/KistTests/KistEvolution*Tests.swift",
        "Package.swift",
        "Package.resolved",
        "Makefile",
        "makefile",
        "GNUmakefile",
        "test.sh",
        ".github/workflows/*",
        ".buildkite/*",
        "ci/*",
        "CI/*",
    ]

    public func protectedFiles(in changedFiles: [String]) -> [String] {
        changedFiles.filter { file in
            // Any `.gitattributes` (at any depth) is protected — it can suppress a file's diff and blind the
            // integrity guard. (Defense-in-depth; GitIsolation also forces `--text` so the guard sees through
            // attributes regardless.) FleetMatcher has no `**`, so match the basename directly.
            let normalized = file.precomposedStringWithCanonicalMapping.lowercased()
            let basename = (normalized as NSString).lastPathComponent
            if basename == ".gitattributes" || basename == ".gitmodules" { return true }
            let components = normalized.split(separator: "/").map(String.init)
            if components.contains(".swiftpm") { return true }
            if basename.hasPrefix("package@swift-") && basename.hasSuffix(".swift") { return true }
            if normalized.hasPrefix("scripts/") { return true }
            // The executable test-policy closure is broader than the root test.sh byte alone. Until a
            // frozen dependency parser can attest sourced helpers, shell scripts are trust-spine inputs.
            if basename.hasSuffix(".sh") { return true }
            // FleetMatcher intentionally has a small glob grammar; prefix-check security/evolution tests
            // directly so a spelling/case variant cannot edit the next evaluator.
            if normalized.hasPrefix("tests/agentcoretests/evolution")
                || normalized.hasPrefix("tests/kisttests/kistevolution")
                || normalized == "tests/agentcoretests/builderosprocesssandboxattestortests.swift"
                || normalized == "tests/agentcoretests/seatbeltsandboxtests.swift"
                || normalized == "tests/agentcoretests/bubblewrapsandboxtests.swift" {
                return true
            }
            return protectedGlobs.contains { rawGlob in
                let glob = rawGlob.precomposedStringWithCanonicalMapping.lowercased()
                return normalized == glob || FleetMatcher.matches(path: normalized, glob: glob)
            }
        }.sorted()
    }
}

public enum EvolutionBenchmarkFailureClass: String, Sendable, Codable, Equatable {
    case passed
    case assertion
    case infrastructure
}

public struct EvolutionBenchmarkAuthorityReceipt: Sendable, Equatable {
    let id: String
    let bindingDigest: String
    let seal: String
    let containmentExecutionDigest: String
}

public struct EvolutionBenchmarkBatch: Sendable, Equatable {
    public let results: [EvolutionBenchmarkResult]
    public let authorityReceipt: EvolutionBenchmarkAuthorityReceipt
    public let capabilityFitness: EvolutionCapabilityFitnessReceiptInput
}

#if DEBUG
/// DEBUG-only result from the legacy advisory benchmark runner. The type intentionally has no authority
/// receipt field, so advisory execution cannot be passed to `EvolutionEvaluator` as production evidence.
struct EvolutionAdvisoryBenchmarkBatchForTesting: Sendable, Equatable {
    let results: [EvolutionBenchmarkResult]
}
#endif

public struct EvolutionBenchmarkResult: Sendable, Codable, Equatable {
    public let command: String
    public let exitCode: Int32
    public let timedOut: Bool
    public let output: String
    /// Present only for host-attested candidate benchmarks (the synthetic `agent_loop` result is not
    /// a subprocess benchmark). These fields bind the durable commit, effective launcher/environment,
    /// kernel policy, complete stream bytes, and one-use sandbox attestation into the sealed archive row.
    public let evaluatedCommitSHA: String?
    public let evaluatedTreeSHA: String?
    public let gitControlDigest: String?
    public let effectiveLauncherDigest: String?
    public let effectiveEnvironmentDigest: String?
    public let sandboxProfileDigest: String?
    public let outputDigest: String?
    public let sandboxAttestationDigest: String?
    public let preHostStateDigest: String?
    public let postHostStateDigest: String?
    public let wasSignalled: Bool?
    public let outputTruncated: Bool?
    public let failureClass: EvolutionBenchmarkFailureClass?
    public let executionEvidenceDigest: String?

    public init(command: String, exitCode: Int32, timedOut: Bool, output: String,
                evaluatedCommitSHA: String? = nil,
                evaluatedTreeSHA: String? = nil,
                gitControlDigest: String? = nil,
                effectiveLauncherDigest: String? = nil,
                effectiveEnvironmentDigest: String? = nil,
                sandboxProfileDigest: String? = nil,
                outputDigest: String? = nil,
                sandboxAttestationDigest: String? = nil,
                preHostStateDigest: String? = nil,
                postHostStateDigest: String? = nil,
                wasSignalled: Bool? = nil,
                outputTruncated: Bool? = nil,
                failureClass: EvolutionBenchmarkFailureClass? = nil,
                executionEvidenceDigest: String? = nil) {
        self.command = command
        self.exitCode = exitCode
        self.timedOut = timedOut
        // Archive/display text is always redacted. Raw stream digests below still bind the complete
        // captured bytes, so evidence remains tamper-evident without persisting credentials.
        self.output = SecretMasker.mask(output)
        self.evaluatedCommitSHA = evaluatedCommitSHA
        self.evaluatedTreeSHA = evaluatedTreeSHA
        self.gitControlDigest = gitControlDigest
        self.effectiveLauncherDigest = effectiveLauncherDigest
        self.effectiveEnvironmentDigest = effectiveEnvironmentDigest
        self.sandboxProfileDigest = sandboxProfileDigest
        self.outputDigest = outputDigest
        self.sandboxAttestationDigest = sandboxAttestationDigest
        self.preHostStateDigest = preHostStateDigest
        self.postHostStateDigest = postHostStateDigest
        self.wasSignalled = wasSignalled
        self.outputTruncated = outputTruncated
        self.failureClass = failureClass
        self.executionEvidenceDigest = executionEvidenceDigest
    }

    public var success: Bool {
        !timedOut && wasSignalled != true && outputTruncated != true && exitCode == 0
    }

    public var isSyntheticAgentLoop: Bool {
        command == "agent_loop" && evaluatedCommitSHA == nil
    }

    static func classifiedFailure(exitCode: Int32, timedOut: Bool, wasSignalled: Bool,
                                  outputTruncated: Bool) -> EvolutionBenchmarkFailureClass {
        if !timedOut, !wasSignalled, !outputTruncated, exitCode == 0 { return .passed }
        if timedOut || wasSignalled || outputTruncated || exitCode < 0 || exitCode >= 125 {
            return .infrastructure
        }
        return .assertion
    }

    static func executionEvidence(
        command: String, commitSHA: String, treeSHA: String, gitControlDigest: String,
        launcherDigest: String, environmentDigest: String, profileDigest: String,
        sandboxAttestationDigest: String, outputDigest: String,
        preHostStateDigest: String, postHostStateDigest: String,
        exitCode: Int32, timedOut: Bool, wasSignalled: Bool, outputTruncated: Bool,
        failureClass: EvolutionBenchmarkFailureClass
    ) -> String {
        BuilderEvidenceDigest.sha256([
            "kist.evolution-benchmark.execution.v2", commitSHA, treeSHA, gitControlDigest,
            command, launcherDigest, environmentDigest, profileDigest,
            sandboxAttestationDigest, outputDigest, preHostStateDigest, postHostStateDigest,
            String(exitCode), String(timedOut), String(wasSignalled), String(outputTruncated),
            failureClass.rawValue,
        ].joined(separator: "\u{0}"))
    }

    func authorityValidationError(expectedCommitSHA: String, expectedTreeSHA: String,
                                  expectedGitControlDigest: String,
                                  expectedHostStateDigest: String) -> String? {
        guard !isSyntheticAgentLoop else { return "synthetic result is not benchmark evidence" }
        let digests = [effectiveLauncherDigest, effectiveEnvironmentDigest, sandboxProfileDigest,
                       outputDigest, sandboxAttestationDigest, preHostStateDigest,
                       postHostStateDigest, executionEvidenceDigest]
        guard evaluatedCommitSHA == expectedCommitSHA,
              evaluatedTreeSHA == expectedTreeSHA,
              gitControlDigest == expectedGitControlDigest,
              preHostStateDigest == expectedHostStateDigest,
              postHostStateDigest == expectedHostStateDigest,
              digests.allSatisfy({ $0.map(EvolutionArchiveAuthorityCodec.isDigest) == true }),
              let launcher = effectiveLauncherDigest,
              let environment = effectiveEnvironmentDigest,
              let profile = sandboxProfileDigest,
              let output = outputDigest,
              let attestation = sandboxAttestationDigest,
              let preHost = preHostStateDigest,
              let postHost = postHostStateDigest,
              let signalled = wasSignalled,
              let truncated = outputTruncated,
              let failureClass,
              let evidence = executionEvidenceDigest else {
            return "missing or mismatched durable subprocess evidence"
        }
        let classified = Self.classifiedFailure(
            exitCode: exitCode, timedOut: timedOut,
            wasSignalled: signalled, outputTruncated: truncated)
        guard failureClass == classified else { return "benchmark failure class is inconsistent" }
        let recomputed = Self.executionEvidence(
            command: command, commitSHA: expectedCommitSHA, treeSHA: expectedTreeSHA,
            gitControlDigest: expectedGitControlDigest, launcherDigest: launcher,
            environmentDigest: environment, profileDigest: profile,
            sandboxAttestationDigest: attestation, outputDigest: output,
            preHostStateDigest: preHost, postHostStateDigest: postHost,
            exitCode: exitCode, timedOut: timedOut, wasSignalled: signalled,
            outputTruncated: truncated, failureClass: failureClass)
        return recomputed == evidence ? nil : "benchmark execution evidence digest does not recompute"
    }
}

public enum EvolutionCandidateStatus: String, Sendable, Codable, Equatable {
    case passed
    case failed
    case blocked
    case noChange
}

public struct EvolutionCandidateRecord: Sendable, Codable, Equatable {
    public let runID: String
    public let candidateID: String
    public let parentID: String?
    public let objective: String
    public let branch: String
    public let worktreePath: String
    public let baseSHA: String
    public let commitSHA: String
    public let status: EvolutionCandidateStatus
    public let score: Int
    public let changedFiles: [String]
    public let protectedFiles: [String]
    public let benchmarks: [EvolutionBenchmarkResult]
    public let summary: String
    public let createdAtEpoch: Double
    /// Required verifier policy and exact durable object/host bindings. Optional only so legacy unsigned
    /// rows remain displayable; a signed authoritative row must contain every field.
    public let requiredBenchmarkCommands: [String]?
    public let treeSHA: String?
    public let gitControlDigest: String?
    public let hostStateDigest: String?
    public let committedDiffDigest: String?
    public let integrityDigest: String?
    public let evaluationReceiptID: String?
    public let evaluationReceiptDigest: String?
    public let evaluationReceiptSeal: String?
    public let evaluationContainmentExecutionDigest: String?
    /// Positive exact-parent paired evidence; unsigned by itself and included in the host receipt seal.
    public let capabilityFitness: EvolutionCapabilityFitnessReceiptInput?
    /// Host-minted archive authority. All-nil is a legacy/display-only row. A partial envelope is
    /// malformed and invalidates authority for the entire archive.
    public let archiveSchema: String?
    public let projectIdentity: String?
    public let archiveSequence: Int?
    public let previousRecordHash: String?
    public let recordHash: String?
    public let archiveSeal: String?

    public init(runID: String,
                candidateID: String,
                parentID: String?,
                objective: String,
                branch: String,
                worktreePath: String,
                baseSHA: String,
                commitSHA: String,
                status: EvolutionCandidateStatus,
                score: Int,
                changedFiles: [String],
                protectedFiles: [String],
                benchmarks: [EvolutionBenchmarkResult],
                summary: String,
                createdAtEpoch: Double,
                requiredBenchmarkCommands: [String]? = nil,
                treeSHA: String? = nil,
                gitControlDigest: String? = nil,
                hostStateDigest: String? = nil,
                committedDiffDigest: String? = nil,
                integrityDigest: String? = nil,
                evaluationReceiptID: String? = nil,
                evaluationReceiptDigest: String? = nil,
                evaluationReceiptSeal: String? = nil,
                evaluationContainmentExecutionDigest: String? = nil,
                capabilityFitness: EvolutionCapabilityFitnessReceiptInput? = nil,
                archiveSchema: String? = nil,
                projectIdentity: String? = nil,
                archiveSequence: Int? = nil,
                previousRecordHash: String? = nil,
                recordHash: String? = nil,
                archiveSeal: String? = nil) {
        self.runID = runID
        self.candidateID = candidateID
        self.parentID = parentID
        self.objective = objective
        self.branch = branch
        self.worktreePath = worktreePath
        self.baseSHA = baseSHA
        self.commitSHA = commitSHA
        self.status = status
        self.score = score
        self.changedFiles = changedFiles
        self.protectedFiles = protectedFiles
        self.benchmarks = benchmarks
        self.summary = summary
        self.createdAtEpoch = createdAtEpoch
        self.requiredBenchmarkCommands = requiredBenchmarkCommands
        self.treeSHA = treeSHA
        self.gitControlDigest = gitControlDigest
        self.hostStateDigest = hostStateDigest
        self.committedDiffDigest = committedDiffDigest
        self.integrityDigest = integrityDigest
        self.evaluationReceiptID = evaluationReceiptID
        self.evaluationReceiptDigest = evaluationReceiptDigest
        self.evaluationReceiptSeal = evaluationReceiptSeal
        self.evaluationContainmentExecutionDigest = evaluationContainmentExecutionDigest
        self.capabilityFitness = capabilityFitness
        self.archiveSchema = archiveSchema
        self.projectIdentity = projectIdentity
        self.archiveSequence = archiveSequence
        self.previousRecordHash = previousRecordHash
        self.recordHash = recordHash
        self.archiveSeal = archiveSeal
    }
}

public enum EvolutionEvaluator {
    public static func evaluate(runID: String,
                                candidateID: String,
                                parentID: String?,
                                objective: String,
                                branch: String,
                                worktreePath: String,
                                baseSHA: String,
                                commitSHA: String,
                                treeSHA: String? = nil,
                                gitControlDigest: String? = nil,
                                hostStateDigest: String? = nil,
                                committedDiff: String? = nil,
                                benchmarkAuthority: EvolutionBenchmarkAuthorityReceipt? = nil,
                                capabilityFitness: EvolutionCapabilityFitnessReceiptInput? = nil,
                                changedFiles: [String],
                                benchmarks: [EvolutionBenchmarkResult],
                                policy: EvolutionPolicy,
                                integrityViolations: [String] = [],
                                createdAtEpoch: Double) -> EvolutionCandidateRecord {
        let protected = policy.protectedFiles(in: changedFiles)
        let subprocessBenchmarks = benchmarks.filter { !$0.isSyntheticAgentLoop }
        let requiredCommands = policy.requiredBenchmarkCommands.isEmpty
            ? subprocessBenchmarks.map(\.command)
            : policy.requiredBenchmarkCommands
        let boundTree = treeSHA ?? subprocessBenchmarks.first?.evaluatedTreeSHA
        let boundControl = gitControlDigest ?? subprocessBenchmarks.first?.gitControlDigest
        let boundHost = hostStateDigest ?? subprocessBenchmarks.first?.preHostStateDigest
        let diffDigest = committedDiff.map {
            EvolutionArchiveAuthorityCodec.sha256Hex(Data($0.utf8))
        }
        let integrityDigest = EvolutionEvaluationAuthority.integrityDigest(integrityViolations)
        var evidenceErrors: [String]
        if let boundTree, let boundControl, let boundHost,
           requiredCommands == subprocessBenchmarks.map(\.command), !requiredCommands.isEmpty {
            evidenceErrors = subprocessBenchmarks.compactMap {
                $0.authorityValidationError(
                    expectedCommitSHA: commitSHA, expectedTreeSHA: boundTree,
                    expectedGitControlDigest: boundControl,
                    expectedHostStateDigest: boundHost)
            }
        } else {
            evidenceErrors = ["missing verifier policy or exact durable object/host binding"]
        }
        if !EvolutionHeldOutOracle.validate(
            capabilityFitness, baseSHA: baseSHA, commitSHA: commitSHA,
            treeSHA: boundTree ?? "", gitControlDigest: boundControl ?? "") {
            evidenceErrors.append("missing exact-parent positive held-out host fitness")
        }
        if committedDiff == nil {
            evidenceErrors.append("missing committed diff and one-use host evaluation receipt")
        }
        if !subprocessBenchmarks.isEmpty, committedDiff != nil {
            if let boundTree, let boundControl, let boundHost, let diffDigest {
                if !EvolutionEvaluationAuthority.receiptMatches(
                    benchmarkAuthority, baseSHA: baseSHA, commitSHA: commitSHA,
                    treeSHA: boundTree, gitControlDigest: boundControl, branch: branch,
                    changedFiles: changedFiles.sorted(), committedDiffDigest: diffDigest,
                    hostStateDigest: boundHost, integrityDigest: integrityDigest,
                    requiredCommands: requiredCommands, benchmarks: subprocessBenchmarks,
                    capabilityFitness: capabilityFitness) {
                    evidenceErrors.append("missing or mismatched one-use host evaluation receipt")
                }
            } else {
                evidenceErrors.append("missing or mismatched one-use host evaluation receipt")
            }
        }
        let status: EvolutionCandidateStatus
        let score: Int
        let summary: String

        // The CONSCIENCE on the self-evolution path: a candidate that makes its own verifier easier
        // (deleted a test, added XCTSkip, focused/`|| true` the runner) is BLOCKED even if benchmarks went
        // green — a green exit earned by gaming the tests is the one thing self-evolution must never reward.
        if !protected.isEmpty || !integrityViolations.isEmpty {
            status = .blocked
            score = 0
            var reasons: [String] = []
            if !protected.isEmpty { reasons.append("changed protected trust-spine file(s): \(protected.joined(separator: ", "))") }
            if !integrityViolations.isEmpty { reasons.append("gamed the verifier: \(integrityViolations.joined(separator: "; "))") }
            summary = "blocked: " + reasons.joined(separator: " · ")
        } else if changedFiles.isEmpty {
            status = .noChange
            score = 0
            summary = "no change: candidate did not produce a diff"
        } else if !evidenceErrors.isEmpty
                    || subprocessBenchmarks.contains(where: { $0.failureClass == .infrastructure }) {
            status = .blocked
            score = 0
            summary = "blocked: untrusted or infrastructure benchmark evidence (\((evidenceErrors.first ?? "resource/sandbox failure")))"
        } else if subprocessBenchmarks.contains(where: { !$0.success }) {
            let passed = subprocessBenchmarks.filter(\.success).count
            status = .failed
            score = max(1, passed * 10)
            let failed = subprocessBenchmarks.filter { !$0.success }.map(\.command).joined(separator: ", ")
            summary = "failed benchmark(s): \(failed)"
        } else {
            let reviewabilityBonus = max(0, 25 - max(0, changedFiles.count - 1))
            status = .passed
            score = 100 + min(50, subprocessBenchmarks.count * 10) + reviewabilityBonus
            summary = "passed \(subprocessBenchmarks.count) benchmark(s), changed \(changedFiles.count) file(s), reviewability +\(reviewabilityBonus)"
        }

        return EvolutionCandidateRecord(
            runID: runID,
            candidateID: candidateID,
            parentID: parentID,
            objective: objective,
            branch: branch,
            worktreePath: worktreePath,
            baseSHA: baseSHA,
            commitSHA: commitSHA,
            status: status,
            score: score,
            changedFiles: changedFiles.sorted(),
            protectedFiles: protected,
            benchmarks: benchmarks,
            summary: summary,
            createdAtEpoch: createdAtEpoch,
            requiredBenchmarkCommands: requiredCommands,
            treeSHA: boundTree,
            gitControlDigest: boundControl,
            hostStateDigest: boundHost,
            committedDiffDigest: diffDigest,
            integrityDigest: integrityDigest,
            evaluationReceiptID: benchmarkAuthority?.id,
            evaluationReceiptDigest: benchmarkAuthority?.bindingDigest,
            evaluationReceiptSeal: benchmarkAuthority?.seal,
            evaluationContainmentExecutionDigest: benchmarkAuthority?.containmentExecutionDigest,
            capabilityFitness: capabilityFitness
        )
    }
}

public enum EvolutionBenchmarkRunner {
    public enum ExecutionError: Error, LocalizedError, Equatable, Sendable {
        case invalidCandidate(String)
        case untrustedCommand(String)
        case protectedHostChanged
        case hardContainmentUnavailable(String)
        case sandboxUnavailable(String)
        case verificationWorkspace(String)
        case cleanupFailed

        public var errorDescription: String? {
            switch self {
            case .invalidCandidate(let reason): return "invalid durable evolution candidate: \(reason)"
            case .untrustedCommand(let command): return "untrusted evolution benchmark command: \(command)"
            case .protectedHostChanged: return "protected host repository/archive/key changed during evaluation"
            case .hardContainmentUnavailable(let reason): return reason
            case .sandboxUnavailable(let reason): return "required evolution benchmark sandbox unavailable: \(reason)"
            case .verificationWorkspace(let reason): return "invalid evolution verification workspace: \(reason)"
            case .cleanupFailed: return "could not destroy the detached evolution verification workspace"
            }
        }
    }

    /// Opaque binding of the source repository, refs/dirty state, authoritative archive bytes, and
    /// ForgeSeal key bytes. Capture before candidate execution and compare again immediately before
    /// archive append; a mismatch is a security failure, never a low benchmark score.
    public struct ProtectedHostState: Equatable, Sendable {
        fileprivate let root: String
        fileprivate let bindingDigest: String

        /// Sealed into every subprocess result so evaluator/archive authority can recompute the exact
        /// pre/post protected-host binding without exposing any protected bytes.
        public var evidenceDigest: String { bindingDigest }
    }

    private struct FrozenCommand: Sendable {
        let label: String
        let launchPath: String
        let launchArgs: [String]
    }

    public static func defaultCommands(repoRoot: String) -> [String] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: repoRoot, isDirectory: true)
        if fm.fileExists(atPath: root.appendingPathComponent("test.sh").path) {
            return ["./test.sh"]
        }
        if fm.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            return ["swift test"]
        }
        return ["git diff --check"]
    }

    /// Capture also proves that a usable ForgeSeal key exists before the pre-evaluation snapshot.
    /// This is a mutating evolution path (unlike status/tree projections) and cannot later append an
    /// authoritative record without the key, so key creation belongs before—not during—the snapshot.
    public static func captureProtectedHostState(repoRoot: String) throws -> ProtectedHostState {
        let identity = try BuilderWorkspaceRootIdentity.capture(rootPath: repoRoot)
        guard !ForgeSeal.sign("kist.evolution-benchmark.authority-readiness.v1").isEmpty else {
            throw ExecutionError.sandboxUnavailable("ForgeSeal authority key is unavailable")
        }
        let root = identity.canonicalPath
        let gitCommands: [[String]] = [
            ["rev-parse", "--verify", "HEAD^{commit}"],
            ["show-ref", "--head"],
            ["status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"],
            ["diff", "--binary", "--no-ext-diff", "--no-textconv", "HEAD", "--"],
            ["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", "HEAD", "--"],
            ["ls-files", "--stage"],
        ]
        var pieces = [
            "kist.evolution.protected-host-state.v1",
            root, String(identity.deviceID), String(identity.inode),
        ]
        do { pieces += try GitIsolation.evolutionProtectedGitBindings(
            repo: root, commands: gitCommands) }
        catch {
            throw ExecutionError.verificationWorkspace(
                "could not capture bounded hardened host git state")
        }
        let evolution = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(".mythos/evolution", isDirectory: true)
        for path in [
            evolution.appendingPathComponent("archive.jsonl").path,
            evolution.appendingPathComponent("archive-head.json").path,
            ForgeSeal.protectedKeyPath,
        ] {
            pieces.append(try stableProtectedFileBinding(path))
        }
        return ProtectedHostState(
            root: root,
            bindingDigest: BuilderEvidenceDigest.sha256(pieces.joined(separator: "\u{0}")))
    }

    public static func validateProtectedHostState(_ expected: ProtectedHostState) throws {
        guard try captureProtectedHostState(repoRoot: expected.root) == expected else {
            throw ExecutionError.protectedHostChanged
        }
    }

    /// Evaluate only the exact durable commit in a fresh detached worktree. The original candidate
    /// remains untouched; verification source is read-only, only a host-created `.build` is writable,
    /// and every subprocess is launched through a one-use, HMAC-attested kernel sandbox scope.
    public static func run(commands: [String],
                           candidate: GitIsolation.EvolutionCommitSnapshot,
                           worktree: GitWorktree,
                           hostRoot: String,
                           expectedHostState: ProtectedHostState,
                           timeoutSeconds: Int = 600) async throws -> EvolutionBenchmarkBatch {
        // Process groups and the current Seatbelt/Bubblewrap wrappers are advisory cleanup boundaries:
        // `setsid`/`setpgid` descendants can escape them, and they do not enforce aggregate CPU, memory,
        // or process-count limits. Until a trusted backend returns and consumes a complete
        // `HardProcessContainmentReceipt`, production evolution must refuse before candidate code starts.
        return try await EvolutionPairedBenchmarkCoordinator.run(
            commands: commands, candidate: candidate, worktree: worktree,
            hostRoot: hostRoot, expectedHostState: expectedHostState,
            timeoutSeconds: timeoutSeconds)
    }

    #if DEBUG
    /// DEBUG-only regression seam for exercising the legacy sandbox/evidence machinery without relabeling
    /// it hard containment. Its distinct result type carries data only and cannot mint or transport a
    /// production evaluation receipt.
    static func runAdvisoryForTesting(commands: [String],
                                      candidate: GitIsolation.EvolutionCommitSnapshot,
                                      worktree: GitWorktree,
                                      hostRoot: String,
                                      expectedHostState: ProtectedHostState,
                                      timeoutSeconds: Int = 600) async throws
        -> EvolutionAdvisoryBenchmarkBatchForTesting {
        #if os(Linux)
        // A nested writable bind can still expose same-filesystem hard-link semantics without an
        // attested seccomp link/linkat denial. Refuse evolution verification on Linux until that
        // kernel boundary is present; ordinary Builder behavior is not silently weakened here.
        throw ExecutionError.sandboxUnavailable(
            "Linux evolution verification lacks an attested link/linkat syscall deny")
        #else
        try GitIsolation.validateEvolutionCandidate(worktree, expected: candidate)
        let hostIdentity = try BuilderWorkspaceRootIdentity.capture(rootPath: hostRoot)
        guard hostIdentity.canonicalPath == expectedHostState.root else {
            throw ExecutionError.protectedHostChanged
        }
        try validateProtectedHostState(expectedHostState)
        guard let verification = GitIsolation.detachedWorktree(
            repo: worktree.repo, commitSHA: candidate.commitSHA, baseSHA: candidate.baseSHA) else {
            throw ExecutionError.verificationWorkspace("could not create exact detached commit")
        }
        let verificationIdentity = try BuilderWorkspaceRootIdentity.capture(
            rootPath: verification.path)

        var removed = false
        do {
            let results = try await runInDetachedWorkspace(
                commands: commands, candidate: candidate, verification: verification,
                hostRoot: hostIdentity.canonicalPath,
                hostStateDigest: expectedHostState.bindingDigest,
                timeoutSeconds: timeoutSeconds)
            guard try BuilderWorkspaceRootIdentity.capture(rootPath: verification.path)
                    == verificationIdentity,
                  GitIsolation.removeWorktree(verification) else { throw ExecutionError.cleanupFailed }
            removed = true
            try GitIsolation.validateEvolutionCandidate(worktree, expected: candidate)
            try validateProtectedHostState(expectedHostState)
            return EvolutionAdvisoryBenchmarkBatchForTesting(results: results)
        } catch {
            if !removed {
                guard (try? BuilderWorkspaceRootIdentity.capture(rootPath: verification.path))
                        == verificationIdentity,
                      GitIsolation.removeWorktree(verification) else {
                    throw ExecutionError.cleanupFailed
                }
            }
            throw error
        }
        #endif
    }
    #endif

    private static func runInDetachedWorkspace(
        commands: [String], candidate: GitIsolation.EvolutionCommitSnapshot,
        verification: GitWorktree, hostRoot: String, hostStateDigest: String,
        timeoutSeconds: Int
    ) async throws -> [EvolutionBenchmarkResult] {
        guard GitIsolation.validateEvolutionVerificationWorkspace(
            verification, expectedCommitSHA: candidate.commitSHA,
            expectedTreeSHA: candidate.treeSHA) else {
            throw ExecutionError.verificationWorkspace("detached bytes do not match the durable SHA")
        }
        try rejectCandidateGeneratedWriteSurfaces(root: verification.path)
        let build = URL(fileURLWithPath: verification.path, isDirectory: true)
            .appendingPathComponent(".build", isDirectory: true)
        try FileManager.default.createDirectory(
            at: build, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        guard chmod(build.path, 0o700) == 0 else {
            throw ExecutionError.verificationWorkspace("could not secure generated output root")
        }

        let frozen = try freezeCommands(commands, worktree: verification)
        guard !frozen.isEmpty else { throw ExecutionError.untrustedCommand("empty benchmark set") }
        let fingerprint = BuilderEvidenceDigest.sha256(
            "kist.evolution-benchmark.v1\u{0}\(candidate.commitSHA)\u{0}"
                + frozen.map(\.label).joined(separator: "\u{0}"))
        let request = BuilderSandboxAttestationRequest(
            contractFingerprint: fingerprint,
            builderContractID: "evolution-benchmark",
            nodeID: "candidate-verification",
            attempt: 1,
            stagedRoot: verification.path,
            governedRootDigest: BuilderEvidenceDigest.sha256(
                "\(candidate.baseSHA)\u{0}\(candidate.commitSHA)"),
            challenge: UUID().uuidString.lowercased(),
            stage: .verification,
            forbiddenReadPaths: [hostRoot, ForgeSeal.protectedKeyPath])
        let attestation: BuilderSandboxAttestation
        do { attestation = try await BuilderOSProcessSandboxAttestor().attest(request) }
        catch { throw ExecutionError.sandboxUnavailable(error.localizedDescription) }

        let results: [EvolutionBenchmarkResult]
        do {
            results = try await BuilderOSProcessSandboxAttestor.withRegisteredScope(
                request: request, attestation: attestation
            ) {
                let sandboxAuthority = try requireEvolutionSandboxAuthority()
                var completed: [EvolutionBenchmarkResult] = []
                for command in frozen {
                    let started = Date()
                    let outcome: ProcessGroupRunner.Outcome = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            continuation.resume(returning: ProcessGroupRunner.run(
                                launchPath: command.launchPath,
                                launchArgs: command.launchArgs,
                                cwd: verification.path,
                                env: [:],
                                timeoutSeconds: max(1, timeoutSeconds),
                                capPerStream: 1_048_576,
                                builderSandboxAuthority: sandboxAuthority,
                                requireBuilderSandbox: true))
                        }
                    }
                    let environmentDigest = outcome.effectiveEnvironmentDigest
                    guard let profileDigest = outcome.sandboxProfileDigest,
                          !profileDigest.isEmpty else {
                        throw ExecutionError.sandboxUnavailable(
                            "subprocess lacks effective sandbox/environment evidence")
                    }
                    let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
                    var exit = outcome.exitCode
                    var combined = outcome.combined
                    if outcome.outputTruncated {
                        exit = 125
                        combined += "\n[refused: benchmark output exceeded its bounded capture]"
                    }
                    if exit != 0, dependencyResolutionInfrastructureFailure(
                        command: command.label, output: combined) {
                        exit = 126
                        combined += "\n[sterile infrastructure failure: offline dependency/toolchain resolution unavailable]"
                    } else if exit != 0, sandboxOrResourceInfrastructureFailure(output: combined) {
                        // A kernel denial or resource exhaustion is not evidence that the candidate's
                        // held-out assertion was wrong. It is sterile infrastructure/security evidence and
                        // must never turn the candidate into a selectable failed stepping-stone.
                        exit = 126
                        combined += "\n[sterile infrastructure failure: sandbox denial or resource exhaustion]"
                    }
                    let failureClass = EvolutionBenchmarkResult.classifiedFailure(
                        exitCode: exit, timedOut: outcome.timedOut,
                        wasSignalled: outcome.wasSignalled,
                        outputTruncated: outcome.outputTruncated)
                    let outputDigest = BuilderEvidenceDigest.sha256([
                        outcome.stdoutDigest, String(outcome.stdoutByteCount),
                        outcome.stderrDigest, String(outcome.stderrByteCount),
                    ].joined(separator: "\u{0}"))
                    let evidence = EvolutionBenchmarkResult.executionEvidence(
                        command: command.label, commitSHA: candidate.commitSHA,
                        treeSHA: candidate.treeSHA,
                        gitControlDigest: candidate.gitControlDigest,
                        launcherDigest: outcome.effectiveLauncherDigest,
                        environmentDigest: environmentDigest, profileDigest: profileDigest,
                        sandboxAttestationDigest: attestation.evidenceDigest,
                        outputDigest: outputDigest,
                        preHostStateDigest: hostStateDigest,
                        postHostStateDigest: hostStateDigest,
                        exitCode: exit, timedOut: outcome.timedOut,
                        wasSignalled: outcome.wasSignalled,
                        outputTruncated: outcome.outputTruncated,
                        failureClass: failureClass)
                    completed.append(EvolutionBenchmarkResult(
                        command: command.label, exitCode: exit,
                        timedOut: outcome.timedOut,
                        output: String("\(combined)\n[elapsed \(elapsed)]".prefix(8_000)),
                        evaluatedCommitSHA: candidate.commitSHA,
                        evaluatedTreeSHA: candidate.treeSHA,
                        gitControlDigest: candidate.gitControlDigest,
                        effectiveLauncherDigest: outcome.effectiveLauncherDigest,
                        effectiveEnvironmentDigest: environmentDigest,
                        sandboxProfileDigest: profileDigest,
                        outputDigest: outputDigest,
                        sandboxAttestationDigest: attestation.evidenceDigest,
                        preHostStateDigest: hostStateDigest,
                        postHostStateDigest: hostStateDigest,
                        wasSignalled: outcome.wasSignalled,
                        outputTruncated: outcome.outputTruncated,
                        failureClass: failureClass,
                        executionEvidenceDigest: evidence))
                }
                return completed
            }
        } catch let error as ExecutionError { throw error }
        catch { throw ExecutionError.sandboxUnavailable(error.localizedDescription) }

        var generated = stat()
        guard lstat(build.path, &generated) == 0,
              generated.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              GitIsolation.validateEvolutionVerificationWorkspace(
                verification, expectedCommitSHA: candidate.commitSHA,
                expectedTreeSHA: candidate.treeSHA) else {
            throw ExecutionError.verificationWorkspace(
                "benchmark changed its committed source, HEAD, or generated-root identity")
        }
        return results
    }

    private static func requireEvolutionSandboxAuthority() throws
        -> BuilderSandboxExecutionAuthority {
        guard let authority = try BuilderOSProcessSandboxAttestor.currentExecutionAuthority() else {
            throw ExecutionError.sandboxUnavailable(
                "one-use Builder sandbox activation is missing")
        }
        return authority
    }

    private static func freezeCommands(_ commands: [String], worktree: GitWorktree) throws
        -> [FrozenCommand] {
        let trusted = GitIsolation.baseTrustedFiles(
            worktree, candidates: ["test.sh", "Package.swift", "Package.resolved",
                                   "package.json", "package-lock.json", "Makefile",
                                   "makefile", "GNUmakefile"])
        let tracked = Set(GitIsolation.trackedFiles(repo: worktree.path))
        let toolchainInputs = ["Package.swift", "Package.resolved", "package.json",
                               "package-lock.json", "Makefile", "makefile", "GNUmakefile"]
        let poisoned = toolchainInputs.contains { name in
            (tracked.contains(name)
             || FileManager.default.fileExists(
                atPath: (worktree.path as NSString).appendingPathComponent(name)))
                && !trusted.contains(name)
        }
        var frozen: [FrozenCommand] = []
        for original in commands {
            let command = original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty, command.utf8.count <= 262_144,
                  !command.unicodeScalars.contains(where: {
                      $0.value == 0 || ($0.value < 0x20 && $0 != "\t" && $0 != "\n" && $0 != "\r")
                  }) else { throw ExecutionError.untrustedCommand(original) }
            if command == "./test.sh" {
                guard trusted.contains("test.sh"), !poisoned,
                      let content = GitIsolation.baseFileContent(worktree, rel: "test.sh") else {
                    throw ExecutionError.untrustedCommand(command)
                }
                frozen.append(FrozenCommand(
                    label: original, launchPath: "/bin/sh", launchArgs: ["-c", content]))
            } else if command == "swift test" {
                guard trusted.contains("Package.swift"), !poisoned else {
                    throw ExecutionError.untrustedCommand(command)
                }
                frozen.append(FrozenCommand(
                    label: original, launchPath: "/usr/bin/swift", launchArgs: ["test"]))
            } else if command == "git diff --check" {
                guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
                    throw ExecutionError.untrustedCommand(command)
                }
                frozen.append(FrozenCommand(
                    label: original, launchPath: "/usr/bin/git",
                    launchArgs: ["--no-pager", "--no-replace-objects",
                                 "-c", "core.hooksPath=/dev/null",
                                 "-c", "core.fsmonitor=false",
                                 "-c", "core.attributesFile=/dev/null",
                                 "-c", "diff.external=", "diff", "--no-ext-diff", "--check"]))
            } else {
                // Non-default commands are operator-owned CLI policy frozen before candidate work.
                // Their transitive candidate code is still untrusted and runs only inside this scope.
                frozen.append(FrozenCommand(
                    label: original, launchPath: "/bin/sh", launchArgs: ["-c", command]))
            }
        }
        return frozen
    }

    private static func rejectCandidateGeneratedWriteSurfaces(root: String) throws {
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root, isDirectory: true),
            includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, error in failure = error; return false }) else {
            throw ExecutionError.verificationWorkspace("cannot enumerate detached commit")
        }
        let generated = Set([".build", ".build-local", "deriveddata"])
        while let item = enumerator.nextObject() as? URL {
            if generated.contains(item.lastPathComponent.lowercased()) {
                throw ExecutionError.verificationWorkspace(
                    "candidate commit contains a generated write surface")
            }
        }
        if failure != nil {
            throw ExecutionError.verificationWorkspace("detached commit enumeration failed")
        }
    }

    private static func dependencyResolutionInfrastructureFailure(
        command: String, output: String
    ) -> Bool {
        guard command == "swift test" || command == "./test.sh" else { return false }
        let text = output.lowercased()
        let markers = [
            "failed to clone repository", "could not resolve package dependencies",
            "failed fetching", "couldn't connect to server", "network is unreachable",
            "the internet connection appears to be offline", "unable to access 'http",
            "failed to resolve dependencies", "toolchain is invalid", "sdk cannot be located",
        ]
        return markers.contains(where: text.contains)
    }

    private static func sandboxOrResourceInfrastructureFailure(output: String) -> Bool {
        let text = output.lowercased()
        let markers = [
            "operation not permitted", "permission denied", "sandbox: deny",
            "sandbox violation", "network is unreachable", "connection refused",
            "resource temporarily unavailable", "too many open files",
            "no space left on device", "disk quota exceeded", "cannot allocate memory",
            "out of memory", "killed: 9", "signal 9",
        ]
        return markers.contains(where: text.contains)
    }

    private static func stableProtectedFileBinding(_ path: String) throws -> String {
        var before = stat()
        if lstat(path, &before) != 0 {
            guard errno == ENOENT else {
                throw ExecutionError.verificationWorkspace("cannot inspect protected host file")
            }
            return "missing:\(path)"
        }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_uid == geteuid(), before.st_size >= 0,
              before.st_size <= 64 * 1_024 * 1_024 else {
            throw ExecutionError.verificationWorkspace("protected host file has unsafe identity or size")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let digest = EvolutionArchiveAuthorityCodec.sha256Hex(data)
        var after = stat()
        guard lstat(path, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_mode == after.st_mode, before.st_uid == after.st_uid,
              before.st_size == after.st_size, Int64(data.count) == before.st_size else {
            throw ExecutionError.verificationWorkspace("protected host file changed while captured")
        }
        return [path, String(before.st_dev), String(before.st_ino), String(before.st_mode),
                String(before.st_uid), String(before.st_size),
                digest]
            .joined(separator: "\u{0}")
    }
}

public enum EvolutionLab {
    public static func candidatePrompt(objective: String,
                                       variantIndex: Int,
                                       variantCount: Int,
                                       archiveContext: String,
                                       policy: EvolutionPolicy) -> String {
        """
        EVOLUTION LAB CANDIDATE \(variantIndex)/\(variantCount)

        Objective:
        \(objective)

        You are improving Mythos itself in a DGM-style isolated candidate branch. Make ONE bounded,
        measurable improvement to the agent system, add or update focused tests, and keep the diff
        reviewable. Prefer prompt/tool/routing/evaluation improvements over broad rewrites.

        Selected parent / local archive context:
        \(archiveContext)

        Hard constraints:
        - Do not merge, rebase, push, or promote this branch.
        - Do not weaken tests, sandboxing, secret masking, signoff, merge gates, or verification.
        - Do not modify protected trust-spine files; the evaluator will block the candidate if these change:
        \(policy.protectedGlobs.map { "  - \($0)" }.joined(separator: "\n"))
        - The final answer must summarize the intended improvement, files changed, and how it was verified.

        Benchmark commands expected after your work:
        \((policy.requiredBenchmarkCommands.isEmpty ? ["auto-detected benchmark command(s)"] : policy.requiredBenchmarkCommands).map { "  - \($0)" }.joined(separator: "\n"))
        """
    }

    public static func headSHA(worktreePath: String) -> String {
        GitIsolation.evolutionHeadSHA(repo: worktreePath) ?? ""
    }
}
