import Foundation

// MARK: - Security-awareness platform: the LEGAL foundation (build before anything sends)
//
// The entire phishing-simulation industry rests on ONE thing: you test only orgs that CONTRACTED you to
// test them, only the people/assets in the signed scope, with consent. Sending a simulated lure outside
// that is wire fraud / CFAA. So — exactly like the bug-bounty SecurityEngagement — authorization here is
// ATTESTED EVIDENCE, not a prompt claim, and everything is FAIL-CLOSED: no consented recipient ⇒ no send;
// a template that wasn't human-reviewed ⇒ no send; a recipient outside the consented list ⇒ no send.

public enum SimChannel: String, Sendable, Codable, Equatable, CaseIterable {
    case email, sms, chat, voice
    /// email is the only channel matched by domain; the rest match a consented identifier exactly.
    public var isDomainScoped: Bool { self == .email }
}

/// A person the client's leadership has CONSENTED to have tested. Public / non-contracted third parties can
/// never appear here, so membership in this list is the hard authorization boundary for a recipient.
public struct ConsentedRecipient: Sendable, Codable, Equatable {
    public let identifier: String   // canonical email or phone
    public let group: String        // employee group (for measurement)
    public init(identifier: String, group: String = "") {
        self.identifier = AwarenessEngagement.canonicalIdentifier(identifier)
        self.group = group
    }
    enum CodingKeys: String, CodingKey { case identifier, group }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(identifier: try c.decode(String.self, forKey: .identifier),
                  group: try c.decodeIfPresent(String.self, forKey: .group) ?? "")
    }
}

/// A reviewed simulation template. `reviewed == false` can NEVER be scheduled/sent — no unreviewed
/// AI-generated lure ever ships. The AI personalizes WITHIN a reviewed template; it doesn't author sends.
public struct SimulationTemplate: Sendable, Codable, Equatable {
    public let id: String
    public let category: String     // credential-harvest | fake-it | invoice | qr | account-alert | mfa-fatigue
    public let reviewed: Bool
    public let difficulty: Int
    public init(id: String, category: String, reviewed: Bool, difficulty: Int = 1) {
        self.id = id; self.category = category; self.reviewed = reviewed; self.difficulty = difficulty
    }
}

/// The signed, attested engagement with ONE client org — the scope every send is checked against.
public struct AwarenessEngagement: Sendable, Codable, Equatable {
    public let id: String
    public let client: String
    public let attestedBy: String        // org-leadership sign-off identity (NOT the model)
    public let attestedAtISO: String
    public let allowedDomains: [String]  // in-scope email domains (lowercased)
    public let consentedRecipients: [ConsentedRecipient]
    public let allowedChannels: [SimChannel]
    public let rulesOfEngagement: [String]

    public init(id: String, client: String, attestedBy: String, attestedAtISO: String,
                allowedDomains: [String], consentedRecipients: [ConsentedRecipient],
                allowedChannels: [SimChannel], rulesOfEngagement: [String] = []) {
        self.id = id; self.client = client; self.attestedBy = attestedBy; self.attestedAtISO = attestedAtISO
        self.allowedDomains = allowedDomains.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        self.consentedRecipients = consentedRecipients
        self.allowedChannels = allowedChannels
        self.rulesOfEngagement = rulesOfEngagement
    }

    /// Fail-closed prerequisites: a real sign-off AND at least one consented recipient AND at least one
    /// allowed channel. An under-specified engagement authorizes NOTHING.
    public var isAuthorized: Bool {
        !attestedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !attestedAtISO.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !consentedRecipients.contains(where: { $0.identifier.isEmpty }) && !consentedRecipients.isEmpty
            && !allowedChannels.isEmpty
    }

    /// Is this exact recipient consented? (identifier set membership — the hard boundary).
    public func isConsented(_ raw: String) -> Bool {
        let id = Self.canonicalIdentifier(raw)
        return !id.isEmpty && consentedRecipients.contains { $0.identifier == id }
    }

    /// For email: is the recipient's domain in the attested scope? (belt-and-suspenders with the consent list).
    public func domainInScope(_ rawEmail: String) -> Bool {
        guard let at = Self.canonicalIdentifier(rawEmail).lastIndex(of: "@") else { return false }
        let domain = String(Self.canonicalIdentifier(rawEmail)[rawEmail.index(after: at)...])
        return allowedDomains.contains(domain)
    }

    /// Canonicalize an email/phone identifier: trim + lowercase. Fail-closed strict charset — reject
    /// whitespace/control that could make the matched identifier differ from the real send target.
    public static func canonicalIdentifier(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "@.+-_".contains($0) }) else { return "" }
        return s
    }
}
