import Foundation

/// P3 — the universal SELF-CHANGE spine. Until now `ClosedEvolutionLoop` could only promote ONE kind of
/// self-modification: a `self__` script tool. But the same fail-closed sequence (provider-distinctness →
/// gate → symbolic veto → independent adversary → promote) is exactly what a PROMPT tweak or a ROUTER-POLICY
/// change needs too. `SelfChangeKind` is the sum type that lets every kind ride the identical spine, each
/// confined to its OWN reserved namespace — the mechanical boundary that keeps evolution from writing
/// anywhere it likes (the analog of `self__` for tools).
public enum SelfChangeKind: String, Sendable, Codable, Equatable, CaseIterable {
    case tool          // a self-authored script tool (today's proven path)
    case prompt        // a self-authored prompt / primer change
    case routerPolicy  // a self-authored routing-policy change

    /// The reserved-namespace prefix a promoted change of this kind MUST carry. Evolution can only ever
    /// register into its own space — a candidate whose identity lacks this prefix is rejected at the gate.
    public var identityPrefix: String {
        switch self {
        case .tool:         return kistSelfAuthoredPrefix   // "self__"
        case .prompt:       return "selfprompt__"
        case .routerPolicy: return "selfrouter__"
        }
    }
}

/// P3 anti-gaming metric — the MONOTONIC held-out invariant. The soundest cheap defense against a self-change
/// that "improves" a headline number while quietly regressing behavior is: a previously-passing held-out case
/// may NEVER fail after the change, at FROZEN difficulty (measured as a COUNT, never a rate — a rate is gamed
/// by adding easy cases). This is a pure, deterministic hard gate: any regression is a mechanical reject, no
/// model opinion involved.
public enum HeldOutInvariant {
    /// `before`/`after` are the SETS of held-out case IDs that PASSED, on the SAME frozen corpus, pre- and
    /// post-change. The change is admissible only if every case that passed before still passes (no set
    /// element dropped) — equivalently, `before ⊆ after`. Returns the specific regressed cases on failure.
    public static func notRegressed(before: Set<String>, after: Set<String>) -> (ok: Bool, reason: String) {
        let regressed = before.subtracting(after)
        if regressed.isEmpty {
            return (true, "no held-out regression (\(before.count) → \(after.count) passing; count did not drop)")
        }
        let named = regressed.sorted().prefix(5).joined(separator: ", ")
        return (false, "held-out REGRESSION — \(regressed.count) previously-passing case(s) now fail: \(named)")
    }
}

/// P3. The regression organ: measures the held-out passing-set with the candidate change applied, against a
/// frozen baseline, and enforces `HeldOutInvariant`. Injected (real impl re-runs the eval corpus; fakes in
/// tests). Optional on the loop — nil ⇒ the step is skipped (the tool path is unchanged until it's wired),
/// so this is purely additive. Its verdict, when present, is a HARD reject that no adversary confidence can
/// override — a regressing change is refused even if it "looks" better.
public protocol RegressionInvariant: Sendable {
    /// The set of held-out case IDs passing on the FROZEN baseline (no change applied).
    func baselinePassing() async -> Set<String>
    /// The set passing with THIS candidate's change applied (same corpus, same difficulty).
    func passingWith(_ candidate: CapabilityCandidate) async -> Set<String>
}
