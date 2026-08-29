import Foundation

/// Authority state is deliberately distinct from display data. A structurally readable legacy row can
/// still be shown to a human, but only a complete project-bound hash chain may influence fitness or
/// ancestry. `.invalid` always means zero authority; callers must not reinterpret it as an empty archive.
public enum EvolutionArchiveAuthorityState: Sendable, Equatable {
    case empty
    case legacyOnly(legacyCount: Int)
    case trusted(authoritativeCount: Int, legacyCount: Int)
    case invalid(reason: String)

    public var isInvalid: Bool {
        if case .invalid = self { return true }
        return false
    }
}

public struct EvolutionArchiveSnapshot: Sendable, Equatable {
    public let records: [EvolutionCandidateRecord]
    public let authoritativeRecords: [EvolutionCandidateRecord]
    public let state: EvolutionArchiveAuthorityState

    public init(records: [EvolutionCandidateRecord],
                authoritativeRecords: [EvolutionCandidateRecord],
                state: EvolutionArchiveAuthorityState) {
        self.records = records
        self.authoritativeRecords = authoritativeRecords
        self.state = state
    }
}

public enum EvolutionParentSelectionDecision: Sendable, Equatable {
    case rootSeed
    case selected(EvolutionCandidateRecord)
    case refused(reason: String)
}

public enum EvolutionArchiveError: Error, Sendable, Equatable, LocalizedError {
    case unsafeStorage(String)
    case malformedArchive(String)
    case duplicateOrReplay(String)
    case crossProject
    case brokenChain(String)
    case invalidSeal(String)
    case invalidRecord(String)
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeStorage(let detail): return "unsafe evolution archive storage: \(detail)"
        case .malformedArchive(let detail): return "malformed evolution archive: \(detail)"
        case .duplicateOrReplay(let detail): return "duplicate/replayed evolution archive identity: \(detail)"
        case .crossProject: return "evolution archive belongs to a different project"
        case .brokenChain(let detail): return "broken evolution archive hash chain: \(detail)"
        case .invalidSeal(let detail): return "invalid evolution archive seal: \(detail)"
        case .invalidRecord(let detail): return "invalid evolution archive record: \(detail)"
        case .persistence(let detail): return "evolution archive persistence failed: \(detail)"
        }
    }
}

/// Canonical hashing/signing codec shared by the secure store and narrow tests. It intentionally seals
/// the complete candidate payload, then chains that seal to the exact preceding archive state.
enum EvolutionArchiveAuthorityCodec {
    static let recordSchema = "kist.evolution-archive-record.v4"
    static let headSchema = "kist.evolution-archive-head.v1"
    static let zeroHash = String(repeating: "0", count: 64)

    enum EnvelopeState { case legacy, signed, partial }

    static func envelopeState(_ record: EvolutionCandidateRecord) -> EnvelopeState {
        let values: [Any?] = [record.archiveSchema, record.projectIdentity, record.archiveSequence,
                              record.previousRecordHash, record.recordHash, record.archiveSeal]
        let present = values.filter { $0 != nil }.count
        if present == 0 { return .legacy }
        if present == values.count { return .signed }
        return .partial
    }

    static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func canonicalRecordData(_ record: EvolutionCandidateRecord) throws -> Data {
        try canonicalEncoder().encode(record)
    }

    static func payloadDigest(_ record: EvolutionCandidateRecord) throws -> String {
        sha256Hex(try canonicalRecordData(withoutAuthority(record)))
    }

    static func withoutAuthority(_ record: EvolutionCandidateRecord) -> EvolutionCandidateRecord {
        EvolutionCandidateRecord(
            runID: record.runID, candidateID: record.candidateID, parentID: record.parentID,
            objective: record.objective, branch: record.branch, worktreePath: record.worktreePath,
            baseSHA: record.baseSHA, commitSHA: record.commitSHA, status: record.status,
            score: record.score, changedFiles: record.changedFiles, protectedFiles: record.protectedFiles,
            benchmarks: record.benchmarks, summary: record.summary, createdAtEpoch: record.createdAtEpoch,
            requiredBenchmarkCommands: record.requiredBenchmarkCommands,
            treeSHA: record.treeSHA, gitControlDigest: record.gitControlDigest,
            hostStateDigest: record.hostStateDigest,
            committedDiffDigest: record.committedDiffDigest,
            integrityDigest: record.integrityDigest,
            evaluationReceiptID: record.evaluationReceiptID,
            evaluationReceiptDigest: record.evaluationReceiptDigest,
            evaluationReceiptSeal: record.evaluationReceiptSeal,
            evaluationContainmentExecutionDigest: record.evaluationContainmentExecutionDigest)
    }

