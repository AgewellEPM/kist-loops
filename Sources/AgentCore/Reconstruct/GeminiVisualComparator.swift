import Foundation

/// The REAL visual-diff node: hand a vision model (Gemini, via VisualVerifyTool / tinky-verify / tinky-
/// vision) the REAL reference and our RENDERED reconstruction, and get back a grounded similarity score +
/// concrete differences. This is what makes "compare it to the real one" real instead of a vibe check.
///
/// Fail-closed: if the model doesn't return a parseable SIMILARITY, or the render didn't happen, the
/// comparison is `ok == false` (never a match) — a missing/garbled verdict must not be read as "identical".
/// `compareImages` is injected (wire it to the Gemini vision API with the two images base64-encoded); tests
/// pass a stub so the parsing + fail-closed logic is verified without a network/model.
public struct GeminiVisualComparator: Sendable {
    public typealias CompareImages = @Sendable (_ referencePath: String, _ renderedPath: String, _ prompt: String) async -> String?
    private let compareImages: CompareImages
    public init(compareImages: @escaping CompareImages) { self.compareImages = compareImages }

    static let prompt = """
    Two images: the FIRST is the REAL reference UI; the SECOND is a RECONSTRUCTION of it. Judge how visually
    IDENTICAL the reconstruction is. Reply in EXACTLY this format:
      SIMILARITY: <0-100>
    then one line per visible difference:
      DIFF|<major|minor>|<area>|<what differs>
    (major = structural/obvious mismatch, minor = subtle). Be STRICT — only give a high score when it is
    near pixel-identical in layout, color, text, and spacing. No prose, no other lines.
    """

    public func compare(reference: VisualReference, rendered: RenderedView) async -> VisualComparison {
        guard rendered.ok else {
            return VisualComparison(similarity: 0, diffs: [], ok: false, note: "no rendered screenshot to compare")
        }
        let raw = await compareImages(reference.source, rendered.imagePath, Self.prompt)
        return Self.parse(raw)
    }

    static func parse(_ raw: String?) -> VisualComparison {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return VisualComparison(similarity: 0, diffs: [], ok: false, note: "vision model returned nothing")
        }
        var similarity: Double?
        var diffs: [VisualDiff] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if similarity == nil, let n = parseSimilarity(l) { similarity = n; continue }
            let parts = l.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 4, parts[0].uppercased() == "DIFF" {
                let sev = parts[1].lowercased() == "minor" ? "minor" : "major"
                diffs.append(VisualDiff(area: parts[2], description: parts[3], severity: sev))
            }
        }
        // No parseable score ⇒ fail-closed: we cannot claim a similarity we didn't get.
        guard let similarity else {
            return VisualComparison(similarity: 0, diffs: diffs, ok: false, note: "no SIMILARITY score in the model's reply")
        }
        return VisualComparison(similarity: similarity, diffs: diffs, ok: true)
    }

    /// Parse "SIMILARITY: 87" (or "similarity 87%") → 0.87. Returns nil if the line has no such score.
    static func parseSimilarity(_ line: String) -> Double? {
        guard line.lowercased().contains("similarity") else { return nil }
        let digits = line.split { !$0.isNumber && $0 != "." }.compactMap { Double($0) }
        guard let n = digits.first else { return nil }
        return n > 1 ? min(1, n / 100) : min(1, max(0, n))   // accept 0-100 or 0-1
    }
}
