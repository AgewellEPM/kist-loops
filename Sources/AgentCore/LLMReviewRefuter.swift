import Foundation

/// The council's SECOND grounding gate: a skeptic that judges whether a GROUNDED review finding is a
/// REAL, in-context bug — not just that its cited code exists. Grounding (ReviewFindingVerifier) proves
/// the code is there; this judges realness. An LLM here can only DOWN-RANK a grounded finding (refute it),
/// never MINT one — so it cannot fabricate, only filter.
///
/// FAIL-STRICT by construction (the hard lesson — a vote parser that defaults to "confirmed" lets a
/// hedged/garbled/empty model reply wrongly clear a finding): a vote is `refuted` UNLESS the model emits
/// an EXPLICIT `VERDICT: REAL` and no refutation marker. Budget-out, a call failure, or any ambiguity all
/// default to REFUTED — a skeptic never confirms on a maybe. With the panel in `ReviewFindingVerifier.verify`,
/// a finding is `.confirmed` only when a STRICT MINORITY of skeptics refute it.
public struct LLMReviewRefuter: ReviewFindingRefuter {
    private let providers: ProviderRegistry
    private let providerId: String
    private let model: String?
    private let projectRoot: String
    private let budget: BudgetLedger?
    private let contextLines: Int

    public init(providers: ProviderRegistry, providerId: String, model: String?,
                projectRoot: String, budget: BudgetLedger? = nil, contextLines: Int = 30) {
        self.providers = providers
        self.providerId = providerId
        self.model = model
        self.projectRoot = projectRoot
        self.budget = budget
        self.contextLines = contextLines
    }

    public func refute(_ finding: GroundedReviewFinding) async -> ReviewRefuteVote {
        // Never spend past the cap; a budget-out skeptic abstains by REFUTING (strict default).
        if let budget, await budget.isExceeded() {
            return ReviewRefuteVote(refuted: true, reason: "budget exceeded — abstained (skeptic default: refute)")
        }
        let context = codeContext(for: finding)
        // If the finding cites a file but we could NOT read its source, we cannot judge realness — REFUSE
        // to confirm (skeptic default), and don't spend a model call we can't ground (Codex MED).
        if context.isEmpty, !finding.file.trimmingCharacters(in: .whitespaces).isEmpty {
            return ReviewRefuteVote(refuted: true, reason: "cited source could not be read — cannot confirm, refuted (skeptic default)")
        }
        let prompt = Self.refutePrompt(finding: finding, context: context)
        let settings = ModelSettings(temperature: 0.0, maxTokens: 350,
                                     systemPrompt: Self.systemPrompt, disableThinking: true)
        do {
            let (text, usage) = try await providers.completeWithUsage(
                providerId: providerId, model: model,
                messages: [ChatMessage(role: .user, content: prompt)], settings: settings)
            if let budget {
                // A provider that reports no usage still costs — estimate from chars so a zero-usage
                // provider can't run the whole N×M panel for free against the cap (Codex MED).
                let measured = usage.isZero
                    ? TokenUsage.estimate(promptChars: prompt.count, completionChars: text.count) : usage
                let usd = CompetitiveBenchmark.priceUSD(vendor: providerId,
                                                        promptTokens: measured.promptTokens,
                                                        completionTokens: measured.completionTokens) ?? 0
                await budget.add(tokens: measured.total, usd: usd)
            }
            return Self.parseVote(text)
        } catch {
            return ReviewRefuteVote(refuted: true, reason: "refuter call failed (\(error)) — abstained (skeptic default: refute)")
        }
    }

    /// Read a window of the real source around the cited line so the skeptic judges against actual code,
    /// not just the finding's self-description. Empty when the file can't be read (the skeptic then judges
    /// on the finding alone — and, lacking confirmation, will default to refuted).
    private func codeContext(for finding: GroundedReviewFinding) -> String {
        guard let full = Self.resolvedPath(finding.file, projectRoot: projectRoot),
              let source = try? String(contentsOfFile: full, encoding: .utf8) else { return "" }
        let lines = source.components(separatedBy: "\n")
        guard let raw = finding.line, raw >= 1 else { return String(source.prefix(4_000)) }
        let line = min(raw, lines.count)
        let lo = max(0, line - 1 - contextLines)
        let hi = min(lines.count, line - 1 + contextLines + 1)
        guard lo < hi else { return String(source.prefix(4_000)) }
        let windowed = lines[lo..<hi].enumerated()
            .map { String(format: "%5d  %@", lo + $0.offset + 1, $0.element) }
            .joined(separator: "\n")
        // Cap the prompt context — a minified one-liner could otherwise send an arbitrarily large prompt
        // (the window is "small" in LINES but a single line can be huge). Bounded like ReviewFindingVerifier.
        return String(windowed.prefix(4_000))
    }

