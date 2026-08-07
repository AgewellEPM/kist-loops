import Foundation

/// The loop-guard for self-evolution. An unattended system that writes+ships its own code MUST NOT be able
/// to try the same evolution forever, or churn the binary. Every attempt is journaled; the pure
/// `shouldAttempt` decision refuses to repeat an already-resolved evolution and caps the rate per window.
public struct SelfEvolutionAttempt: Codable, Sendable, Equatable {
    public let tool: String
    public let category: String          // FailureCategory.rawValue
    public let signature: String         // dedup key: tool + normalized failure signature
    public let outcome: String           // attempted | promoted | rejected | spec-handed-off | blocked
    public let atEpoch: Double
    public init(tool: String, category: String, signature: String, outcome: String, atEpoch: Double) {
        self.tool = tool; self.category = category; self.signature = signature
        self.outcome = outcome; self.atEpoch = atEpoch
    }
}

public struct SelfEvolutionLedger {
    public let path: String
    public let maxAttemptsPerWindow: Int
    public let windowSeconds: Double

    public init(projectRoot: String, maxAttemptsPerWindow: Int = 3, windowSeconds: Double = 3600) {
        self.path = (projectRoot as NSString).appendingPathComponent(".kist/self-evolution.jsonl")
        self.maxAttemptsPerWindow = maxAttemptsPerWindow
        self.windowSeconds = windowSeconds
    }

    /// A stable signature for a failure so the SAME wall never triggers a second unattended evolution.
    public static func signature(tool: String, evidence: String) -> String {
        // Normalize volatile bits (paths, quoted args, digits) so "unknown … C:\HELLO.VBS" and
        // "unknown … C:\OTHER.VBS" collapse to one capability signature.
        let norm = evidence.lowercased()
            .replacingOccurrences(of: #"['"].*?['"]"#, with: "'…'", options: .regularExpression)
            .replacingOccurrences(of: #"[a-z]:\\[^ ]+"#, with: "<path>", options: .regularExpression)
            .replacingOccurrences(of: #"[0-9]+"#, with: "#", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return tool + "|" + String(norm.prefix(120))
    }

    // MARK: - Pure decision (testable without file I/O)

    public static func decideShouldAttempt(signature: String, now: Double,
                                           history: [SelfEvolutionAttempt],
                                           maxAttemptsPerWindow: Int,
                                           windowSeconds: Double) -> (ok: Bool, reason: String) {
        // Already resolved for this exact wall → never repeat (promoted = done; rejected = the adversarial
        // gate already said no; spec-handed-off = it's the other repo's job now).
        if let prior = history.last(where: { $0.signature == signature }),
           ["promoted", "rejected", "spec-handed-off"].contains(prior.outcome) {
            return (false, "already ‘\(prior.outcome)’ for this failure — not repeating")
        }
        // Rate cap: never let self-evolution churn the binary.
        let recent = history.filter { now - $0.atEpoch <= windowSeconds }
        if recent.count >= maxAttemptsPerWindow {
            return (false, "self-evolution rate cap reached (\(maxAttemptsPerWindow) per \(Int(windowSeconds))s)")
        }
        return (true, "ok")
    }

    // MARK: - File-backed (append-only JSONL)

    public func load() -> [SelfEvolutionAttempt] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            try? dec.decode(SelfEvolutionAttempt.self, from: Data(line.utf8))
        }
    }

    public func shouldAttempt(signature: String, now: Double) -> (ok: Bool, reason: String) {
        Self.decideShouldAttempt(signature: signature, now: now, history: load(),
                                 maxAttemptsPerWindow: maxAttemptsPerWindow, windowSeconds: windowSeconds)
    }

    public func record(_ attempt: SelfEvolutionAttempt) {
        guard let data = try? JSONEncoder().encode(attempt),
              let line = String(data: data, encoding: .utf8) else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
