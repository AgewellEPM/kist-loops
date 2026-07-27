import Foundation

/// Parses an operator-authored `ProgramSpec` into the two typed authorization objects the whole pipeline
/// runs on: a `SecurityEngagement` (attested scope) and `BountyProgramRules`. Fail-closed and deterministic:
/// no attestation, no valid target, or no program name ⇒ REFUSED (an unauthorized engagement can never
/// gate anything). Automation/rate/classes collapse to their strictest reading when unspecified.
public enum ProgramIntake {

    public enum IntakeError: Error, Equatable {
        case emptyProgramName
        case missingAttestation           // no attestedBy / attestedAtISO — scope is a claim, not evidence
        case noValidTargets(dropped: Int) // every target was unknown-kind or canonicalized to empty
        case notAuthorized(reason: String)
    }

    public static func parse(_ spec: ProgramSpec) -> Result<(SecurityEngagement, BountyProgramRules), IntakeError> {
        let program = spec.program.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !program.isEmpty else { return .failure(.emptyProgramName) }
        guard !spec.attestedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !spec.attestedAtISO.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.missingAttestation)
        }

        // Build targets; drop any with an unknown kind or an empty canonical value (SecurityTarget
        // canonicalizes + refuses malformed/over-broad values on its own — fail-closed by construction).
        var targets: [SecurityTarget] = []
        var dropped = 0
        for t in spec.targets {
            guard let kind = SecurityTarget.Kind(rawValue: t.kind.trimmingCharacters(in: .whitespaces).lowercased()) else {
                dropped += 1; continue
            }
            let target = SecurityTarget(kind: kind, value: t.value)
            if target.value.isEmpty { dropped += 1; continue }
            targets.append(target)
        }
        guard !targets.isEmpty else { return .failure(.noValidTargets(dropped: dropped)) }

        let engagement = SecurityEngagement(
            id: spec.id.isEmpty ? program : spec.id, program: program,
            attestedBy: spec.attestedBy, attestedAtISO: spec.attestedAtISO,
            targets: targets, safeHarbor: spec.safeHarbor, rulesURL: spec.rulesURL,
            testingLimits: spec.testingLimits)

        // Belt-and-suspenders: the engagement itself must consider this authorized.
        guard engagement.isAuthorized else {
            return .failure(.notAuthorized(reason: "engagement failed its own authorization check"))
        }

        // Rules: strictest reading of anything unspecified (unknown automation ⇒ banned).
        let automation = AutomationPolicy(rawValue: spec.automation.trimmingCharacters(in: .whitespaces).lowercased()) ?? .banned
        let rules = BountyProgramRules(
            automation: automation, maxRequestsPerSecond: spec.maxRequestsPerSecond,
            allowedVulnClasses: Set(spec.allowedVulnClasses), payoutTableUSD: spec.payoutTableUSD,
            disclosureURL: spec.disclosureURL)

        return .success((engagement, rules))
    }

    /// Parse from JSON bytes (a `.kist/bounty/<program>.json` the operator authored/reviewed).
    public static func parse(json: Data) -> Result<(SecurityEngagement, BountyProgramRules), Error> {
        do {
            let spec = try JSONDecoder().decode(ProgramSpec.self, from: json)
            return parse(spec).mapError { $0 as Error }
        } catch { return .failure(error) }
    }

    /// Parse + persist: the engagement to `EngagementStore` (the canonical authorization store the security
    /// tools already read) and the rules to `BountyRulesStore`, both keyed by the same id.
    @discardableResult
    public static func ingest(_ spec: ProgramSpec,
                              engagements: EngagementStore = EngagementStore(),
                              rulesStore: BountyRulesStore = BountyRulesStore()) throws -> (SecurityEngagement, BountyProgramRules) {
        switch parse(spec) {
        case .failure(let e): throw e
        case .success(let (engagement, rules)):
            try engagements.save(engagement)
            try rulesStore.save(id: engagement.id, rules: rules)
            return (engagement, rules)
        }
    }
}
