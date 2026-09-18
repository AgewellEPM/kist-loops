import Foundation

/// PEEL STATUS WORD (Luke 2026-09-17): typing "peel" in the REPL displays the word SCIENCE and a
/// status readout of the science tool system — is the Lois/Peel symbolic gate armed, is the
/// research lane wired, and does the scientist package (hash-chained hypothesis ledger) exist
/// under this project root. Read-only: unlike "lois", "peel" never changes any mode.
public enum PeelIntent: Equatable {
    /// Bare "peel" (or "peel status") → print the SCIENCE banner + tool-system status.
    case status

    /// Deterministic, conservative parser: only a LEADING "peel" token fires, and only bare or
    /// followed by "status" — "peel the orange" or "banana peel" must never steal a prose turn.
    public static func parse(_ input: String) -> PeelIntent? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1,
                                  omittingEmptySubsequences: true)
        guard let head = parts.first else { return nil }
        // The word may carry trailing punctuation ("peel!", "Peel?") but nothing else fused to
        // it — "peeled" or "peeling" must NOT fire.
        let headWord = head.lowercased()
        let stripped = headWord.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?:;"))
        guard stripped == "peel", headWord.hasPrefix("peel"),
              headWord.dropFirst("peel".count).allSatisfy({ ".,!?:;".contains($0) })
        else { return nil }
        guard parts.count > 1 else { return .status }
        let rest = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rest == "status" || rest.isEmpty ? .status : nil
    }
}

/// Renders the SCIENCE banner + status lines. Pure over its inputs except the scientist-ledger
/// scan, which is a read-only directory walk under `projectRoot` and fails soft to "not found".
public enum PeelScienceStatus {

    /// What the scientist-package scan found. Separated from rendering so tests can pin the scan
    /// arithmetic without parsing ANSI output.
    public struct LedgerScan: Equatable {
        public var runs: Int
        public var events: Int
        public init(runs: Int = 0, events: Int = 0) {
            self.runs = runs
            self.events = events
        }
    }

    /// Counts dogfood runs (directories holding a ledger.jsonl) and their total chained events.
    /// Missing scientist package → nil; unreadable individual files count as zero-event runs.
    public static func scanScientist(projectRoot: String) -> LedgerScan? {
        let fm = FileManager.default
        let dogfood = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent("scientist/dogfood", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: dogfood,
                                                        includingPropertiesForKeys: nil)
        else { return nil }
        var scan = LedgerScan()
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let ledger = entry.appendingPathComponent("ledger.jsonl")
            guard fm.fileExists(atPath: ledger.path) else { continue }
            scan.runs += 1
            if let contents = try? String(contentsOf: ledger, encoding: .utf8) {
                scan.events += contents.split(separator: "\n",
                                              omittingEmptySubsequences: true).count
            }
        }
        return scan
    }

    /// The display. SCIENCE is the headline word by explicit request; the lines under it are the
    /// honest tool-system state — never "started" unless the corresponding wiring actually exists.
    public static func render(peelActive: Bool, researchAvailable: Bool,
                              projectRoot: String) -> String {
        let green = "\u{001B}[32m", dim = "\u{001B}[2m", reset = "\u{001B}[0m"
        var lines = ["\(green)◫ S C I E N C E\(reset)"]

        lines.append(peelActive
            ? "  \(green)peel gate: ACTIVE\(reset)\(dim) — research requires grounded PEEL evidence · \"lois off\" to release\(reset)"
            : "  peel gate: advisory\(dim) — type \"lois\" to arm the fail-closed symbolic gate\(reset)")

        lines.append(researchAvailable
            ? "  research lane: wired\(dim) — \"lois <question>\" runs a PEEL-gated pass\(reset)"
            : "  research lane: unavailable in this mode")

        if let scan = scanScientist(projectRoot: projectRoot) {
            lines.append("  scientist ledger: \(scan.runs) run(s), \(scan.events) chained event(s)\(dim) under scientist/dogfood\(reset)")
        } else {
            lines.append("  scientist ledger: not found\(dim) — no scientist/dogfood under this project root\(reset)")
        }
        return lines.joined(separator: "\n")
    }
}
