import Foundation

/// One recorded run outcome — what the EffortController PREDICTED vs how the run ACTUALLY went. The
/// history of these is what lets the controller self-calibrate ("I keep under-estimating 'migrate' tasks").
public struct EffortOutcome: Codable, Sendable, Equatable {
    public let signature: String        // EffortController.signature(for: goal)
    public let predicted: Int           // predicted complexity 0…100
    public let actual: Int              // measured difficulty 0…100 (post-hoc, from run signals)
    public let quality: Int             // run quality 0…100 (did it finish + verify + efficiently)
    public let success: Bool
    public let at: Double
    public init(signature: String, predicted: Int, actual: Int, quality: Int, success: Bool, at: Double) {
        self.signature = signature; self.predicted = predicted; self.actual = actual
        self.quality = quality; self.success = success; self.at = at
    }
}

/// Pure grading: turn a finished run's signals into a difficulty (how hard it really was) and a quality
/// score (how well it went). No I/O — unit-tested deterministically.
public enum EffortScorer {
    /// How hard the task ACTUALLY turned out (0…100), from the struggle the run exhibited.
    public static func actualDifficulty(failureRate: Double, iterationsUsed: Int, replansUsed: Int, wasStuck: Bool) -> Int {
        let raw = Double(iterationsUsed) * 1.5
            + failureRate * 40
            + Double(replansUsed) * 12
            + (wasStuck ? 25 : 0)
        return max(0, min(100, Int(raw.rounded())))
    }

    /// How WELL the run went (0…100): finished + verified + efficient, penalized by failure/struggle.
    public static func quality(success: Bool, verified: Bool, failureRate: Double, iterationsUsed: Int, iterationBudget: Int) -> Int {
        var q = success ? 60 : 8
        if verified { q += 25 }
        if success, iterationBudget > 0 {
            let usedFraction = Double(iterationsUsed) / Double(iterationBudget)
            if usedFraction <= 0.5 { q += 15 }              // finished with budget to spare
            else if usedFraction > 1.0 { q -= 10 }          // blew the budget
        }
        q -= Int((failureRate * 20).rounded())
        return max(0, min(100, q))
    }
}

/// Durable, append-only history of effort outcomes at `<root>/.kist/effort-history.jsonl`, and the
/// self-calibration derived from it. Fail-soft: a missing/corrupt file just means "no history yet"
/// (neutral calibration), never a crash.
public final class EffortMemory {
    private let path: String
    private let maxRecords: Int

    public init(projectRoot: String, maxRecords: Int = 500) {
        self.path = projectRoot + "/.kist/effort-history.jsonl"
        self.maxRecords = maxRecords
    }

    /// Record one outcome (best-effort; a write failure is swallowed — history is advisory, never blocking).
    /// ATOMIC read-append-write (temp+rename via `write(atomically:)`) — an unlocked `FileHandle` append can
    /// interleave partial lines and CORRUPT the JSONL under concurrent runs (panel finding). Also bounds the
    /// file to `maxRecords`. Cross-process the worst case is last-writer-wins (a concurrent entry dropped) —
    /// acceptable for advisory history; corruption is not.
    public func record(_ outcome: EffortOutcome) {
        guard let line = try? JSONEncoder().encode(outcome),
              let text = String(data: line, encoding: .utf8) else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var lines = (try? String(contentsOfFile: path, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        lines.append(text)
        if lines.count > maxRecords { lines = Array(lines.suffix(maxRecords)) }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    public func load() -> [EffortOutcome] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let all = text.split(separator: "\n").compactMap { line -> EffortOutcome? in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(EffortOutcome.self, from: d)
        }
        return Array(all.suffix(maxRecords))
    }

    /// The learned calibration for a goal: over recent runs with the SAME signature, the mean gap between
    /// actual and predicted difficulty, confidence-weighted so one outlier can't swing it. Pure given the
    /// loaded history, so the math is tested directly via `calibration(from:signature:)`.
    public func calibration(forGoal goal: String) -> EffortController.Calibration {
        Self.calibration(from: load(), signature: EffortController.signature(for: goal))
    }

    public static func calibration(from history: [EffortOutcome], signature: String, recent: Int = 12) -> EffortController.Calibration {
        let matches = history.filter { $0.signature == signature }.suffix(recent)
        guard !matches.isEmpty else { return .neutral }
        let meanDelta = Double(matches.reduce(0) { $0 + ($1.actual - $1.predicted) }) / Double(matches.count)
        // Confidence ramps to full over 5 samples so a single run nudges gently, not violently.
        let confidence = Double(min(matches.count, 5)) / 5.0
        let bias = Int((meanDelta * confidence).rounded())
        // Clamp so history can adjust, never dominate.
        return EffortController.Calibration(bias: max(-30, min(30, bias)), samples: matches.count)
    }
}
