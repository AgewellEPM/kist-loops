import Foundation

/// Pure aggregation over `RunRecord` history — the read side of the Phase 3.5 spine. No I/O, fully
/// deterministic, so every number the self-improvement loop (Phase 4) acts on is unit-tested directly.
/// This is where "does decision X correlate with worse runs?" becomes a computed fact, and where the
/// honest before/after "did the change help?" lift is measured.
public enum RunAnalytics {

    /// Rolled-up outcome stats for a group of runs (one route, one signature, whatever the caller sliced).
    public struct Stats: Sendable, Equatable {
        public let count: Int
        public let successRate: Double        // 0…1
        public let verifiedRate: Double       // 0…1 — independently critic-verified
        public let avgIterations: Double
        public let avgTokens: Double
        public let avgDurationMs: Double
        public let underEscalated: Int        // routing misfits: went too light
        public let overEscalated: Int         // routing misfits: went too heavy

        public static let empty = Stats(count: 0, successRate: 0, verifiedRate: 0, avgIterations: 0,
                                        avgTokens: 0, avgDurationMs: 0, underEscalated: 0, overEscalated: 0)
    }

    public static func stats(_ records: [RunRecord]) -> Stats {
        guard !records.isEmpty else { return .empty }
        let n = Double(records.count)
        let succ = records.filter { $0.success }.count
        let ver = records.filter { $0.verified }.count
        var under = 0, over = 0
        for r in records {
            switch r.routingMisfit {
            case .underEscalated: under += 1
            case .overEscalated:  over += 1
            case nil: break
            }
        }
        return Stats(
            count: records.count,
            successRate: Double(succ) / n,
            verifiedRate: Double(ver) / n,
            avgIterations: Double(records.reduce(0) { $0 + $1.iterationsUsed }) / n,
            avgTokens: Double(records.reduce(0) { $0 + $1.totalTokens }) / n,
            avgDurationMs: records.reduce(0) { $0 + $1.durationMs } / n,
            underEscalated: under, overEscalated: over)
    }

    /// Per-route breakdown — the "which routing bucket is healthy vs. mis-sized" view. Keyed by route.
    public static func byRoute(_ records: [RunRecord]) -> [String: Stats] {
        Dictionary(grouping: records, by: { $0.route }).mapValues { stats($0) }
    }

    /// The routing decisions the data says are systematically wrong, as concrete candidate rule-changes
    /// for the meta-loop to consider. A signal fires only with enough evidence (`minSamples`) AND a
    /// meaningful misfit rate (`threshold`) — so one unlucky run can't propose a config change.
    public struct RoutingSignal: Sendable, Equatable {
        public let route: String
        public let misfit: RoutingMisfit
        public let rate: Double               // fraction of that route's runs that were this misfit
        public let sampleSize: Int
        /// Human/loop-readable, and directional: under-escalation ⇒ raise sensitivity (route heavier);
        /// over-escalation ⇒ lower it (route lighter).
        public var suggestion: String {
            switch misfit {
            case .underEscalated:
                return "route '\(route)' under-served \(pct)% of \(sampleSize) runs — consider routing this class HEAVIER (lower the fast/complex threshold)"
            case .overEscalated:
                return "route '\(route)' over-escalated \(pct)% of \(sampleSize) runs — consider routing this class LIGHTER (raise the complex threshold)"
            }
        }
        private var pct: Int { Int((rate * 100).rounded()) }
    }

    public static func routingSignals(_ records: [RunRecord],
                                      minSamples: Int = 8,
                                      threshold: Double = 0.25) -> [RoutingSignal] {
        var signals: [RoutingSignal] = []
        for (route, group) in Dictionary(grouping: records, by: { $0.route }) {
            guard group.count >= minSamples else { continue }
            let n = Double(group.count)
            let under = group.filter { $0.routingMisfit == .underEscalated }.count
            let over = group.filter { $0.routingMisfit == .overEscalated }.count
            if Double(under) / n >= threshold {
                signals.append(RoutingSignal(route: route, misfit: .underEscalated, rate: Double(under) / n, sampleSize: group.count))
            }
            if Double(over) / n >= threshold {
                signals.append(RoutingSignal(route: route, misfit: .overEscalated, rate: Double(over) / n, sampleSize: group.count))
            }
        }
        // Deterministic ordering (route, then misfit) so output is stable across runs and testable.
        return signals.sorted { ($0.route, $0.misfit.rawValue) < ($1.route, $1.misfit.rawValue) }
    }

