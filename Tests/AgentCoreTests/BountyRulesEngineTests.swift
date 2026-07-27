import XCTest
@testable import AgentCore

/// The public-edition bounty gate is the legal safety rail: it must FAIL CLOSED on every rule. These tests
/// pin each gate individually (named rule per assertion) so a regression says exactly which rail broke,
/// not just "something refused". Happy path proves the gate still lets legitimate, in-scope work through.
final class BountyRulesEngineTests: XCTestCase {

    let gate = BountyGate()   // defaults to PublicEditionPolicy — the only conformer in this repo

    func engagement(attestedBy: String = "luke") -> SecurityEngagement {
        SecurityEngagement(
            id: "acme", program: "HackerOne: Acme", attestedBy: attestedBy,
            attestedAtISO: "2026-06-30T00:00:00Z",
            targets: [SecurityTarget(kind: .domain, value: "example.com"),
                      SecurityTarget(kind: .repo, value: "acme/app")],
            safeHarbor: true, rulesURL: nil, testingLimits: [])
    }

    func rules(automation: AutomationPolicy = .allowed, rate: Double? = 5,
               classes: Set<String> = ["xss", "idor"]) -> BountyProgramRules {
        BountyProgramRules(automation: automation, maxRequestsPerSecond: rate, allowedVulnClasses: classes)
    }

    // MARK: happy path

    func testInScopeAutomatedScanWithinAllRulesIsAllowed() {
        let a = BountyAction(targetHost: "api.example.com", vulnClass: "xss",
                             method: .activeScan, isAutomated: true, requestsPerSecond: 3)
        let d = gate.evaluate(a, engagement: engagement(), rules: rules())
        XCTAssertTrue(d.isAllowed, "expected allow, got: \(d.reason)")
        XCTAssertEqual(d.edition, "public")   // every decision is edition-stamped
    }

    // MARK: scope rails

    func testNoTargetRefused() {
        let a = BountyAction(vulnClass: "xss", method: .activeScan, isAutomated: true, requestsPerSecond: 1)
        let d = gate.evaluate(a, engagement: engagement(), rules: rules())
        XCTAssertEqual(d.ruleHit, "scope.no-target")
    }

    func testHostOutOfScopeRefused() {
        let a = BountyAction(targetHost: "evil.com", vulnClass: "xss",
                             method: .activeScan, isAutomated: true, requestsPerSecond: 1)
        XCTAssertEqual(gate.evaluate(a, engagement: engagement(), rules: rules()).ruleHit, "scope.host-out-of-scope")
    }

    func testRepoOutOfScopeRefused() {
        let a = BountyAction(targetRepo: "someone/else", vulnClass: "idor",
                             method: .activeScan, isAutomated: false)
        XCTAssertEqual(gate.evaluate(a, engagement: engagement(), rules: rules()).ruleHit, "scope.repo-out-of-scope")
    }

    func testUnauthorizedEngagementRefusesEvenInScopeLookingHost() {
        // Empty attestation ⇒ engagement.isAuthorized == false ⇒ EVERY host is out of scope.
        let a = BountyAction(targetHost: "api.example.com", vulnClass: "xss",
                             method: .activeScan, isAutomated: false, requestsPerSecond: 1)
        let d = gate.evaluate(a, engagement: engagement(attestedBy: "   "), rules: rules())
        XCTAssertFalse(d.isAllowed)
        XCTAssertEqual(d.ruleHit, "scope.host-out-of-scope")
    }

    // MARK: categorical method bans — assert EVERY forbidden method individually

    func testEveryAlwaysForbiddenMethodRefused() {
        for method in PublicEditionPolicy.alwaysForbidden {
            let a = BountyAction(targetHost: "api.example.com", vulnClass: "xss",
                                 method: method, isAutomated: false)
            let d = gate.evaluate(a, engagement: engagement(), rules: rules())
            XCTAssertEqual(d.ruleHit, "method.always-forbidden", "\(method.rawValue) should be categorically forbidden")
        }
    }

    // MARK: automation policy

    func testAutomationBannedRefusesAutomatedAction() {
        let a = BountyAction(targetHost: "api.example.com", vulnClass: "xss",
                             method: .activeScan, isAutomated: true, requestsPerSecond: 1)
        XCTAssertEqual(gate.evaluate(a, engagement: engagement(), rules: rules(automation: .banned)).ruleHit,
                       "automation.banned")
    }

