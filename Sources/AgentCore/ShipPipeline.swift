import Foundation

/// Hooks up Luke's intended system into ONE flow: a goal is built HANDS-FREE in a sandbox, then the
/// COUNCIL OF MINDS reviews the actual result (diff + tests), and only a council blessing makes it
/// deploy-eligible. This is the pure, testable orchestration — the runner injects the real autopilot
/// build and performs the deploy. FAIL-CLOSED + SAFETY INVARIANT: the council can only make the
/// decision STRICTER, nothing is deploy-eligible without changes, and the deploy itself stays a
/// deliberate, separately-confirmed step (never auto-armed).
public struct ShipPipeline: Sendable {
    /// What the sandboxed build actually produced — the evidence the council judges.
    public struct BuildResult: Sendable, Equatable {
        public var hadChanges: Bool
        public var diffSummary: String
        public var testsPassed: Bool
        public var testSummary: String
        public var signoffSummary: String
        public init(hadChanges: Bool, diffSummary: String, testsPassed: Bool,
                    testSummary: String, signoffSummary: String) {
            self.hadChanges = hadChanges; self.diffSummary = diffSummary; self.testsPassed = testsPassed
            self.testSummary = testSummary; self.signoffSummary = signoffSummary
        }
    }

    public struct Decision: Sendable {
        public var verdict: CouncilPromotionVerdict?   // nil = the build produced nothing to review
        public var canDeploy: Bool                     // council blessed it → eligible (still needs your OK)
        public var reason: String
    }

    private let council: PromotionCouncil
    private let threshold: Int

    public init(council: PromotionCouncil, threshold: Int = 3) {
        self.council = council
        self.threshold = threshold
    }

    /// Review a sandboxed build. No changes ⇒ never deploy-eligible (can't ship nothing). Otherwise the
    /// council of minds judges the real diff/tests and its FAIL-CLOSED tally decides deploy-eligibility.
    public func review(goal: String, build: BuildResult) async -> Decision {
        guard build.hadChanges else {
            return Decision(verdict: nil, canDeploy: false, reason: "nothing was built — no changes to ship")
        }
        let ctx = PromotionContext(goal: goal, diffSummary: build.diffSummary, testsPassed: build.testsPassed,
                                   testSummary: build.testSummary, signoffSummary: build.signoffSummary)
        let verdict = await council.judge(ctx, threshold: threshold)
        return Decision(verdict: verdict, canDeploy: verdict.isShipWorthy, reason: verdict.summary)
    }
}
