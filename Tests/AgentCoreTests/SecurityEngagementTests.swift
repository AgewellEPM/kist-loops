import XCTest
@testable import AgentCore

/// The bug-bounty authorization spine. These tests pin the FAIL-CLOSED invariant: anything not explicitly
/// attested is out of scope, and the classic look-alike / boundary attacks (evil-example.com,
/// example.com.attacker.com, redirect to a third-party host) are refused.
final class SecurityEngagementTests: XCTestCase {

    private func eng(_ targets: [SecurityTarget], attestedBy: String = "luke") -> SecurityEngagement {
        SecurityEngagement(id: "e1", program: "Test", attestedBy: attestedBy, attestedAtISO: "2026-06-29T00:00:00Z",
                           targets: targets, safeHarbor: true, rulesURL: nil, testingLimits: [])
    }

    // MARK: fail-closed prerequisites

    func testEmptyScopeAuthorizesNothing() {
        let e = eng([])
        XCTAssertFalse(e.isAuthorized)
        XCTAssertFalse(e.inScope(host: "example.com").isInScope)
    }

    func testNoAttestationIsNotAuthorized() {
        let e = eng([SecurityTarget(kind: .domain, value: "example.com")], attestedBy: "  ")
        XCTAssertFalse(e.isAuthorized)
        XCTAssertFalse(e.inScope(host: "example.com").isInScope)   // even an in-scope host is refused
    }

    // MARK: Codex regression pins (each names the finding it closes)

    func testCodexCritical_newlineAttestationDoesNotAuthorize() {
        for blank in ["\n", "\t", "  \n ", "\r\n"] {
            let e = eng([SecurityTarget(kind: .domain, value: "example.com")], attestedBy: blank)
            XCTAssertFalse(e.isAuthorized, "attestedBy=\(blank.debugDescription) must not authorize")
            XCTAssertFalse(e.inScope(host: "example.com").isInScope)
        }
    }

    func testCodexHigh_emptyCanonicalTargetAuthorizesNothing() {
        // A blank repo target canonicalizes to "" → not a real target → engagement unauthorized.
        let e = eng([SecurityTarget(kind: .repo, value: "   ")])
        XCTAssertFalse(e.isAuthorized)
        XCTAssertFalse(e.inScope(repo: "   ").isInScope)   // blank input must not match a blank target
        XCTAssertFalse(e.inScope(repo: "").isInScope)
    }

    func testCodexHigh_controlCharHostIsRejected() {
        let e = eng([SecurityTarget(kind: .domain, value: "example.com")])
        XCTAssertFalse(e.inScope(host: "evil.com\t.example.com").isInScope)   // tab splices a fake suffix
        XCTAssertFalse(e.inScope(host: "evil.com\n.example.com").isInScope)
        XCTAssertFalse(e.inScope(host: "exam\u{0000}ple.com").isInScope)       // NUL
        XCTAssertFalse(e.inScope(host: "exàmple.com").isInScope)               // non-ASCII / IDN homoglyph
    }

    func testCodexMedium_octalAmbiguousIpIsRejected() {
        let e = eng([SecurityTarget(kind: .cidr, value: "10.0.0.0/8")])
        XCTAssertFalse(e.inScope(host: "010.0.0.1").isInScope)   // leading-zero octet → not a clean IPv4
        XCTAssertFalse(e.inScope(host: "10.00.0.1").isInScope)
    }

    func testCodexLow_codableReCanonicalizesUppercaseTarget() throws {
        // Simulate an on-disk target stored non-canonically (uppercase), decode, and confirm it still matches.
        let json = #"{"id":"e","program":"P","attestedBy":"luke","attestedAtISO":"2026-06-29T00:00:00Z","targets":[{"kind":"domain","value":"EXAMPLE.COM"}],"safeHarbor":true,"rulesURL":null,"testingLimits":[]}"#
        let e = try JSONDecoder().decode(SecurityEngagement.self, from: Data(json.utf8))
        XCTAssertTrue(e.inScope(host: "api.example.com").isInScope, "decoded uppercase target must re-canonicalize")
    }

    // MARK: domain matching (apex + subdomains, on a label boundary)

    func testDomainMatchesApexAndSubdomains() {
        let e = eng([SecurityTarget(kind: .domain, value: "example.com")])
        XCTAssertTrue(e.inScope(host: "example.com").isInScope)
        XCTAssertTrue(e.inScope(host: "api.example.com").isInScope)
        XCTAssertTrue(e.inScope(host: "a.b.example.com").isInScope)
    }

    func testDomainRejectsLookAlikeAndSuffixAttacks() {
        let e = eng([SecurityTarget(kind: .domain, value: "example.com")])
        XCTAssertFalse(e.inScope(host: "evil-example.com").isInScope)       // not a subdomain
        XCTAssertFalse(e.inScope(host: "notexample.com").isInScope)         // bare suffix string, not label boundary
        XCTAssertFalse(e.inScope(host: "example.com.attacker.com").isInScope) // suffix-prefixed look-alike
        XCTAssertFalse(e.inScope(host: "example.org").isInScope)
    }

    // MARK: host (exact) and wildcard (subdomains only)

    func testHostIsExactOnly() {
        let e = eng([SecurityTarget(kind: .host, value: "api.example.com")])
        XCTAssertTrue(e.inScope(host: "api.example.com").isInScope)
        XCTAssertFalse(e.inScope(host: "example.com").isInScope)
        XCTAssertFalse(e.inScope(host: "www.api.example.com").isInScope)
    }

