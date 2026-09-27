import Foundation

/// Distinguishes "the account has no credits" from "slow down for a minute".
///
/// Every HTTP-backed provider used to collapse any 429 into `AIProviderError.rateLimited`
/// BEFORE reading the response body. OpenAI answers a drained balance with the same 429
/// status plus `{"error":{"type":"insufficient_quota","code":"credit_balance_exhausted"}}`,
/// so a dead billing account looked like a transient rate limit: the registry retried it
/// three times per call, the cooldown ledger benched it for only five minutes, and every
/// build-lane preflight pinned to that provider died identically for days (observed
/// 2026-09-27: `build me a hello world app` → "The provider rate limit was exceeded." ×3 →
/// exit 2, zero files written, while chat turns on other providers kept working).
///
/// A quota failure is NOT retryable (nothing clears in 750 ms), IS fallback-eligible, and
/// deserves a long cross-process cooldown. The registry's `shouldFallback` already treats
/// any 429 `.http` as fallback-eligible, so classifying quota exhaustion as
/// `.http(status: 429, body:)` with a recognizable body keeps every existing switch
/// exhaustive while letting `isRetryable`, cooldown TTL, and the operator message tell the
/// two failures apart.
public enum ProviderQuotaExhaustion {
    /// Substrings (lowercased match) that identify a billing/credit exhaustion, not a
    /// per-minute limiter. Deliberately concrete: Gemini's generic `RESOURCE_EXHAUSTED`
    /// covers both cases and is NOT listed; its quota variant carries
    /// "exceeded your current quota", which is.
    public static let markers: [String] = [
        "insufficient_quota",
        "credit_balance_exhausted",
        "no credits remaining",
        "out of credits",
        "billing_hard_limit_reached",
        "exceeded your current quota",
        "insufficient balance",
        "insufficient funds",
        "payment required",
        // Subscription CLIs (codex / claude) report exhaustion as prose on stderr.
        "hit your usage limit",
        "usage limit",
    ]

    /// Prefix stamped onto the retained body so downstream classifiers (cooldown TTL, turn
    /// summaries, substitution reasons) can recognize the failure without re-parsing JSON.
    public static let bodyTag = "quota_exhausted"

    /// Cross-process cooldown for a drained account. Rate limits clear in minutes; a balance
    /// does not refill on its own, so bench the provider long enough that every lane routes
    /// around it until the operator adds credits (the ledger still expires, so a recharged
    /// account comes back without manual cleanup).
    public static let cooldownTTL: TimeInterval = 6 * 3600

    /// True when the (already bounded) response body signals exhausted credits/quota.
    public static func matches(body: String) -> Bool {
        let lower = body.lowercased()
        return markers.contains { lower.contains($0) }
    }

    /// The typed error for a non-200 response once the body has been read. 401/403 are the
    /// caller's decision (providers differ on which means "bad key"); everything else routes
    /// here so the four HTTP provider stream sites share one 429 policy.
    public static func classify(status: Int, body: String) -> AIProviderError {
        let bounded = String(body.prefix(600))
        if status == 402 || (status == 429 && matches(body: bounded)) {
            return .http(status: status, body: "\(bodyTag): \(bounded)")
        }
        if status == 429 { return .rateLimited }
        return .http(status: status, body: bounded)
    }

    /// True for an error that means "this provider's account is drained" — a 402, or a 429
    /// whose retained body carries a quota marker (including the stamped tag above).
    public static func isQuotaExhausted(_ error: Error) -> Bool {
        guard case AIProviderError.http(let status, let body) = error else { return false }
        if status == 402 { return true }
        return status == 429 && matches(body: body)
    }

    /// True for a summary/description string that reports a drained account. Used by the
    /// text-only lanes (turn summaries) that never see the typed error.
    public static func mentioned(in text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains(bodyTag) { return true }
        return matches(body: lower)
    }
}
