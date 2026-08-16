import Foundation

/// Decides whether a plain message is a LOOKUP question — "find what we did for tinkyspeak", "how does
/// your X work", "what's the state of Y", "where is Z" — that should be answered from our OWN files
/// instead of the model's memory. On a hit, Kist auto-searches the estate and grounds the answer in what
/// it finds, so it stops hallucinating about work it can't see.
///
/// Deliberately NARROW: it fires for knowledge/recall questions, NOT for build tasks ("add/create/implement"
/// — those route to plan-execute) and NOT for pure chit-chat. Pure logic, no I/O, fully unit-tested.
public enum EstateLookupIntent {

    /// Verbs/phrasings that mean "go look this up in what we already have."
    private static let lookupCues: [String] = [
        "find ", "what did we do", "what have we done", "what did we build", "what did we make",
        "what have we built", "what we did", "what we built", "where is", "where's", "where are",
        "what's the state of", "what is the state of", "status of", "state of our", "how does",
        "how do you", "how did we", "show me", "look up", "recall", "remind me what", "do we have",
        "did we ever", "what do we have for", "what exists for", "what's in", "whats in",
        "dig up", "pull up", "search for", "look through", "look for", "what about our"
    ]

    /// Self-references — questions about Kist / "this system" / "our setup" also want grounding in real files.
    private static let selfCues: [String] = [
        "kist", "yourself", "your code", "your source", "your repo", "this system", "our system",
        "our setup", "our stack", "the captain", "your architecture", "how you work"
    ]

    /// Build/creation cues — these are TASKS, not lookups; never intercept them for retrieval.
    private static let buildCues: [String] = [
        "add ", "build ", "create ", "implement ", "refactor ", "write ", "fix ", "make a ",
        "delete ", "remove ", "rename ", "deploy ", "wire ", "install ", "generate "
    ]

    /// True when `message` is a lookup/find/self question worth auto-searching the estate for.
    public static func matches(_ message: String) -> Bool {
        let t = normalizedForIntent(message)
        guard t.count >= 6 else { return false }                 // too short to be a real lookup
        if buildCues.contains(where: { t.hasPrefix($0) }) { return false }   // a build task, not a lookup
        let hasLookupCue = lookupCues.contains { t.contains($0) }
        // Luke often types quickly ("ksit", "tellme", missing '?'). A self-directed "what's next"
        // question is still a lookup even with those harmless shapes; missing it sends the model to its
        // own memory/web and recreates the exact hallucination mode this detector exists to prevent.
        let hasSelfCue = selfCues.contains { t.contains($0) }
            && (t.contains("?") || isQuestionOpener(t) || t.contains("what's next")
                || t.contains("whats next") || t.contains("next natural") || t.hasPrefix("tell me "))
        return hasLookupCue || hasSelfCue
    }

    private static func normalizedForIntent(_ message: String) -> String {
        var t = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "ksit", with: "kist")
        if t.hasPrefix("tellme ") { t = "tell me " + t.dropFirst("tellme ".count) }
        return t
    }

    /// Question-word openers so "how does the router work" counts even without a trailing "?".
    private static func isQuestionOpener(_ t: String) -> Bool {
        ["how ", "what ", "where ", "why ", "which ", "who ", "when ", "does ", "do we ", "is our ", "are our "]
            .contains { t.hasPrefix($0) }
    }

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "for", "our", "we", "did", "do", "does", "what", "where",
        "how", "why", "which", "who", "when", "is", "are", "was", "were", "to", "of", "in", "on", "at",
        "with", "about", "that", "this", "these", "those", "it", "its", "you", "your", "find", "show",
        "me", "up", "look", "have", "has", "had", "been", "get", "got", "want", "need", "please", "can",
        "could", "would", "should", "tell", "give", "state", "status", "work", "works", "made", "make",
        "built", "build", "recall", "remind", "search", "dig", "pull", "everything", "anything", "all",
        "hard", "coded", "hardcoded", "queue", "change", "always", "same", "research", "prior",
        "implementation", "analyze", "analyse", "system"
    ]

    /// The distinctive search terms extracted from a lookup question — proper nouns / project names like
    /// "tinkyspeak", "kist", "perslis" survive; filler and question words are dropped. Deduped, order-preserved,
    /// capped so a rambling question can't spawn a huge query. Empty ⇒ caller should skip the search.
    public static func searchTerms(_ message: String, limit: Int = 6) -> [String] {
        let tokens = normalizedForIntent(message)
            .replacingOccurrences(of: "'s", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        var seen = Set<String>()
        var terms: [String] = []
        // Three-character typo fragments such as "que" previously matched "queue" across the entire
        // estate and nominated unrelated repos. Project identifiers shorter than four characters need
        // an explicit query rather than a dangerously broad automatic sweep.
        for tok in tokens where tok.count >= 4 && !stopwords.contains(tok) {
            if seen.insert(tok).inserted { terms.append(tok) }
            if terms.count >= limit { break }
        }
        return terms
    }
}