    func testWildcardIsSubdomainsButNotApex() {
        let e = eng([SecurityTarget(kind: .wildcard, value: "example.com")])
        XCTAssertTrue(e.inScope(host: "api.example.com").isInScope)
        XCTAssertFalse(e.inScope(host: "example.com").isInScope)   // apex excluded by a *.example.com scope
    }

    // MARK: URL / port / case canonicalization

    func testCanonicalizationStripsSchemePortPathAndCase() {
        let e = eng([SecurityTarget(kind: .domain, value: "Example.com")])   // target canonicalized too
        XCTAssertTrue(e.inScope(host: "https://API.Example.com:443/login?x=1").isInScope)
        XCTAssertTrue(e.inScope(host: "user@api.example.com").isInScope)
        XCTAssertTrue(e.inScope(host: "example.com.").isInScope)             // trailing dot (FQDN)
    }

    func testUnparseableHostIsOutOfScope() {
        let e = eng([SecurityTarget(kind: .domain, value: "example.com")])
        XCTAssertFalse(e.inScope(host: "   ").isInScope)
        XCTAssertFalse(e.inScope(host: "has space.com").isInScope)
    }

    // MARK: CIDR (IPv4)

    func testCidrV4Containment() {
        let e = eng([SecurityTarget(kind: .cidr, value: "10.0.0.0/8")])
        XCTAssertTrue(e.inScope(host: "10.1.2.3").isInScope)
        XCTAssertTrue(e.inScope(host: "10.255.255.255").isInScope)
        XCTAssertFalse(e.inScope(host: "11.0.0.1").isInScope)
        XCTAssertFalse(e.inScope(host: "9.255.255.255").isInScope)
    }

    // MARK: external-review (DeepSeek/Grok) regression pins

    func testReview_slashZeroCidrIsRefusedNotEntireInternet() {
        // 0.0.0.0/0 must NOT authorize all of IPv4. The target canonicalizes to "" → excluded.
        let t = SecurityTarget(kind: .cidr, value: "0.0.0.0/0")
        XCTAssertEqual(t.value, "")
        let e = eng([t])
        XCTAssertFalse(e.isAuthorized)                               // only an empty target ⇒ unauthorized
        XCTAssertFalse(e.inScope(host: "8.8.8.8").isInScope)
    }

    func testReview_overlyBroadCidrBelowFloorIsRefused() {
        for broad in ["10.0.0.0/4", "1.0.0.0/1", "0.0.0.0/7"] {
            XCTAssertEqual(SecurityTarget(kind: .cidr, value: broad).value, "", "\(broad) must be refused")
        }
        // a /8 is exactly the floor — still allowed.
        XCTAssertEqual(SecurityTarget(kind: .cidr, value: "10.0.0.0/8").value, "10.0.0.0/8")
    }

    func testReview_malformedCidrCanonicalizesToEmpty() {
        for bad in ["10.0.0.0", "10.0.0.0/33", "garbage/24", "10.0.0.0/x"] {
            XCTAssertEqual(SecurityTarget(kind: .cidr, value: bad).value, "", "\(bad) must canonicalize empty")
        }
    }

    func testReview_wildcardStarDotNormalizesToParent() {
        let t = SecurityTarget(kind: .wildcard, value: "*.example.com")
        XCTAssertEqual(t.value, "example.com")
        let e = eng([t])
        XCTAssertTrue(e.inScope(host: "api.example.com").isInScope)  // subdomain in scope
        XCTAssertFalse(e.inScope(host: "example.com").isInScope)     // wildcard still excludes apex
    }

    func testCidrSlash32IsSingleHost() {
        let e = eng([SecurityTarget(kind: .cidr, value: "192.168.1.50/32")])
        XCTAssertTrue(e.inScope(host: "192.168.1.50").isInScope)
        XCTAssertFalse(e.inScope(host: "192.168.1.51").isInScope)
    }

    func testMalformedIpIsNotMatchedByCidr() {
        let e = eng([SecurityTarget(kind: .cidr, value: "10.0.0.0/8")])
        XCTAssertFalse(e.inScope(host: "10.0.0.256").isInScope)   // octet > 255 → not an IP → out
        XCTAssertFalse(e.inScope(host: "10.0.0").isInScope)
    }

    // MARK: repo scope (separate axis from host)

    func testRepoScopeIsExactAndSeparateFromHost() {
        let e = eng([SecurityTarget(kind: .repo, value: "Acme/Web")])
        XCTAssertTrue(e.inScope(repo: "acme/web").isInScope)
        XCTAssertFalse(e.inScope(repo: "acme/web-2").isInScope)
        XCTAssertFalse(e.inScope(host: "acme/web").isInScope)     // a repo target never authorizes a host
    }

    // MARK: mixed scope — first matching target wins, rest still fail-closed

    func testMixedTargetsResolveIndependently() {
        let e = eng([
            SecurityTarget(kind: .domain, value: "example.com"),
            SecurityTarget(kind: .cidr, value: "203.0.113.0/24"),
        ])
        XCTAssertTrue(e.inScope(host: "api.example.com").isInScope)
        XCTAssertTrue(e.inScope(host: "203.0.113.7").isInScope)
        XCTAssertFalse(e.inScope(host: "example.net").isInScope)
        XCTAssertFalse(e.inScope(host: "203.0.114.7").isInScope)
    }

    // MARK: Codable round-trip (engagements are persisted as durable authorization evidence)

    func testCodableRoundTrip() throws {
        let e = eng([SecurityTarget(kind: .domain, value: "example.com"),
                     SecurityTarget(kind: .cidr, value: "10.0.0.0/8")])
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(SecurityEngagement.self, from: data)
        XCTAssertEqual(e, back)
        XCTAssertTrue(back.inScope(host: "api.example.com").isInScope)
    }
}
