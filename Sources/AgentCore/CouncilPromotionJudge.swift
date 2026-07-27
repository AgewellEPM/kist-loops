import Foundation

/// THE COUNCIL-OF-MINDS PROMOTION JUDGE — half of Luke's "council decides it's real, worth going live"
/// policy (the other half is the captain's cryptographic gate; see `CaptainGate`).
///
/// Distinct from `AICouncil`, which PLANS work. This council JUDGES a FINISHED, captain-verified
/// integration branch: several minds, each through a DIFFERENT lens (correctness / security / product
/// worth / completeness), vote SHIP or HOLD on the built result. The aggregate is FAIL-CLOSED and
/// VETO-FIRST: a single HOLD from any non-failed mind blocks, and a quorum of SHIP votes is required —
/// because the cost of a false SHIP is a corrupted main, while the cost of a false HOLD is a manual review.
///
/// The council can VETO but it can NEVER AUTHORIZE on its own. `CaptainGate` still requires the captain's
/// crypto sign-off on top. The judgment is advisory INPUT that can only make promotion STRICTER.
public struct PromotionContext: Sendable, Equatable {
    public let goal: String
    public let diffSummary: String        // e.g. `git diff --stat` of the integration branch
    public let testsPassed: Bool
    public let testSummary: String        // e.g. "1959 tests, 0 failures" — or the failure detail
    public let signoffSummary: String     // what the captain actually verified (from the signoff ledger)

    public init(goal: String, diffSummary: String, testsPassed: Bool,
                testSummary: String, signoffSummary: String) {
        self.goal = goal; self.diffSummary = diffSummary; self.testsPassed = testsPassed
        self.testSummary = testSummary; self.signoffSummary = signoffSummary
    }
}

public struct PromotionMindVote: Sendable, Codable, Equatable {
    public let name: String       // the lens ("Correctness", "Security", …)
    public let shipWorthy: Bool   // SHIP (true) vs HOLD (false)
    public let reason: String
    public let failed: Bool        // the mind's LLM call errored — counts as NEITHER ship nor veto

    public init(name: String, shipWorthy: Bool, reason: String, failed: Bool = false) {
        self.name = name; self.shipWorthy = shipWorthy; self.reason = reason; self.failed = failed
    }
}

public struct CouncilPromotionVerdict: Sendable, Codable, Equatable {
    public let votes: [PromotionMindVote]
    public let isShipWorthy: Bool
    public let threshold: Int
    public let summary: String

    public init(votes: [PromotionMindVote], isShipWorthy: Bool, threshold: Int, summary: String) {
        self.votes = votes; self.isShipWorthy = isShipWorthy; self.threshold = threshold; self.summary = summary
    }

    /// FAIL-CLOSED, VETO-FIRST aggregation. Ship-worthy ONLY when: at least `threshold` non-failed minds
    /// voted SHIP **and** ZERO non-failed minds voted HOLD. A failed mind is neither (it shrinks the SHIP
    /// pool, so if enough minds break you can't reach quorum → fail closed). `threshold` is clamped to ≥1
    /// so an empty/zero threshold can never auto-bless.
    public static func tally(_ votes: [PromotionMindVote], threshold: Int) -> CouncilPromotionVerdict {
        let t = max(1, threshold)
        let voting = votes.filter { !$0.failed }
        let yes = voting.filter { $0.shipWorthy }.count
        let no = voting.filter { !$0.shipWorthy }.count
        let failedCount = votes.count - voting.count
        let ship = (yes >= t) && (no == 0)
        let summary: String
        if ship {
            summary = "council blessed: \(yes)/\(votes.count) SHIP (≥\(t) required), 0 HOLD"
        } else if no > 0 {
            let vetoers = voting.filter { !$0.shipWorthy }.map { $0.name }.joined(separator: ", ")
            summary = "council HELD: \(no) veto(s) [\(vetoers)] — any HOLD blocks promotion"
        } else {
            summary = "council short of quorum: \(yes)/\(votes.count) SHIP, need ≥\(t)"
                + (failedCount > 0 ? " (\(failedCount) mind(s) failed)" : "")
        }
        return CouncilPromotionVerdict(votes: votes, isShipWorthy: ship, threshold: t, summary: summary)
    }
}

public struct CouncilPromotionJudge: Sendable {
    private let providers: ProviderRegistry
    private let roles: RoleBindings
    private let recorder: TraceRecorder?

