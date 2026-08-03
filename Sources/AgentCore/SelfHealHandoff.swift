import Foundation

/// The immutable, machine-readable HANDOFF a self-heal researcher produces for the builder — the clean
/// contract between departments. The builder receives ONLY this (not the research transcript), so it
/// stops acting like half-researcher and just executes: open target_files, apply repair_spec, run the
/// reproduction + verification commands, return the diff.
///
/// If the researcher cannot pin the cause it sets `blocked = true` with a reason — that is a valid,
/// terminal outcome (escalate), NOT a trigger to spawn more research.
public struct SelfHealHandoff: Codable, Equatable, Sendable {
    public var from: String
    public var to: String
    public var taskId: Int?
    public var rootCause: String
    public var confidence: Double          // normalized 0.0–1.0
    public var targetFiles: [String]
    public var repairSpec: String
    public var reproductionCommand: String?
    public var verificationCommands: [String]
    public var blocked: Bool
    public var blockedReason: String?

    private enum CodingKeys: String, CodingKey {
        case from, to, confidence, blocked
        case taskId = "task_id"
        case rootCause = "root_cause"
        case targetFiles = "target_files"
        case repairSpec = "repair_spec"
        case reproductionCommand = "reproduction_command"
        case verificationCommands = "verification_commands"
        case blockedReason = "blocked_reason"
    }

    public init(from: String = "self-heal-researcher", to: String = "self-heal-builder",
                taskId: Int? = nil, rootCause: String, confidence: Double, targetFiles: [String],
                repairSpec: String, reproductionCommand: String? = nil,
                verificationCommands: [String] = [], blocked: Bool = false, blockedReason: String? = nil) {
        self.from = from; self.to = to; self.taskId = taskId; self.rootCause = rootCause
        self.confidence = confidence; self.targetFiles = targetFiles; self.repairSpec = repairSpec
        self.reproductionCommand = reproductionCommand; self.verificationCommands = verificationCommands
        self.blocked = blocked; self.blockedReason = blockedReason
    }

    /// Lenient decode: models write `confidence` as 0.92, 92, or "92%"; missing lists default to empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = (try? c.decode(String.self, forKey: .from)) ?? "self-heal-researcher"
        to = (try? c.decode(String.self, forKey: .to)) ?? "self-heal-builder"
        taskId = try? c.decode(Int.self, forKey: .taskId)
        rootCause = (try? c.decode(String.self, forKey: .rootCause)) ?? ""
        confidence = Self.normalizeConfidence(from: c)
        targetFiles = (try? c.decode([String].self, forKey: .targetFiles)) ?? []
        repairSpec = (try? c.decode(String.self, forKey: .repairSpec)) ?? ""
        reproductionCommand = try? c.decode(String.self, forKey: .reproductionCommand)
        verificationCommands = (try? c.decode([String].self, forKey: .verificationCommands)) ?? []
        blocked = (try? c.decode(Bool.self, forKey: .blocked)) ?? false
        blockedReason = try? c.decode(String.self, forKey: .blockedReason)
    }

    private static func normalizeConfidence(from c: KeyedDecodingContainer<CodingKeys>) -> Double {
        if let d = try? c.decode(Double.self, forKey: .confidence) { return d > 1 ? min(d / 100, 1) : max(d, 0) }
        if let i = try? c.decode(Int.self, forKey: .confidence) { return Double(i) > 1 ? min(Double(i) / 100, 1) : Double(i) }
        if let s = try? c.decode(String.self, forKey: .confidence) {
            let n = Double(s.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) ?? 0
            return n > 1 ? min(n / 100, 1) : max(n, 0)
        }
        return 0
    }

    /// A handoff is only actionable when it names a concrete fix. A blocked or specless handoff is not.
    public var isActionable: Bool { !blocked && !repairSpec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Extract the handoff JSON from a researcher's free-text summary. Accepts a ```handoff or ```json
    /// (or bare ```) fenced block containing a JSON object; returns the first that decodes. nil = the
    /// researcher did not produce a valid handoff (→ research is NOT complete; do not spawn more research).
    public static func parse(from summary: String) -> SelfHealHandoff? {
        for candidate in jsonCandidates(in: summary) {
            if let data = candidate.data(using: .utf8),
               let handoff = try? JSONDecoder().decode(SelfHealHandoff.self, from: data) {
                return handoff
            }
        }
        return nil
    }

    /// Fenced blocks first (```handoff / ```json / ```), then a last-resort brace-balanced object scan.
    static func jsonCandidates(in text: String) -> [String] {
        var out: [String] = []
        let scalars = Array(text)
        var i = 0
        while i < scalars.count {
            if scalars[i] == "`", i + 2 < scalars.count, scalars[i + 1] == "`", scalars[i + 2] == "`" {
                var j = i + 3
                while j < scalars.count, scalars[j] != "\n" { j += 1 }   // skip the ```lang label line
                var body = ""
                var k = j + 1
                while k + 2 < scalars.count, !(scalars[k] == "`" && scalars[k + 1] == "`" && scalars[k + 2] == "`") {
                    body.append(scalars[k]); k += 1
                }
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("{") { out.append(trimmed) }
                i = k + 3
            } else { i += 1 }
        }
        // Fallback: the first brace-balanced {...} anywhere (a model that forgot the fence).
        if out.isEmpty, let start = text.firstIndex(of: "{") {
            var depth = 0
            var end: String.Index?
            var idx = start
            while idx < text.endIndex {
                let ch = text[idx]
                if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1; if depth == 0 { end = idx; break } }
                idx = text.index(after: idx)
            }
            if let end { out.append(String(text[start...end])) }
        }
        return out
    }

    /// The clean, transcript-free brief handed to the builder. No research narrative — just the contract.
    public func builderBrief() -> String {
        var lines = [
            "REPAIR HANDOFF — you are the BUILDER. Do NOT research or re-investigate; the cause is decided.",
            "Root cause: \(rootCause)",
            "Confidence: \(Int((confidence * 100).rounded()))%",
            "Repair spec (make the SMALLEST reversible change): \(repairSpec)",
        ]
        if !targetFiles.isEmpty { lines.append("Target files: \(targetFiles.joined(separator: ", "))") }
        if let repro = reproductionCommand, !repro.isEmpty {
            lines.append("Reproduce FIRST (must fail before your fix): \(repro)")
        }
        if !verificationCommands.isEmpty {
            lines.append("Verify AFTER (must pass, and re-run the repro to prove it's gone): "
                + verificationCommands.joined(separator: " ; "))
        }
        lines.append("Return the diff. Emit VERIFY: <command> => PASS|FAIL: <evidence> for each check you run.")
        return lines.joined(separator: "\n")
    }
}
