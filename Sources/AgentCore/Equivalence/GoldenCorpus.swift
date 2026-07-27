import Foundation

/// One captured golden-master case: an input and the ORIGINAL's sealed, Gate-0-verified output. Once a
/// case is golden, determinism has ALREADY been established (the oracle agreed with itself at capture), so
/// replay is a cheap candidate-vs-reference compare — no need to re-run the (possibly slow/unavailable)
/// original.
public struct GoldenCase: Codable, Sendable, Equatable {
    public let id: String
    public let input: String
    public let reference: String      // raw oracle output; canonicalized at compare time
    public init(id: String, input: String, reference: String) { self.id = id; self.input = input; self.reference = reference }
}

/// Durable capture-once / replay-many golden-master store at `<root>/.kist/golden/<name>.jsonl`. Mirrors
/// the `RunLedger`/`EffortMemory` storage discipline (atomic write, fail-soft, resilient per-line read).
/// The capture step enforces Gate 0 up front: only inputs whose oracle is deterministic become golden; a
/// non-deterministic input is reported as UNSEALED (its capture must be fixed, never silently stored).
public final class GoldenCorpus {
    private let path: String
    public init(projectRoot: String, name: String = "default") {
        self.path = projectRoot + "/.kist/golden/\(name).jsonl"
    }

    /// Capture golden cases: run the oracle TWICE per input; keep only the deterministic ones. Returns the
    /// golden set plus the ids of inputs that failed Gate 0 (unsealed — the capture is leaking nondeterminism).
    public static func capture(_ cases: [EquivalenceRun.Case], volatiles: [VolatileField] = [],
                               oracle: (String) throws -> String) -> (golden: [GoldenCase], unsealed: [String]) {
        var golden: [GoldenCase] = [], unsealed: [String] = []
        for c in cases {
            guard let a = try? oracle(c.input), let b = try? oracle(c.input) else { unsealed.append(c.id); continue }
            if CanonicalForm.canonicalize(a, projecting: volatiles) == CanonicalForm.canonicalize(b, projecting: volatiles) {
                golden.append(GoldenCase(id: c.id, input: c.input, reference: a))
            } else {
                unsealed.append(c.id)   // oracle disagreed with itself — do NOT mint a golden from broken capture
            }
        }
        return (golden, unsealed)
    }

    /// Replay a candidate against stored references. Reuses the verdict core: a golden case is a CaseEvidence
    /// whose two oracle "runs" are both the stored reference (Gate 0 trivially holds — determinism was
    /// proven at capture), so the judge reduces to candidate-vs-reference equivalence.
    public static func replay(_ golden: [GoldenCase], volatiles: [VolatileField] = [],
                              candidate: (String) throws -> String) -> EquivalenceReport {
        let evidence = golden.map { g -> CaseEvidence in
            let out: String?; let threw: Bool
            do { out = try candidate(g.input); threw = false } catch { out = nil; threw = true }
            return CaseEvidence(id: g.id, oracleRunA: g.reference, oracleRunB: g.reference,
                                candidate: out, candidateThrew: threw, volatiles: volatiles)
        }
        return EquivalenceReport.judging(evidence)
    }

    // MARK: - persistence (mirrors RunLedger: atomic write, resilient per-line read, fail-soft)

    public func save(_ cases: [GoldenCase]) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let lines = cases.compactMap { c -> String? in
            (try? JSONEncoder().encode(c)).flatMap { String(data: $0, encoding: .utf8) }
        }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    public func load() -> [GoldenCase] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return data.split(separator: 0x0A).compactMap { line in
            try? JSONDecoder().decode(GoldenCase.self, from: Data(line))
        }
    }
}
