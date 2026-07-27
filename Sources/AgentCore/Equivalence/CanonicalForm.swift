import Foundation

/// A volatile-field projection: a regex whose matches are replaced with a stable placeholder BEFORE
/// comparison, so a value we KNOW is nondeterministic (a timestamp, a UUID, a request id) is checked for
/// *shape/presence* but never for *value*. The declared list is deliberately minimal — every field you
/// project is a permanent blind spot (a real regression inside it becomes invisible), so projection is a
/// last resort after sealing, not a convenience (council: "over-canonicalization hides real regressions").
public struct VolatileField: Sendable, Equatable {
    public let pattern: String
    public let placeholder: String
    public init(pattern: String, placeholder: String = "<VOLATILE>") {
        self.pattern = pattern; self.placeholder = placeholder
    }

    /// A couple of common defaults callers can opt into (never applied automatically).
    public static let isoTimestamp = VolatileField(pattern: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?"#, placeholder: "<TS>")
    public static let uuid = VolatileField(pattern: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#, placeholder: "<UUID>")
}

/// Canonicalization — reduce a captured output to a stable form so only SEMANTIC differences survive a
/// diff. Two tiers, applied in order:
///   1. declared volatile-field projection (opt-in; see `VolatileField`),
///   2. structural normalization: if the text parses as JSON, re-serialize with SORTED keys + compact
///      separators (key order & insignificant whitespace stop being diffs); otherwise normalize line
///      endings and strip trailing whitespace.
/// Pure and symmetric: both the oracle output and the candidate output pass through the *same*
/// canonicalizer, so any normalization is applied identically to both sides — a normalization can never
/// manufacture a false *difference*, only mask one (which is why tier 1 is kept minimal).
///
/// JSON is canonicalized by `JSONCanonicalizer` (NOT Foundation's `JSONSerialization`, which the council
/// caught minting false `.equivalent` verdicts by collapsing `1.0`→`1` and dropping duplicate keys). Our
/// canonicalizer sorts keys, preserves number lexemes verbatim (a representational change is surfaced, not
/// masked), normalizes string values, and rejects duplicate-key objects (→ text fallback). It is thus
/// fail-closed toward NOT-EQUIVALENT on any representational ambiguity — the caller opts into numeric
/// tolerance via an invariant only when it is genuinely insignificant.
public enum CanonicalForm {
    public static func canonicalize(_ raw: String, projecting volatiles: [VolatileField] = []) -> String {
        var s = raw
        for v in volatiles {
            guard let re = try? NSRegularExpression(pattern: v.pattern) else { continue }
            let range = NSRange(s.startIndex..., in: s)
            s = re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: v.placeholder)
        }
        if let json = canonicalJSON(s) { return json }
        return normalizeText(s)
    }

    /// Canonical JSON via the token-preserving `JSONCanonicalizer` (see its doc for why not
    /// `JSONSerialization`). Returns nil if the string isn't one clean JSON value or has duplicate keys,
    /// so the caller falls back to safe text normalization.
    static func canonicalJSON(_ s: String) -> String? { JSONCanonicalizer.canonical(s) }

    /// Text normalization: CRLF→LF, strip trailing whitespace per line (indentation is preserved — it can
    /// be semantic), and trim the trailing blank tail.
    static func normalizeText(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
