import Foundation

// MARK: - DAST: gated active probing of a RUNNING target (thread #3)
//
// Source recon (ReconPipeline) reads code we hold. DAST tests a LIVE system — which is exactly where an
// unauthorized request becomes a crime. So the ONE inviolable rule: every probe is routed through
// `BountyGate` (scope + program rules + rate) BEFORE it can fire, and a refused probe is NEVER executed —
// the network prober is not even called. Any candidate finding a probe surfaces is still UNPROVEN: it flows
// into the SAME verify spine (BountyFindingVerifier) — reproduced + panel-reviewed — before it's report-ready.

/// One intended active probe. Its `.action` is what the gate evaluates; it is always automated + active.
public struct DASTProbe: Sendable, Equatable {
    public let targetHost: String
    public let path: String          // endpoint/path being probed (for evidence + the drafted finding)
    public let vulnClass: String     // must be in the program's accepted classes
    public let method: TestMethod    // .activeScan or .exploitPoC
    public let requestsPerSecond: Double?

    public init(targetHost: String, path: String, vulnClass: String,
                method: TestMethod = .activeScan, requestsPerSecond: Double? = nil) {
        self.targetHost = targetHost; self.path = path; self.vulnClass = vulnClass
        self.method = method; self.requestsPerSecond = requestsPerSecond
    }

    public var action: BountyAction {
        BountyAction(targetHost: targetHost, vulnClass: vulnClass, method: method,
                     isAutomated: true, requestsPerSecond: requestsPerSecond)
    }
}

/// What a probe observed against the live target. `looksVulnerable` is a LEAD, not a verdict — it still has
/// to reproduce + survive the panel. Evidence is redacted through the finding pipeline downstream.
public struct ProbeObservation: Sendable, Equatable {
    public let evidence: String
    public let looksVulnerable: Bool
    public init(evidence: String, looksVulnerable: Bool) { self.evidence = evidence; self.looksVulnerable = looksVulnerable }
}

/// Executes ONE authorized probe against the live target. Real implementations do the HTTP/network work;
/// tests inject a stub. CONTRACT: the scanner only ever calls this AFTER `BountyGate` has allowed the probe.
public protocol NetworkProber: Sendable {
    func probe(_ probe: DASTProbe) async -> ProbeObservation
}

public enum DASTProbeOutcome: Sendable, Equatable {
    case refused(reason: String, rule: String?)          // gate said no — the prober was NOT called
    case executed(observation: ProbeObservation)
}

public struct DASTScanResult: Sendable, Equatable {
    public let probe: DASTProbe
    public let outcome: DASTProbeOutcome
}

public struct DASTScanner: Sendable {
    public let gate: BountyGate
    public let prober: NetworkProber

    public init(gate: BountyGate = BountyGate(), prober: NetworkProber) {
        self.gate = gate; self.prober = prober
    }

    /// Gate every probe, execute only the allowed ones. A refused probe never touches the network.
    public func scan(_ probes: [DASTProbe],
                     engagement: SecurityEngagement,
                     rules: BountyProgramRules) async -> [DASTScanResult] {
        var out: [DASTScanResult] = []
        for probe in probes {
            let decision = gate.evaluate(probe.action, engagement: engagement, rules: rules)
            guard decision.isAllowed else {
                out.append(DASTScanResult(probe: probe, outcome: .refused(reason: decision.reason, rule: decision.ruleHit)))
                continue   // fail-closed: do NOT call the prober
            }
            let obs = await prober.probe(probe)
            out.append(DASTScanResult(probe: probe, outcome: .executed(observation: obs)))
        }
        return out
    }

    /// Turn probes that LOOK vulnerable into candidate findings (+ drafted PoCs) for the verify spine. These
    /// are unproven leads — BountyFindingVerifier must reproduce + panel them before they're report-ready.
    public func candidates(from results: [DASTScanResult]) -> [(SecurityFinding, ProofOfConcept)] {
        results.compactMap { r in
            guard case .executed(let obs) = r.outcome, obs.looksVulnerable else { return nil }
            let p = r.probe
            let finding = SecurityFinding(
                severity: .high, category: .codeInjection, rule: "dast:\(p.vulnClass)",
                title: "Live \(p.vulnClass) at \(p.targetHost)\(p.path)", file: "\(p.targetHost)\(p.path)",
                line: 1, evidence: obs.evidence, recommendation: "Validate + fix the \(p.vulnClass) surface.",
                owasp: nil)
            let poc = ProofOfConcept(
                findingId: finding.id, summary: "live \(p.vulnClass) probe", method: p.method,
                targetHost: p.targetHost, targetRepo: nil, vulnClass: p.vulnClass,
                requestsPerSecond: p.requestsPerSecond,
                reproSteps: "Re-issue the probe to \(p.targetHost)\(p.path) (rate-limited, in-scope).",
                expectedSignal: obs.evidence)
            return (finding, poc)
        }
    }
}
