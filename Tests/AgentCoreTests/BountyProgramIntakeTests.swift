import XCTest
@testable import AgentCore

/// Program intake turns an operator-authored spec into attested scope + rules, fail-closed: no attestation
/// or no valid target ⇒ refused, and unspecified rules collapse to strictest. Round-trips through JSON +
/// the stores.
final class BountyProgramIntakeTests: XCTestCase {

    var roots: [String] = []
    override func tearDownWithError() throws { for r in roots { try? FileManager.default.removeItem(atPath: r) }; roots = [] }
    func tempRoot() -> String { let d = NSTemporaryDirectory() + "bounty-intake-" + UUID().uuidString; roots.append(d); return d }

    func goodSpec() -> ProgramSpec {
        ProgramSpec(id: "acme", program: "HackerOne: Acme", attestedBy: "luke",
                    attestedAtISO: "2026-06-30T00:00:00Z",
                    targets: [.init(kind: "domain", value: "example.com"), .init(kind: "repo", value: "acme/app")],
                    safeHarbor: true, rulesURL: "https://h1/acme", testingLimits: ["no DoS"],
                    automation: "allowed", maxRequestsPerSecond: 5, allowedVulnClasses: ["xss", "injection"],
                    payoutTableUSD: ["high": 1500])
    }

    func testValidSpecParsesToAuthorizedEngagementAndRules() {
        guard case .success(let (eng, rules)) = ProgramIntake.parse(goodSpec()) else { return XCTFail("should parse") }
        XCTAssertTrue(eng.isAuthorized)
        XCTAssertEqual(eng.targets.count, 2)
        XCTAssertTrue(eng.inScope(host: "api.example.com").isInScope)
        XCTAssertEqual(rules.automation, .allowed)
        XCTAssertEqual(rules.maxRequestsPerSecond, 5)
        XCTAssertTrue(rules.isAllowed(vulnClass: "injection"))
    }

    func testMissingAttestationRefused() {
        var s = goodSpec()
        s = ProgramSpec(id: s.id, program: s.program, attestedBy: "   ", attestedAtISO: s.attestedAtISO,
                        targets: s.targets, automation: s.automation, maxRequestsPerSecond: s.maxRequestsPerSecond,
                        allowedVulnClasses: s.allowedVulnClasses)
        guard case .failure(let e) = ProgramIntake.parse(s) else { return XCTFail("should refuse") }
        XCTAssertEqual(e, .missingAttestation)
    }

    func testNoValidTargetsRefused() {
        let s = ProgramSpec(id: "x", program: "P", attestedBy: "luke", attestedAtISO: "t",
                            targets: [.init(kind: "banana", value: "whatever"), .init(kind: "cidr", value: "0.0.0.0/0")],
                            automation: "allowed", maxRequestsPerSecond: 1, allowedVulnClasses: ["xss"])
        // "banana" is an unknown kind; "/0" CIDR is refused by SecurityTarget (over-broad) ⇒ 0 valid targets.
        guard case .failure(let e) = ProgramIntake.parse(s) else { return XCTFail("should refuse") }
        guard case .noValidTargets = e else { return XCTFail("wrong error: \(e)") }
    }

    func testUnknownAutomationCollapsesToStrictestBanned() {
        let s = ProgramSpec(id: "x", program: "P", attestedBy: "luke", attestedAtISO: "t",
                            targets: [.init(kind: "domain", value: "example.com")],
                            automation: "sure-why-not", maxRequestsPerSecond: nil, allowedVulnClasses: [])
        guard case .success(let (_, rules)) = ProgramIntake.parse(s) else { return XCTFail("should parse") }
        XCTAssertEqual(rules.automation, .banned)         // strictest
        XCTAssertNil(rules.maxRequestsPerSecond)          // unknown rate
        XCTAssertTrue(rules.allowedVulnClasses.isEmpty)   // nothing accepted
    }

    func testJSONRoundTrip() throws {
        let data = try JSONEncoder().encode(goodSpec())
        guard case .success(let (eng, rules)) = ProgramIntake.parse(json: data) else { return XCTFail("json should parse") }
        XCTAssertEqual(eng.program, "HackerOne: Acme")
        XCTAssertEqual(rules.automation, .allowed)
    }

    func testIngestPersistsEngagementAndRules() throws {
        let engStore = EngagementStore(root: tempRoot())
        let rulesStore = BountyRulesStore(root: tempRoot())
        let (eng, _) = try ProgramIntake.ingest(goodSpec(), engagements: engStore, rulesStore: rulesStore)
        XCTAssertNotNil(try engStore.load(id: eng.id))
        let loadedRules = try rulesStore.load(id: eng.id)
        XCTAssertEqual(loadedRules?.automation, .allowed)
        XCTAssertEqual(loadedRules?.maxRequestsPerSecond, 5)
    }

    // A malformed spec that decodes to an EMPTY spec must not silently become a permissive program.
    func testEmptyJSONIsRefusedNotPermissive() {
        let data = "{}".data(using: .utf8)!
        guard case .failure = ProgramIntake.parse(json: data) else { return XCTFail("empty spec must be refused") }
    }
}
