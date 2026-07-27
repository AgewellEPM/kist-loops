import Foundation

// Pure, dependency-free reliability guards for the edit/write apply path.
//
// Ported TECHNIQUE (not code) from the OpenCode Morph fast-apply plugin (MIT):
// a green build hides three silent-corruption failure modes that a model-produced
// edit can introduce. Catch them at the apply seam, before bytes hit disk:
//
//   1. LEAKED EDIT MARKERS   — merge-conflict / patch-envelope / lazy-placeholder
//                              sentinels that were never supposed to survive into
//                              committed source.
//   2. CATASTROPHIC TRUNCATION — a "localized" edit that nukes >60% of the file
//                              (the model regenerated the whole file and dropped
//                              half of it, or an apply merged wrong).
//   3. DROPPED IMPORTS       — a localized edit that silently deletes an
//                              import/include line it never meant to touch.
//
// CONTRACT — STRICTER, NEVER LOOSER. `validate` returns a `.failure` ToolResult to
// SHORT-CIRCUIT a write, or `nil` to allow it. It never mutates content and it can
// only BLOCK an edit — it can never make a rejected edit succeed. False positives
// are minimized structurally: guards fire only on problems the edit *introduced*
// (compared against `old`), and the aggressive size/import checks run only for
// `localized` edits, where a large drop is essentially always a bug.
public enum EditGuards {

    /// A localized edit whose new content keeps < this fraction of the old content's
    /// characters is treated as catastrophic truncation. 0.40 == "lost more than 60%".
    public static let truncationKeepFloor = 0.40

    /// Below this many old characters the truncation ratio is meaningless (tiny files
    /// legitimately collapse to near-zero), so the truncation check is skipped.
    static let truncationMinOldChars = 200

    /// Validate a proposed old→new content transition for one file.
    ///
    /// - Parameter localized: `true` for surgical edits (edit_file, apply_patch Update
    ///   hunks) where truncation/import-drop are almost never intentional; `false` for
    ///   whole-file replacement (write_file, apply_patch Add) where only the always-valid
    ///   marker check applies.
    /// - Returns: a `.failure` ToolResult to refuse the write, or `nil` to proceed.
    public static func validate(old: String, new: String, path: String, localized: Bool) -> ToolResult? {
        if let m = leakedMarker(old: old, new: new, path: path) { return m }
        guard localized else { return nil }
        if let t = catastrophicTruncation(old: old, new: new, path: path) { return t }
        if let d = droppedImports(old: old, new: new, path: path) { return d }
        return nil
    }

    // MARK: - Guard 1: leaked edit markers

    /// Sentinels that must never appear in committed source. Each is flagged ONLY when
    /// the edit INTRODUCED it (count in `new` > count in `old`), so files that
    /// legitimately contain these tokens — this very file, conflict-resolution docs —
    /// are never falsely refused.
    static let markerSignals: [String] = [
        "<<<<<<<",            // merge-conflict: ours
        ">>>>>>>",            // merge-conflict: theirs
        "*** Begin Patch",    // V4A patch envelope leaked into content
        "*** End Patch",
    ]

    /// Lazy-placeholder comment lines the model emits when it means "keep the rest" but
    /// the apply pasted the placeholder verbatim. Matched per-line (case-insensitive, so
    /// "… Existing code …" can't dodge it) so prose that merely mentions "existing code"
    /// is not caught. (DeepSeek review: was case-sensitive.)
    static let lazyPlaceholderPattern =
        #"(?im)^\s*(?://|#|--|/\*|\*)\s*\.\.\.\s*(existing|unchanged|rest|remaining|previous|omitted|keep)\b.*$"#

    /// The merge-conflict SEPARATOR: exactly seven `=` on their own line. Anchored+exact so
    /// longer `====…` section dividers (which are legitimate) are never flagged. (DeepSeek
    /// review: `=======` could survive after `<<<`/`>>>` are removed.)
    static let conflictSeparatorPattern = #"(?m)^=======\r?$"#