    public init(providers: ProviderRegistry, roles: RoleBindings, recorder: TraceRecorder? = nil) {
        self.providers = providers; self.roles = roles; self.recorder = recorder
    }

    /// One lens = (display name, AgentRole for vendor binding, the judging brief).
    struct Lens { let name: String; let role: AgentRole; let brief: String }
    static let lenses: [Lens] = [
        Lens(name: "Correctness", role: .critic, brief:
            "Judge whether the change is CORRECT and the tests genuinely cover it. HOLD if tests are weakened, missing for new behavior, or the diff looks like it games the verifier rather than solving the goal."),
        Lens(name: "Security", role: .critic, brief:
            "Judge security/trust. HOLD if the diff widens an attack surface, leaks secrets, bypasses a gate, escapes its declared scope, or weakens a fail-closed check."),
        Lens(name: "Worth", role: .planner, brief:
            "Judge whether this is REAL and WORTH shipping to main against the goal — not a stub, partial, or demo. HOLD if it doesn't actually accomplish the stated goal."),
        Lens(name: "Completeness", role: .worker, brief:
            "Judge completeness. HOLD if the goal implies sibling sites/edge cases the diff didn't touch, or if 'done' is claimed without the evidence (tests green, in-scope)."),
    ]

    /// Run every lens against the built branch, then FAIL-CLOSED tally. `threshold` defaults to a quorum of
    /// 3 of the 4 lenses (with the zero-veto rule on top). The per-mind LLM call is live (not unit-tested,
    /// like `AICouncil.run`); the tally that decides ship/hold is pure and pinned.
    public func judge(_ ctx: PromotionContext, threshold: Int = 3) async -> CouncilPromotionVerdict {
        var votes: [PromotionMindVote] = []
        for lens in Self.lenses { votes.append(await ask(lens, ctx)) }
        return CouncilPromotionVerdict.tally(votes, threshold: threshold)
    }

    private func ask(_ lens: Lens, _ ctx: PromotionContext) async -> PromotionMindVote {
        let binding = roles.binding(for: lens.role)
        let prompt = Self.judgePrompt(lens: lens, ctx: ctx)
        let settings = ModelSettings(temperature: 0.0, maxTokens: 600,
                                     systemPrompt: Self.systemPrompt(lens: lens.name),
                                     disableThinking: true)
        let started = Date()
        do {
            let (text, usage) = try await providers.completeWithUsage(
                providerId: binding.providerId, model: binding.model,
                messages: [ChatMessage(role: .user, content: prompt)], settings: settings)
            await record(role: "promote_\(lens.name.lowercased())", binding: binding, usage: usage,
                         promptChars: prompt.count, completionChars: text.count, started: started, status: .ok)
            let (ship, reason) = Self.parseVote(text)
            return PromotionMindVote(name: lens.name, shipWorthy: ship, reason: reason)
        } catch {
            await record(role: "promote_\(lens.name.lowercased())", binding: binding, usage: .zero,
                         promptChars: prompt.count, completionChars: 0, started: started, status: .error)
            // FAIL-CLOSED: a broken mind is `failed` (neither SHIP nor veto), shrinking the SHIP pool.
            return PromotionMindVote(name: lens.name, shipWorthy: false, reason: "FAILED: \(error)", failed: true)
        }
    }

    /// Parse a mind's reply. FAIL-CLOSED: only a LINE that is a clean `VERDICT: SHIP` is approval. We scan
    /// per-line and require the line to START with `VERDICT:` (after trimming) — so "I cannot give VERDICT:
    /// SHIP because…" (H4) is NOT approval, and "VERDICT: SHIPWRECK" is NOT SHIP. HOLD wins ties; anything
    /// without a clean SHIP line is HOLD. Substring search on the whole body is the bug, not the fix.
    /// Explicit trailing characters we'll strip off a verdict token — punctuation + ASCII whitespace only.
    /// NOT a "everything non-alphanumeric" rule, which would also eat zero-width/emoji and let a decorated
    /// "SHIP" pass.
    static let strippableTrailers: Set<Character> = [".", "!", "?", ",", ";", ":", "*", " ", "\t", ")", "]", "\"", "'"]
    /// Line trim uses ONLY ASCII space/tab/CR — NOT `CharacterSet.whitespaces`, which also strips a trailing
    /// zero-width space (so a decorated "SHIP\u{200B}" would normalize to "SHIP" and falsely approve).
    static let asciiLineTrim = CharacterSet(charactersIn: " \t\r")

