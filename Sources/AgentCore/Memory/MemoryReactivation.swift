import Foundation

/// Q3: context-recurrence reactivation. A memory that decayed below the retrieval floor should
/// return when the SITUATION it belongs to recurs — same error, same entity, same failure shape —
/// even though the current query text does not resemble it. Signatures therefore derive from the
/// current situation (recent failure details), never from the query: query-token matching is what
/// lexical ranking already does, and letting it bypass the salience floor would make decay
/// meaningless for anything query-similar.
public struct MemoryRecurrenceContext: Sendable, Equatable {
    public static let maximumSignatures = 64
    public static let maximumSignatureBytes = 64
    /// Generic failure vocabulary and common English carry no situation identity; matching on
    /// them would reactivate everything that ever failed.
    static let genericTokens: Set<String> = [
        "error", "errors", "failed", "failure", "failures", "exception", "warning", "fatal",
        "cannot", "could", "would", "should", "unable", "invalid", "unknown", "missing",
        "timeout", "denied", "aborted", "unexpected", "exited", "status", "command", "process",
        "with", "that", "this", "from", "when", "then", "than", "were", "been", "have",
        "will", "your", "after", "before", "while", "which", "there", "their", "because",
    ]

    public let signatures: Set<String>

    public var isEmpty: Bool { signatures.isEmpty }

    /// Derive situation signatures from recent failure details. Tokens are lowercased, bounded,
    /// and must be identifier-like (length ≥ 4) and non-generic to count as situation identity.
    public static func derive(failureDetails: [String]) -> MemoryRecurrenceContext {
        var signatures: Set<String> = []
        for detail in failureDetails {
            for token in tokens(detail) {
                guard signatures.count < maximumSignatures else {
                    return MemoryRecurrenceContext(signatures: signatures)
                }
                signatures.insert(token)
            }
        }
        return MemoryRecurrenceContext(signatures: signatures)
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "_") }
            .map(String.init)
            .filter { $0.count >= 4 && $0.utf8.count <= maximumSignatureBytes && !genericTokens.contains($0) }
    }

    /// Fraction of situation identity present in the candidate, over a bounded signature window
    /// so one huge failure dump cannot make every score infinitesimal.
    public func recurrenceScore(title: String, text: String) -> Double {
        guard !signatures.isEmpty else { return 0 }
        let candidateTokens = Set(Self.tokens(title) + Self.tokens(text))
        let matched = signatures.intersection(candidateTokens).count
        return min(1, Double(matched) / Double(min(signatures.count, 4)))
    }
}

/// Durable reactivation overlay. Reconsolidation without forgery: the ORIGINAL record is never
/// touched (reading must never refresh an event's age), but each reactivation appends an overlay
/// record that (a) merges the current context signatures — the engineered analogue of re-storing
/// a recalled memory updated by present context — and (b) sustains the memory's retrievability
/// via a fast-decaying boost. The overlay itself forgets: with no fresh recurrence, boosts halve
/// every seven days and the memory sinks back below the floor.
public struct MemoryReactivationStore {
    public static let directory = ".kist/memory/reactivation/v1"
    public static let maximumRecords = 4_096
    public static let maximumRecordedSignatures = 16
    public static let boostHalfLifeDays = 7.0
    public static let perHitBoost = 0.5
    public static let maximumBoost = SeasonalMemoryWindow.maximumInSeasonBoost

    struct Record: Codable {
        let locatorSHA256: String
        let at: Date
        let signatures: [String]
        let querySHA256: String
    }

    let hostRoot: String
    let names: [String]
    let inventoryIssue: String?

    public init(hostRoot: String) {
        self.hostRoot = hostRoot
        do {
            let confined = try ConfinedRoot(root: hostRoot, readOnly: true)
            names = try confined.entries(Self.directory).map(\.name)
            inventoryIssue = names.count <= Self.maximumRecords ? nil
                : "memory reactivation inventory exceeds its bound"
        } catch ToolError.notFound {
            names = []; inventoryIssue = nil
        } catch {
            names = []; inventoryIssue = "memory reactivation inventory unavailable: \(error)"
        }
    }

    static func locatorPrefix(_ locator: String) -> String {
        String(BuilderEvidenceDigest.sha256(locator).prefix(16))
    }

