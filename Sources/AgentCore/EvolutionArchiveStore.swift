import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Owner-controlled, locked JSONL persistence for the evolution archive. The archive file itself is the
/// interprocess lock, so a reader can never observe a writer between validation and append. Every read is
/// descriptor-bound (`O_NOFOLLOW`) and every authority decision is all-or-nothing over the full chain.
public struct EvolutionArchiveStore: Sendable {
    public let root: String

    private static let processLock = NSLock()
    private static let maximumArchiveBytes = 64 * 1_024 * 1_024
    private static let maximumLineBytes = 2 * 1_024 * 1_024
    private static let maximumHeadBytes = 64 * 1_024

    public init(root: String) { self.root = root }

    public var directoryURL: URL {
        URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(".mythos/evolution", isDirectory: true)
    }

    public var archiveURL: URL { directoryURL.appendingPathComponent("archive.jsonl") }
    public var headURL: URL { directoryURL.appendingPathComponent("archive-head.json") }

    public func snapshot() -> EvolutionArchiveSnapshot {
        Self.processLock.lock(); defer { Self.processLock.unlock() }
        do {
            let identity = try AcceptedRunProjectIdentitySnapshot.capture(projectRoot: root)
            let chain = try Self.openDirectoryChain(identity: identity, create: false, lockOperation: LOCK_SH)
            defer { chain.release() }
            guard let directoryFD = chain.evolutionFD else {
                try chain.validate(identity: identity)
                guard try identity.isStillCurrent() else { throw EvolutionArchiveError.unsafeStorage("project root changed") }
                return EvolutionArchiveSnapshot(records: [], authoritativeRecords: [], state: .empty)
            }
            let result = try Self.readSnapshot(directoryFD: directoryFD, identity: identity, lockOperation: LOCK_SH,
                                               readOnlySealVerification: true)
            try chain.validate(identity: identity)
            guard try identity.isStillCurrent() else { throw EvolutionArchiveError.unsafeStorage("project root changed") }
            return result.snapshot
        } catch {
            return Self.invalidSnapshot(error)
        }
    }

    public func records() -> [EvolutionCandidateRecord] { snapshot().records }
    public func authoritativeRecords() -> [EvolutionCandidateRecord] { snapshot().authoritativeRecords }

