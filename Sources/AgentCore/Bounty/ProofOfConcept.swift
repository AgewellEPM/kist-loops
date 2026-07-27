import Foundation

// MARK: - Proof-of-Concept: the reproducibility half of the verify spine
//
// The plan's hard rule: "every candidate finding must produce a REPRODUCIBLE PoC … can't reproduce it →
// it's a false positive → DROPPED." That is the moat — in a market drowning in AI-slop reports, only
// what actually reproduces gets you off the ban list. A PoC is the recipe; a `PoCReproducer` re-runs it
// and reports whether the expected signal actually showed up. Reproduction is itself an ACTION against a
// target, so it is gated by `BountyGate` (scope + rules) BEFORE any traffic is sent.

public struct ProofOfConcept: Sendable, Codable, Equatable {
    public let findingId: String        // ties back to the SecurityFinding this proves
    public let summary: String
    public let method: TestMethod       // how it reproduces (typically .exploitPoC or .activeScan)
    public let targetHost: String?
    public let targetRepo: String?
    public let vulnClass: String        // canonical lowercase; must match the program's accepted classes
    public let requestsPerSecond: Double?
    public let reproSteps: String       // the exact request / command / steps to reproduce
    public let expectedSignal: String   // the observable that PROVES the vuln (e.g. "reflects <script> unescaped")

    public init(findingId: String, summary: String, method: TestMethod = .exploitPoC,
                targetHost: String? = nil, targetRepo: String? = nil, vulnClass: String,
                requestsPerSecond: Double? = nil, reproSteps: String, expectedSignal: String) {
        self.findingId = findingId
        self.summary = summary
        self.method = method
        self.targetHost = targetHost
        self.targetRepo = targetRepo
        self.vulnClass = vulnClass
        self.requestsPerSecond = requestsPerSecond
        self.reproSteps = reproSteps
        self.expectedSignal = expectedSignal
    }

    /// The action the reproducer will take. It is ALWAYS automated (a tool re-runs it) and never a
    /// submission — so `BountyGate` evaluates it as active target traffic and can refuse it out-of-scope,
    /// rate-over-budget, wrong vuln-class, or against a program that bans automation.
    public var reproAction: BountyAction {
        BountyAction(targetHost: targetHost, targetRepo: targetRepo, vulnClass: vulnClass,
                     method: method, isAutomated: true, requestsPerSecond: requestsPerSecond, isSubmission: false)
    }
}

/// The outcome of re-running a PoC. `reproduced == true` means the expected signal was observed — the only
/// thing that lets a finding become report-ready. Default toward NOT reproduced when uncertain.
public struct ReproResult: Sendable, Codable, Equatable {
    public let reproduced: Bool
    public let observed: String
    public init(reproduced: Bool, observed: String) {
        self.reproduced = reproduced
        self.observed = observed
    }
}

/// Re-runs a PoC and reports whether it reproduced. Real implementations execute the scoped request/command
/// inside the sandbox; tests inject deterministic stubs. A reproducer MUST only be invoked AFTER `BountyGate`
/// has authorized `poc.reproAction` — it is not itself an authorization boundary, it is the observation.
public protocol PoCReproducer: Sendable {
    func reproduce(_ poc: ProofOfConcept) async -> ReproResult
}
