import Foundation

/// P2 triangle edge — "a repeated obstacle should nominate a capability." A DETERMINISTIC, LLM-free function
/// of the self-evolution ledger: a failure signature that RECURS but is not yet resolved is queued as a
/// `CapabilityNomination` for a future curriculum (P5) to hand to `ClosedEvolutionLoop`. Same doctrine as
/// `FailureClassifier` — the thing that decides WHAT to grow next must be a fixed, testable function of the
/// evidence, never a model's opinion. Nominations are QUEUED, never auto-applied (no live consumer in P2;
/// P5's `CurriculumSelector` will read `CapabilityNominationStore.load()`).
///
/// Why the ledger (not the captain-learning ring): the ledger's `signature` carries CAPABILITY identity
/// (tool + normalized failure), whereas captain-learning samples have no culprit-tool field.
public struct CapabilityNomination: Codable, Sendable, Equatable {
    public let signature: String     // SelfEvolutionLedger signature (tool + normalized failure)
    public let tool: String          // the recurring culprit capability
    public let category: String      // FailureCategory.rawValue
    public let recurrence: Int       // count of non-terminal attempts for this signature (monotonic — see enqueue upsert)
    public let atEpoch: Double        // when (re)nominated (injected — pure fn takes `now`)
    public init(signature: String, tool: String, category: String, recurrence: Int, atEpoch: Double) {
        self.signature = signature; self.tool = tool; self.category = category
        self.recurrence = recurrence; self.atEpoch = atEpoch
    }
}

public enum CapabilityNominator {
    /// PURE: emit nominations for signatures that (1) recur at least `recurrenceThreshold` times via
    /// non-terminal attempts and (2) are NOT resolved — where "resolved" means the LATEST row for the
    /// signature is terminal, matching `SelfEvolutionLedger.decideShouldAttempt`'s `last(where:)` semantics
    /// (review #15: the old `contains(where:)` disagreed with the ledger). Deterministic: sorted by signature,
    /// one nomination per signature.
    ///
    /// Nomination is a PASSIVE OBSERVATION and is deliberately NOT rate-capped (review #8): the anti-churn
    /// rate cap belongs at ACTUATION (when P5 decides to actually ATTEMPT a nomination), not at the point of
    /// remembering that a wall keeps happening. A saturated window still records the recurring obstacle.
    public static func nominate(history: [SelfEvolutionAttempt], now: Double,
                                recurrenceThreshold: Int = 2) -> [CapabilityNomination] {
        var bySig: [String: [SelfEvolutionAttempt]] = [:]
        for a in history { bySig[a.signature, default: []].append(a) }

        var out: [CapabilityNomination] = []
        for (sig, rows) in bySig {
            let sorted = rows.sorted { $0.atEpoch < $1.atEpoch }
            guard let latest = sorted.last else { continue }
            // (2) resolved iff the LATEST row is terminal — a signature that recurs AGAIN after a terminal
            // outcome (latest row non-terminal) is NOT resolved and may re-nominate.
            if SelfEvolutionLedger.terminalOutcomes.contains(latest.outcome) { continue }
            // (1) recurrence = non-terminal attempts (complement of the shared terminal set — no second
            // hand-maintained allowlist to drift, review #15).
            let recurrence = rows.filter { !SelfEvolutionLedger.terminalOutcomes.contains($0.outcome) }.count
            guard recurrence >= recurrenceThreshold else { continue }
            out.append(CapabilityNomination(signature: sig, tool: latest.tool, category: latest.category,
                                            recurrence: recurrence, atEpoch: now))
        }
        return out.sorted { $0.signature < $1.signature }
    }
}

/// Durable queue of nominations, keyed by signature. Locked + atomic-rewrite (NOT bare append) so concurrent
/// parallel-session writers can't lose updates or glue a new record onto a truncation-partial last line
/// (review #9/#10). UPSERTS by signature (review #11): a signature that recurs further UPDATES its stored
/// recurrence instead of being frozen at first-queue time. Re-derivable from the ledger, so a lost file is
/// re-nominated next pass. No live consumer yet; P5's curriculum reads `load()`.
public struct CapabilityNominationStore {
    public let path: String
    public init(projectRoot: String) {
        self.path = (projectRoot as NSString).appendingPathComponent(".kist/capability-nominations.jsonl")
    }

    public func load() -> [CapabilityNomination] {
        withFileLock { loadUnlocked() }
    }

    private func loadUnlocked() -> [CapabilityNomination] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? dec.decode(CapabilityNomination.self, from: Data($0.utf8)) }
    }

    /// Upsert nominations by signature under a lock, then atomically rewrite the whole file. Returns the
    /// records that were newly added OR updated (a strictly higher recurrence, or a new signature). A
    /// re-nomination with an equal/lower recurrence is a no-op.
    @discardableResult
    public func enqueue(_ nominations: [CapabilityNomination]) -> [CapabilityNomination] {
        withFileLock {
            var bySig = Dictionary(loadUnlocked().map { ($0.signature, $0) }, uniquingKeysWith: { a, _ in a })
            var changed: [CapabilityNomination] = []
            for n in nominations {
                if let existing = bySig[n.signature], n.recurrence <= existing.recurrence { continue }  // no new info
                bySig[n.signature] = n
                changed.append(n)
            }
            guard !changed.isEmpty else { return [] }
            let lines = bySig.values.sorted { $0.signature < $1.signature }.compactMap { rec -> String? in
                guard let d = try? JSONEncoder().encode(rec) else { return nil }
                return String(data: d, encoding: .utf8)
            }.joined(separator: "\n")
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? (lines + "\n").write(toFile: path, atomically: true, encoding: .utf8)   // atomic: no partial-line glue
            return changed
        }
    }

    private func withFileLock<T>(_ body: () -> T) -> T {
        #if canImport(Darwin) || canImport(Glibc)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(path + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return body() }
        defer { flock(fd, LOCK_UN); close(fd) }
        flock(fd, LOCK_EX)
        return body()
        #else
        return body()
        #endif
    }
}