    /// The before/after lift of a config change — the seed of "PROVE it improved". Compares two
    /// disjoint slices of runs (e.g. the same held-out task class under orgVersion A vs. B).
    public struct Lift: Sendable, Equatable {
        public let before: Stats
        public let after: Stats
        public let successRateDelta: Double   // after − before (positive = better)
        public let avgIterationsDelta: Double  // after − before (negative = better)
        public let avgTokensDelta: Double      // after − before (negative = better)
        /// A CONSERVATIVE, honestly-named verdict — NOT a statistical significance claim. It requires a
        /// real sample on both sides and a change that is directionally good and beyond a noise margin.
        /// The Captain never declares a self-improvement "proven" on thinner evidence than this.
        public let isClearLift: Bool
    }

    public static func lift(before: [RunRecord], after: [RunRecord], minSamples: Int = 8) -> Lift {
        let b = stats(before), a = stats(after)
        let dSucc = a.successRate - b.successRate
        let dIter = a.avgIterations - b.avgIterations
        let dTok  = a.avgTokens - b.avgTokens
        // Enough evidence on BOTH sides, AND either a materially higher success rate OR clearly cheaper
        // (fewer steps/tokens) WITHOUT regressing success. Deliberately strict — false "it improved" is
        // the one failure mode that corrupts a self-improving system (the leaky-benchmark trap).
        let enough = before.count >= minSamples && after.count >= minSamples
        // Council (DeepSeek) fix: a 5-point delta on 8 vs 8 runs (e.g. 5/8→6/8) is noise (p≈0.6), yet the
        // doc claims the verdict is "conservative/honest". The success-rate improvement must therefore clear
        // a real SIGNIFICANCE bar (two-proportion z ≥ 1.96 ≈ p<0.05), not just a magnitude — otherwise the
        // meta-loop "proves" improvements from chance and drifts. This is the leaky-benchmark trap made real.
        let successBetter = dSucc >= 0.05 && successZ(before: before, after: after) >= 1.96
        // Council (GPT) hardening: the token-relative gate must not be satisfiable by a degenerate tiny
        // baseline — with `b.avgTokens` near zero, `dTok <= -0.1 * b.avgTokens` fires on a fractional-token
        // "reduction" and manufactures a false lift. A real LLM run burns hundreds of tokens; below this
        // floor the token signal is noise, so the cost path must instead prove a real ITERATION reduction.
        let tokenBaselineMeaningful = b.avgTokens >= 200
        let cheaperNoRegression = dSucc >= -0.001 && (dIter <= -0.5 || (tokenBaselineMeaningful && dTok <= -0.1 * b.avgTokens))
        return Lift(before: b, after: a, successRateDelta: dSucc, avgIterationsDelta: dIter,
                    avgTokensDelta: dTok, isClearLift: enough && (successBetter || cheaperNoRegression))
    }

    /// Two-proportion z-statistic (normal approximation) on the two slices' success counts — how many
    /// standard errors the after-rate sits above the before-rate. |z| ≥ 1.96 ≈ p < 0.05. Returns 0 when
    /// the test is undefined (empty slice, or zero pooled variance because every run in both slices shares
    /// the same outcome) so an undefined test can never read as significant. Pure ⇒ tested directly.
    static func successZ(before: [RunRecord], after: [RunRecord]) -> Double {
        let n1 = Double(before.count), n2 = Double(after.count)
        guard n1 > 0, n2 > 0 else { return 0 }
        let s1 = Double(before.filter { $0.success }.count)
        let s2 = Double(after.filter { $0.success }.count)
        let pooled = (s1 + s2) / (n1 + n2)
        let se = (pooled * (1 - pooled) * (1 / n1 + 1 / n2)).squareRoot()
        guard se > 0 else { return 0 }
        return (s2 / n2 - s1 / n1) / se
    }
}
