import XCTest
@testable import AgentCore

/// The security-awareness send gate is the legal rail: no simulated lure sends without a signed scope, a
/// reviewed template, an agreed channel, and a CONSENTED recipient. Each rule is pinned individually so a
/// regression names exactly which safeguard broke.
final class CampaignGateTests: XCTestCase {

    let gate = CampaignGate()

    func engagement(attestedBy: String = "ciso@acme.com",
                    recipients: [ConsentedRecipient] = [ConsentedRecipient(identifier: "alice@acme.com", group: "eng")],
                    channels: [SimChannel] = [.email]) -> AwarenessEngagement {
        AwarenessEngagement(id: "acme", client: "Acme Inc", attestedBy: attestedBy,
                            attestedAtISO: "2026-06-30T00:00:00Z", allowedDomains: ["acme.com"],
                            consentedRecipients: recipients, allowedChannels: channels)
    }
    func template(reviewed: Bool = true) -> SimulationTemplate {
        SimulationTemplate(id: "cred-harvest-1", category: "credential-harvest", reviewed: reviewed)
    }
    func send(to recipient: String = "alice@acme.com", channel: SimChannel = .email, reviewed: Bool = true) -> CampaignSend {
        CampaignSend(recipient: recipient, channel: channel, template: template(reviewed: reviewed))
    }

    func testConsentedReviewedInScopeSendIsAllowed() {
        XCTAssertTrue(gate.evaluate(send(), engagement: engagement()).isAllowed)
    }

    func testUnauthorizedEngagementRefused() {
        // no sign-off ⇒ unauthorized
        let d = gate.evaluate(send(), engagement: engagement(attestedBy: "   "))
        XCTAssertEqual(d.rule, "scope.unauthorized")
    }

    func testUnreviewedTemplateRefused() {
        XCTAssertEqual(gate.evaluate(send(reviewed: false), engagement: engagement()).rule, "template.unreviewed")
    }

    func testChannelNotAllowedRefused() {
        // engagement allows email only; try SMS
        let d = gate.evaluate(send(to: "alice@acme.com", channel: .sms), engagement: engagement(channels: [.email]))
        XCTAssertEqual(d.rule, "channel.not-allowed")
    }

    func testNonConsentedRecipientRefused() {
        let d = gate.evaluate(send(to: "stranger@acme.com"), engagement: engagement())
        XCTAssertEqual(d.rule, "recipient.not-consented")
    }

    func testConsentedButOutOfScopeDomainRefused() {
        // consented identifier but its domain isn't in allowedDomains (belt-and-suspenders)
        let e = engagement(recipients: [ConsentedRecipient(identifier: "bob@evil.com")])
        let d = gate.evaluate(send(to: "bob@evil.com"), engagement: e)
        XCTAssertEqual(d.rule, "recipient.domain-out-of-scope")
    }

    func testEmptyConsentListAuthorizesNothing() {
        let e = engagement(recipients: [])
        XCTAssertFalse(gate.evaluate(send(), engagement: e).isAllowed)
    }

    func testSmsToConsentedPhoneAllowedWithoutDomainCheck() {
        let e = engagement(recipients: [ConsentedRecipient(identifier: "+15551234567", group: "sales")], channels: [.sms])
        let s = CampaignSend(recipient: "+15551234567", channel: .sms, template: template())
        XCTAssertTrue(gate.evaluate(s, engagement: e).isAllowed)
    }

    func testWhitespaceInjectionInRecipientCannotSlipConsent() {
        // a recipient with control/space chars canonicalizes to "" ⇒ never matches a consented id
        let d = gate.evaluate(send(to: "alice@acme.com\n"), engagement: engagement())
        // "alice@acme.com\n" trims to "alice@acme.com" (trailing newline trimmed) ⇒ allowed; but an embedded
        // space must fail:
        XCTAssertTrue(d.isAllowed)
        let d2 = gate.evaluate(send(to: "alice @acme.com"), engagement: engagement())
        XCTAssertEqual(d2.rule, "recipient.not-consented")
    }
}
