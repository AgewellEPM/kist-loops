import Foundation

/// Layer B of the provider-resilience plan: when a requested/catalog model id is NOT in the provider's
/// live list (the Grok `grok-2-latest` 404), pick the nearest VALID id ON THE SAME PROVIDER — so kist
/// answers from the model family the caller chose, never a silent cross-provider switch.
///
/// Pure + deterministic so it's fully testable offline; the live `/models` fetch is done by the caller
/// (the registry, reactively, only on a model-not-found error — no per-call network).
public enum ModelResolver {

    /// Resolve a requested id against the provider's live ids. Order:
    ///   1. exact live match → keep it,
    ///   2. nearest id in the SAME family (grok→grok, gpt→gpt) by longest shared prefix,
    ///   3. the provider default if it's live,
    ///   4. any live id (deterministic).
    /// Returns nil only when the live list is empty (caller keeps the original and lets the error surface).
    public static func resolve(requested: String, default defaultModel: String, live: [String]) -> String? {
        guard !live.isEmpty else { return nil }
        let liveSet = Set(live)
        if liveSet.contains(requested) { return requested }
        if let nearest = nearestByFamily(requested: requested, live: live) { return nearest }
        if liveSet.contains(defaultModel) { return defaultModel }
        return live.sorted().first
    }

    /// Among live ids sharing the requested id's FAMILY (leading alpha token), the best deterministic
    /// match: longest shared prefix, ties broken lexicographically. nil if no live id shares the family.
    static func nearestByFamily(requested: String, live: [String]) -> String? {
        let fam = family(requested)
        guard !fam.isEmpty else { return nil }
        let sameFamily = live.filter { family($0) == fam }
        guard !sameFamily.isEmpty else { return nil }
        return sameFamily.sorted { a, b in
            let pa = sharedPrefixLen(requested, a), pb = sharedPrefixLen(requested, b)
            return pa != pb ? pa > pb : a < b
        }.first
    }

    /// The family token: the leading run of letters, lowercased. "grok-2-latest"→"grok", "gpt-5.5"→"gpt".
    static func family(_ id: String) -> String { String(id.lowercased().prefix { $0.isLetter }) }

    static func sharedPrefixLen(_ a: String, _ b: String) -> Int {
        let aa = Array(a.lowercased()), bb = Array(b.lowercased())
        var i = 0
        while i < aa.count, i < bb.count, aa[i] == bb[i] { i += 1 }
        return i
    }

    /// Is this error a "model not found" (so we should resolve a valid id rather than fall back)? Covers
    /// both a 404 and the providers (e.g. xAI) that return 400 with "Model not found" in the body.
    public static func isModelNotFound(_ error: Error) -> Bool {
        guard let e = error as? AIProviderError, case let .http(status, body) = e else { return false }
        if status == 404 { return true }
        let b = body.lowercased()
        return status == 400 && (b.contains("model not found") || b.contains("model_not_found")
                                 || b.contains("does not exist") || b.contains("unknown model"))
    }
}