    /// Multiplier ≥ 1 sustaining a previously reactivated memory. Bounded by the same ceiling as
    /// an explicit seasonal boost; it can lift a decayed memory over the floor, never resurrect
    /// a retired or superseded one (the admission gate checks lifecycle first).
    public func boost(locator: String, at now: Date) -> Double {
        let prefix = Self.locatorPrefix(locator)
        let matching = names.filter { $0.hasPrefix(prefix + "-") }
        guard !matching.isEmpty, let confined = try? ConfinedRoot(root: hostRoot, readOnly: true) else { return 1 }
        var accumulated = 0.0
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for name in matching.prefix(64) {
            guard let data = try? confined.readStableData(Self.directory + "/" + name, maxBytes: 8_192),
                  let record = try? decoder.decode(Record.self, from: data),
                  record.locatorSHA256 == BuilderEvidenceDigest.sha256(locator) else { continue }
            let ageDays = now.timeIntervalSince(record.at) / 86_400
            guard ageDays >= 0 else { continue }
            accumulated += Self.perHitBoost * pow(0.5, ageDays / Self.boostHalfLifeDays)
        }
        return min(Self.maximumBoost, 1 + min(1, accumulated))
    }

    /// Append one reactivation record. Returns a reportable issue instead of throwing; a failed
    /// overlay write degrades reconsolidation visibly but never blocks recall.
    public func record(locator: String, context: MemoryRecurrenceContext,
                       query: String, at now: Date) -> String? {
        do {
            let confined = try ConfinedRoot(root: hostRoot)
            guard names.count < Self.maximumRecords else {
                return "memory reactivation overlay at capacity (\(Self.maximumRecords) records); pruning required"
            }
            let record = Record(locatorSHA256: BuilderEvidenceDigest.sha256(locator), at: now,
                                signatures: Array(context.signatures.sorted().prefix(Self.maximumRecordedSignatures)),
                                querySHA256: BuilderEvidenceDigest.sha256(query))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let name = "\(Self.locatorPrefix(locator))-\(Int(now.timeIntervalSince1970 * 1_000))-\(UUID().uuidString.lowercased().prefix(8)).json"
            _ = try confined.createDataIfMissing(Self.directory + "/" + name,
                                                 try encoder.encode(record), createParents: true)
            return nil
        } catch {
            return "memory reactivation record unavailable: \(error)"
        }
    }
}

/// The advisor the admission gate consults when a candidate is eligible but below the salience
/// floor. It carries this recall's situation context and the durable overlay; it has no authority
/// over lifecycle or scope denials.
public struct MemoryRecurrenceAdvisor {
    public static let reactivationThreshold = 0.5

    public let context: MemoryRecurrenceContext
    let store: MemoryReactivationStore
    let evidence: [MemoryFailureEvidence]?

    public init(context: MemoryRecurrenceContext, store: MemoryReactivationStore) {
        self.context = context
        self.store = store
        self.evidence = nil
    }

    public func priorBoost(locator: String, at now: Date) -> Double {
        store.boost(locator: locator, at: now)
    }

    public func recurrenceScore(_ entry: AgentMemoryEntry) -> Double {
        context.recurrenceScore(title: entry.title, text: entry.text)
    }
}

extension ProjectMemory {
    /// Dormant band: episodes that are temporally ELIGIBLE (not retired, superseded, expired, or
    /// future) but whose salience decayed below the recall floor. Ordinary recall never returns
    /// them; the reactivation pass presents them to the admission gate, which admits one only on
    /// a genuine context recurrence. Lifecycle-ineligible rows stay out — reactivation can lift
    /// decay, never resurrect.
    func dormantEpisodes(from data: Data, limit: Int, now: Date) -> [Episode] {
        guard limit > 0, Self.isWireDate(now), data.count <= ProjectMemory.defaultMaxEpisodeBytes,
              let text = String(data: data, encoding: .utf8) else { return [] }
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(ProjectMemory.defaultMaxEpisodeRows)
        var dormant: [Episode] = []
        for line in rows {
            guard let lineData = line.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Episode.self, from: lineData),
                  let episode = Self.episodeWithTemporalMetadata(Self.sanitizedEpisode(decoded)),
                  !Self.hasFutureEvidence(episode, relativeTo: now),
                  let temporal = episode.temporal else { continue }
            let evaluation = temporal.evaluate(at: now)
            guard evaluation.isRetrievalEligible,
                  evaluation.salience < Self.minimumEpisodeSalience else { continue }
            dormant.append(episode)
        }
        return Array(dormant.sorted { $0.at < $1.at }.suffix(limit))
    }
}