    static func genesisCursor(projectIdentity: String) -> String {
        sha256Hex(Data("kist.evolution-archive.genesis.v1|project=\(ForgeSeal.field(projectIdentity))".utf8))
    }

    /// Legacy rows are sterile, but their exact stored bytes are folded into the first signed row's
    /// predecessor. This prevents a legacy-prefix edit from leaving a later signed suffix apparently valid.
    static func advanceLegacyCursor(_ cursor: String, lineIndex: Int, rawLine: Data) -> String {
        var material = Data("kist.evolution-archive.legacy-link.v1|previous=\(cursor)|index=\(lineIndex)|bytes=\(rawLine.count)|".utf8)
        material.append(rawLine)
        return sha256Hex(material)
    }

    static func seal(_ record: EvolutionCandidateRecord, projectIdentity: String,
                     sequence: Int, previousHash: String) throws -> EvolutionCandidateRecord {
        guard sequence >= 0, isDigest(projectIdentity), isDigest(previousHash),
              !record.runID.isEmpty, !record.candidateID.isEmpty, !record.objective.isEmpty else {
            throw EvolutionArchiveError.invalidRecord("missing identity or invalid chain input")
        }
        guard case .legacy = envelopeState(record) else {
            throw EvolutionArchiveError.duplicateOrReplay(record.candidateID)
        }
        let payload = try payloadDigest(record)
        let hashCanonical = recordHashCanonical(projectIdentity: projectIdentity, sequence: sequence,
                                                previousHash: previousHash, payloadDigest: payload)
        let recordHash = sha256Hex(Data(hashCanonical.utf8))
        let sealCanonical = recordSealCanonical(projectIdentity: projectIdentity, sequence: sequence,
                                                previousHash: previousHash, payloadDigest: payload,
                                                recordHash: recordHash)
        let seal = ForgeSeal.sign(sealCanonical)
        guard isDigest(seal) else { throw EvolutionArchiveError.invalidSeal(record.candidateID) }
        return EvolutionCandidateRecord(
            runID: record.runID, candidateID: record.candidateID, parentID: record.parentID,
            objective: record.objective, branch: record.branch, worktreePath: record.worktreePath,
            baseSHA: record.baseSHA, commitSHA: record.commitSHA, status: record.status,
            score: record.score, changedFiles: record.changedFiles, protectedFiles: record.protectedFiles,
            benchmarks: record.benchmarks, summary: record.summary, createdAtEpoch: record.createdAtEpoch,
            requiredBenchmarkCommands: record.requiredBenchmarkCommands,
            treeSHA: record.treeSHA, gitControlDigest: record.gitControlDigest,
            hostStateDigest: record.hostStateDigest,
            committedDiffDigest: record.committedDiffDigest,
            integrityDigest: record.integrityDigest,
            evaluationReceiptID: record.evaluationReceiptID,
            evaluationReceiptDigest: record.evaluationReceiptDigest,
            evaluationReceiptSeal: record.evaluationReceiptSeal,
            evaluationContainmentExecutionDigest: record.evaluationContainmentExecutionDigest,
            archiveSchema: recordSchema, projectIdentity: projectIdentity, archiveSequence: sequence,
            previousRecordHash: previousHash, recordHash: recordHash, archiveSeal: seal)
    }

    static func verify(_ record: EvolutionCandidateRecord, expectedProjectIdentity: String? = nil,
                       expectedSequence: Int? = nil, expectedPreviousHash: String? = nil,
                       readOnly: Bool = false) -> EvolutionArchiveError? {
        guard case .signed = envelopeState(record),
              record.archiveSchema == recordSchema,
              let project = record.projectIdentity, let sequence = record.archiveSequence,
              let previous = record.previousRecordHash, let storedHash = record.recordHash,
              let seal = record.archiveSeal,
              sequence >= 0, isDigest(project), isDigest(previous), isDigest(storedHash), isDigest(seal)
        else { return .invalidRecord(record.candidateID) }
        if let expectedProjectIdentity, project != expectedProjectIdentity { return .crossProject }
        if let expectedSequence, sequence != expectedSequence {
            return .brokenChain("sequence \(sequence), expected \(expectedSequence)")
        }
        if let expectedPreviousHash, previous != expectedPreviousHash {
            return .brokenChain("predecessor mismatch at \(record.candidateID)")
        }
        guard let payload = try? payloadDigest(record) else { return .invalidRecord(record.candidateID) }
        let hashCanonical = recordHashCanonical(projectIdentity: project, sequence: sequence,
                                                previousHash: previous, payloadDigest: payload)
        guard sha256Hex(Data(hashCanonical.utf8)) == storedHash else {
            return .brokenChain("record hash mismatch at \(record.candidateID)")
        }
        let sealCanonical = recordSealCanonical(projectIdentity: project, sequence: sequence,
                                                previousHash: previous, payloadDigest: payload,
                                                recordHash: storedHash)
        let validSeal = readOnly
            ? ForgeSeal.verifyWithoutCreatingKey(sealCanonical, seal: seal)
            : ForgeSeal.verify(sealCanonical, seal: seal)
        return validSeal ? nil : .invalidSeal(record.candidateID)
    }