    @discardableResult
    public func append(_ record: EvolutionCandidateRecord) throws -> EvolutionCandidateRecord {
        Self.processLock.lock(); defer { Self.processLock.unlock() }
        let identity = try AcceptedRunProjectIdentitySnapshot.capture(projectRoot: root)
        let chain = try Self.openDirectoryChain(identity: identity, create: true, lockOperation: LOCK_EX)
        defer { chain.release() }
        guard let directoryFD = chain.evolutionFD else {
            throw EvolutionArchiveError.persistence("could not create evolution directory")
        }

        let archiveFD = try Self.openArchiveForAppend(directoryFD: directoryFD)
        defer { _ = flock(archiveFD, LOCK_UN); _ = close(archiveFD) }
        guard flock(archiveFD, LOCK_EX) == 0 else { throw Self.systemError("lock archive") }
        let before = try Self.readArchiveDescriptor(archiveFD, directoryFD: directoryFD)
        let head = try Self.readOptionalFile(directoryFD: directoryFD, name: "archive-head.json",
                                             maximumBytes: Self.maximumHeadBytes)
        let parsed = Self.parse(archiveData: before, headData: head, projectIdentity: identity.digest,
                                readOnlySealVerification: false)
        if case .invalid(let reason) = parsed.snapshot.state {
            throw EvolutionArchiveError.malformedArchive("refusing append to invalid archive: \(reason)")
        }
        guard case .legacy = EvolutionArchiveAuthorityCodec.envelopeState(record) else {
            throw EvolutionArchiveError.duplicateOrReplay(record.candidateID)
        }
        guard !record.runID.isEmpty, !record.candidateID.isEmpty, !record.objective.isEmpty else {
            throw EvolutionArchiveError.invalidRecord("runID, candidateID, and objective are required")
        }
        if let error = EvolutionRecordAuthority.validationError(record) { throw error }
        let pendingEvaluation = EvolutionEvaluationAuthority.pendingAuthorization(record)
        if record.status == .passed || record.status == .failed {
            guard pendingEvaluation != nil else {
                throw EvolutionArchiveError.invalidRecord(
                    "fitness row lacks a live one-use host evaluation receipt")
            }
        }
        let testBypass = pendingEvaluation == true
            && EvolutionEvaluationAuthority.testAuthorityAvailable
        if !testBypass { try validateLiveCandidateAuthority(record) }
        guard !parsed.snapshot.records.contains(where: { $0.candidateID == record.candidateID }) else {
            throw EvolutionArchiveError.duplicateOrReplay(record.candidateID)
        }
        let objectives = Set(parsed.snapshot.records.filter { $0.runID == record.runID }.map(\.objective))
        guard objectives.isEmpty || objectives == [record.objective] else {
            throw EvolutionArchiveError.duplicateOrReplay("run \(record.runID) changed objective")
        }
        if let parentID = record.parentID {
            guard let parent = parsed.snapshot.authoritativeRecords.first(where: { $0.candidateID == parentID }) else {
                throw EvolutionArchiveError.invalidRecord("parent \(parentID) is not an earlier authoritative row")
            }
            guard record.baseSHA == parent.commitSHA else {
                throw EvolutionArchiveError.invalidRecord(
                    "candidate base \(record.baseSHA) does not match parent \(parentID) commit \(parent.commitSHA)")
            }
            if let fitness = record.capabilityFitness {
                guard fitness.plan.parentIdentity.treeSHA == parent.treeSHA,
                      fitness.plan.parentIdentity.gitControlDigest == parent.gitControlDigest else {
                    throw EvolutionArchiveError.invalidRecord(
                        "held-out parent identity differs from the sealed lineage parent")
                }
            }
        }
        guard try Self.readArchiveDescriptor(archiveFD, directoryFD: directoryFD) == before,
              try Self.readOptionalFile(directoryFD: directoryFD, name: "archive-head.json",
                                        maximumBytes: Self.maximumHeadBytes) == head else {
            throw EvolutionArchiveError.unsafeStorage("archive changed during locked append")
        }
        if record.evaluationReceiptID != nil,
           !EvolutionEvaluationAuthority.consume(record) {
            throw EvolutionArchiveError.duplicateOrReplay(
                record.evaluationReceiptID ?? record.candidateID)
        }

        let signed = try EvolutionArchiveAuthorityCodec.seal(
            record, projectIdentity: identity.digest,
            sequence: parsed.lineCount, previousHash: parsed.tailHash)
        var line = try EvolutionArchiveAuthorityCodec.canonicalRecordData(signed)
        guard line.count <= Self.maximumLineBytes else {
            throw EvolutionArchiveError.invalidRecord("candidate row exceeds size limit")
        }
        line.append(0x0a)
        guard before.count <= Self.maximumArchiveBytes - line.count else {
            throw EvolutionArchiveError.persistence("archive exceeds size limit")
        }
        try Self.writeAll(archiveFD, data: line)
        guard fsync(archiveFD) == 0 else { throw Self.systemError("sync archive") }
        let newByteCount = before.count + line.count
        let newHead = try EvolutionArchiveHead.make(
            projectIdentity: identity.digest, lineCount: parsed.lineCount + 1,
            tailHash: signed.recordHash!, archiveByteCount: newByteCount)
        let headData = try EvolutionArchiveAuthorityCodec.canonicalEncoder().encode(newHead)
        try Self.atomicWrite(directoryFD: directoryFD, name: "archive-head.json", data: headData)
        try Self.validateDescriptor(archiveFD, directoryFD: directoryFD, name: "archive.jsonl",
                                    maximumBytes: Self.maximumArchiveBytes)
        try chain.validate(identity: identity)
        guard try identity.isStillCurrent() else { throw EvolutionArchiveError.unsafeStorage("project root changed") }
        return signed
    }

