import Foundation

/// P0 of the self-evolving-loop plan: the ABLATION ORACLE — the one un-fakeable measure that the flywheel
/// is actually compounding. It runs the SAME held-out corpus twice: COLD (no accumulated memory / self__
/// tools / scorecard) vs WARM (with them), and reports the advantage WARM − COLD.
///
/// This is an ORACLE, not the Captain — and the separation is load-bearing (a decider that measures its own
/// improvement will wish the curve upward). Three properties enforce that here:
///   1. The metric is derived only from GROUNDED per-case outcomes (execution-grounded pass/fail), never a
///      model's self-report — the caller MUST pass `GroundedVerdict`-derived booleans.
///   2. The held-out corpus MUST be DISJOINT from whatever fed the warm state; if it isn't, `measure`
///      REFUSES to produce a result (contamination ⇒ invalid, not a rosy number).
///   3. The advantage CAN GO DOWN — negative transfer (warm worse than cold) is a first-class, alarmed
///      outcome. A number that can only rise is a gamed number.
public enum AblationArm: String, Sendable, Codable, Equatable { case cold, warm }

public struct AblationResult: Sendable, Codable, Equatable {
    public let epoch: Double
    public let corpusHash: String     // which held-out corpus this measured (disjointness-checked)
    public let n: Int
    public let coldSuccess: Double    // grounded success rate, COLD arm
    public let warmSuccess: Double    // grounded success rate, WARM arm
    public init(epoch: Double, corpusHash: String, n: Int, coldSuccess: Double, warmSuccess: Double) {
        self.epoch = epoch; self.corpusHash = corpusHash; self.n = n
        self.coldSuccess = coldSuccess; self.warmSuccess = warmSuccess
    }
    /// The whole point: does the accumulated state HELP on unseen work? Can be negative.
    public var advantage: Double { warmSuccess - coldSuccess }
    /// The honesty alarm — the warm system did WORSE than cold on held-out (the state is net-harmful here).
    public var negativeTransfer: Bool { advantage < -1e-9 }
}

public enum AblationHarness {

    /// Disjointness guard: the held-out corpus must share NOTHING with the cases that fed the warm state
    /// (its memory, self__ tools, scorecard). Overlap = the warm arm was tested on what it trained on.
    public static func heldOutIsClean(heldOut: Set<String>, accumulatedFrom: Set<String>) -> Bool {
        heldOut.isDisjoint(with: accumulatedFrom)
    }

    /// Measure one COLD-vs-WARM ablation. `coldGrounded`/`warmGrounded` are GROUNDED per-case outcomes on
    /// the SAME held-out cases (index-aligned). Returns nil — REFUSES to fabricate a result — when:
    ///   • the arms disagree on size / are empty (not a comparison),
    ///   • the held-out ids don't match the outcome count (mislabelled corpus),
    ///   • the corpus is CONTAMINATED (overlaps the warm state's training) — the key anti-self-cert guard.
    public static func measure(coldGrounded: [Bool], warmGrounded: [Bool],
                               heldOutIDs: [String], accumulatedFrom: Set<String>,
                               corpusHash: String, epoch: Double) -> AblationResult? {
        guard !coldGrounded.isEmpty, coldGrounded.count == warmGrounded.count,
              heldOutIDs.count == coldGrounded.count else { return nil }
        guard heldOutIsClean(heldOut: Set(heldOutIDs), accumulatedFrom: accumulatedFrom) else { return nil }
        let cold = Double(coldGrounded.filter { $0 }.count) / Double(coldGrounded.count)
        let warm = Double(warmGrounded.filter { $0 }.count) / Double(warmGrounded.count)
        return AblationResult(epoch: epoch, corpusHash: corpusHash, n: coldGrounded.count,
                              coldSuccess: cold, warmSuccess: warm)
    }

    /// Is the flywheel ACCELERATING? Least-squares slope of `advantage` over `epoch` across history.
    /// Positive = the warm advantage is growing run over run (compounding). ~0 = flat. Negative = decaying.
    /// < 2 points ⇒ 0 (no trend yet).
    public static func advantageSlope(_ history: [AblationResult]) -> Double {
        let pts = history.sorted { $0.epoch < $1.epoch }
        guard pts.count >= 2 else { return 0 }
        let xs = pts.map { $0.epoch }, ys = pts.map { $0.advantage }
        let n = Double(pts.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in 0..<pts.count { let dx = xs[i] - mx; num += dx * (ys[i] - my); den += dx * dx }
        return den == 0 ? 0 : num / den
    }
}

/// Durable log of ablation measurements (append-only JSONL), so the advantage SLOPE is trackable over time —
/// the "is the flywheel real" curve. Sibling of EvalHistoryStore; separate file so the oracle's record can't
/// be confused with the (Captain-facing) eval baseline.
public struct AblationHistoryStore {
    public let path: String
    public init(projectRoot: String) {
        self.path = (projectRoot as NSString).appendingPathComponent(".kist/self-evolution/ablation.jsonl")
    }
    public func load() -> [AblationResult] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? dec.decode(AblationResult.self, from: Data($0.utf8)) }
    }
    public func record(_ r: AblationResult) {
        guard let data = try? JSONEncoder().encode(r), let line = String(data: data, encoding: .utf8) else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close()
        } else { try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