    func testAutomationRestrictedRefusesAutomatedActiveButAllowsPassive() {
        let active = BountyAction(targetHost: "api.example.com", vulnClass: "xss",
                                  method: .activeScan, isAutomated: true, requestsPerSecond: 1)
        XCTAssertEqual(gate.evaluate(active, engagement: engagement(), rules: rules(automation: .restricted)).ruleHit,
                       "automation.restricted-active")
        let passive = BountyAction(targetHost: "api.example.com", method: .passiveRecon, isAutomated: true)
        XCTAssertTrue(gate.evaluate(passive, engagement: engagement(), rules: rules(automation: .restricted)).isAllowed)
    }

    // MARK: vuln class

    func testVulnClassNotAcceptedRefused() {
        let a = BountyAction(targetHost: "api.example.com", vulnClass: "rce",
                             method: .activeScan, isAutomated: false, requestsPerSecond: 1)
        XCTAssertEqual(gate.evaluate(a, engagement: engagement(), rules: rules()).ruleHit, "vulnclass.not-accepted")
    }

    func testExploitWithNoVulnClassRefused() {
        let a = BountyAction(targetHost: "api.example.com", vulnClass: "",
                             method: .exploitPoC, isAutomated: false, requestsPerSecond: 1)
        XCTAssertEqual(gate.evaluate(a, engagement: engagement(), rules: rules()).ruleHit, "vulnclass.not-accepted")
    }

    func testEmptyAllowedClassesRefusesEverythingActive() {
        let a = BountyAction(targetHost: "api.example.com", vulnClass: "xss",
                             method: .activeScan, isAutomated: false, requestsPerSecond: 1)
        XCTAssertEqual(gate.evaluate(a, engagement: engagement(), rules: rules(classes: [])).ruleHit, "vulnclass.not-accepted")
    }

    // MARK: traffic budget

    func testUnknownRateLimitRefusesAutomatedTraffic() {
        let a = BountyAction(targetHost: "api.example.com", vulnClass: "xss",
                             method: .activeScan, isAutomated: true, requestsPerSecond: 1)
        XCTAssertEqual(gate.evaluate(a, engagement: engagement(), rules: rules(rate: nil)).ruleHit, "rate.unknown-limit")
    }

    func testKnownLimitButUnspecifiedRateRefused() {
        let a = BountyAction(targetHost: "api.example.com", vulnClass: "xss",
                             method: .activeScan, isAutomated: false, requestsPerSecond: nil)
        XCTAssertEqual(gate.evaluate(a, engagement: engagement(), rules: rules()).ruleHit, "rate.unspecified")
    }

    func testOverRateLimitRefused() {
        let a = BountyAction(targetHost: "api.example.com", vulnClass: "xss",
                             method: .activeScan, isAutomated: false, requestsPerSecond: 10)
        XCTAssertEqual(gate.evaluate(a, engagement: engagement(), rules: rules()).ruleHit, "rate.over-limit")
    }

    // MARK: submission — human stays on the button

    func testAutomatedSubmissionRefused() {
        let a = BountyAction(targetHost: "api.example.com", method: .passiveRecon,
                             isAutomated: true, isSubmission: true)
        // automation allowed + passive ⇒ gets past automation; the submit rail is what must catch it.
        XCTAssertEqual(gate.evaluate(a, engagement: engagement(), rules: rules()).ruleHit, "submit.no-auto-submit")
    }

    func testHumanSubmissionAllowed() {
        let a = BountyAction(targetHost: "api.example.com", method: .passiveRecon,
                             isAutomated: false, isSubmission: true)
        XCTAssertTrue(gate.evaluate(a, engagement: engagement(), rules: rules()).isAllowed)
    }

    // MARK: strictest-unknown fixture really is closed

    func testStrictestUnknownRulesRefuseEvenInScopeAutomatedScan() {
        let a = BountyAction(targetHost: "api.example.com", vulnClass: "xss",
                             method: .activeScan, isAutomated: true, requestsPerSecond: 1)
        let d = gate.evaluate(a, engagement: engagement(), rules: .strictestUnknown)
        XCTAssertFalse(d.isAllowed)
        XCTAssertEqual(d.ruleHit, "automation.banned")   // strictest bans automation first
    }
}
