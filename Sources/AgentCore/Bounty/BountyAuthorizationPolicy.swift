import Foundation

// MARK: - The EDITION SEAM
//
// This is the single boundary that separates the two distributions. The protocol lives in the shared core;
// the PUBLIC repo ships ONLY `PublicEditionPolicy` below. The full-access edition is a SEPARATE, PRIVATE
// repository that imports this core and supplies its own `BountyAuthorizationPolicy` conformer — the bypass
// capability is physically ABSENT from this public build, not a flag that can be flipped.
//
// Distribution model:
//   PUBLIC build  → wires `PublicEditionPolicy()` (fail-closed; what's in this file)
//   FULL build    → private repo wires its own `FullAccessEditionPolicy` (broad attested authority)
// Because the full conformer doesn't exist in this repo, no amount of config/prompt can produce it here.

public protocol BountyAuthorizationPolicy: Sendable {
    /// Stamped onto every `BountyDecision` for auditability ("which build made this call").
    var editionName: String { get }
    /// Evaluate a proposed action against the attested scope (engagement) AND the program rules.
    /// MUST be fail-closed: any missing/ambiguous input resolves to `.refuse`.
    func evaluate(action: BountyAction, engagement: SecurityEngagement, rules: BountyProgramRules) -> BountyDecision
}

/// PUBLIC EDITION — the fail-closed gate that ships to everyone. Order of checks runs most-fundamental
/// first (authorization → categorical bans → program courtesy rules → traffic budget → submission), and
/// ANY failure short-circuits to a refusal naming the rule. There is no "probably fine" branch.
public struct PublicEditionPolicy: BountyAuthorizationPolicy {
    public let editionName = "public"

    /// Methods the public edition refuses categorically, for EVERY program — these are the ones that get a
    /// hunter banned or sued. Only a different edition (private repo) may ever permit them.
    public static let alwaysForbidden: Set<TestMethod> = [
        .denialOfService, .socialEngineering, .dataExfiltration, .lateralMovement, .physicalAccess
    ]

    public init() {}

    public func evaluate(action: BountyAction, engagement: SecurityEngagement, rules: BountyProgramRules) -> BountyDecision {
        let edition = editionName

        // 1) AUTHORIZATION / SCOPE — the action must touch at least one target, and every named target
        //    must be inside the attested engagement. Delegates to the hardened, fail-closed membership gate.
        if action.targetHost == nil && action.targetRepo == nil {
            return .refuse(edition: edition, rule: "scope.no-target",
                           reason: "action names no target host or repo; refusing (cannot prove it is in scope)")
        }
        if let host = action.targetHost {
            let m = engagement.inScope(host: host)
            if case .outOfScope(let why) = m {
                return .refuse(edition: edition, rule: "scope.host-out-of-scope",
                               reason: "host out of scope: \(why)")
            }
        }
        if let repo = action.targetRepo {
            let m = engagement.inScope(repo: repo)
            if case .outOfScope(let why) = m {
                return .refuse(edition: edition, rule: "scope.repo-out-of-scope",
                               reason: "repo out of scope: \(why)")
            }
        }

        // 2) CATEGORICAL BANS — destructive / out-of-bounds methods are refused regardless of program.
        if Self.alwaysForbidden.contains(action.method) {
            return .refuse(edition: edition, rule: "method.always-forbidden",
                           reason: "\(action.method.rawValue) is categorically forbidden in the public edition")
        }

        // 3) AUTOMATION POLICY — honor a program that bans/limits automated tooling.
        if action.isAutomated {
            switch rules.automation {
            case .banned:
                return .refuse(edition: edition, rule: "automation.banned",
                               reason: "program bans automated/AI tooling; this action is automated")
            case .restricted:
                // passive automation is tolerated; automated ACTIVE work is refused.
                if action.method != .passiveRecon {
                    return .refuse(edition: edition, rule: "automation.restricted-active",
                                   reason: "program restricts automation to passive; this is automated \(action.method.rawValue)")
                }
            case .allowed:
                break
            }
        }

        // 4) VULN CLASS — active findings must be in the program's accepted classes. Recon carries no class
        //    and is exempt; everything that asserts a vuln must name an in-scope class (empty set ⇒ refuse).
        if action.method == .activeScan || action.method == .exploitPoC {
            guard rules.isAllowed(vulnClass: action.vulnClass) else {
                let cls = action.vulnClass.isEmpty ? "(none given)" : action.vulnClass
                return .refuse(edition: edition, rule: "vulnclass.not-accepted",
                               reason: "vuln class \(cls) is not in the program's accepted classes")
            }
        }

        // 5) TRAFFIC BUDGET — anything that sends target traffic must fit the rate limit. An UNKNOWN limit
        //    (nil) forbids automated traffic outright; a known limit refuses an over-budget or unspecified rate.
        if action.method.sendsTargetTraffic {
            switch rules.maxRequestsPerSecond {
            case .none:
                if action.isAutomated {
                    return .refuse(edition: edition, rule: "rate.unknown-limit",
                                   reason: "program rate limit is unknown; automated target traffic is refused")
                }
            case .some(let limit):
                guard let rps = action.requestsPerSecond else {
                    return .refuse(edition: edition, rule: "rate.unspecified",
                                   reason: "action sends target traffic but states no rate; refusing against the \(limit)/s limit")
                }
                if rps > limit {
                    return .refuse(edition: edition, rule: "rate.over-limit",
                                   reason: "intended \(rps)/s exceeds the program limit of \(limit)/s")
                }
            }
        }

        // 6) SUBMISSION — the public edition NEVER auto-submits. A human stays on the submit button; an
        //    automated submission is refused so one bad finding can't torch the operator's reputation.
        if action.isSubmission && action.isAutomated {
            return .refuse(edition: edition, rule: "submit.no-auto-submit",
                           reason: "public edition requires a human to submit; automated submission is refused")
        }

        return .allow(edition: edition)
    }
}

/// The single entry point the rest of the app calls. In the PUBLIC build it is constructed with
/// `PublicEditionPolicy` (the only conformer present). The private full repo constructs it with its own
/// policy at its one wiring site. Keeping the policy behind this facade means the rest of the codebase is
/// edition-agnostic — it just asks the gate.
public struct BountyGate: Sendable {
    public let policy: BountyAuthorizationPolicy
    public init(policy: BountyAuthorizationPolicy = PublicEditionPolicy()) { self.policy = policy }

    public func evaluate(_ action: BountyAction, engagement: SecurityEngagement, rules: BountyProgramRules) -> BountyDecision {
        policy.evaluate(action: action, engagement: engagement, rules: rules)
    }
}
