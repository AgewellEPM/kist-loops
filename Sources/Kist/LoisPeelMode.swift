import Foundation

/// LOIS WAKE WORD (Luke 2026-09-17): typing "Lois" in the REPL activates the Peel symbolic lane.
/// Lois is the public name of the Jeeves/Peel engine, so the wake word flips a persistent mode in
/// which every research run must cross the symbolic PEEL proof gate (`requirePEEL: true` in
/// `KistRunner.runResearch`) — grounded symbolic evidence or the run is BLOCKED, never a silent
/// fall-through to an ungrounded dossier. "lois off" releases the mode.
///
/// The mode lives in a small lock-guarded box (not a REPL `var`) because the research closure is
/// built once in `KistRunner` and must observe toggles made later from inside the REPL loop without
/// capturing the REPL itself (retain cycle: repl.research → closure → repl).
public final class LoisPeelMode: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    public init() {}

    public var isActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return active }
        set { lock.lock(); defer { lock.unlock() }; active = newValue }
    }
}

/// What a "lois…" line means. Deterministic, conservative parser: only a LEADING "lois" token fires
/// (never "ask lois later" mid-sentence), so ordinary prose can't trip the Peel gate by accident.
public enum LoisIntent: Equatable {
    /// Bare "lois" → Peel mode ON.
    case activate
    /// "lois off" / "lois stop" / "lois done" / "lois deactivate" → Peel mode OFF.
    case deactivate
    /// "lois <question>" → Peel mode ON and run a PEEL-required research pass on the question now.
    case research(String)

    public static func parse(_ input: String) -> LoisIntent? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1,
                                  omittingEmptySubsequences: true)
        guard let head = parts.first else { return nil }
        // The wake word may carry trailing punctuation ("lois!", "Lois,") but nothing else fused to
        // it — "loisy" or "lois's" must NOT wake the gate.
        let headWord = head.lowercased()
        let stripped = headWord.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?:;"))
        guard stripped == "lois", headWord.hasPrefix("lois"),
              headWord.dropFirst("lois".count).allSatisfy({ ".,!?:;".contains($0) })
        else { return nil }
        guard parts.count > 1 else { return .activate }
        let rest = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty { return .activate }
        let offWords: Set<String> = ["off", "stop", "done", "deactivate", "out"]
        if offWords.contains(rest.lowercased()) { return .deactivate }
        return .research(rest)
    }
}
