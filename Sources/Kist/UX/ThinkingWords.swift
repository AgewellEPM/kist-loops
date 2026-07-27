import Foundation

/// The rotating "spinner verb" shown while the model works — kist's answer to Claude Code's cycling
/// "Thinking… / Pondering… / Percolating…". kist's voice is Wu-Tang by DNA, so the words are hip-hop /
/// rap-booth flavored with a streak of dark comedy. Pure over (phase, elapsed, seed) so the rotation is
/// deterministic and unit-tested without a terminal; the event sink just feeds it the live clock.
enum ThinkingWords {
    enum Phase { case thinking, planning, working }

    /// Map the sink's internal phase label ("thinking"/"planning"/"working") to a Phase.
    static func phase(from label: String) -> Phase {
        switch label {
        case "planning": return .planning
        case "working":  return .working
        default:         return .thinking
        }
    }

    // The bars. Lowercase to match kist's existing "◇ thinking" cadence; apostrophe-gerunds for the flow.
    static let thinking = [
        "cookin' bars", "freestylin'", "in the booth", "diggin' in the crates",
        "channelin' ODB", "summonin' the flow", "sharpenin' the pen", "spittin' game",
        "consultin' the dead homies", "meditatin' on your sins", "readin' your obituary",
        "plottin' the come-up", "vibin' in the dark", "ciphering", "brewin' beef", "countin' bodies",
    ]
    static let planning = [
        "plottin' the heist", "drawin' the blueprint", "castin' the crew", "mappin' the come-up",
        "riggin' the game", "settin' the trap", "callin' the shots", "stagin' the ambush",
        "drawin' the map to the loot",
    ]
    static let working = [
        "grindin'", "cookin' in the lab", "puttin' in work", "hammerin' the coffin shut",
        "buryin' the evidence", "layin' bricks", "weldin' the frame", "diggin' the grave",
        "buildin' the empire", "closin' the casket", "stackin' it up", "servin' it hot",
    ]

    static func words(for phase: Phase) -> [String] {
        switch phase {
        case .thinking: return thinking
        case .planning: return planning
        case .working:  return working
        }
    }

    /// The word to show for a phase, rotating every `intervalSeconds` of elapsed time. `seed` varies the
    /// starting word per turn so two turns don't always open on the same line. Deterministic in its inputs.
    static func word(phase: Phase, elapsed: TimeInterval, seed: Int, intervalSeconds: Double = 3.5) -> String {
        let list = words(for: phase)
        guard !list.isEmpty else { return "thinking" }
        let step = Int(max(0, elapsed) / max(0.5, intervalSeconds))
        // Non-negative modulo even if seed is negative.
        let idx = (((seed + step) % list.count) + list.count) % list.count
        return list[idx]
    }
}
