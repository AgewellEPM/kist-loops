import Foundation

/// The atoms of the deterministic, no-LLM Captain. A symbolic rule is a PURE predicate over structured
/// facts — never asks a model, never hallucinates; same facts → same outcome.
///
/// The split between "right by construction" and "assumed right" is enforced MECHANICALLY:
///   • A StructuralRule is an invariant we DEFINE as correct. Its logic is DATA — a
///     `StructuralPredicate` the engine interprets over `BuildFacts` ONLY. There is no closure to
///     capture anything and no case that can name a world fact, so it is LITERALLY UNABLE to depend on
///     the world-signal. It can never secretly be a world-proxy masquerading as an invariant.
///   • A ProxyRule is a stand-in for a real-world outcome we cannot check directly. It MAY read
///     `WorldFacts`, and it MUST name the outcome it proxies. nil correspondent == UNGROUNDED.
///
/// Ported from TinkySDR's Captain (Stage 1.4).

/// The deterministic result of evaluating one rule against the facts.
public enum RuleOutcome: Equatable, Sendable {
    case pass
    case fail(evidence: String)
    case notApplicable
}

/// How hard a failure bites. A blocker stops "done"; a warn is surfaced only.
public enum RuleSeverity: Equatable, Sendable { case blocker, warn }

/// A build-fact flag a structural predicate may reference. There is deliberately NO case for any world
/// fact — the vocabulary itself cannot express a world dependency, which is what makes "structural" an
/// honest, mechanical claim.
public enum BuildFlag: String, Equatable, Sendable {
    case claimedDone, testsGreen, diffPresent, codexReviewed, stepCapHit
    /// The run ended WITHOUT a clean done (killed / step-capped / aborted). Checked unconditionally.
    case runIncomplete
}

/// A declarative structural predicate. It is DATA, not a closure — so it cannot capture or reach world
/// state. The engine interprets it over `BuildFacts` only.
public enum StructuralPredicate: Equatable, Sendable {
    case maxFileLinesAtMost(Int)
    case onDoneRequires(BuildFlag)   // if claimedDone, the flag must be TRUE
    case onDoneForbids(BuildFlag)    // if claimedDone, the flag must be FALSE
    case forbidsAlways(BuildFlag)    // UNCONDITIONAL: the flag must be FALSE, done or not
}

/// An invariant that is right by construction. Its logic is a `StructuralPredicate` (interpreted over
/// build facts only), so it cannot be a disguised proxy.
public struct StructuralRule: Sendable {
    public let id: String
    public let summary: String
    public let severity: RuleSeverity
    public let predicate: StructuralPredicate

    public init(id: String, summary: String, severity: RuleSeverity, predicate: StructuralPredicate) {
        self.id = id; self.summary = summary; self.severity = severity; self.predicate = predicate
    }

    /// Interpret the predicate over build facts ONLY. Pure, deterministic; the world-signal is
    /// unreachable from here by construction.
    public func evaluate(_ b: BuildFacts) -> RuleOutcome {
        switch predicate {
        case .maxFileLinesAtMost(let limit):
            return b.maxFileLines > limit
                ? .fail(evidence: "largest touched file is \(b.maxFileLines) lines (> \(limit) limit)")
                : .pass
        case .onDoneRequires(let flag):
            guard b.claimedDone else { return .notApplicable }
            return b.value(of: flag) ? .pass : .fail(evidence: "claimed done but \(flag.rawValue) is false")
        case .onDoneForbids(let flag):
            guard b.claimedDone else { return .notApplicable }
            return b.value(of: flag) ? .fail(evidence: "claimed done but \(flag.rawValue) is true") : .pass
        case .forbidsAlways(let flag):
            return b.value(of: flag) ? .fail(evidence: "\(flag.rawValue) is true — the run did not complete cleanly") : .pass
        }
    }
}

/// A stand-in for a real-world outcome we cannot directly check. It MAY read the world-signal (honest
/// about it), and MUST name the outcome it proxies.
public struct ProxyRule: @unchecked Sendable {
    public let id: String
    public let summary: String
    /// The real outcome this proxies, in words. nil == UNGROUNDED (unverifiable).
    public let truthCorrespondent: String?
    public let check: (BuildFacts, WorldFacts) -> RuleOutcome

    public init(id: String, summary: String, truthCorrespondent: String?,
                check: @escaping (BuildFacts, WorldFacts) -> RuleOutcome) {
        self.id = id; self.summary = summary; self.truthCorrespondent = truthCorrespondent; self.check = check
    }

    public var isUngrounded: Bool { truthCorrespondent == nil }
}