    private func validateLiveCandidateAuthority(_ record: EvolutionCandidateRecord) throws {
        let hostState = try EvolutionBenchmarkRunner.captureProtectedHostState(repoRoot: root)
        guard hostState.evidenceDigest == record.hostStateDigest else {
            throw EvolutionArchiveError.invalidRecord(
                "protected host state changed before archive authority append")
        }
        let snapshot: GitIsolation.EvolutionCommitSnapshot
        do {
            snapshot = try GitIsolation.captureEvolutionArchiveCandidate(
                repo: root, worktreePath: record.worktreePath,
                branch: record.branch, baseSHA: record.baseSHA)
        } catch {
            throw EvolutionArchiveError.invalidRecord(
                "live candidate/ref/tree validation failed: \(error.localizedDescription)")
        }
        let diffDigest = EvolutionArchiveAuthorityCodec.sha256Hex(
            Data(snapshot.committedDiff.utf8))
        guard snapshot.commitSHA == record.commitSHA,
              snapshot.treeSHA == record.treeSHA,
              snapshot.gitControlDigest == record.gitControlDigest,
              snapshot.changedFiles == record.changedFiles,
              diffDigest == record.committedDiffDigest else {
            throw EvolutionArchiveError.invalidRecord(
                "archive candidate does not match the exact live durable commit/tree/diff")
        }
        let violations = CIIntegrityGuard.inspect(
            committedFiles: snapshot.changedFiles, committedDiff: snapshot.committedDiff)
            .map { "\($0.kind): \($0.claim)" }
        guard EvolutionEvaluationAuthority.integrityDigest(violations) == record.integrityDigest else {
            throw EvolutionArchiveError.invalidRecord("candidate integrity digest does not recompute")
        }
        let receipt: EvolutionBenchmarkAuthorityReceipt?
        if let id = record.evaluationReceiptID,
           let digest = record.evaluationReceiptDigest,
           let seal = record.evaluationReceiptSeal,
           let containmentExecutionDigest = record.evaluationContainmentExecutionDigest {
            receipt = EvolutionBenchmarkAuthorityReceipt(
                id: id, bindingDigest: digest, seal: seal,
                containmentExecutionDigest: containmentExecutionDigest)
        } else {
            receipt = nil
        }
        let recomputed = EvolutionEvaluator.evaluate(
            runID: record.runID, candidateID: record.candidateID,
            parentID: record.parentID, objective: record.objective,
            branch: record.branch, worktreePath: record.worktreePath,
            baseSHA: record.baseSHA, commitSHA: record.commitSHA,
            treeSHA: snapshot.treeSHA, gitControlDigest: snapshot.gitControlDigest,
            hostStateDigest: record.hostStateDigest,
            committedDiff: snapshot.committedDiff, benchmarkAuthority: receipt,
            capabilityFitness: record.capabilityFitness,
            changedFiles: snapshot.changedFiles, benchmarks: record.benchmarks,
            policy: EvolutionPolicy(requiredBenchmarkCommands:
                record.requiredBenchmarkCommands ?? []),
            integrityViolations: violations, createdAtEpoch: record.createdAtEpoch)
        guard recomputed.status == record.status,
              recomputed.score == record.score,
              recomputed.protectedFiles == record.protectedFiles,
              recomputed.summary == record.summary else {
            throw EvolutionArchiveError.invalidRecord(
                "status/score/protected evidence was not host-evaluator derived")
        }
    }

    public func topCandidates(limit: Int = 5) -> [EvolutionCandidateRecord] {
        let readiness = EvolutionAutonomyReadinessAssessment.current
        guard !readiness.blockers.contains(where: {
            $0.gate == .parentRelativeCapabilityFitness || $0.gate == .externalRollbackWitness
        }) else { return [] }
        return topCandidatesForTesting(limit: limit)
    }

