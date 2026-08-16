import Foundation

/// The `/advise` core (dynamic-advisor A1.5): read a task's domain, convene the best-matching advisor
/// persona from the catalog, and return its advice with provenance + a MECHANICAL regulated-domain
/// disclaimer. Injectable `convene` closure so this is testable without live models — the REPL wires the
/// real `SpecialistSpawner.run` as `convene`. Advisory ONLY: it returns text; it never writes/executes
/// (the spawner's isolation enforces the tool ceiling).
public enum AdvisorSession {

    /// Convene the top-matched advisor(s) for `task`. Returns nil when NOTHING matches, so the caller can
    /// fall through to normal handling instead of forcing a bad persona. `convene(persona, task)` runs the
    /// persona (isolated) and returns its output.
    public static func advise(task: String,
                              matcher: TaskPersonaMatcher,
                              limit: Int = 1,
                              convene: (_ persona: SpecialistDefinition, _ task: String) async -> String) async -> String? {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let matches = matcher.matches(for: trimmed, limit: max(1, limit))
        guard let top = matches.first else { return nil }

        let advice = await convene(top.specialist, trimmed)
        let consulted = matches.dropFirst().map(\.specialist.name)
        var header = "🧑‍⚖️ advisor · \(top.specialist.name) · \(top.reasons.joined(separator: "; "))"
        if !consulted.isEmpty { header += " · also considered: \(consulted.joined(separator: ", "))" }

        var out = "\(header)\n\n\(advice)"
        // MECHANICAL disclaimer — appended regardless of what the persona's own prose said, so a regulated
        // advisor can never present as licensed advice even if the model drops its in-prompt caveat.
        if AdvisorSafety.isRegulated(top.specialist.name) { out += "\n\n\(AdvisorSafety.disclaimer)" }
        return out
    }
}

/// Mechanical safety for advisor personas in regulated domains (Luke's vulnerable-user domain: never let a
/// synthesized/convened "lawyer"/"doctor"/"financial advisor" present as licensed advice).
///
/// A1.5 uses a name allowlist of the KNOWN regulated builtins; A3 (persona synthesis) will move this onto a
/// structured `regulatedDomain` flag on `SpecialistDefinition` so synthesized + on-disk personas are covered too.
public enum AdvisorSafety {
    public static let regulatedPersonas: Set<String> = [
        "legal-research-analyst",
        "real-estate-law-advisor",
        "financial-advisor",
        "medical-researcher",
        "music-licensing-advisor",
        "ip-prior-art-researcher",
    ]

    public static func isRegulated(_ personaName: String) -> Bool { regulatedPersonas.contains(personaName) }

    public static let disclaimer =
        "⚠️ Advisory only — this is a reasoning aid, NOT professional legal/medical/financial advice. Verify with a licensed professional before acting."
}
