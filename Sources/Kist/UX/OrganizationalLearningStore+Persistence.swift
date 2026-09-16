import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct OrganizationalJSONLRow<Value> {
    let ordinal: Int
    let value: Value
}

enum OrganizationalJSONLLoadResult<Value> {
    case missing
    case complete([OrganizationalJSONLRow<Value>])
    case partial([OrganizationalJSONLRow<Value>])
    case refused
    case failure

    var readableRows: [OrganizationalJSONLRow<Value>] {
        switch self {
        case .complete(let rows), .partial(let rows): return rows
        case .missing, .refused, .failure: return []
        }
    }

    var valuesForMutation: [Value]? {
        switch self {
        case .missing: return []
        case .complete(let rows): return rows.map(\.value)
        case .partial, .refused, .failure: return nil
        }
    }
}

extension OrganizationalLearningStore {
    static let maximumJSONLFileBytes = 64 * 1_024 * 1_024
    static let maximumJSONLLineBytes = 1_024 * 1_024
    static let maximumJSONLRows = 100_000

    /// Append one advisory memory observation with an explicit shared temporal envelope. The caller
    /// chooses the shelf's decay class and may attach a real recurrence; no season is inferred from
    /// prose, tags, filenames, or wall-clock month.
    @discardableResult
    func appendGenericMemory(_ raw: DiskMemoryRecord, to path: String,
                             decayRate: MemoryDecayRate = .medium,
                             seasonalWindow: SeasonalMemoryWindow? = nil,
                             at suppliedInstant: Date? = nil) -> Bool {
        let instant = OrganizationalMemoryTemporal.canonicalInstant(suppliedInstant ?? now())
        guard let record = temporalizedGenericMemory(
            raw, at: instant, decayRate: decayRate, seasonalWindow: seasonalWindow) else {
            return false
        }
        return appendJSON(record, to: path)
    }

    /// Stable-ID update for advisory memory. Updating title/body advances transaction time only; it
    /// preserves the original evidence/decay anchor and every lifecycle/season field. A legacy row
    /// with no event clock is retained for audit and a new temporal observation is added beside it,
    /// rather than inventing an age or silently rewriting history.
    @discardableResult
    func upsertGenericMemory(_ raw: DiskMemoryRecord, to path: String,
                             decayRate: MemoryDecayRate = .medium,
                             seasonalWindow: SeasonalMemoryWindow? = nil,
                             at suppliedInstant: Date? = nil) -> Bool {
        let instant = OrganizationalMemoryTemporal.canonicalInstant(suppliedInstant ?? now())
        guard var incoming = temporalizedGenericMemory(
            raw, at: instant, decayRate: decayRate, seasonalWindow: seasonalWindow) else {
            return false
        }
        return mutateJSONL(DiskMemoryRecord.self, path: path) { records in
            if let id = incoming.id,
               let index = records.lastIndex(where: { $0.id == id }) {
                let prior = records[index]
                if let envelope = prior.temporalProjection,
                   let updated = OrganizationalMemoryTemporal.transactionUpdated(
                        envelope, at: instant, seasonalWindow: seasonalWindow) {
                    incoming.createdAt = updated.createdAt.timeIntervalSince1970
                    incoming.updatedAt = updated.updatedAt.timeIntervalSince1970
                    incoming.temporal = updated
                    records[index] = incoming
                } else {
                    // Unknown-age legacy data stays visible to audit but never becomes a fresh claim by
                    // replacement. The temporally explicit row wins operational dedupe/ranking.
                    records.append(incoming)
                }
            } else {
                records.append(incoming)
            }
            return true
        }
    }

    private func temporalizedGenericMemory(
        _ raw: DiskMemoryRecord,
        at instant: Date,
        decayRate: MemoryDecayRate,
        seasonalWindow: SeasonalMemoryWindow?
    ) -> DiskMemoryRecord? {
        var record = Self.bounded(raw)
        if let projection = record.temporalProjection {
            guard projection.decayRate == decayRate else { return nil }
            return record
        }
        guard record.createdAt == nil, record.updatedAt == nil, record.temporal == nil,
              let envelope = OrganizationalMemoryTemporal.make(
                createdAt: instant, decayRate: decayRate,
                seasonalWindow: seasonalWindow) else { return nil }
        record.createdAt = envelope.createdAt.timeIntervalSince1970
        record.updatedAt = envelope.updatedAt.timeIntervalSince1970
        record.temporal = envelope
        return record
    }

