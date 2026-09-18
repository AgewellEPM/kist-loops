import Foundation

/// A current situation is grounded in an immutable host event, never in the time it was read.
struct MemoryFailureEvidence: Sendable {
    static let maximumContextAge: TimeInterval = 7 * 86_400
    let identity: String
    let at: Date
    let locator: String
    let detailSHA256: String
    let context: MemoryRecurrenceContext

    init?(event: AgentHistoryEvent, now: Date) {
        let age = now.timeIntervalSince(event.at)
        guard event.kind == "failed", ProjectMemory.isWireDate(now),
              ProjectMemory.isWireDate(event.at), age >= 0, age <= Self.maximumContextAge else { return nil }
        context = MemoryRecurrenceContext.derive(failureDetails: [event.detail])
        guard !context.isEmpty else { return nil }
        locator = event.locator
        detailSHA256 = event.detailSHA256
        identity = Self.digest([locator, detailSHA256, String(event.at.timeIntervalSince1970)])
        at = event.at
    }

    static func digest(_ fields: [String]) -> String {
        let framed = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return BuilderEvidenceDigest.sha256(framed)
    }

    static func target(_ entry: AgentMemoryEntry) -> String {
        let clock = entry.temporal?.createdAt ?? entry.observedAt
        return digest([entry.locator, clock.map { String($0.timeIntervalSince1970) } ?? "unknown",
                       entry.text])
    }

    func matches(_ entry: AgentMemoryEntry) -> Bool {
        context.recurrenceScore(title: entry.title, text: entry.text)
            >= MemoryRecurrenceAdvisor.reactivationThreshold
    }
}

extension MemoryReactivationStore {
    private struct EvidenceRecord: Codable {
        let schema: Int
        let targetSHA256: String
        let memoryLocator: String
        let failureIdentitySHA256: String
        let failureLocator: String
        let failureDetailSHA256: String
        let failureAt: Double
    }

    private static func evidenceName(target: String, failure: String) -> String {
        "evidence-\(target)-\(failure).json"
    }

    func alreadyRecorded(_ entry: AgentMemoryEntry, evidence: MemoryFailureEvidence) -> Bool {
        // A malformed or unreadable existing record cannot authorize a second publication.
        inventoryIssue != nil || names.contains(Self.evidenceName(
            target: MemoryFailureEvidence.target(entry), failure: evidence.identity))
    }

    func record(_ entry: AgentMemoryEntry, evidence: MemoryFailureEvidence) -> String? {
        if let inventoryIssue { return inventoryIssue }
        do {
            let confined = try ConfinedRoot(root: hostRoot)
            let target = MemoryFailureEvidence.target(entry)
            let path = Self.directory + "/" + Self.evidenceName(target: target, failure: evidence.identity)
            let record = EvidenceRecord(schema: 2, targetSHA256: target,
                                        memoryLocator: entry.locator,
                                        failureIdentitySHA256: evidence.identity,
                                        failureLocator: evidence.locator,
                                        failureDetailSHA256: evidence.detailSHA256,
                                        failureAt: evidence.at.timeIntervalSince1970)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            let count: Int
            do { count = try confined.entries(Self.directory).count }
            catch ToolError.notFound { count = 0 }
            guard count < Self.maximumRecords else {
                return "memory reactivation overlay at capacity; recurrence not recorded"
            }
            // The name binds both identities. Concurrent readers can publish at most one record,
            // and no read can replace the original failure timestamp with a newer access time.
            if try !confined.createDataIfMissing(path, data, createParents: true) {
                guard try confined.readStableData(path, maxBytes: 8_192) == data else {
                    return "memory reactivation record identity conflict; existing bytes preserved"
                }
            }
            return nil
        } catch {
            return "memory reactivation evidence unavailable: \(error)"
        }
    }

    func boost(_ entry: AgentMemoryEntry, at now: Date) -> Double {
        guard inventoryIssue == nil, ProjectMemory.isWireDate(now),
              let confined = try? ConfinedRoot(root: hostRoot, readOnly: true) else { return 1 }
        let target = MemoryFailureEvidence.target(entry)
        let prefix = "evidence-\(target)-"
        var accumulated = 0.0
        for name in names.filter({ $0.hasPrefix(prefix) }).sorted().prefix(64) {
            guard let data = try? confined.readStableData(Self.directory + "/" + name, maxBytes: 8_192),
                  let record = try? JSONDecoder().decode(EvidenceRecord.self, from: data),
                  record.schema == 2, record.targetSHA256 == target,
                  record.memoryLocator == entry.locator,
                  record.failureIdentitySHA256.count == 64,
                  record.failureIdentitySHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  name == Self.evidenceName(target: target, failure: record.failureIdentitySHA256),
                  record.failureAt.isFinite,
                  ProjectMemory.isWireDate(Date(timeIntervalSince1970: record.failureAt)),
                  record.failureIdentitySHA256 == MemoryFailureEvidence.digest([
                    record.failureLocator, record.failureDetailSHA256, String(record.failureAt)]) else { continue }
            let age = now.timeIntervalSince1970 - record.failureAt
            guard age >= 0 else { continue }
            accumulated += Self.perHitBoost * pow(0.5, age / (86_400 * Self.boostHalfLifeDays))
        }
        return min(Self.maximumBoost, 1 + min(1, accumulated))
    }
}

extension MemoryRecurrenceAdvisor {
    /// Production recall uses host event identities. The explicit context initializer remains
    /// available to host callers; ordinary history reads never use its unbound overlay path.
    init(events: [AgentHistoryEvent], store: MemoryReactivationStore, at now: Date) {
        let evidence = events.compactMap { MemoryFailureEvidence(event: $0, now: now) }
            .sorted { $0.at == $1.at ? $0.identity < $1.identity : $0.at < $1.at }
        let bounded = Array(evidence.suffix(8))
        self.evidence = bounded
        self.context = MemoryRecurrenceContext(signatures:
            Set(bounded.flatMap { $0.context.signatures }.sorted()
                .prefix(MemoryRecurrenceContext.maximumSignatures)))
        self.store = store
    }

    func priorBoost(_ entry: AgentMemoryEntry, at now: Date) -> Double {
        evidence == nil ? store.boost(locator: entry.locator, at: now) : store.boost(entry, at: now)
    }

    func canReactivate(_ entry: AgentMemoryEntry) -> Bool {
        guard store.inventoryIssue == nil else { return false }
        if let evidence {
            return evidence.contains { $0.matches(entry) && !store.alreadyRecorded(entry, evidence: $0) }
        }
        return recurrenceScore(entry) >= Self.reactivationThreshold
    }

    func recordReactivation(_ entry: AgentMemoryEntry, query: String, at now: Date) -> String? {
        guard let evidence else {
            return store.record(locator: entry.locator, context: context, query: query, at: now)
        }
        let pending = evidence.filter { $0.matches(entry) && !store.alreadyRecorded(entry, evidence: $0) }
        // Process this captured evidence set together. A later read must not consume another
        // already-present failure and gradually strengthen the overlay through access count.
        let issues = pending.compactMap { store.record(entry, evidence: $0) }
        return issues.isEmpty ? nil : issues.joined(separator: "; ")
    }
}