    /// Pure ranking seam for unit tests. Production callers cannot inject optimistic gate state.
    func topCandidatesForTesting(limit: Int = 5) -> [EvolutionCandidateRecord] {
        return Array(authoritativeRecords().filter { $0.status == .passed }.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.createdAtEpoch > rhs.createdAtEpoch
        }.prefix(max(0, limit)))
    }

    public func context(limit: Int = 5) -> String {
        let top = topCandidates(limit: limit)
        guard !top.isEmpty else {
            return "No externally witnessed parent-relative capability-fitness candidates are selectable."
        }
        return top.map { "- \($0.candidateID) score=\($0.score) branch=\($0.branch): \($0.summary)" }
            .joined(separator: "\n")
    }

    func contextForTesting(limit: Int = 5) -> String {
        let top = topCandidatesForTesting(limit: limit)
        guard !top.isEmpty else {
            return "No externally witnessed parent-relative capability-fitness candidates are selectable."
        }
        return top.map { "- \($0.candidateID) score=\($0.score) branch=\($0.branch): \($0.summary)" }
            .joined(separator: "\n")
    }

    public func context(
        selectedParent: EvolutionCandidateRecord?,
        limit: Int = 5,
        config: EvolutionParentSelector.Config = .default
    ) -> String {
        let readiness = EvolutionAutonomyReadinessAssessment.current
        guard !readiness.blockers.contains(where: {
            $0.gate == .parentRelativeCapabilityFitness || $0.gate == .externalRollbackWitness
        }) else {
            return "No externally witnessed parent-relative capability-fitness candidates are selectable."
        }
        return contextForTesting(selectedParent: selectedParent, limit: limit, config: config)
    }

    func contextForTesting(
        selectedParent: EvolutionCandidateRecord?,
        limit: Int = 5,
        config: EvolutionParentSelector.Config = .default
    ) -> String {
        guard let selectedParent else { return contextForTesting(limit: limit) }
        var lines = ["Selected parent to build from:", "- \(renderContextLine(selectedParent))"]
        let rest = EvolutionParentSelector.frontier(authoritativeRecords(), config: config)
            .filter { $0.candidateID != selectedParent.candidateID }.prefix(max(0, limit - 1))
        if !rest.isEmpty {
            lines += ["", "Other eligible authoritative frontier candidates:"]
            lines += rest.map { "- \(renderContextLine($0))" }
        }
        return lines.joined(separator: "\n")
    }

    public func selectParentDecision(seed: UInt64,
                                     config: EvolutionParentSelector.Config = .default) -> EvolutionParentSelectionDecision {
        let required: Set<EvolutionAutonomyGate> = [
            .parentRelativeCapabilityFitness,
            .externalRollbackWitness,
        ]
        let blockers = EvolutionAutonomyReadinessAssessment.current.blockers.filter {
            required.contains($0.gate)
        }
        guard blockers.isEmpty else {
            return .refused(reason: blockers.map {
                "\($0.gate.rawValue): \($0.reason)"
            }.joined(separator: "; "))
        }
        return selectParentDecisionForTesting(seed: seed, config: config)
    }

    /// Internal seam for testing local archive/ref validation independently from the deliberately absent
    /// external fitness/witness authorities. Production callers must use `selectParentDecision` above.
    func selectParentDecisionForTesting(seed: UInt64,
                                        config: EvolutionParentSelector.Config = .default) -> EvolutionParentSelectionDecision {
        let current = snapshot()
        if case .invalid(let reason) = current.state { return .refused(reason: reason) }
        let eligible = EvolutionParentSelector.eligibleParents(current.authoritativeRecords, config: config)
        guard !eligible.isEmpty else { return .rootSeed }
        var liveIDs = Set<String>()
        var failures: [String] = []
        for candidate in eligible {
            switch GitIsolation.validateEvolutionParentRef(
                repo: root, branch: candidate.branch, expectedCommitSHA: candidate.commitSHA) {
            case .valid: liveIDs.insert(candidate.candidateID)
            case .invalid(let reason): failures.append("\(candidate.candidateID): \(reason)")
            }
        }
        guard !liveIDs.isEmpty else {
            return .refused(reason: "no authoritative parent has a live matching evolution ref (\(failures.joined(separator: "; ")))")
        }
        guard let selected = EvolutionParentSelector.selectParent(
            from: current.authoritativeRecords, seed: seed, config: config,
            allowedCandidateIDs: liveIDs) else {
            return .refused(reason: "authoritative parent selection produced no live candidate")
        }
        return .selected(selected)
    }

    /// Compatibility projection. Authority-aware orchestrators must use `selectParentDecision`, because
    /// nil cannot distinguish a legitimate root seed from an invalid archive.
    public func selectParent(seed: UInt64,
                             config: EvolutionParentSelector.Config = .default) -> EvolutionCandidateRecord? {
        if case .selected(let record) = selectParentDecision(seed: seed, config: config) { return record }
        return nil
    }

    public func frontier(limit: Int = 5,
                         config: EvolutionParentSelector.Config = .default) -> [EvolutionCandidateRecord] {
        Array(EvolutionParentSelector.frontier(authoritativeRecords(), config: config).prefix(max(0, limit)))
    }

    private func renderContextLine(_ record: EvolutionCandidateRecord) -> String {
        let files = record.changedFiles.prefix(5).joined(separator: ", ")
        let changed = files.isEmpty ? "no changed files" : "changed \(files)"
        return "\(record.candidateID) status=\(record.status.rawValue) score=\(record.score) branch=\(record.branch) \(changed): \(record.summary)"
    }
}

private extension EvolutionArchiveStore {
    struct SecureDirectoryChain {
        let rootFD: Int32
        let mythosFD: Int32?
        let evolutionFD: Int32?

        func validate(identity: AcceptedRunProjectIdentitySnapshot) throws {
            try EvolutionArchiveStore.validateProjectRoot(rootFD, identity: identity)
            if let mythosFD {
                try EvolutionArchiveStore.validateDirectory(mythosFD, parentFD: rootFD, name: ".mythos")
                if let evolutionFD {
                    try EvolutionArchiveStore.validateDirectory(
                        evolutionFD, parentFD: mythosFD, name: "evolution")
                } else {
                    try EvolutionArchiveStore.requireMissing(parentFD: mythosFD, name: "evolution")
                }
            } else {
                try EvolutionArchiveStore.requireMissing(parentFD: rootFD, name: ".mythos")
            }
        }

