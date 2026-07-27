import Foundation

/// Per-connector operating levels the system adjusts automatically.
public struct ConnectorLevel: Codable, Sendable, Equatable {
    public var concurrency: Int
    public var retries: Int
    public var backoffMs: Int
    public init(concurrency: Int = 2, retries: Int = 1, backoffMs: Int = 250) {
        self.concurrency = concurrency
        self.retries = retries
        self.backoffMs = backoffMs
    }
}

/// "Auto-adjust levels" — a deterministic policy that raises throughput when a
/// connector is healthy and backs off when it's failing/slow. Pure and testable;
/// this is the honest, inspectable core an AI-driven policy can later replace or
/// tune, not a black box. Bounded so it can never runaway.
public struct AutoTuner: Sendable {
    public let minConcurrency: Int
    public let maxConcurrency: Int
    public let maxBackoffMs: Int
    public let maxRetries: Int

    public init(minConcurrency: Int = 1, maxConcurrency: Int = 16,
                maxBackoffMs: Int = 8000, maxRetries: Int = 5) {
        self.minConcurrency = max(1, minConcurrency)
        self.maxConcurrency = max(self.minConcurrency, maxConcurrency)
        self.maxBackoffMs = max(100, maxBackoffMs)
        self.maxRetries = max(0, maxRetries)
    }

    /// Adjust `level` from an observation window. `errorRate` in [0,1]; `p50ms` is the
    /// median latency. Struggling ⇒ shrink concurrency, grow backoff + retries.
    /// Healthy + fast ⇒ grow concurrency, shrink backoff. Otherwise hold steady.
    public func adjust(_ level: ConnectorLevel, errorRate: Double, p50ms: Int) -> ConnectorLevel {
        var l = level
        if errorRate > 0.2 {
            l.concurrency = max(minConcurrency, l.concurrency - 1)
            l.backoffMs = min(maxBackoffMs, max(100, l.backoffMs * 2))
            l.retries = min(maxRetries, l.retries + 1)
        } else if errorRate < 0.02 && p50ms < 500 {
            l.concurrency = min(maxConcurrency, l.concurrency + 1)
            l.backoffMs = max(100, l.backoffMs / 2)
        }
        return l
    }
}