    private static func recordHashCanonical(projectIdentity: String, sequence: Int,
                                            previousHash: String, payloadDigest: String) -> String {
        "kist.evolution-archive.hash.v4|project=\(projectIdentity)|sequence=\(sequence)|previous=\(previousHash)|payload=\(payloadDigest)"
    }

    private static func recordSealCanonical(projectIdentity: String, sequence: Int,
                                            previousHash: String, payloadDigest: String,
                                            recordHash: String) -> String {
        "kist.evolution-archive.seal.v4|project=\(projectIdentity)|sequence=\(sequence)|previous=\(previousHash)|payload=\(payloadDigest)|record=\(recordHash)"
    }

    static func sha256Hex(_ data: Data) -> String {
        MythosCrypto.sha256(data).map { String(format: "%02x", $0) }.joined()
    }

    static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
    }
}

/// One-use host authority joining an exact durable Git snapshot to one sandboxed benchmark batch.
/// The persisted HMAC makes historical rows independently checkable; the private pending registry makes
/// `append` reject a caller that merely recomputed hashes or called the public ForgeSeal primitive.
enum EvolutionEvaluationAuthority {
    static let testOnlyContainmentDigest = "test-only:no-hard-containment-authority"

    private struct Pending: Equatable {
        let bindingDigest: String
        let testOnly: Bool
    }

    private final class Registry: @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var pending: [String: Pending] = [:]

        func register(id: String, pending value: Pending) throws {
            lock.lock(); defer { lock.unlock() }
            guard pending.count < 512, pending[id] == nil else {
                throw EvolutionArchiveError.duplicateOrReplay(id)
            }
            pending[id] = value
        }

        func pendingValue(id: String) -> Pending? {
            lock.lock(); defer { lock.unlock() }
            return pending[id]
        }