        func release() {
            if let evolutionFD { _ = close(evolutionFD) }
            if let mythosFD { _ = close(mythosFD) }
            _ = flock(rootFD, LOCK_UN)
            _ = close(rootFD)
        }
    }

    struct ParsedArchive {
        let snapshot: EvolutionArchiveSnapshot
        let lineCount: Int
        let tailHash: String
    }

    static func invalidSnapshot(_ error: Error, records: [EvolutionCandidateRecord] = []) -> EvolutionArchiveSnapshot {
        let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return EvolutionArchiveSnapshot(records: records, authoritativeRecords: [], state: .invalid(reason: reason))
    }

    static func readSnapshot(directoryFD: Int32, identity: AcceptedRunProjectIdentitySnapshot,
                             lockOperation: Int32, readOnlySealVerification: Bool) throws -> ParsedArchive {
        var pathInfo = stat()
        if fstatat(directoryFD, "archive.jsonl", &pathInfo, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw systemError("inspect archive") }
            if try readOptionalFile(directoryFD: directoryFD, name: "archive-head.json",
                                    maximumBytes: maximumHeadBytes) != nil {
                throw EvolutionArchiveError.brokenChain("head exists without archive")
            }
            return ParsedArchive(snapshot: .init(records: [], authoritativeRecords: [], state: .empty),
                                 lineCount: 0,
                                 tailHash: EvolutionArchiveAuthorityCodec.genesisCursor(projectIdentity: identity.digest))
        }
        let fd = openat(directoryFD, "archive.jsonl", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw systemError("open archive") }
        defer { _ = flock(fd, LOCK_UN); _ = close(fd) }
        guard flock(fd, lockOperation) == 0 else { throw systemError("lock archive") }
        let archive = try readArchiveDescriptor(fd, directoryFD: directoryFD)
        let head = try readOptionalFile(directoryFD: directoryFD, name: "archive-head.json",
                                        maximumBytes: maximumHeadBytes)
        let parsed = parse(archiveData: archive, headData: head, projectIdentity: identity.digest,
                           readOnlySealVerification: readOnlySealVerification)
        guard try readArchiveDescriptor(fd, directoryFD: directoryFD) == archive,
              try readOptionalFile(directoryFD: directoryFD, name: "archive-head.json",
                                   maximumBytes: maximumHeadBytes) == head else {
            throw EvolutionArchiveError.unsafeStorage("archive changed during locked read")
        }
        return parsed
    }

    static func parse(archiveData: Data, headData: Data?, projectIdentity: String,
                      readOnlySealVerification: Bool) -> ParsedArchive {
        let genesis = EvolutionArchiveAuthorityCodec.genesisCursor(projectIdentity: projectIdentity)
        guard !archiveData.isEmpty else {
            if headData != nil {
                let invalid = invalidSnapshot(EvolutionArchiveError.brokenChain("head exists for empty archive"))
                return ParsedArchive(snapshot: invalid, lineCount: 0, tailHash: genesis)
            }
            return ParsedArchive(snapshot: .init(records: [], authoritativeRecords: [], state: .empty),
                                 lineCount: 0, tailHash: genesis)
        }
        guard archiveData.last == 0x0a else {
            return ParsedArchive(snapshot: invalidSnapshot(EvolutionArchiveError.malformedArchive("torn final row")),
                                 lineCount: 0, tailHash: genesis)
        }
        var rawLines: [Data] = []
        var start = archiveData.startIndex
        for index in archiveData.indices where archiveData[index] == 0x0a {
            let line = archiveData.subdata(in: start..<index)
            guard !line.isEmpty, line.count <= maximumLineBytes else {
                return ParsedArchive(snapshot: invalidSnapshot(EvolutionArchiveError.malformedArchive("blank or oversized row")),
                                     lineCount: rawLines.count, tailHash: genesis)
            }
            rawLines.append(line)
            start = archiveData.index(after: index)
        }
        guard start == archiveData.endIndex else {
            return ParsedArchive(snapshot: invalidSnapshot(EvolutionArchiveError.malformedArchive("torn final row")),
                                 lineCount: rawLines.count, tailHash: genesis)
        }

        let decoder = JSONDecoder()
        var records: [EvolutionCandidateRecord] = []
        for (index, line) in rawLines.enumerated() {
            guard let record = try? decoder.decode(EvolutionCandidateRecord.self, from: line),
                  let canonical = try? EvolutionArchiveAuthorityCodec.canonicalRecordData(record),
                  canonical == line else {
                return ParsedArchive(snapshot: invalidSnapshot(
                    EvolutionArchiveError.malformedArchive("row \(index) is not strict canonical JSON")),
                    lineCount: rawLines.count, tailHash: genesis)
            }
            records.append(record)
        }

        var candidateIDs = Set<String>()
        var objectivesByRun: [String: String] = [:]
        for record in records {
            guard !record.candidateID.isEmpty, !record.runID.isEmpty,
                  candidateIDs.insert(record.candidateID).inserted else {
                return ParsedArchive(snapshot: invalidSnapshot(
                    EvolutionArchiveError.duplicateOrReplay(record.candidateID), records: records),
                    lineCount: rawLines.count, tailHash: genesis)
            }
            if let prior = objectivesByRun[record.runID], prior != record.objective {
                return ParsedArchive(snapshot: invalidSnapshot(
                    EvolutionArchiveError.duplicateOrReplay("run \(record.runID) changed objective"), records: records),
                    lineCount: rawLines.count, tailHash: genesis)
            }
            objectivesByRun[record.runID] = record.objective
        }

        var tail = genesis
        var signedStarted = false
        var legacyCount = 0
        var authoritative: [EvolutionCandidateRecord] = []
        var authoritativeIDs = Set<String>()
        for (index, record) in records.enumerated() {
            switch EvolutionArchiveAuthorityCodec.envelopeState(record) {
            case .legacy:
                guard !signedStarted else {
                    return ParsedArchive(snapshot: invalidSnapshot(
                        EvolutionArchiveError.brokenChain("legacy row follows signed authority"), records: records),
                        lineCount: rawLines.count, tailHash: tail)
                }
                tail = EvolutionArchiveAuthorityCodec.advanceLegacyCursor(
                    tail, lineIndex: index, rawLine: rawLines[index])
                legacyCount += 1
            case .partial:
                return ParsedArchive(snapshot: invalidSnapshot(
                    EvolutionArchiveError.invalidRecord("partial authority envelope at row \(index)"), records: records),
                    lineCount: rawLines.count, tailHash: tail)
            case .signed:
                signedStarted = true
                if let error = EvolutionRecordAuthority.validationError(record) {
                    return ParsedArchive(snapshot: invalidSnapshot(error, records: records),
                                         lineCount: rawLines.count, tailHash: tail)
                }
                if let error = EvolutionArchiveAuthorityCodec.verify(
                    record, expectedProjectIdentity: projectIdentity, expectedSequence: index,
                    expectedPreviousHash: tail, readOnly: readOnlySealVerification) {
                    return ParsedArchive(snapshot: invalidSnapshot(error, records: records),
                                         lineCount: rawLines.count, tailHash: tail)
                }
                if let parent = record.parentID, !authoritativeIDs.contains(parent) {
                    return ParsedArchive(snapshot: invalidSnapshot(
                        EvolutionArchiveError.invalidRecord("parent \(parent) is not an earlier authoritative row"),
                        records: records), lineCount: rawLines.count, tailHash: tail)
                }
                tail = record.recordHash!
                authoritative.append(record)
                authoritativeIDs.insert(record.candidateID)
            }
        }

        guard !authoritative.isEmpty else {
            if headData != nil {
                return ParsedArchive(snapshot: invalidSnapshot(
                    EvolutionArchiveError.brokenChain("signed head exists for legacy-only archive"), records: records),
                    lineCount: rawLines.count, tailHash: tail)
            }
            return ParsedArchive(snapshot: .init(records: records, authoritativeRecords: [],
                                                 state: .legacyOnly(legacyCount: legacyCount)),
                                 lineCount: rawLines.count, tailHash: tail)
        }
        guard let headData else {
            return ParsedArchive(snapshot: invalidSnapshot(
                EvolutionArchiveError.brokenChain("signed archive head is missing"), records: records),
                lineCount: rawLines.count, tailHash: tail)
        }
        guard let head = try? decoder.decode(EvolutionArchiveHead.self, from: headData),
              let canonicalHead = try? EvolutionArchiveAuthorityCodec.canonicalEncoder().encode(head),
              canonicalHead == headData else {
            return ParsedArchive(snapshot: invalidSnapshot(
                EvolutionArchiveError.malformedArchive("archive head is not strict canonical JSON"), records: records),
                lineCount: rawLines.count, tailHash: tail)
        }
        if let error = head.validationError(
            expectedProjectIdentity: projectIdentity, lineCount: rawLines.count,
            tailHash: tail, archiveByteCount: archiveData.count,
            readOnly: readOnlySealVerification) {
            return ParsedArchive(snapshot: invalidSnapshot(error, records: records),
                                 lineCount: rawLines.count, tailHash: tail)
        }
        return ParsedArchive(snapshot: .init(
            records: records, authoritativeRecords: authoritative,
            state: .trusted(authoritativeCount: authoritative.count, legacyCount: legacyCount)),
            lineCount: rawLines.count, tailHash: tail)
    }

    static func openDirectoryChain(identity: AcceptedRunProjectIdentitySnapshot,
                                   create: Bool, lockOperation: Int32) throws -> SecureDirectoryChain {
        let rootFD = open(identity.canonicalRoot, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootFD >= 0 else { throw systemError("open project root") }
        do {
            try validateProjectRoot(rootFD, identity: identity)
            guard flock(rootFD, lockOperation) == 0 else { throw systemError("lock project archive root") }
            let mythosFD = try openDirectory(parentFD: rootFD, name: ".mythos", create: create)
            guard let mythosFD else {
                return SecureDirectoryChain(rootFD: rootFD, mythosFD: nil, evolutionFD: nil)
            }
            do {
                let evolutionFD = try openDirectory(parentFD: mythosFD, name: "evolution", create: create)
                return SecureDirectoryChain(rootFD: rootFD, mythosFD: mythosFD, evolutionFD: evolutionFD)
            } catch {
                _ = close(mythosFD)
                throw error
            }
        } catch {
            _ = flock(rootFD, LOCK_UN)
            _ = close(rootFD)
            throw error
        }
    }

    static func validateProjectRoot(_ fd: Int32,
                                    identity: AcceptedRunProjectIdentitySnapshot) throws {
        var descriptorInfo = stat(); var pathInfo = stat()
        guard fstat(fd, &descriptorInfo) == 0,
              lstat(identity.canonicalRoot, &pathInfo) == 0,
              (descriptorInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (pathInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              descriptorInfo.st_uid == getuid(), pathInfo.st_uid == getuid(),
              UInt64(descriptorInfo.st_dev) == identity.deviceID,
              UInt64(descriptorInfo.st_ino) == identity.inode,
              descriptorInfo.st_dev == pathInfo.st_dev, descriptorInfo.st_ino == pathInfo.st_ino else {
            throw EvolutionArchiveError.unsafeStorage("project root descriptor changed")
        }
    }

    static func requireMissing(parentFD: Int32, name: String) throws {
        var info = stat()
        guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            throw EvolutionArchiveError.unsafeStorage("\(name) appeared during locked archive read")
        }
    }

    static func openDirectory(parentFD: Int32, name: String, create: Bool) throws -> Int32? {
        var info = stat()
        if fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw systemError("inspect \(name) directory") }
            guard create else { return nil }
            guard mkdirat(parentFD, name, mode_t(0o700)) == 0 || errno == EEXIST else {
                throw systemError("create \(name) directory")
            }
        }
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw systemError("open \(name) directory") }
        do { try validateDirectory(fd, parentFD: parentFD, name: name); return fd }
        catch { _ = close(fd); throw error }
    }

    static func validateDirectory(_ fd: Int32, parentFD: Int32, name: String) throws {
        var descriptorInfo = stat(); var pathInfo = stat()
        guard fstat(fd, &descriptorInfo) == 0,
              fstatat(parentFD, name, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              (descriptorInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (pathInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              descriptorInfo.st_uid == getuid(), pathInfo.st_uid == getuid(),
              (descriptorInfo.st_mode & mode_t(0o022)) == 0,
              descriptorInfo.st_dev == pathInfo.st_dev, descriptorInfo.st_ino == pathInfo.st_ino else {
            throw EvolutionArchiveError.unsafeStorage("untrusted \(name) directory")
        }
    }

    static func openArchiveForAppend(directoryFD: Int32) throws -> Int32 {
        var before = stat()
        let existed = fstatat(directoryFD, "archive.jsonl", &before, AT_SYMLINK_NOFOLLOW) == 0
        if !existed && errno != ENOENT { throw systemError("inspect archive") }
        let fd = openat(directoryFD, "archive.jsonl",
                        O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw systemError("open archive for append") }
        do {
            if !existed { guard fchmod(fd, mode_t(0o600)) == 0 else { throw systemError("secure archive") } }
            try validateDescriptor(fd, directoryFD: directoryFD, name: "archive.jsonl",
                                   maximumBytes: maximumArchiveBytes)
            return fd
        } catch { _ = close(fd); throw error }
    }

    static func readArchiveDescriptor(_ fd: Int32, directoryFD: Int32) throws -> Data {
        try validateDescriptor(fd, directoryFD: directoryFD, name: "archive.jsonl",
                               maximumBytes: maximumArchiveBytes)
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw systemError("seek archive") }
        let data = try readAll(fd, maximumBytes: maximumArchiveBytes)
        try validateDescriptor(fd, directoryFD: directoryFD, name: "archive.jsonl",
                               maximumBytes: maximumArchiveBytes)
        return data
    }

    static func readOptionalFile(directoryFD: Int32, name: String,
                                 maximumBytes: Int) throws -> Data? {
        var pathInfo = stat()
        if fstatat(directoryFD, name, &pathInfo, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw systemError("inspect \(name)") }
            return nil
        }
        let fd = openat(directoryFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw systemError("open \(name)") }
        defer { _ = close(fd) }
        try validateDescriptor(fd, directoryFD: directoryFD, name: name, maximumBytes: maximumBytes)
        let data = try readAll(fd, maximumBytes: maximumBytes)
        try validateDescriptor(fd, directoryFD: directoryFD, name: name, maximumBytes: maximumBytes)
        return data
    }

    static func validateDescriptor(_ fd: Int32, directoryFD: Int32, name: String,
                                   maximumBytes: Int) throws {
        var descriptorInfo = stat(); var pathInfo = stat()
        guard fstat(fd, &descriptorInfo) == 0,
              fstatat(directoryFD, name, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0,
              (descriptorInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (pathInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              descriptorInfo.st_uid == getuid(), pathInfo.st_uid == getuid(),
              (descriptorInfo.st_mode & mode_t(0o077)) == 0,
              descriptorInfo.st_nlink == 1, pathInfo.st_nlink == 1,
              descriptorInfo.st_dev == pathInfo.st_dev, descriptorInfo.st_ino == pathInfo.st_ino,
              descriptorInfo.st_size >= 0, descriptorInfo.st_size <= maximumBytes else {
            throw EvolutionArchiveError.unsafeStorage("untrusted \(name)")
        }
    }

    static func readAll(_ fd: Int32, maximumBytes: Int) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return output }
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError("read archive storage")
            }
            guard output.count <= maximumBytes - count else {
                throw EvolutionArchiveError.unsafeStorage("archive storage exceeds size limit")
            }
            output.append(buffer, count: count)
        }
    }

    static func writeAll(_ fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = write(fd, base.advanced(by: written), raw.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw systemError("write archive storage")
                }
                guard count > 0 else { throw EvolutionArchiveError.persistence("short write") }
                written += count
            }
        }
    }

    static func atomicWrite(directoryFD: Int32, name: String, data: Data) throws {
        if try readOptionalFile(directoryFD: directoryFD, name: name, maximumBytes: maximumHeadBytes) != nil {
            // Existing storage was validated above; replacement remains inside the pinned directory fd.
        }
        let temporary = ".\(name).tmp-\(UUID().uuidString)"
        let fd = openat(directoryFD, temporary,
                        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw systemError("create archive head temporary") }
        var installed = false
        defer {
            _ = close(fd)
            if !installed { _ = unlinkat(directoryFD, temporary, 0) }
        }
        guard fchmod(fd, mode_t(0o600)) == 0 else { throw systemError("secure archive head temporary") }
        try writeAll(fd, data: data)
        guard fsync(fd) == 0 else { throw systemError("sync archive head temporary") }
        guard renameat(directoryFD, temporary, directoryFD, name) == 0 else {
            throw systemError("install archive head")
        }
        installed = true
        guard fsync(directoryFD) == 0 || errno == EINVAL else { throw systemError("sync evolution directory") }
        guard try readOptionalFile(directoryFD: directoryFD, name: name,
                                   maximumBytes: maximumHeadBytes) == data else {
            throw EvolutionArchiveError.persistence("archive head post-write mismatch")
        }
    }

    static func systemError(_ operation: String) -> EvolutionArchiveError {
        let code = errno
        return .persistence("\(operation): errno \(code) (\(String(cString: strerror(code))))")
    }
}