    @discardableResult
    func appendJSON<T: Encodable>(_ value: T, to path: String) -> Bool {
        let bounded = Self.boundedDecoded(value)
        guard Self.decodedRowIsMutationSafe(bounded),
              let data = try? JSONEncoder().encode(bounded),
              data.count <= Self.maximumJSONLLineBytes else { return false }
        return withJSONLMutationLock(path: path) {
            do {
                if !FileManager.default.fileExists(atPath: path) {
                    guard FileManager.default.createFile(atPath: path, contents: nil,
                                                         attributes: [.posixPermissions: 0o600]) else {
                        return false
                    }
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                guard let existingBytes = (attributes[.size] as? NSNumber)?.uint64Value else {
                    return false
                }
                let appendBytes = UInt64(data.count + 1)
                guard existingBytes <= UInt64(Self.maximumJSONLFileBytes),
                      appendBytes <= UInt64(Self.maximumJSONLFileBytes) - existingBytes else {
                    return false
                }
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                try handle.seekToEnd()
                var line = data
                line.append(0x0a)
                try handle.write(contentsOf: line)
                return true
            } catch {
                return false
            }
        } ?? false
    }

    func loadJSONL<T: Decodable>(_ type: T.Type, path: String) -> [T] {
        loadJSONLWithOrdinals(type, path: path).map(\.value)
    }

    func loadJSONLForMutation<T: Decodable>(_ type: T.Type, path: String) -> [T]? {
        guard mutationInputIsWithinHardCaps(path: path) else { return nil }
        return loadJSONLResult(type, path: path).valuesForMutation
    }

    private func mutationInputIsWithinHardCaps(path: String) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else { return true }
        guard let attributes = try? manager.attributesOfItem(atPath: path),
              let fileBytes = (attributes[.size] as? NSNumber)?.uint64Value,
              fileBytes <= UInt64(Self.maximumJSONLFileBytes),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path),
                                   options: [.mappedIfSafe]),
              data.count <= Self.maximumJSONLFileBytes else { return false }
        var rowCount = 0
        var lineBytes = 0
        for byte in data {
            if byte == 0x0a {
                if lineBytes > 0 {
                    rowCount += 1
                    if rowCount > Self.maximumJSONLRows { return false }
                }
                lineBytes = 0
            } else {
                lineBytes += 1
                if lineBytes > Self.maximumJSONLLineBytes { return false }
            }
        }
        if lineBytes > 0 { rowCount += 1 }
        return rowCount <= Self.maximumJSONLRows
    }

    /// Keeps the physical line number after malformed rows are skipped. This makes equal-score
    /// ordering deterministic without letting one damaged JSONL line hide the safe lines around it.
    func loadJSONLWithOrdinals<T: Decodable>(
        _ type: T.Type, path: String
    ) -> [OrganizationalJSONLRow<T>] {
        loadJSONLResult(type, path: path).readableRows
    }

    /// Audit reads fail soft and return every independently safe row. Mutation callers receive the
    /// richer state and may rewrite only `.complete` or `.missing`; a cap, malformed line, invalid
    /// temporal projection, or I/O failure can therefore never collapse a durable archive.
    func loadJSONLResult<T: Decodable>(
        _ type: T.Type, path: String
    ) -> OrganizationalJSONLLoadResult<T> {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else { return .missing }
        guard let attributes = try? manager.attributesOfItem(atPath: path),
              let fileBytes = (attributes[.size] as? NSNumber)?.uint64Value else {
            return .failure
        }
        guard fileBytes <= UInt64(Self.maximumJSONLFileBytes) else { return .refused }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path),
                                   options: [.mappedIfSafe]) else { return .failure }
        guard data.count <= Self.maximumJSONLFileBytes else { return .refused }

        var rows: [OrganizationalJSONLRow<T>] = []
        rows.reserveCapacity(min(Self.maximumJSONLRows, 1_024))
        var nonemptyRows = 0
        var incomplete = false
        for (ordinal, line) in data.split(separator: 0x0a, omittingEmptySubsequences: false).enumerated() {
            guard !line.isEmpty else { continue }
            nonemptyRows += 1
            guard nonemptyRows <= Self.maximumJSONLRows else {
                incomplete = true
                break
            }
            guard line.count <= Self.maximumJSONLLineBytes,
                  let decoded = try? JSONDecoder().decode(T.self, from: Data(line)) else {
                incomplete = true
                continue
            }
            let bounded = Self.boundedDecoded(decoded)
            if !Self.decodedRowIsMutationSafe(bounded) { incomplete = true }
            rows.append(OrganizationalJSONLRow(ordinal: ordinal, value: bounded))
        }
        return incomplete ? .partial(rows) : .complete(rows)
    }

    @discardableResult
    func saveJSONL<T: Codable>(_ values: [T], to path: String) -> Bool {
        withJSONLMutationLock(path: path) {
            saveJSONLUnlocked(values, to: path)
        } ?? false
    }

    /// Holds the same sidecar lock across load, transform, and atomic replacement. Locking only the
    /// final write loses concurrent updates because every participant can otherwise read the same
    /// old generation and overwrite the other's result.
    func mutateJSONL<T: Codable>(
        _ type: T.Type,
        path: String,
        _ mutation: (inout [T]) -> Bool
    ) -> Bool {
        withJSONLMutationLock(path: path) {
            guard var values = loadJSONLForMutation(type, path: path),
                  mutation(&values) else { return false }
            return saveJSONLUnlocked(values, to: path)
        } ?? false
    }

    private func saveJSONLUnlocked<T: Codable>(_ values: [T], to path: String) -> Bool {
        guard values.count <= Self.maximumJSONLRows,
              mutationInputIsWithinHardCaps(path: path) else { return false }
        switch loadJSONLResult(T.self, path: path) {
        case .missing, .complete: break
        case .partial, .refused, .failure: return false
        }
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
        } catch {
            return false
        }
        var output = Data()
        for value in values {
            let bounded = Self.boundedDecoded(value)
            guard Self.decodedRowIsMutationSafe(bounded),
                  let data = try? JSONEncoder().encode(bounded),
                  data.count <= Self.maximumJSONLLineBytes,
                  output.count <= Self.maximumJSONLFileBytes - data.count - 1 else {
                return false
            }
            output.append(data)
            output.append(0x0a)
        }
        do {
            try output.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// A per-ledger advisory lock used by every organizational JSONL mutation path. It is not an
    /// authority seal; it only prevents cooperative local writers from dropping one another's rows.
    private func withJSONLMutationLock<T>(path: String, _ body: () -> T) -> T? {
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
#if canImport(Darwin) || canImport(Glibc)
        let descriptor = open(
            path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { return nil }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_nlink == 1,
              metadata.st_uid == geteuid(),
              fchmod(descriptor, mode_t(0o600)) == 0,
              flock(descriptor, LOCK_EX) == 0 else { return nil }
#endif
        return body()
    }

    static func boundedDecoded<T>(_ value: T) -> T {
        if let capsule = value as? LearningCapsule {
            return (bounded(capsule) as? T) ?? value
        }
        if let debt = value as? KnowledgeDebtRecord {
            return (bounded(debt) as? T) ?? value
        }
        if let rule = value as? OrganizationalRuleRecord {
            return (bounded(rule) as? T) ?? value
        }
        if let memory = value as? DiskMemoryRecord {
            return (bounded(memory) as? T) ?? value
        }
        if let evidence = value as? LearningEvidenceRecord {
            return (bounded(evidence) as? T) ?? value
        }
        return value
    }

    static func decodedRowIsMutationSafe<T>(_ value: T) -> Bool {
        if let capsule = value as? LearningCapsule {
            return capsule.temporalProjection != nil
        }
        if let debt = value as? KnowledgeDebtRecord {
            return debt.temporalProjection != nil
        }
        if let rule = value as? OrganizationalRuleRecord {
            return rule.temporalProjection != nil
        }
        if let memory = value as? DiskMemoryRecord {
            let allLegacyFieldsMissing = memory.createdAt == nil
                && memory.updatedAt == nil && memory.temporal == nil
            return allLegacyFieldsMissing || memory.temporalProjection != nil
        }
        return true
    }

    static func bounded(_ value: LearningCapsule) -> LearningCapsule {
        var value = value
        value.id = boundedText(value.id, limit: 256)
        value.taskTitle = boundedText(value.taskTitle, limit: 2_048)
        value.summary = boundedText(value.summary, limit: 8_192)
        value.learned = boundedStrings(value.learned)
        value.surprises = boundedStrings(value.surprises)
        value.slowdowns = boundedStrings(value.slowdowns)
        value.assumptionsToChallenge = boundedStrings(value.assumptionsToChallenge)
        value.futureEvolution = boundedText(value.futureEvolution, limit: 8_192)
        value.tokenCount = min(1_000_000_000, max(0, value.tokenCount))
        return value
    }

    static func bounded(_ value: KnowledgeDebtRecord) -> KnowledgeDebtRecord {
        var value = value
        value.id = boundedText(value.id, limit: 256)
        value.topic = boundedText(value.topic, limit: 2_048)
        value.reason = boundedText(value.reason, limit: 8_192)
        value.visit = boundedText(value.visit, limit: 8_192)
        value.impact = min(5, max(1, value.impact))
        value.estimatedLearning = boundedText(value.estimatedLearning, limit: 2_048)
        value.expectedBenefit = boundedStrings(value.expectedBenefit)
        value.sourceCapsuleID = value.sourceCapsuleID.map { boundedText($0, limit: 256) }
        return value
    }

    static func bounded(_ value: OrganizationalRuleRecord) -> OrganizationalRuleRecord {
        var value = value
        value.id = boundedText(value.id, limit: 256)
        value.lesson = boundedText(value.lesson, limit: 4_096)
        value.confidence = min(100, max(1, value.confidence))
        value.reason = boundedText(value.reason, limit: 8_192)
        value.evidence = boundedStrings(value.evidence)
        value.sourceCapsuleID = value.sourceCapsuleID.map { boundedText($0, limit: 256) }
        return value
    }

    static func bounded(_ value: DiskMemoryRecord) -> DiskMemoryRecord {
        var value = value
        value.id = value.id.map { boundedText($0, limit: 256) }
        value.title = value.title.map { boundedText($0, limit: 2_048) }
        value.summary = value.summary.map { boundedText($0, limit: 8_192) }
        value.body = value.body.map { boundedText($0, limit: 16_384) }
        value.source = value.source.map { boundedText($0, limit: 4_096) }
        value.confidence = value.confidence.map { min(100, max(0, $0)) }
        value.impact = value.impact.map { min(5, max(0, $0)) }
        value.tags = value.tags.map { boundedStrings($0) }
        return value
    }

    static func bounded(_ value: LearningEvidenceRecord) -> LearningEvidenceRecord {
        var value = value
        value.id = boundedText(value.id, limit: 256)
        value.objective = boundedText(value.objective, limit: 8_192)
        value.specialistName = boundedText(value.specialistName, limit: 512)
        value.role = boundedText(value.role, limit: 2_048)
        value.preferredModel = boundedText(value.preferredModel, limit: 512)
        value.artifactPath = boundedText(value.artifactPath, limit: 4_096)
        value.taskIDs = Array(value.taskIDs.prefix(1_024))
        value.taskEvidenceUpdated = min(1_024, max(0, value.taskEvidenceUpdated))
        return value
    }

    static func boundedStrings(_ values: [String], count: Int = 64,
                               each: Int = 4_096) -> [String] {
        values.prefix(max(0, count)).map { boundedText($0, limit: each) }
    }

    static func boundedText(_ text: String, limit: Int) -> String {
        let clean = safe(text)
        let maximumBytes = max(0, limit)
        let bytes = clean.utf8
        guard bytes.count > maximumBytes else { return clean }
        var end = bytes.index(bytes.startIndex, offsetBy: maximumBytes)
        while end > bytes.startIndex,
              (bytes[end] & 0b1100_0000) == 0b1000_0000 {
            end = bytes.index(before: end)
        }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

}
