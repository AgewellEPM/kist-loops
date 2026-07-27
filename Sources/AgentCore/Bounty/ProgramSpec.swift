import Foundation

/// The operator-authored intake for a program. This is DELIBERATELY a structured spec the human fills in
/// (or reviews), not free text an LLM parses — authorization scope cannot be invented by a model. Decoding
/// is lenient toward the STRICTEST reading: anything missing/ambiguous collapses to "no", so a half-filled
/// spec is maximally restricted, never accidentally permissive.
public struct ProgramSpec: Sendable, Codable, Equatable {
    public struct TargetSpec: Sendable, Codable, Equatable {
        public let kind: String    // domain | host | wildcard | cidr | repo
        public let value: String
        public init(kind: String, value: String) { self.kind = kind; self.value = value }
    }

    // engagement (scope + attestation)
    public let id: String
    public let program: String
    public let attestedBy: String
    public let attestedAtISO: String
    public let targets: [TargetSpec]
    public let safeHarbor: Bool
    public let rulesURL: String?
    public let testingLimits: [String]

    // program rules
    public let automation: String            // "banned" | "restricted" | "allowed"; unknown ⇒ banned
    public let maxRequestsPerSecond: Double? // nil ⇒ unknown ⇒ strictest
    public let allowedVulnClasses: [String]  // empty ⇒ nothing accepted
    public let payoutTableUSD: [String: Int]
    public let disclosureURL: String?

    public init(id: String, program: String, attestedBy: String, attestedAtISO: String,
                targets: [TargetSpec], safeHarbor: Bool = false, rulesURL: String? = nil,
                testingLimits: [String] = [], automation: String, maxRequestsPerSecond: Double?,
                allowedVulnClasses: [String], payoutTableUSD: [String: Int] = [:], disclosureURL: String? = nil) {
        self.id = id; self.program = program; self.attestedBy = attestedBy; self.attestedAtISO = attestedAtISO
        self.targets = targets; self.safeHarbor = safeHarbor; self.rulesURL = rulesURL
        self.testingLimits = testingLimits; self.automation = automation
        self.maxRequestsPerSecond = maxRequestsPerSecond; self.allowedVulnClasses = allowedVulnClasses
        self.payoutTableUSD = payoutTableUSD; self.disclosureURL = disclosureURL
    }

    enum CodingKeys: String, CodingKey {
        case id, program, attestedBy, attestedAtISO, targets, safeHarbor, rulesURL, testingLimits
        case automation, maxRequestsPerSecond, allowedVulnClasses, payoutTableUSD, disclosureURL
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        program = try c.decodeIfPresent(String.self, forKey: .program) ?? ""
        attestedBy = try c.decodeIfPresent(String.self, forKey: .attestedBy) ?? ""
        attestedAtISO = try c.decodeIfPresent(String.self, forKey: .attestedAtISO) ?? ""
        targets = try c.decodeIfPresent([TargetSpec].self, forKey: .targets) ?? []
        safeHarbor = try c.decodeIfPresent(Bool.self, forKey: .safeHarbor) ?? false
        rulesURL = try c.decodeIfPresent(String.self, forKey: .rulesURL)
        testingLimits = try c.decodeIfPresent([String].self, forKey: .testingLimits) ?? []
        automation = try c.decodeIfPresent(String.self, forKey: .automation) ?? "banned"    // strictest default
        maxRequestsPerSecond = try c.decodeIfPresent(Double.self, forKey: .maxRequestsPerSecond)
        allowedVulnClasses = try c.decodeIfPresent([String].self, forKey: .allowedVulnClasses) ?? []
        payoutTableUSD = try c.decodeIfPresent([String: Int].self, forKey: .payoutTableUSD) ?? [:]
        disclosureURL = try c.decodeIfPresent(String.self, forKey: .disclosureURL)
    }
}
