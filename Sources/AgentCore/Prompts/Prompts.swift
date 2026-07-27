import Foundation

/// The central, versioned home for engineered prompts — the start of pulling scattered inline string
/// literals into one auditable place with a consistent voice + PER-MODEL-TIER scaffolding. The MiMo lesson:
/// one prompt for all models is wrong; a weak model needs heavy scaffolding (exact steps, no exploration),
/// a strong one needs less. `ModelTier` selects.
public enum ModelTier: Sendable {
    case strong   // frontier models — light scaffolding, trusted to navigate/reason
    case weak     // small/local/cheap — heavy scaffolding, exact steps, no autonomous exploration

    /// Classify a (provider, model) into a tier. FAIL-SAFE: anything not known-strong is treated `.weak`
    /// (more scaffolding never breaks a strong model; too little breaks a weak one).
    public static func of(providerId: String, model: String?) -> ModelTier {
        let p = providerId.lowercased(); let m = (model ?? "").lowercased()
        // Weak markers win FIRST — a "flash"/"haiku"/"mini"/small model is weak regardless of provider.
        let weakMarkers = ["flash", "haiku", "mini", "-3b", "-1b", "-7b", "small", "tiny", "lite"]
        if weakMarkers.contains(where: { m.contains($0) }) { return .weak }
        // Known-strong providers (their non-small models).
        if ["anthropic", "openai", "gemini"].contains(p) { return .strong }
        // Known-strong model families on any provider.
        let strongModelHints = ["claude", "gpt-4", "gpt-5", "o1", "o3", "gemini-2", "gemini-3",
                                "deepseek-r", "deepseek-v3", "sonnet", "opus"]
        if strongModelHints.contains(where: { m.contains($0) }) { return .strong }
        return .weak
    }
}

public enum Prompts {

    /// REVIEW prompt. The model is HANDED the file list (from `ReviewTargetResolver`) so it never has to
    /// navigate — it just reads + reasons, which every tier can do. Weak tier gets exact, no-exploration
    /// steps; strong tier gets the lighter form. No-fabrication is enforced in both: cite file:line, and a
    /// finding you can't point at is not a finding.
    public static func review(plan: ReviewPlan, tier: ModelTier) -> String {
        let fileList = plan.files.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let header = """
        STRICT CODE REVIEW. The exact files to review are listed below — they were resolved for you
        (\(plan.rationale)). You do NOT need to search or list directories; everything you need is named.
        """
        let principles = """
        Rules:
        - Report REAL correctness/security bugs, not style.
        - Every finding MUST cite file:line and say why it's a bug and the fix. A finding you can't point
          at a specific line for is NOT a finding — drop it (no fabrication).
        - Rank by severity. If a file is clean, say so in one line.
        """
        switch tier {
        case .weak:
            return """
            \(header)

            Files to review (read EACH one fully with read_file before judging — do NOT list directories,
            do NOT search, do NOT explore beyond these):
            \(fileList)

            Do exactly this, in order:
            1. read_file on file 1, then file 2, … through the last file. Read each ONCE, fully.
            2. Only after reading them all, write ONE final review — do not review before you've read them.
            3. \(principles)
            Then finish (done:true) with the review in the summary. Do not call any other tools.
            """
        case .strong:
            return """
            \(header)

            Files:
            \(fileList)

            Read what you need from them, then give the review.
            \(principles)
            """
        }
    }
}
