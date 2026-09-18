import Foundation

/// Structured classification of "did the PROVIDER fault (server-side) on this call?" — used to route the
/// great-loop AROUND a flaky provider on later cycles. This reads the STRUCTURED `AIProviderError`
/// (HTTP status / typed case), NOT a humanized summary string: a 5-model review flagged that regexing the
/// prose summary is brittle (false positives when an agent-authored summary merely mentions "server error",
/// false negatives when the phrasing changes or the error is non-HTTP). The structured status is immune to
/// both. `fromSummary` remains ONLY as a last-resort fallback for a value that is already a plain string
/// with no typed error available.
public enum ProviderFault {

    /// A provider-side fault worth routing around: server 5xx, rate limit / overload (429), or a transport
    /// failure (connection reset / timeout / TLS). Auth (401/403), missing key, and content 4xx are NOT
    /// provider faults — routing to another provider wouldn't help, and (for auth) it should surface.
    public static func isProviderFault(_ error: Error) -> Bool {
        if let routed = error as? ProviderRouteFailure { return isProviderFault(routed.underlying) }
        guard let e = error as? AIProviderError else { return false }
        switch e {
        case .rateLimited:          return true
        case .transport:            return true                 // connection reset / timeout / TLS
        case .streamTimedOut:       return true
        case .http(let status, _):  return status == 429 || (500...599).contains(status)
        case .invalidResponse:      return false                // malformed body ≠ server down
        case .missingAPIKey, .invalidAPIKey, .configuration:
            return false                                        // config/auth — another provider won't fix it
        }
    }

    /// Last-resort fallback when only a humanized string is available (no typed error). Kept NARROW and
    /// documented as inferior to `isProviderFault(_:)`. Prefer threading the typed error / a structured
    /// flag instead of calling this.
    public static func fromSummary(_ summary: String) -> Bool {
        let s = summary.lowercased()
        let markers = ["server error", "error on its side", "internal server", "service unavailable",
                       "http 500", "http 502", "http 503", "http 504",
                       "status 500", "status 502", "status 503", "status 504",
                       "timed out", "timeout", "connection reset", "connection refused"]
        return markers.contains { s.contains($0) }
    }
}

/// COOLDOWN tracker for faulted providers: a provider is "active" (routed around) only for `cooldown`
/// seconds after its most recent fault, then it's eligible again — the next call becomes a half-open probe.
/// Pure value type (clock injected) so the recovery semantics are unit-tested without wall-clock flake.
public struct ProviderCooldownTracker: Sendable {
    private var faultAt: [String: Double] = [:]   // provider → epoch of its most recent fault
    public let cooldown: Double
    public init(cooldown: Double = 120) { self.cooldown = cooldown }
    public mutating func recordFault(_ provider: String, at now: Double) { faultAt[provider] = now }
    /// Providers still inside their cooldown window at `now`.
    public func active(now: Double) -> Set<String> {
        Set(faultAt.filter { now - $0.value < cooldown }.keys)
    }
}
