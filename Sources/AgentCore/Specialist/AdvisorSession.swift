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
                              catalog: [SpecialistDefinition] = BuiltinSpecialists.all,
                              limit: Int = 1,
                              classify: ((_ task: String, _ catalog: [SpecialistDefinition]) async -> [String])? = nil,
                              convene: (_ persona: SpecialistDefinition, _ task: String) async -> String) async -> String? {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1) deterministic keyword match — free, fast, and it wins when it fires.
        let matches = matcher.matches(for: trimmed, limit: max(1, limit))
        var picks: [(def: SpecialistDefinition, reason: String)] =
            matches.map { ($0.specialist, $0.reasons.joined(separator: "; ")) }

        // 2) A2 — LLM domain-classifier fallback ONLY when keywords miss (novel phrasing/domain). The classifier
        // returns catalog names (already catalog-validated in AdvisorPanelPlanner); resolve them to definitions.
        // Fail-open: a nil/empty classify result leaves `picks` empty ⇒ the caller answers normally.
        if picks.isEmpty, let classify {
            let byName = Dictionary(catalog.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            picks = (await classify(trimmed, catalog)).compactMap { name in byName[name].map { ($0, "domain-classified") } }
        }

        guard let top = picks.first else { return nil }
        let advice = await convene(top.def, trimmed)
        let consulted = picks.dropFirst().map(\.def.name)
        var header = "🧑‍⚖️ advisor · \(top.def.name) · \(top.reason)"
        if !consulted.isEmpty { header += " · also considered: \(consulted.joined(separator: ", "))" }

        var out = "\(header)\n\n\(advice)"
        // MECHANICAL disclaimer — appended regardless of what the persona's own prose said, so a regulated
        // advisor can never present as licensed advice even if the model drops its in-prompt caveat.
        if AdvisorSafety.isRegulated(top.def.name) { out += "\n\n\(AdvisorSafety.disclaimer)" }
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
