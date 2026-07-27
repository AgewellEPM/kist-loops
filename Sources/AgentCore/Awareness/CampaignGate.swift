import Foundation

/// The send gate: NO simulated phishing send is permitted unless it clears every check, fail-closed. This
/// is the legal backstop under all the campaign machinery — a template that wasn't reviewed, a recipient who
/// wasn't consented, a channel that wasn't agreed, an unauthorized engagement: all refused, and the refusal
/// names the rule. Mirrors the bug-bounty BountyGate: authorization is a set-membership test, not a prompt.

public struct CampaignSend: Sendable, Equatable {
    public let recipient: String
    public let channel: SimChannel
    public let template: SimulationTemplate
    public init(recipient: String, channel: SimChannel, template: SimulationTemplate) {
        self.recipient = recipient; self.channel = channel; self.template = template
    }
}

public struct CampaignDecision: Sendable, Equatable {
    public enum Verdict: String, Sendable, Equatable { case allow, refuse }
    public let verdict: Verdict
    public let reason: String
    public let rule: String?
    public var isAllowed: Bool { verdict == .allow }

    public static func allow(_ reason: String = "in scope, consented recipient, reviewed template") -> CampaignDecision {
        CampaignDecision(verdict: .allow, reason: reason, rule: nil)
    }
    public static func refuse(_ rule: String, _ reason: String) -> CampaignDecision {
        CampaignDecision(verdict: .refuse, reason: reason, rule: rule)
    }
}

public struct CampaignGate: Sendable {
    public init() {}

    public func evaluate(_ send: CampaignSend, engagement: AwarenessEngagement) -> CampaignDecision {
        // 1) AUTHORIZATION — a signed, non-empty engagement with consent + channels.
        guard engagement.isAuthorized else {
            return .refuse("scope.unauthorized", "engagement is not authorized (no sign-off / no consented recipients / no channels)")
        }
        // 2) REVIEWED TEMPLATE — no unreviewed / AI-authored lure ever sends.
        guard send.template.reviewed else {
            return .refuse("template.unreviewed", "template '\(send.template.id)' is not human-reviewed; refusing to send an unreviewed lure")
        }
        // 3) CHANNEL — must be an agreed channel.
        guard engagement.allowedChannels.contains(send.channel) else {
            return .refuse("channel.not-allowed", "channel \(send.channel.rawValue) is not in the agreed channels for '\(engagement.client)'")
        }
        // 4) CONSENT — the recipient must be on the consented list (the hard boundary; a public/third party
        //    can never be here). This is what keeps a lure from ever reaching a non-contracted person.
        guard engagement.isConsented(send.recipient) else {
            return .refuse("recipient.not-consented", "recipient is not on the consented list for '\(engagement.client)'")
        }
        // 5) DOMAIN (email only) — belt-and-suspenders: an email recipient's domain must also be in scope.
        if send.channel.isDomainScoped, !engagement.domainInScope(send.recipient) {
            return .refuse("recipient.domain-out-of-scope", "recipient's email domain is not in the attested scope")
        }
        return .allow()
    }
}
