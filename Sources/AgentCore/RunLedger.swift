import Foundation

/// Durable, append-only decision→outcome history at `<root>/.kist/run-ledger.jsonl` — the persisted
/// Phase 3.5 spine. Mirrors `EffortMemory`'s storage discipline exactly (atomic read-append-write to
/// avoid interleaved partial lines under concurrent runs; bounded to `maxRecords`; fail-soft — a
/// missing/corrupt file just means "no history yet", never a crash). History is ADVISORY: a write
/// failure is swallowed, never blocking a run.
public final class RunLedger {
    private let path: String
    private let maxRecords: Int

    public init(projectRoot: String, maxRecords: Int = 1000) {
        self.path = projectRoot + "/.kist/run-ledger.jsonl"
        self.maxRecords = maxRecords
    }

    /// Best-effort atomic append. ATOMIC read-append-write (temp+rename via `write(atomically:)`) — an
    /// unlocked `FileHandle` append can interleave partial lines and CORRUPT the JSONL under concurrent
    /// runs. Cross-process worst case is last-writer-wins (a concurrent entry dropped) — acceptable for
    /// advisory history; corruption is not.
    public func record(_ run: RunRecord) {
        guard let data = try? JSONEncoder().encode(run),
              let text = String(data: data, encoding: .utf8) else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Council (DeepSeek) fix: read existing lines RESILIENTLY (per-line decode), NOT as one
        // all-or-nothing UTF-8 string. A single non-UTF-8 byte previously made the whole read fail →
        // `?? []` → the append silently OVERWROTE all prior history with just the new record. Now one bad
        // byte drops only its own line; every other valid record is preserved across the rewrite.
        var lines = existingLines()
        lines.append(text)
        if lines.count > maxRecords { lines = Array(lines.suffix(maxRecords)) }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Load the (bounded) history, newest-last. Skips any corrupt line rather than failing the whole read.
    public func load() -> [RunRecord] {
        let all = existingLines().compactMap { line -> RunRecord? in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(RunRecord.self, from: d)
        }
        return Array(all.suffix(maxRecords))
    }

    /// Resilient newline-split read: decode each record line INDEPENDENTLY so one corrupt byte anywhere in
    /// the file can never take down the whole history (used by both read paths). Splits on the raw newline
    /// byte at the Data layer, then decodes each line as UTF-8 — a non-decodable line is simply dropped.
    private func existingLines() -> [String] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return data.split(separator: 0x0A).compactMap { String(data: Data($0), encoding: .utf8) }
    }

    // MARK: - Convenience slices for the meta-loop (thin wrappers over pure RunAnalytics)

    /// Runs for one task class (signature), optionally scoped to one org config version.
    public func runs(signature: String, orgVersion: String? = nil) -> [RunRecord] {
        load().filter { $0.signature == signature && (orgVersion == nil || $0.orgVersion == orgVersion) }
    }

    /// The routing decisions the accumulated history says are systematically mis-sized.
    public func routingSignals(minSamples: Int = 8, threshold: Double = 0.25) -> [RunAnalytics.RoutingSignal] {
        RunAnalytics.routingSignals(load(), minSamples: minSamples, threshold: threshold)
    }

    /// The before/after lift of a config change on ONE task class: its runs under `before` vs `after`
    /// orgVersion. This is the honest "did the Captain's self-change actually help?" primitive.
    public func lift(signature: String, before: String, after: String, minSamples: Int = 8) -> RunAnalytics.Lift {
        let history = load().filter { $0.signature == signature }
        return RunAnalytics.lift(before: history.filter { $0.orgVersion == before },
                                 after: history.filter { $0.orgVersion == after },
                                 minSamples: minSamples)
    }
}
