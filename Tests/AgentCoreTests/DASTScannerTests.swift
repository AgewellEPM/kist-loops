import XCTest
@testable import AgentCore

/// DAST's one inviolable rule: a probe the gate refuses is NEVER sent. The network prober must not be called
/// for an out-of-scope / automation-banned / over-rate / wrong-class probe. Allowed probes execute and feed
/// the (still fail-closed) verify spine.
final class DASTScannerTests: XCTestCase {

    /// Records how many times it was actually called — the proof a refused probe never fires.
    final class CountingProber: NetworkProber, @unchecked Sendable {
        var calls = 0
        var looksVulnerable = true
        func probe(_ p: DASTProbe) async -> ProbeObservation {
            calls += 1
            return ProbeObservation(evidence: "reflected <script> at \(p.path)", looksVulnerable: looksVulnerable)
        }
    }

    func engagement() -> SecurityEngagement {
        SecurityEngagement(id: "acme", program: "HackerOne: Acme", attestedBy: "luke",
                           attestedAtISO: "2026-06-30T00:00:00Z",
                           targets: [SecurityTarget(kind: .domain, value: "example.com")],
                           safeHarbor: true, rulesURL: nil, testingLimits: [])
    }
    func rules(automation: AutomationPolicy = .allowed, rate: Double? = 5,
               classes: Set<String> = ["xss"]) -> BountyProgramRules {
        BountyProgramRules(automation: automation, maxRequestsPerSecond: rate, allowedVulnClasses: classes)
    }
    func probe(host: String = "api.example.com", vulnClass: String = "xss", rps: Double? = 1) -> DASTProbe {
        DASTProbe(targetHost: host, path: "/search?q=<script>", vulnClass: vulnClass,
                  method: .activeScan, requestsPerSecond: rps)
    }

    func testInScopeProbeExecutes() async {
        let prober = CountingProber()
        let results = await DASTScanner(prober: prober).scan([probe()], engagement: engagement(), rules: rules())
        XCTAssertEqual(prober.calls, 1)
        if case .executed = results[0].outcome {} else { XCTFail("expected executed") }
    }

    func testOutOfScopeProbeIsNeverSent() async {
        let prober = CountingProber()
        let results = await DASTScanner(prober: prober).scan([probe(host: "evil.com")], engagement: engagement(), rules: rules())
        XCTAssertEqual(prober.calls, 0, "an out-of-scope probe must NEVER touch the network")
        if case .refused(_, let rule) = results[0].outcome { XCTAssertEqual(rule, "scope.host-out-of-scope") } else { XCTFail() }
    }

    func testAutomationBannedProbeIsNeverSent() async {
        let prober = CountingProber()
        _ = await DASTScanner(prober: prober).scan([probe()], engagement: engagement(), rules: rules(automation: .banned))
        XCTAssertEqual(prober.calls, 0)
    }

    func testOverRateProbeIsNeverSent() async {
        let prober = CountingProber()
        let results = await DASTScanner(prober: prober).scan([probe(rps: 50)], engagement: engagement(), rules: rules(rate: 5))
        XCTAssertEqual(prober.calls, 0)
        if case .refused(_, let rule) = results[0].outcome { XCTAssertEqual(rule, "rate.over-limit") } else { XCTFail() }
    }

    func testWrongClassProbeIsNeverSent() async {
        let prober = CountingProber()
        _ = await DASTScanner(prober: prober).scan([probe(vulnClass: "rce")], engagement: engagement(), rules: rules(classes: ["xss"]))
        XCTAssertEqual(prober.calls, 0)
    }

    func testMixedBatchOnlyFiresAllowedProbes() async {
        let prober = CountingProber()
        let batch = [probe(), probe(host: "evil.com"), probe(vulnClass: "rce"), probe()]
        let results = await DASTScanner(prober: prober).scan(batch, engagement: engagement(), rules: rules())
        XCTAssertEqual(prober.calls, 2, "only the 2 in-scope, in-class probes fire")
        XCTAssertEqual(results.filter { if case .executed = $0.outcome { return true }; return false }.count, 2)
    }

    func testCandidatesOnlyFromVulnerableExecutedProbes() async {
        let prober = CountingProber(); prober.looksVulnerable = true
        let results = await DASTScanner(prober: prober).scan([probe()], engagement: engagement(), rules: rules())
        let cands = DASTScanner(prober: prober).candidates(from: results)
        XCTAssertEqual(cands.count, 1)
        XCTAssertEqual(cands[0].1.targetHost, "api.example.com")   // the drafted PoC targets the probed host
        XCTAssertEqual(cands[0].1.vulnClass, "xss")
    }

    func testNonVulnerableProbeProducesNoCandidate() async {
        let prober = CountingProber(); prober.looksVulnerable = false
        let results = await DASTScanner(prober: prober).scan([probe()], engagement: engagement(), rules: rules())
        XCTAssertTrue(DASTScanner(prober: prober).candidates(from: results).isEmpty)
    }
}
