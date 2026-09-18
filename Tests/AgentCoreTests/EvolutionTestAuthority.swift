import Foundation
@testable import AgentCore

/// Narrow test mint. Production authority is only minted by `EvolutionArchiveStore.append`; pure selector
/// and rendering tests use this helper so their fixtures exercise the same HMAC envelope instead of
/// accidentally teaching unsigned legacy rows to influence fitness.
enum EvolutionTestAuthority {
    static let projectIdentity = String(repeating: "a", count: 64)
    static let baseSHA = String(repeating: "1", count: 40)
    static let commitSHA = String(repeating: "2", count: 40)
    static let treeSHA = String(repeating: "3", count: 40)
    static let gitControlDigest = String(repeating: "4", count: 64)
    static let hostStateDigest = String(repeating: "5", count: 64)

    static func benchmark(command: String = "swift test", exitCode: Int32 = 0,
                          commitSHA: String = EvolutionTestAuthority.commitSHA,
                          treeSHA: String = EvolutionTestAuthority.treeSHA,
                          gitControlDigest: String = EvolutionTestAuthority.gitControlDigest,
                          hostStateDigest: String = EvolutionTestAuthority.hostStateDigest,
                          timedOut: Bool = false, wasSignalled: Bool = false,
                          outputTruncated: Bool = false) -> EvolutionBenchmarkResult {
        let launcher = String(repeating: "6", count: 64)
        let environment = String(repeating: "7", count: 64)
        let profile = String(repeating: "8", count: 64)
        let output = String(repeating: "9", count: 64)
        let attestation = String(repeating: "a", count: 64)
        let failure = EvolutionBenchmarkResult.classifiedFailure(
            exitCode: exitCode, timedOut: timedOut,
            wasSignalled: wasSignalled, outputTruncated: outputTruncated)
        let evidence = EvolutionBenchmarkResult.executionEvidence(
            command: command, commitSHA: commitSHA, treeSHA: treeSHA,
            gitControlDigest: gitControlDigest, launcherDigest: launcher,
            environmentDigest: environment, profileDigest: profile,
            sandboxAttestationDigest: attestation, outputDigest: output,
            preHostStateDigest: hostStateDigest, postHostStateDigest: hostStateDigest,
            exitCode: exitCode, timedOut: timedOut, wasSignalled: wasSignalled,
            outputTruncated: outputTruncated, failureClass: failure)
        return EvolutionBenchmarkResult(
            command: command, exitCode: exitCode, timedOut: timedOut, output: "",
            evaluatedCommitSHA: commitSHA, evaluatedTreeSHA: treeSHA,
            gitControlDigest: gitControlDigest, effectiveLauncherDigest: launcher,
            effectiveEnvironmentDigest: environment, sandboxProfileDigest: profile,
            outputDigest: output, sandboxAttestationDigest: attestation,
            preHostStateDigest: hostStateDigest, postHostStateDigest: hostStateDigest,
            wasSignalled: wasSignalled, outputTruncated: outputTruncated,
            failureClass: failure, executionEvidenceDigest: evidence)
    }

    static func authoritative(_ record: EvolutionCandidateRecord) -> EvolutionCandidateRecord {
        let base = isObjectID(record.baseSHA) ? record.baseSHA : baseSHA
        let commit = isObjectID(record.commitSHA) && record.commitSHA != base
            ? record.commitSHA : commitSHA
        let tree = record.treeSHA ?? treeSHA
        let control = record.gitControlDigest ?? gitControlDigest
        let host = record.hostStateDigest ?? hostStateDigest
        let required = record.requiredBenchmarkCommands ?? ["swift test"]
        let actual: [EvolutionBenchmarkResult]
        switch record.status {
        case .passed:
            actual = required.map {
                benchmark(command: $0, commitSHA: commit, treeSHA: tree,
                          gitControlDigest: control, hostStateDigest: host)
            }
        case .failed:
            actual = required.enumerated().map { index, command in
                benchmark(command: command, exitCode: index == 0 ? 1 : 0,
                          commitSHA: commit, treeSHA: tree,
                          gitControlDigest: control, hostStateDigest: host)
            }
        case .blocked, .noChange:
            actual = []
        }
        let changed = record.status == .noChange ? [] : record.changedFiles.sorted()
        let branch = record.branch.hasPrefix("mythos/auto-evolve-")
            ? record.branch : "mythos/auto-evolve-\(record.candidateID)"
        let unsigned = EvolutionCandidateRecord(
            runID: record.runID, candidateID: record.candidateID, parentID: record.parentID,
            objective: record.objective, branch: branch, worktreePath: record.worktreePath,
            baseSHA: base, commitSHA: commit, status: record.status,
            score: record.status == .blocked || record.status == .noChange ? 0 : max(1, record.score),
            changedFiles: changed,
            protectedFiles: EvolutionPolicy().protectedFiles(in: changed),
            benchmarks: actual, summary: record.summary, createdAtEpoch: record.createdAtEpoch,
            requiredBenchmarkCommands: required, treeSHA: tree,
            gitControlDigest: control, hostStateDigest: host,
            committedDiffDigest: record.committedDiffDigest ?? String(repeating: "b", count: 64),
            integrityDigest: record.integrityDigest ?? EvolutionEvaluationAuthority.integrityDigest([]),
            capabilityFitness: record.capabilityFitness)
        let receipt: EvolutionBenchmarkAuthorityReceipt
        do { receipt = try EvolutionEvaluationAuthority.issueForTesting(unsigned) }
        catch { preconditionFailure("test evaluation receipt failed: \(error)") }
        return EvolutionCandidateRecord(
            runID: unsigned.runID, candidateID: unsigned.candidateID,
            parentID: unsigned.parentID, objective: unsigned.objective,
            branch: unsigned.branch, worktreePath: unsigned.worktreePath,
            baseSHA: unsigned.baseSHA, commitSHA: unsigned.commitSHA,
            status: unsigned.status, score: unsigned.score,
            changedFiles: unsigned.changedFiles, protectedFiles: unsigned.protectedFiles,
            benchmarks: unsigned.benchmarks, summary: unsigned.summary,
            createdAtEpoch: unsigned.createdAtEpoch,
            requiredBenchmarkCommands: unsigned.requiredBenchmarkCommands,
            treeSHA: unsigned.treeSHA, gitControlDigest: unsigned.gitControlDigest,
            hostStateDigest: unsigned.hostStateDigest,
            committedDiffDigest: unsigned.committedDiffDigest,
            integrityDigest: unsigned.integrityDigest,
            evaluationReceiptID: receipt.id,
            evaluationReceiptDigest: receipt.bindingDigest,
            evaluationReceiptSeal: receipt.seal,
            evaluationContainmentExecutionDigest: receipt.containmentExecutionDigest,
            capabilityFitness: unsigned.capabilityFitness)
    }

    static func seal(_ record: EvolutionCandidateRecord,
                     projectIdentity: String = projectIdentity,
                     sequence: Int = 0,
                     previousHash: String = EvolutionArchiveAuthorityCodec.zeroHash) -> EvolutionCandidateRecord {
        do {
            return try EvolutionArchiveAuthorityCodec.seal(
                authoritative(record), projectIdentity: projectIdentity,
                sequence: sequence, previousHash: previousHash)
        } catch {
            preconditionFailure("test authority mint failed: \(error)")
        }
    }

    private static func isObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
    }
}