        func consume(id: String, bindingDigest: String) -> Pending? {
            lock.lock(); defer { lock.unlock() }
            guard let value = pending[id], value.bindingDigest == bindingDigest else { return nil }
            pending.removeValue(forKey: id)
            return value
        }
    }

    static func integrityDigest(_ violations: [String]) -> String {
        EvolutionArchiveAuthorityCodec.sha256Hex(Data(
            (["kist.evolution.integrity.v1"] + violations.sorted()).joined(separator: "\u{0}").utf8))
    }

    static func issue(candidate: GitIsolation.EvolutionCommitSnapshot,
                      hostStateDigest: String, requiredCommands: [String],
                      benchmarks: [EvolutionBenchmarkResult],
                      containment: ValidatedHardProcessContainment) throws
        -> EvolutionBenchmarkAuthorityReceipt {
        let id = "eval-\(UUID().uuidString.lowercased())"
        let diffDigest = EvolutionArchiveAuthorityCodec.sha256Hex(Data(candidate.committedDiff.utf8))
        let expectedContainmentDigest = try containmentExecutionDigest(
            baseSHA: candidate.baseSHA, commitSHA: candidate.commitSHA,
            treeSHA: candidate.treeSHA, gitControlDigest: candidate.gitControlDigest,
            branch: candidate.branch, changedFiles: candidate.changedFiles,
            committedDiffDigest: diffDigest, hostStateDigest: hostStateDigest,
            integrityDigest: integrityDigest([]), requiredCommands: requiredCommands,
            benchmarks: benchmarks)
        guard containment.mechanism.isQualifyingHardBackend,
              containment.executionDigest == expectedContainmentDigest else {
            throw EvolutionArchiveError.invalidRecord(
                "hard-containment authority is not bound to the exact benchmark batch")
        }
        let canonical = try canonical(
            id: id, baseSHA: candidate.baseSHA, commitSHA: candidate.commitSHA,
            treeSHA: candidate.treeSHA, gitControlDigest: candidate.gitControlDigest,
            branch: candidate.branch, changedFiles: candidate.changedFiles,
            committedDiffDigest: diffDigest, hostStateDigest: hostStateDigest,
            integrityDigest: integrityDigest([]), requiredCommands: requiredCommands,
            benchmarks: benchmarks, containmentExecutionDigest: containment.executionDigest)
        return try mint(
            id: id, canonical: canonical, testOnly: false,
            containmentExecutionDigest: containment.executionDigest)
    }

    #if DEBUG
    /// DEBUG/XCTest-only fixture mint. The reserved non-digest containment marker is sealed into the row,
    /// so this receipt is structurally incapable of validating as production hard-containment authority.
    static func issueForTesting(_ record: EvolutionCandidateRecord) throws
        -> EvolutionBenchmarkAuthorityReceipt {
        guard testAuthorityAvailable else {
            throw EvolutionArchiveError.invalidRecord("test authority is unavailable outside XCTest")
        }
        let id = "test-eval-\(UUID().uuidString.lowercased())"
        let canonical = try canonical(
            record: record, overridingID: id,
            containmentExecutionDigest: testOnlyContainmentDigest)
        return try mint(
            id: id, canonical: canonical, testOnly: true,
            containmentExecutionDigest: testOnlyContainmentDigest)
    }
    #endif

    /// SwiftPM's XCTest runner does not consistently set `XCTestConfigurationFilePath`. Bind the narrow
    /// fixture mint to an actual `.xctest` host executable/bundle instead of treating a debug build or a
    /// caller-controlled environment flag as test authority.
    static var testAuthorityAvailable: Bool {
        #if DEBUG
        if Bundle.main.bundlePath.hasSuffix(".xctest") { return true }
        if Bundle.allBundles.contains(where: { $0.bundleURL.pathExtension == "xctest" }) {
            return true
        }
        if Bundle.allFrameworks.contains(where: { $0.bundleURL.lastPathComponent == "XCTest.framework" }) {
            return true
        }
        if NSClassFromString("XCTest.XCTestCase") != nil || NSClassFromString("XCTestCase") != nil {
            return true
        }
        return ProcessInfo.processInfo.arguments.first?.split(separator: "/").contains(where: {
            $0.hasSuffix(".xctest")
        }) == true
        #else
        return false
        #endif
    }

    static func validationError(_ record: EvolutionCandidateRecord) -> EvolutionArchiveError? {
        validationError(record, allowTestAuthority: testAuthorityAvailable)
    }

    /// Pure classification seam: archive parsing outside an XCTest host passes false. Tests use it to prove
    /// that a DEBUG fixture receipt cannot cross the production authority boundary after serialization.
    static func validationError(_ record: EvolutionCandidateRecord,
                                allowTestAuthority: Bool) -> EvolutionArchiveError? {
        guard let id = record.evaluationReceiptID,
              let digest = record.evaluationReceiptDigest,
              let seal = record.evaluationReceiptSeal,
              let containmentDigest = record.evaluationContainmentExecutionDigest,
              id.utf8.count <= 256,
              EvolutionArchiveAuthorityCodec.isDigest(digest),
              EvolutionArchiveAuthorityCodec.isDigest(seal) else {
            return .invalidRecord("missing or invalid one-use evaluation receipt")
        }
        let testOnly = id.hasPrefix("test-eval-")
        if testOnly {
            guard allowTestAuthority,
                  containmentDigest == testOnlyContainmentDigest else {
                return .invalidRecord(
                    "test-only evaluation receipt is not production authority")
            }
        } else {
            guard id.hasPrefix("eval-"),
                  EvolutionArchiveAuthorityCodec.isDigest(containmentDigest),
                  let expected = try? containmentExecutionDigest(record: record),
                  expected == containmentDigest else {
                return .invalidRecord(
                    "evaluation receipt lacks exact hard-containment execution binding")
            }
        }
        guard let canonical = try? canonical(
                  record: record, overridingID: id,
                  containmentExecutionDigest: containmentDigest),
              EvolutionArchiveAuthorityCodec.sha256Hex(Data(canonical.utf8)) == digest,
              ForgeSeal.verifyWithoutCreatingKey(receiptSealCanonical(id: id, digest: digest),
                                                 seal: seal) else {
            return .invalidRecord("missing or invalid one-use evaluation receipt")
        }
        return nil
    }

    static func pendingAuthorization(_ record: EvolutionCandidateRecord) -> Bool? {
        guard validationError(record) == nil,
              let id = record.evaluationReceiptID,
              let digest = record.evaluationReceiptDigest,
              let pending = Registry.shared.pendingValue(id: id),
              pending.bindingDigest == digest,
              pending.testOnly == id.hasPrefix("test-eval-") else { return nil }
        return pending.testOnly
    }

    static func consume(_ record: EvolutionCandidateRecord) -> Bool {
        guard validationError(record) == nil,
              let id = record.evaluationReceiptID,
              let digest = record.evaluationReceiptDigest else { return false }
        return Registry.shared.consume(id: id, bindingDigest: digest) != nil
    }

    static func receiptMatches(
        _ receipt: EvolutionBenchmarkAuthorityReceipt?, baseSHA: String, commitSHA: String,
        treeSHA: String, gitControlDigest: String, branch: String, changedFiles: [String],
        committedDiffDigest: String, hostStateDigest: String, integrityDigest: String,
        requiredCommands: [String], benchmarks: [EvolutionBenchmarkResult]
    ) -> Bool {
        guard let receipt,
              receipt.id.hasPrefix("eval-"),
              EvolutionArchiveAuthorityCodec.isDigest(receipt.containmentExecutionDigest),
              let expectedContainmentDigest = try? containmentExecutionDigest(
                baseSHA: baseSHA, commitSHA: commitSHA, treeSHA: treeSHA,
                gitControlDigest: gitControlDigest, branch: branch,
                changedFiles: changedFiles, committedDiffDigest: committedDiffDigest,
                hostStateDigest: hostStateDigest, integrityDigest: integrityDigest,
                requiredCommands: requiredCommands, benchmarks: benchmarks),
              expectedContainmentDigest == receipt.containmentExecutionDigest,
              let canonical = try? canonical(
                id: receipt.id, baseSHA: baseSHA, commitSHA: commitSHA,
                treeSHA: treeSHA, gitControlDigest: gitControlDigest, branch: branch,
                changedFiles: changedFiles, committedDiffDigest: committedDiffDigest,
                hostStateDigest: hostStateDigest, integrityDigest: integrityDigest,
                requiredCommands: requiredCommands, benchmarks: benchmarks,
                containmentExecutionDigest: receipt.containmentExecutionDigest),
              EvolutionArchiveAuthorityCodec.sha256Hex(Data(canonical.utf8)) == receipt.bindingDigest,
              ForgeSeal.verifyWithoutCreatingKey(
                receiptSealCanonical(id: receipt.id, digest: receipt.bindingDigest),
                seal: receipt.seal),
              let pending = Registry.shared.pendingValue(id: receipt.id),
              pending.bindingDigest == receipt.bindingDigest,
              !pending.testOnly else {
            return false
        }
        return true
    }

    private static func mint(id: String, canonical: String, testOnly: Bool,
                             containmentExecutionDigest: String) throws
        -> EvolutionBenchmarkAuthorityReceipt {
        let digest = EvolutionArchiveAuthorityCodec.sha256Hex(Data(canonical.utf8))
        let seal = ForgeSeal.sign(receiptSealCanonical(id: id, digest: digest))
        guard EvolutionArchiveAuthorityCodec.isDigest(seal) else {
            throw EvolutionArchiveError.invalidSeal(id)
        }
        try Registry.shared.register(
            id: id, pending: Pending(bindingDigest: digest, testOnly: testOnly))
        return EvolutionBenchmarkAuthorityReceipt(
            id: id, bindingDigest: digest, seal: seal,
            containmentExecutionDigest: containmentExecutionDigest)
    }

    private static func canonical(record: EvolutionCandidateRecord, overridingID id: String,
                                  containmentExecutionDigest: String) throws -> String {
        guard let tree = record.treeSHA, let control = record.gitControlDigest,
              let host = record.hostStateDigest, let diff = record.committedDiffDigest,
              let integrity = record.integrityDigest,
              let required = record.requiredBenchmarkCommands else {
            throw EvolutionArchiveError.invalidRecord("evaluation receipt binding is incomplete")
        }
        return try canonical(
            id: id, baseSHA: record.baseSHA, commitSHA: record.commitSHA,
            treeSHA: tree, gitControlDigest: control, branch: record.branch,
            changedFiles: record.changedFiles, committedDiffDigest: diff,
            hostStateDigest: host, integrityDigest: integrity,
            requiredCommands: required,
            benchmarks: record.benchmarks.filter { !$0.isSyntheticAgentLoop },
            containmentExecutionDigest: containmentExecutionDigest)
    }

    static func containmentExecutionDigest(record: EvolutionCandidateRecord) throws -> String {
        guard let tree = record.treeSHA, let control = record.gitControlDigest,
              let host = record.hostStateDigest, let diff = record.committedDiffDigest,
              let integrity = record.integrityDigest,
              let required = record.requiredBenchmarkCommands else {
            throw EvolutionArchiveError.invalidRecord(
                "hard-containment execution binding is incomplete")
        }
        return try containmentExecutionDigest(
            baseSHA: record.baseSHA, commitSHA: record.commitSHA,
            treeSHA: tree, gitControlDigest: control, branch: record.branch,
            changedFiles: record.changedFiles, committedDiffDigest: diff,
            hostStateDigest: host, integrityDigest: integrity,
            requiredCommands: required,
            benchmarks: record.benchmarks.filter { !$0.isSyntheticAgentLoop })
    }

    static func containmentExecutionDigest(
        baseSHA: String, commitSHA: String, treeSHA: String,
        gitControlDigest: String, branch: String, changedFiles: [String],
        committedDiffDigest: String, hostStateDigest: String, integrityDigest: String,
        requiredCommands: [String], benchmarks: [EvolutionBenchmarkResult]
    ) throws -> String {
        let benchmarkData = try EvolutionArchiveAuthorityCodec.canonicalEncoder().encode(benchmarks)
        let benchmarkDigest = EvolutionArchiveAuthorityCodec.sha256Hex(benchmarkData)
        let commandData = try EvolutionArchiveAuthorityCodec.canonicalEncoder().encode(requiredCommands)
        let commandDigest = EvolutionArchiveAuthorityCodec.sha256Hex(commandData)
        let changedData = try EvolutionArchiveAuthorityCodec.canonicalEncoder().encode(changedFiles)
        let changedDigest = EvolutionArchiveAuthorityCodec.sha256Hex(changedData)
        return EvolutionArchiveAuthorityCodec.sha256Hex(Data([
            "kist.evolution.hard-contained-benchmark-batch.v1", baseSHA, commitSHA, treeSHA,
            gitControlDigest, branch, changedDigest, committedDiffDigest, hostStateDigest,
            integrityDigest, commandDigest, benchmarkDigest,
        ].joined(separator: "\u{0}").utf8))
    }

    private static func canonical(
        id: String, baseSHA: String, commitSHA: String, treeSHA: String,
        gitControlDigest: String, branch: String, changedFiles: [String],
        committedDiffDigest: String, hostStateDigest: String, integrityDigest: String,
        requiredCommands: [String], benchmarks: [EvolutionBenchmarkResult],
        containmentExecutionDigest: String
    ) throws -> String {
        let benchmarkData = try EvolutionArchiveAuthorityCodec.canonicalEncoder().encode(benchmarks)
        let benchmarkDigest = EvolutionArchiveAuthorityCodec.sha256Hex(benchmarkData)
        let commandData = try EvolutionArchiveAuthorityCodec.canonicalEncoder().encode(requiredCommands)
        let commandDigest = EvolutionArchiveAuthorityCodec.sha256Hex(commandData)
        let changedData = try EvolutionArchiveAuthorityCodec.canonicalEncoder().encode(changedFiles)
        let changedDigest = EvolutionArchiveAuthorityCodec.sha256Hex(changedData)
        return [
            "kist.evolution.evaluation-receipt.v2", id, baseSHA, commitSHA, treeSHA,
            gitControlDigest, branch, changedDigest, committedDiffDigest, hostStateDigest,
            integrityDigest, commandDigest, benchmarkDigest, containmentExecutionDigest,
        ].joined(separator: "\u{0}")
    }

    private static func receiptSealCanonical(id: String, digest: String) -> String {
        "kist.evolution.evaluation-receipt.seal.v2|id=\(ForgeSeal.field(id))|binding=\(digest)"
    }
}