    static func leakedMarker(old: String, new: String, path: String) -> ToolResult? {
        for sig in markerSignals where occurrences(of: sig, in: new) > occurrences(of: sig, in: old) {
            return .failure(
                "edit refused: introduced a leaked edit marker \"\(sig)\" into \(path). "
                + "This is an apply artifact, not real code. Re-read the file and regenerate the "
                + "full, marker-free content.")
        }
        if introducedRegexMatch(conflictSeparatorPattern, old: old, new: new) {
            return .failure(
                "edit refused: introduced a merge-conflict separator (a lone \"=======\" line) into "
                + "\(path). This is a leftover conflict marker, not real code. Regenerate the resolved content.")
        }
        if introducedRegexMatch(lazyPlaceholderPattern, old: old, new: new) {
            return .failure(
                "edit refused: introduced a lazy placeholder (\"… existing code …\"-style comment) "
                + "into \(path). The apply kept the placeholder instead of the real lines. Re-issue "
                + "the edit with the actual code in place of the placeholder.")
        }
        return nil
    }

    /// True when `pattern` matches MORE times in `new` than in `old` — i.e. the edit
    /// INTRODUCED it. Keeps the introduced-only contract for regex signals.
    static func introducedRegexMatch(_ pattern: String, old: String, new: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let newHits = re.numberOfMatches(in: new, range: NSRange(new.startIndex..., in: new))
        let oldHits = re.numberOfMatches(in: old, range: NSRange(old.startIndex..., in: old))
        return newHits > oldHits
    }

    // MARK: - Guard 2: catastrophic truncation

    static func catastrophicTruncation(old: String, new: String, path: String) -> ToolResult? {
        // UTF-8 byte length, not grapheme .count — robust for emoji/CJK-heavy files where
        // grapheme count and real size diverge sharply (DeepSeek review).
        let oldCount = old.utf8.count
        guard oldCount >= truncationMinOldChars else { return nil }
        let keepRatio = Double(new.utf8.count) / Double(oldCount)
        guard keepRatio < truncationKeepFloor else { return nil }
        let lostPct = Int((1.0 - keepRatio) * 100)
        return .failure(
            "edit refused: this localized edit would drop \(lostPct)% of \(path) "
            + "(\(oldCount) → \(new.utf8.count) bytes). That is almost certainly a truncated/mismerged apply, "
            + "not an intentional deletion. Re-read the file and regenerate a complete edit. If you truly "
            + "mean to shrink the file this much, use write_file with the exact intended content.")
    }

    // MARK: - Guard 3: dropped imports

    /// Line shapes counted as an import/include across the languages kist edits.
    static let importPatterns: [String] = [
        #"^\s*import\s+\S"#,          // Swift / JS / TS / Python / Go / Java / Kotlin
        #"^\s*from\s+\S+\s+import\s"#, // Python from-import
        #"^\s*#include\s"#,           // C / C++ / Obj-C
        #"^\s*#import\s"#,            // Obj-C
        #"^\s*use\s+\S"#,             // Rust / PHP
        #"^\s*(?:const|let|var)\s+\S+\s*=\s*require\("#, // CommonJS
        #"^\s*@import\s"#,            // CSS / SCSS
    ]

    /// A localized edit that drops this many or more imports at once is treated as an apply
    /// bug (accidental mass deletion). Dropping one or two is normal refactoring — allowed,
    /// and if an import was genuinely still needed the compiler catches it immediately.
    static let droppedImportFloor = 3

    static func droppedImports(old: String, new: String, path: String) -> ToolResult? {
        let oldImports = importLines(in: old)
        guard !oldImports.isEmpty else { return nil }
        let newImports = importLines(in: new)
        let dropped = oldImports.subtracting(newImports)
        guard dropped.count >= droppedImportFloor else { return nil }
        let sample = dropped.sorted().prefix(5).joined(separator: "\n  ")
        return .failure(
            "edit refused: this localized edit silently removed \(dropped.count) import/include line(s) "
            + "from \(path):\n  \(sample)\nDropping imports that the edit region didn't intend to touch is a "
            + "classic apply bug. Re-issue the edit keeping every import, or make the removal explicit.")
    }

    /// Trimmed set of import-shaped lines in `text`.
    static func importLines(in text: String) -> Set<String> {
        let res = importPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
        var out = Set<String>()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let range = NSRange(line.startIndex..., in: line)
            if res.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                out.insert(trimmed)
            }
        }
        return out
    }

    // MARK: - helpers

    /// Non-overlapping literal-substring count (fast, no regex).
    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }
}