    static func parseVote(_ text: String) -> (shipWorthy: Bool, reason: String) {
        var sawShip = false, sawHold = false
        for raw in text.split(whereSeparator: { $0 == "\n" }) {
            // CASE-SENSITIVE by contract — NO `.uppercased()`. Unicode case-folding would map a lookalike
            // ("ſHıP" long-s/dotless-i, or "Ship") onto "SHIP". The protocol demands literal uppercase
            // "VERDICT: SHIP"/"VERDICT: HOLD"; anything else → HOLD (fail-closed, a wrong HOLD costs a review).
            let line = raw.trimmingCharacters(in: Self.asciiLineTrim)
            guard line.hasPrefix("VERDICT:") else { continue }
            // The remainder after "VERDICT:" must be EXACTLY SHIP/HOLD (trailing punctuation tolerated, but
            // NOT extra words). So "VERDICT: SHIP." → ship; "VERDICT: SHIPWRECK", "VERDICT: SHIP but … HOLD"
            // → neither (→ HOLD via fail-closed). Stricter than a leading-token grab, which a mixed line beats.
            var rem = String(line.dropFirst("VERDICT:".count)).trimmingCharacters(in: Self.asciiLineTrim)
            // Strip ONLY an explicit allowlist of trailing punctuation/whitespace. Anything else (a digit,
            // a zero-width space, an emoji, any other Unicode) stays in the token, so it won't match SHIP/
            // HOLD → HOLD (fail-closed). "VERDICT: SHIP." → SHIP; "VERDICT: SHIP1"/"SHIP\u{200B}" → HOLD.
            while let last = rem.last, Self.strippableTrailers.contains(last) { rem.removeLast() }
            if rem == "SHIP" { sawShip = true } else if rem == "HOLD" { sawHold = true }
        }
        let reason = extractReason(text)
        if sawHold { return (false, reason) }                 // HOLD wins ties
        if sawShip { return (true, reason) }
        return (false, reason.isEmpty ? "no clean VERDICT: SHIP line — treated as HOLD (fail-closed)" : reason)
    }

    private static func extractReason(_ text: String) -> String {
        for raw in text.split(whereSeparator: { $0 == "\n" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("REASON:") {
                return String(line.dropFirst("REASON:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240).description
    }

    private static func systemPrompt(lens: String) -> String {
        """
        You are the \(lens) judge on an AI promotion council deciding whether a built change is good
        enough to ship. Be skeptical and honest, and judge the ACTUAL built result, not the intent.

        HOLD ONLY for a BLOCKING defect through your lens: the code is broken or doesn't run, it doesn't
        accomplish the goal, it has a real security/trust hole, or risky new logic ships with no coverage.
        Do NOT HOLD for cosmetic or style NITS — a trailing newline, formatting, naming, an unfamiliar
        file type, or minor cleanup. If the change works and meets the goal, vote SHIP and put the nit in
        REASON. A nit is never a reason to block a working change. When a real defect is in doubt, HOLD.

        Answer in EXACTLY this shape, nothing else:
        VERDICT: SHIP   (or)   VERDICT: HOLD
        REASON: <one concrete sentence>
        """
    }

    private static func judgePrompt(lens: Lens, ctx: PromotionContext) -> String {
        """
        Lens: \(lens.name)
        Your job: \(lens.brief)

        GOAL the change was supposed to accomplish:
        \(ctx.goal)

        TEST STATUS: \(ctx.testsPassed ? "PASSING" : "NOT PASSING") — \(ctx.testSummary)

        CAPTAIN SIGN-OFF (what was verified in-process):
        \(ctx.signoffSummary)

        COMMITTED DIFF (stat / summary of the integration branch):
        \(String(ctx.diffSummary.prefix(8000)))

        Decide: is this REAL and worth merging to main through YOUR lens? Output only the VERDICT/REASON shape.
        """
    }

    private func record(role: String, binding: ProviderBinding, usage: TokenUsage,
                        promptChars: Int, completionChars: Int, started: Date, status: SpanStatus) async {
        guard let recorder else { return }
        let measured = usage.isZero
            ? TokenUsage.estimate(promptChars: promptChars, completionChars: completionChars) : usage
        await recorder.record(AgentSpan(id: TraceID.make(), traceId: recorder.traceId, kind: .llmCall,
                                        role: role, vendor: binding.providerId, model: binding.model,
                                        promptTokens: measured.promptTokens,
                                        completionTokens: measured.completionTokens,
                                        finishReason: nil, startedAt: started, endedAt: Date(), status: status))
    }
}