/// Semantic authority is deliberately separate from the HMAC envelope. A caller that can invoke the
/// in-process store must not be able to turn nil/mismatched subprocess evidence into selectable fitness
/// merely by asking the store to seal it.
enum EvolutionRecordAuthority {
    static func validationError(_ record: EvolutionCandidateRecord) -> EvolutionArchiveError? {
        guard boundedIdentifier(record.runID), boundedIdentifier(record.candidateID),
              boundedText(record.objective, maximumBytes: 64 * 1_024),
              boundedText(record.summary, maximumBytes: 64 * 1_024),
              record.createdAtEpoch.isFinite, record.createdAtEpoch >= 0,
              objectID(record.baseSHA), objectID(record.commitSHA),
              record.baseSHA != record.commitSHA,
              let tree = record.treeSHA, objectID(tree),
              let control = record.gitControlDigest,
              let host = record.hostStateDigest,
              let diff = record.committedDiffDigest,
              let integrity = record.integrityDigest,
              EvolutionArchiveAuthorityCodec.isDigest(control),
              EvolutionArchiveAuthorityCodec.isDigest(host),
              EvolutionArchiveAuthorityCodec.isDigest(diff),
              EvolutionArchiveAuthorityCodec.isDigest(integrity),
              record.branch.hasPrefix("mythos/auto-evolve-"),
              GitIsolation.isSafeLocalBranchName(record.branch),
              record.worktreePath.hasPrefix("/"), record.worktreePath.utf8.count <= 4_096,
              let required = record.requiredBenchmarkCommands,
              !required.isEmpty, required.count <= 64,
              Set(required).count == required.count,
              required.allSatisfy({ boundedText($0, maximumBytes: 262_144) }),
              record.score >= 0, record.score <= EvolutionParentSelector.maxFitness else {
            return .invalidRecord("missing or unsafe durable candidate/evaluator binding")
        }

        let evaluationEnvelope: [Any?] = [
            record.evaluationReceiptID, record.evaluationReceiptDigest,
            record.evaluationReceiptSeal, record.evaluationContainmentExecutionDigest,
        ]
        let evaluationFieldCount = evaluationEnvelope.filter { $0 != nil }.count
        guard evaluationFieldCount == 0 || evaluationFieldCount == evaluationEnvelope.count else {
            return .invalidRecord("partial evaluation authority envelope")
        }

        let changed = record.changedFiles
        guard !changed.isEmpty || record.status == .noChange,
              changed == changed.sorted(), Set(changed).count == changed.count,
              changed.count <= 100_000,
              changed.allSatisfy(safeRepositoryPath),
              record.protectedFiles == record.protectedFiles.sorted(),
              Set(record.protectedFiles).count == record.protectedFiles.count,
              record.protectedFiles.allSatisfy({ changed.contains($0) }),
              EvolutionPolicy().protectedFiles(in: changed) == record.protectedFiles else {
            return .invalidRecord("changed/protected path evidence is inconsistent")
        }

        let synthetic = record.benchmarks.filter(\.isSyntheticAgentLoop)
        let actual = record.benchmarks.filter { !$0.isSyntheticAgentLoop }
        guard synthetic.count <= 1, record.benchmarks.count <= 65 else {
            return .invalidRecord("benchmark identity count is invalid")
        }
        for benchmark in actual {
            if let reason = benchmark.authorityValidationError(
                expectedCommitSHA: record.commitSHA, expectedTreeSHA: tree,
                expectedGitControlDigest: control, expectedHostStateDigest: host) {
                return .invalidRecord("\(benchmark.command): \(reason)")
            }
        }

        switch record.status {
        case .passed:
            guard record.protectedFiles.isEmpty, !changed.isEmpty,
                  actual.map(\.command) == required,
                  actual.allSatisfy({ $0.success && $0.failureClass == .passed }),
                  record.score > 0,
                  EvolutionEvaluationAuthority.validationError(record) == nil else {
                return .invalidRecord("passed fitness is not backed by every required benchmark")
            }
        case .failed:
            guard record.protectedFiles.isEmpty, !changed.isEmpty,
                  actual.map(\.command) == required,
                  !actual.isEmpty,
                  actual.contains(where: { $0.failureClass == .assertion }),
                  actual.allSatisfy({ $0.failureClass != .infrastructure }),
                  record.score > 0,
                  EvolutionEvaluationAuthority.validationError(record) == nil else {
                return .invalidRecord("failed stepping-stone contains unsafe/infra fitness evidence")
            }
        case .blocked:
            guard record.score == 0,
                  actual.allSatisfy({ required.contains($0.command) }),
                  (record.evaluationReceiptID == nil
                    && record.evaluationReceiptDigest == nil
                    && record.evaluationReceiptSeal == nil
                    && record.evaluationContainmentExecutionDigest == nil)
                    || EvolutionEvaluationAuthority.validationError(record) == nil else {
                return .invalidRecord("blocked candidate has inconsistent score/evidence")
            }
        case .noChange:
            guard record.score == 0, changed.isEmpty, record.protectedFiles.isEmpty,
                  actual.isEmpty else {
                return .invalidRecord("no-change candidate has change or fitness evidence")
            }
        }
        return nil
    }

