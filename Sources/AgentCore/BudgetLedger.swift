import Foundation

/// The cost ceiling for a run — the #1 abandonment/ban trigger the research flagged (agentic +
/// multi-vendor burns ~15× tokens; tools get pulled at the org level over surprise bills). A hard,
/// thread-safe token cap that bounds worst-case spend "even when dashboards lag" — the runner kills
/// the run at the ceiling rather than discovering the overage afterward.
///
/// Tokens (MEASURED, un-game-able) are the budget unit, not an estimated dollar figure; a $ estimate
/// is a separate, clearly-labeled derivation. An actor so it accounts correctly across the parallel
/// workers Phase 5 will add.
public actor BudgetLedger {
    /// nil = no token cap. Otherwise the run halts once `spent >= maxTokens`.
    public let maxTokens: Int?
    /// nil = no dollar cap (Sprint 3 / C1). The DOLLAR ceiling is what serious cost governance needs —
    /// users budget in money, and a 1M-token Gemini call ≠ a 1M-token Claude call. Either cap (token
    /// OR dollar) halts the run; both are tracked.
    public let maxUSD: Double?
    private var spent = 0
    private var spentUSDValue = 0.0
    /// In-flight RESERVATIONS — estimates debited BEFORE a call and released at commit. This is the
    /// atomic reserve-before-spend that closes the TOCTOU: under a shared fleet ledger, two parallel
    /// workers can't both pass an isExceeded() check and then both spend, because the first one's
    /// reservation is already counted against the second's reserve() attempt.
    private var reservedTokens = 0
    private var reservedUSDValue = 0.0
    /// Outstanding reservations keyed by a unique id, each holding the EXACT amount it reserved. `commit`
    /// consumes a specific id, so a double-commit (same id committed twice) or an unknown id is a no-op —
    /// it can't re-subtract the hold or re-book spend. A plain counter is INSUFFICIENT (Codex): with two
    /// live reservations a double-commit of one would still pass a `> 0` check and double-book. Per-id
    /// identity is the only correct guard. The ledger owns the reserved amounts so callers can't re-pass
    /// a mismatched figure at commit. No current caller double-commits; this makes the contract safe.
    private var nextReservationID = 0
    private var outstanding: [Int: (tokens: Int, usd: Double)] = [:]

    public init(maxTokens: Int? = nil, maxUSD: Double? = nil) {
        self.maxTokens = maxTokens
        self.maxUSD = maxUSD
    }

    /// Atomically reserve an ESTIMATE for an upcoming call. Returns nil (DENY) if committing this
    /// estimate on top of already-spent + already-reserved would breach EITHER cap — the caller then
    /// halts WITHOUT making the call. Returns a unique RESERVATION ID (to pass to `commit`) otherwise.
    /// Negatives clamp. On an uncapped ledger this always succeeds (but still tracks the reservation).
    public func reserve(tokens: Int, usd: Double) -> Int? {
        let t = max(0, tokens), u = max(0, usd)
        let projTokens = spent + reservedTokens + t
        let projUSD = spentUSDValue + reservedUSDValue + u
        if let cap = maxTokens, projTokens > cap { return nil }
        if let cap = maxUSD, projUSD > cap { return nil }
        reservedTokens += t
        reservedUSDValue += u
        let id = nextReservationID
        nextReservationID += 1
        outstanding[id] = (t, u)
        return id
    }

    /// Release the reservation `id` and record the ACTUAL usage. Call exactly once per successful
    /// `reserve` — including on the error path (with actual 0) so a failed call doesn't leak its hold.
    /// Committing an unknown/already-committed id is a no-op (the ledger owns each reservation's reserved
    /// amount, so a double-commit can't re-release the hold or double-book spend — Codex/DeepSeek LOW).
    public func commit(reservation id: Int, actualTokens: Int, actualUSD: Double) {
        guard let held = outstanding.removeValue(forKey: id) else { return }   // double-commit / unknown → no-op
        reservedTokens = max(0, reservedTokens - held.tokens)
        reservedUSDValue = max(0, reservedUSDValue - held.usd)
        spent += max(0, actualTokens)
        spentUSDValue += max(0, actualUSD)
    }

    /// Add measured (or estimated) TOKEN usage only. Negative inputs ignored. (Back-compat shim — the
    /// $-aware path is `add(tokens:usd:)`.)
    public func add(_ tokens: Int) { spent += max(0, tokens) }

    /// Add measured usage AND its dollar cost at the single accounting chokepoint. Both clamp ≥0.
    public func add(tokens: Int, usd: Double) {
        spent += max(0, tokens)
        spentUSDValue += max(0, usd)
    }

    public func spentTokens() -> Int { spent }
    public func spentUSD() -> Double { spentUSDValue }

    /// Remaining token budget, or nil when token-uncapped.
    public func remaining() -> Int? { maxTokens.map { max(0, $0 - spent) } }
    /// Remaining dollar budget, or nil when dollar-uncapped.
    public func remainingUSD() -> Double? { maxUSD.map { max(0, $0 - spentUSDValue) } }

    /// True once EITHER cap is reached (token or dollar). Always false when both are nil.
    public func isExceeded() -> Bool {
        if let cap = maxTokens, spent >= cap { return true }
        if let cap = maxUSD, spentUSDValue >= cap { return true }
        return false
    }

    /// Which cap was hit (for an honest halt message). nil if not exceeded.
    public func exceededReason() -> String? {
        if let cap = maxTokens, spent >= cap { return "token budget exceeded (\(spent)/\(cap) tokens)" }
        if let cap = maxUSD, spentUSDValue >= cap {
            return String(format: "cost budget exceeded ($%.4f/$%.4f)", spentUSDValue, cap)
        }
        return nil
    }
}

public extension TokenUsage {
    /// Rough fallback when a provider reports no usage: ~4 characters per token. Clearly an ESTIMATE,
    /// used only so the budget/observability still function on providers that omit usage.
    static func estimate(promptChars: Int, completionChars: Int) -> TokenUsage {
        TokenUsage(promptTokens: promptChars / 4, completionTokens: completionChars / 4)
    }
}
