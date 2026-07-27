import Foundation

// MARK: - Per-program RULES (the layer that sits ON TOP of SecurityEngagement's SCOPE)
//
// `SecurityEngagement` answers ONE question, fail-closed: "is this target authorized?" (set membership
// on an attested host/repo). These rules answer the OTHER question a real program imposes: "is this
// ACTION permitted, and how?" — automation policy, rate limit, allowed vuln classes, forbidden methods,
// human-on-submit. BOTH must pass before any active work runs.
//
// Public-edition contract: every field defaults to the STRICTEST interpretation, so an under-specified
// program is maximally restricted, never accidentally permissive. "Unknown" always resolves to "no".

/// Whether a program permits automated / AI-driven tooling. Many programs RESTRICT or outright BAN it,
/// and ignoring that is a fast way to get a hunter banned — so this is a first-class, enforced field.
public enum AutomationPolicy: String, Sendable, Codable, Equatable {
    case banned       // no automated/AI tooling at all
    case restricted   // passive automation only; automated ACTIVE actions are refused
    case allowed      // automation permitted, still subject to the rate limit
}

/// The kind of action being taken against a target. The destructive / out-of-bounds ones are categorically
/// refused by the PUBLIC edition (see `PublicEditionPolicy.alwaysForbidden`) — they are exactly the methods
/// that get a hunter banned or sued. Only a DIFFERENT edition policy (private full-access repo) may permit
/// them, and only inside its own attested authorization.
public enum TestMethod: String, Sendable, Codable, Equatable, CaseIterable {
    case passiveRecon       // OSINT / public sources; minimal-to-no target traffic
    case activeScan         // probes that send traffic to the target
    case exploitPoC         // a minimal, non-destructive proof-of-concept of a real vuln
    case denialOfService    // ⛔ always forbidden in public
    case socialEngineering  // ⛔ always forbidden in public
    case dataExfiltration   // ⛔ always forbidden in public
    case lateralMovement    // ⛔ always forbidden in public (pivoting)
    case physicalAccess     // ⛔ always forbidden in public

    /// Does this method push traffic at the target (and therefore fall under the rate limit)?
    public var sendsTargetTraffic: Bool {
        switch self {
        case .activeScan, .exploitPoC: return true
        case .passiveRecon, .denialOfService, .socialEngineering,
             .dataExfiltration, .lateralMovement, .physicalAccess: return false
        }
    }
}

/// The structured rules for ONE program. Pairs with a `SecurityEngagement` (same `program` string) to form
/// a complete authorization: engagement = WHAT you may touch, rules = HOW you may touch it.
public struct BountyProgramRules: Sendable, Codable, Equatable {
    public let automation: AutomationPolicy
    /// nil ⇒ UNKNOWN ⇒ strictest: no automated target traffic is permitted at an unknown rate.
    public let maxRequestsPerSecond: Double?
    /// Canonical lowercase vuln-class tags the program accepts (e.g. "xss", "idor", "ssrf").
    /// EMPTY ⇒ nothing is in-class ⇒ active findings are refused (fail-closed).
    public let allowedVulnClasses: Set<String>
    /// severity → typical payout (USD). Informational only; never gates anything.
    public let payoutTableUSD: [String: Int]
    public let disclosureURL: String?

    public init(automation: AutomationPolicy,
                maxRequestsPerSecond: Double?,
                allowedVulnClasses: Set<String>,
                payoutTableUSD: [String: Int] = [:],
                disclosureURL: String? = nil) {
        self.automation = automation
        self.maxRequestsPerSecond = maxRequestsPerSecond
        // Canonicalize on the way in so on-disk/source values always match the runtime lookup.
        self.allowedVulnClasses = Set(allowedVulnClasses.map { BountyProgramRules.canonicalClass($0) }.filter { !$0.isEmpty })
        self.payoutTableUSD = payoutTableUSD
        self.disclosureURL = disclosureURL
    }

    enum CodingKeys: String, CodingKey {
        case automation, maxRequestsPerSecond, allowedVulnClasses, payoutTableUSD, disclosureURL
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            automation: try c.decode(AutomationPolicy.self, forKey: .automation),
            maxRequestsPerSecond: try c.decodeIfPresent(Double.self, forKey: .maxRequestsPerSecond),
            allowedVulnClasses: try c.decodeIfPresent(Set<String>.self, forKey: .allowedVulnClasses) ?? [],
            payoutTableUSD: try c.decodeIfPresent([String: Int].self, forKey: .payoutTableUSD) ?? [:],
            disclosureURL: try c.decodeIfPresent(String.self, forKey: .disclosureURL))
    }

    /// The strictest possible ruleset — what an UNKNOWN/unspecified program collapses to. Nothing automated,
    /// nothing in-class, no rate budget. A program intake that can't fill the fields lands here, not open.
    public static let strictestUnknown = BountyProgramRules(
        automation: .banned, maxRequestsPerSecond: nil, allowedVulnClasses: [])

    public func isAllowed(vulnClass raw: String) -> Bool {
        allowedVulnClasses.contains(BountyProgramRules.canonicalClass(raw))
    }

    static func canonicalClass(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - A proposed action + the gate's verdict

/// One concrete thing the assistant proposes to do, evaluated BEFORE it runs. `targetHost`/`targetRepo`
/// are what the action touches (at least one must be present); everything else describes how.
public struct BountyAction: Sendable, Equatable {
    public let targetHost: String?
    public let targetRepo: String?     // "owner/name" for source-level findings
    public let vulnClass: String       // canonical lowercase; "" for pure recon
    public let method: TestMethod
    public let isAutomated: Bool        // is this an automated / tool-driven action (vs. a manual human one)?
    public let requestsPerSecond: Double?   // intended traffic rate, if it sends target traffic
    public let isSubmission: Bool       // is this the SUBMIT-the-report step?

    public init(targetHost: String? = nil, targetRepo: String? = nil, vulnClass: String = "",
                method: TestMethod, isAutomated: Bool, requestsPerSecond: Double? = nil,
                isSubmission: Bool = false) {
        self.targetHost = targetHost
        self.targetRepo = targetRepo
        self.vulnClass = vulnClass
        self.method = method
        self.isAutomated = isAutomated
        self.requestsPerSecond = requestsPerSecond
        self.isSubmission = isSubmission
    }
}

/// The gate's decision. Carries the EDITION that evaluated it and the specific rule that fired, so every
/// refusal is auditable and every log line says which build + which rule made the call.
public struct BountyDecision: Sendable, Equatable {
    public enum Verdict: String, Sendable, Equatable { case allow, refuse }
    public let verdict: Verdict
    public let edition: String
    public let reason: String
    public let ruleHit: String?

    public var isAllowed: Bool { verdict == .allow }

    public static func allow(edition: String, reason: String = "passes scope + program rules") -> BountyDecision {
        BountyDecision(verdict: .allow, edition: edition, reason: reason, ruleHit: nil)
    }
    public static func refuse(edition: String, rule: String, reason: String) -> BountyDecision {
        BountyDecision(verdict: .refuse, edition: edition, reason: reason, ruleHit: rule)
    }
}