    static func parentEligible(_ record: EvolutionCandidateRecord,
                               includeFailed: Bool) -> Bool {
        guard validationError(record) == nil else { return false }
        switch record.status {
        case .passed: return true
        case .failed: return includeFailed
            && record.benchmarks.contains(where: { $0.failureClass == .assertion })
            && !record.benchmarks.contains(where: { $0.failureClass == .infrastructure })
        case .blocked, .noChange: return false
        }
    }

    private static func boundedIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: {
                $0.value == 0 || CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func boundedText(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func objectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
    }

    private static func safeRepositoryPath(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 4_096, !value.hasPrefix("/"),
              value == value.precomposedStringWithCanonicalMapping,
              !value.unicodeScalars.contains(where: {
                  $0.value == 0 || CharacterSet.controlCharacters.contains($0)
              }) else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return false
        }
        return !components.contains(where: {
            $0.precomposedStringWithCanonicalMapping.lowercased() == ".git"
        })
    }
}

extension EvolutionCandidateRecord {
    /// Individual envelope validity is necessary but not sufficient authority: the store additionally
    /// verifies the complete chain, checkpoint, project binding, duplicate identities, and live git ref.
    public var hasValidArchiveAuthority: Bool {
        EvolutionArchiveAuthorityCodec.verify(self, readOnly: true) == nil
    }