    static let systemPrompt =
        "You are a skeptical senior engineer on a review panel. Your ONLY job is to REFUTE a proposed code "
        + "finding: decide whether it is a REAL, in-context defect given the actual source, or a false "
        + "positive (the code doesn't actually have the claimed problem, it isn't reachable, or the claim "
        + "misreads the code). Default to NOT_A_BUG when uncertain. Do not invent new issues."

    static func refutePrompt(finding: GroundedReviewFinding, context: String) -> String {
        """
        A reviewer flagged this finding. Judge ONLY whether it is a real, in-context bug.

        Severity: \(finding.severity)
        Location: \(finding.file)\(finding.line.map { ":\($0)" } ?? "")
        Claim: \(finding.claim)
        Quoted code: \(finding.codeQuote)

        Actual source around the cited location:
        ```
        \(context.isEmpty ? "(source unavailable — judge on the claim alone; if you cannot confirm a real defect, answer NOT_A_BUG)" : context)
        ```

        Reason briefly (2-3 sentences), then end with EXACTLY one final line:
        VERDICT: REAL        (only if this is genuinely a real, in-context defect)
        VERDICT: NOT_A_BUG   (false positive / not actually a problem / can't confirm)
        """
    }

    /// STRICT, TOKEN-EXACT: refuted UNLESS a `VERDICT:` line's verdict token is EXACTLY `real`. A SUBSTRING
    /// match on "real" would FALSE-CONFIRM on `VERDICT: REALLY`, `VERDICT: REAL_TALK`, or hyphen/digit
    /// variants like `VERDICT: REAL-ish` / `VERDICT: REAL1` (the dangerous direction — a skeptic that wrongly
    /// clears a finding). So: scan for `verdict:` lines, take the LAST one, read its first whitespace-delimited
    /// token, allow only trailing sentence punctuation, and confirm ONLY when that token == "real". No verdict
    /// line, any other token, empty, or ambiguity ⇒ refuted (a skeptic never confirms on a maybe).
    static func parseVote(_ text: String) -> ReviewRefuteVote {
        let lower = text.lowercased()
        // A NOT_A_BUG / refuted marker ANYWHERE is DISPOSITIVE — refute. This also resolves a contradictory
        // reply ("VERDICT: REAL ... VERDICT: NOT_A_BUG") in the SAFE direction without confirming it.
        if lower.contains("not_a_bug") || lower.contains("verdict: refuted") || lower.contains("verdict:refuted") {
            return ReviewRefuteVote(refuted: true, reason: "skeptic judged it a false positive (NOT_A_BUG)")
        }
        // Otherwise confirm ONLY when a `VERDICT:` line's first token is EXACTLY `real` (token-exact, not a
        // substring — so `REALLY` / `REAL_TALK` / `REALITY_CHECK` / `REAL-ish` do NOT confirm). Last verdict
        // line wins.
        var token: String? = nil
        for rawLine in lower.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("verdict:") else { continue }
            let rest = line.dropFirst("verdict:".count).drop { $0 == " " }
            var first = String(rest.prefix { !$0.isWhitespace })
            while let last = first.last, [".", ",", ";", ":", "!", "?"].contains(last) {
                first.removeLast()
            }
            token = first
        }
        if token == "real" {
            return ReviewRefuteVote(refuted: false, reason: "skeptic confirmed a real in-context defect")
        }
        return ReviewRefuteVote(refuted: true,
            reason: token.map { "skeptic verdict '\($0)' — refuted" } ?? "no explicit VERDICT: REAL — refuted")
    }

    /// Project-confined, symlink-safe path resolve (mirrors ReviewFindingVerifier's). Read-only.
    static func resolvedPath(_ ref: String, projectRoot: String) -> String? {
        var r = ref
        while r.hasPrefix("./") { r.removeFirst(2) }
        if r.hasPrefix("/") || r.contains("://") || r.isEmpty { return nil }
        let candidate = URL(fileURLWithPath: projectRoot).appendingPathComponent(r).standardizedFileURL
        let lexicalRoot = URL(fileURLWithPath: projectRoot).standardizedFileURL.path
        guard candidate.path == lexicalRoot || candidate.path.hasPrefix(lexicalRoot + "/") else { return nil }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        let realFull = candidate.resolvingSymlinksInPath().path
        let realRoot = URL(fileURLWithPath: projectRoot).resolvingSymlinksInPath().path
        guard realFull == realRoot || realFull.hasPrefix(realRoot + "/") else { return nil }
        return candidate.path
    }
}
