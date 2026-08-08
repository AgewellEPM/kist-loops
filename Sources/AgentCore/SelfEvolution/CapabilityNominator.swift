import Foundation

/// P2 triangle edge — "a repeated obstacle should nominate a capability." A DETERMINISTIC, LLM-free function
/// of the self-evolution ledger: a failure signature that RECURS but is not yet resolved is queued as a
/// `CapabilityNomination` for a future curriculum (P5) to hand to `ClosedEvolutionLoop`. Same doctrine as
/// `FailureClassifier` — the thing that decides WHAT to grow next must be a fixed, testable function of the
/// evidence, never a model's opinion. Nominations are QUEUED, never auto-applied (no live consumer in P2).
///
/// Why the ledger (not the captain-learning ring): the ledger's `signature` carries CAPABILITY identity
/// (tool + normalized failure), whereas captain-learning samples have no culprit-tool field. So the ledger is
/// the only source that can name which capability to grow.
public struct CapabilityNomination: Codable, Sendable, Equatable {
    public let signature: String     // SelfEvolutionLedger signature (tool + normalized failure)
    public let tool: String          // the recurring culprit capability
    public let category: String      // FailureCategory.rawValue
    public let recurrence: Int       // count of non-terminal attempts for this signature
    public let atEpoch: Double        // when nominated (injected — pure fn takes `now`)
    public init(signature: String, tool: String, category: String, recurrence: Int, atEpoch: Double) {
        self.signature = signature; self.tool = tool; self.category = category
        self.recurrence = recurrence; self.atEpoch = atEpoch
    }
}

public enum CapabilityNominator {
    /// An outcome that RESOLVES a signature — a resolved wall is never re-nominated (promoted = done; rejected =
    /// the adversarial gate already said no; spec-handed-off = another repo's job).
    static let terminalOutcomes: Set<String> = ["promoted", "rejected", "spec-handed-off"]
    /// A non-terminal attempt — the recurrence signal (the wall keeps happening and isn't settled).
    static let recurringOutcomes: Set<String> = ["attempted", "blocked"]

    /// PURE: emit nominations for signatures that (1) recur at least `recurrenceThreshold` times via
    /// non-terminal attempts, (2) are NOT already resolved (no terminal outcome in history), and (3) are not
    /// currently globally rate-capped (reuses `SelfEvolutionLedger.decideShouldAttempt` semantics — a rate cap
    /// DEFERS the whole batch, matching the ledger's global cap). Deterministic: sorted by signature, one
    /// nomination per signature. Idempotent by construction — same history + now ⇒ same output.
    public static func nominate(history: [SelfEvolutionAttempt], now: Double,
                                recurrenceThreshold: Int = 2,
                                maxAttemptsPerWindow: Int = 3, windowSeconds: Double = 3600) -> [CapabilityNomination] {
        var bySig: [String: [SelfEvolutionAttempt]] = [:]
        for a in history { bySig[a.signature, default: []].append(a) }

        var out: [CapabilityNomination] = []
        for (sig, rows) in bySig {
            // (2) resolved signatures are done — never re-nominate.
            if rows.contains(where: { terminalOutcomes.contains($0.outcome) }) { continue }
            // (1) recurrence = count of non-terminal attempts.
            let recurrence = rows.filter { recurringOutcomes.contains($0.outcome) }.count
            guard recurrence >= recurrenceThreshold else { continue }
            // (3) global rate cap ⇒ defer the whole batch (queue, don't drop — it re-derives next pass).
            let gate = SelfEvolutionLedger.decideShouldAttempt(
                signature: sig, now: now, history: history,
                maxAttemptsPerWindow: maxAttemptsPerWindow, windowSeconds: windowSeconds)
            guard gate.ok else { continue }
            // Identity from the most recent row for this signature (stable — it's the same tool/category).
            let latest = rows.max(by: { $0.atEpoch < $1.atEpoch })!
            out.append(CapabilityNomination(signature: sig, tool: latest.tool, category: latest.category,
                                            recurrence: recurrence, atEpoch: now))
        }
        return out.sorted { $0.signature < $1.signature }
    }
}

/// Durable, append-only, signature-deduped queue of nominations (ledger-style JSONL; tolerant of the
/// parallel-session full-rewrite/truncation clobber — it re-derives from the ledger, so a lost line is
/// re-nominated next pass). No live consumer yet; P5's curriculum reads `load()`.
public struct CapabilityNominationStore {
    public let path: String
    public init(projectRoot: String) {
        self.path = (projectRoot as NSString).appendingPathComponent(".kist/capability-nominations.jsonl")
    }

    public func load() -> [CapabilityNomination] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? dec.decode(CapabilityNomination.self, from: Data($0.utf8)) }
    }

    /// Append only nominations whose signature isn't already queued (idempotent). Returns the newly-added ones.
    @discardableResult
    public func enqueueNew(_ nominations: [CapabilityNomination]) -> [CapabilityNomination] {
        let existing = Set(load().map { $0.signature })
        let fresh = nominations.filter { !existing.contains($0.signature) }
        guard !fresh.isEmpty else { return [] }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let lines = fresh.compactMap { n -> String? in
            guard let d = try? JSONEncoder().encode(n) else { return nil }
            return String(data: d, encoding: .utf8)
        }.joined(separator: "\n")
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(Data((lines + "\n").utf8)); try? handle.close()
        } else {
            try? (lines + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        return fresh
    }
}
