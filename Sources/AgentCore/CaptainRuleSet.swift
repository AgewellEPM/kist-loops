import Foundation

/// The rules the symbolic Captain enforces, plus the `audit()` that answers the only question that
/// matters once the enforcer is deterministic: how much of this rulebook is right BY CONSTRUCTION, and
/// how much is merely an ASSUMED-right proxy that could perfectly enforce a wrong goal?
///
///   • STRUCTURAL invariants — a hard pass/fail referee for "did we follow our own process"
///     (modularity, done-requires-tests/diff/review). They cannot read the world (type-enforced), so
///     none of them can secretly be a proxy.
///   • One PROXY rule — the DRIFT detector. It reaches for the outside signal and FAILS loudly when the
///     proxy looks shippable but THIS BUILD has no confirmed real-world outcome (or no signal is wired
///     / the signal is tampered). The deterministic conscience catching its own drift.
///
/// Ported from TinkySDR's Captain (Stage 1.4). The proxy's truth-correspondent wording was genericized
/// to Mythos's dev-tool context (an external, signed confirmation that THIS build produced a real,
/// consequential outcome) — the mechanism is identical.
public enum CaptainRuleSet {

    /// Structural invariants (right by construction). Each is DECLARATIVE DATA — a `StructuralPredicate`
    /// over build facts only — so none of them can reach the world-signal.
    public static var structural: [StructuralRule] {
        [
            StructuralRule(id: "monolith_limit",
                           summary: "No source file past the 1500-line hard stop.",
                           severity: .blocker, predicate: .maxFileLinesAtMost(1500)),
            StructuralRule(id: "done_needs_tests",
                           summary: "A 'done' claim requires a green test suite.",
                           severity: .blocker, predicate: .onDoneRequires(.testsGreen)),
            StructuralRule(id: "done_needs_diff",
                           summary: "A 'done' claim requires an actual change (non-empty diff).",
                           severity: .blocker, predicate: .onDoneRequires(.diffPresent)),
            StructuralRule(id: "done_needs_codex",
                           summary: "A 'done' claim requires the review gate to have run.",
                           severity: .blocker, predicate: .onDoneRequires(.codexReviewed)),
            StructuralRule(id: "stepcap_is_not_done",
                           summary: "Hitting the autonomy step cap is a stop, never a clean 'done'.",
                           severity: .blocker, predicate: .onDoneForbids(.stepCapHit)),
            StructuralRule(id: "run_must_complete",
                           summary: "An incomplete run (killed / step-capped / aborted) is never green.",
                           severity: .blocker, predicate: .forbidsAlways(.runIncomplete)),
        ]
    }

    /// Proxy rules (the part that needs the outside signal). The drift detector.
    public static var proxies: [ProxyRule] {
        [
            ProxyRule(id: "outcome_confirmed_or_drift",
                      summary: "When the build looks shippable, a real confirmed outcome must attest THIS build.",
                      truthCorrespondent:
                        "a real, consequential outcome attributed to THIS build, confirmed by an externally-signed conscience entry (the build actually did the thing it claims, verified outside the loop)",
                      check: { b, w in
                          // Only meaningful once the proxy says "ship": claimed done + the cheap green
                          // signals. Otherwise the structural rules govern.
                          guard b.claimedDone, b.testsGreen, b.diffPresent else { return .notApplicable }
                          if !w.hasSignal {
                              return .fail(evidence: "DRIFT: 'done' looks green but NO world-signal is wired — this cannot be confirmed against any real outcome. You are green about a world you cannot see.")
                          }
                          if w.signalBroken {
                              return .fail(evidence: "DRIFT: world-signal integrity is broken (conscience ledger tamper) — no confirmation can be trusted.")
                          }
                          if w.confirmedHelpForBuild == 0 {
                              return .fail(evidence: "DRIFT: rules say green, world says nothing — 0 confirmed real-world outcomes for THIS build '\(b.buildID)'.")
                          }
                          return .pass
                      }),
        ]
    }

    // MARK: The "are the rules right?" dashboard

    public struct Audit: Equatable, Sendable {
        public let total: Int
        public let structural: Int               // right by construction
        public let groundedProxies: Int          // proxy WITH a declared real-world correspondent
        public let ungroundedProxies: [String]   // proxy WITHOUT one — enforcing the unverifiable
        public init(total: Int, structural: Int, groundedProxies: Int, ungroundedProxies: [String]) {
            self.total = total; self.structural = structural
            self.groundedProxies = groundedProxies; self.ungroundedProxies = ungroundedProxies
        }
        /// Fraction of the rulebook that is right-by-construction. The rest is assumed-right.
        public var structuralFraction: Double { total == 0 ? 0 : Double(structural) / Double(total) }
    }

    /// Audit a rulebook: how much is verifiable vs assumed.
    public static func audit(structural: [StructuralRule], proxies: [ProxyRule]) -> Audit {
        let ungrounded = proxies.filter { $0.isUngrounded }.map(\.id)
        return Audit(total: structural.count + proxies.count,
                     structural: structural.count,
                     groundedProxies: proxies.count - ungrounded.count,
                     ungroundedProxies: ungrounded)
    }
}
