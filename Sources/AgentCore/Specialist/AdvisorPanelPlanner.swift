import Foundation

/// A2 — the LLM domain classifier for `/advise`. When the deterministic keyword matcher misses (novel
/// phrasing, or a domain whose words don't overlap a persona's keyword set), ask a fast model which catalog
/// persona(s) best fit — so "help me toast the bride" still finds the comedian/copywriter even with no keyword
/// hit. PURE + injectable (`complete` is the model call) so it's testable without a live model. The result is
/// ALWAYS validated against the catalog — a hallucinated name is dropped, never convened.
public enum AdvisorPanelPlanner {

    /// Returns catalog persona NAMES (most-fitting first, ≤ `limit`), validated to exist in `catalog`.
    /// Empty ⇒ nothing fit (caller falls open to normal handling). `complete(system, user)` runs one fast
    /// model call; a nil return (provider failure) yields [] — fail-open, never a crash.
    public static func classify(task: String, catalog: [SpecialistDefinition], limit: Int = 2,
                                complete: (_ system: String, _ user: String) async -> String?) async -> [String] {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !catalog.isEmpty else { return [] }

        let roster = catalog.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        let system = """
        You route a user's task to the best-fitting expert(s) from a FIXED roster. Reply with ONLY the exact \
        persona name(s) from the roster, most-fitting first, comma-separated, at most \(max(1, limit)). If none \
        genuinely fit, reply exactly: NONE. Do not invent names, explain, or add anything else.
        """
        let user = "Task: \(trimmed)\n\nRoster:\n\(roster)"

        guard let raw = await complete(system, user) else { return [] }
        let response = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if response.uppercased() == "NONE" || response.isEmpty { return [] }

        let valid = Set(catalog.map(\.name))
        let strip = CharacterSet.whitespaces.union(.punctuationCharacters)
        let cap = max(1, limit)
        var result: [String] = []
        var seen = Set<String>()
        for part in response.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let name = String(part).trimmingCharacters(in: strip)   // catalog-validated + de-duped
            if valid.contains(name), seen.insert(name).inserted {
                result.append(name)
                if result.count >= cap { break }
            }
        }
        return result
    }
}