    /// Complete durable fitness semantics. Full archive membership/project/ref authority remains
    /// store-owned and is intentionally not implied by this convenience property.
    public var hasValidEvolutionEvidence: Bool {
        EvolutionRecordAuthority.validationError(self) == nil
    }
}

struct EvolutionArchiveHead: Codable, Sendable, Equatable {
    let schema: String
    let projectIdentity: String
    let lineCount: Int
    let tailHash: String
    let archiveByteCount: Int
    let seal: String

    static func make(projectIdentity: String, lineCount: Int, tailHash: String,
                     archiveByteCount: Int) throws -> Self {
        let canonical = signingCanonical(projectIdentity: projectIdentity, lineCount: lineCount,
                                         tailHash: tailHash, archiveByteCount: archiveByteCount)
        let seal = ForgeSeal.sign(canonical)
        guard EvolutionArchiveAuthorityCodec.isDigest(seal) else {
            throw EvolutionArchiveError.invalidSeal("archive head")
        }
        return Self(schema: EvolutionArchiveAuthorityCodec.headSchema,
                    projectIdentity: projectIdentity, lineCount: lineCount,
                    tailHash: tailHash, archiveByteCount: archiveByteCount, seal: seal)
    }

    func validationError(expectedProjectIdentity: String, lineCount expectedLines: Int,
                         tailHash expectedTail: String, archiveByteCount expectedBytes: Int,
                         readOnly: Bool) -> EvolutionArchiveError? {
        guard schema == EvolutionArchiveAuthorityCodec.headSchema,
              EvolutionArchiveAuthorityCodec.isDigest(projectIdentity),
              EvolutionArchiveAuthorityCodec.isDigest(tailHash),
              EvolutionArchiveAuthorityCodec.isDigest(seal), lineCount >= 0, archiveByteCount >= 0
        else { return .invalidRecord("archive head") }
        guard projectIdentity == expectedProjectIdentity else { return .crossProject }
        guard lineCount == expectedLines, tailHash == expectedTail,
              archiveByteCount == expectedBytes else {
            return .brokenChain("archive head does not match the complete JSONL tail")
        }
        let canonical = Self.signingCanonical(projectIdentity: projectIdentity, lineCount: lineCount,
                                              tailHash: tailHash, archiveByteCount: archiveByteCount)
        let valid = readOnly
            ? ForgeSeal.verifyWithoutCreatingKey(canonical, seal: seal)
            : ForgeSeal.verify(canonical, seal: seal)
        return valid ? nil : .invalidSeal("archive head")
    }

    private static func signingCanonical(projectIdentity: String, lineCount: Int,
                                         tailHash: String, archiveByteCount: Int) -> String {
        "kist.evolution-archive.head.v1|project=\(projectIdentity)|lines=\(lineCount)|tail=\(tailHash)|bytes=\(archiveByteCount)"
    }
}
