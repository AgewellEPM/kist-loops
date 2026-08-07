import Foundation

/// Phase 3 SAFETY CORE — the promote rule Luke chose ("independent adversarial check", never self-certify).
///
/// The insight this encodes: for a capability the AI just WROTE, the regression gate (full test suite) only
/// proves it didn't break EXISTING behavior. The only tests of the NEW capability are the ones the SAME
/// author wrote — so "green ⇒ ship" means the model grades its own homework. That is the exact
/// "unverified work laundered as success" this whole system exists to prevent. Promotion therefore requires
/// an INDEPENDENT vouch: a different model that tries to BREAK the new capability and attacks its tests.
/// Its own tests passing is necessary but never sufficient.
public struct AdversaryVerdict: Sendable, Equatable {
    /// Could the independent adversary NOT break the capability (tried, failed to find a hole)?
    public let survived: Bool
    /// What the adversary found, if it broke it (a bug, a missing case, a test that asserts nothing).
    public let attackFound: String?
    /// How sure the adversary is (0–1). Low confidence on "couldn't break it" ⇒ hold, don't ship on a shrug.
    public let confidence: Double
    public init(survived: Bool, attackFound: String? = nil, confidence: Double) {
        self.survived = survived; self.attackFound = attackFound; self.confidence = confidence
    }
}

public enum AdversarialPromoteGate {

    public struct Decision: Sendable, Equatable {
        public let promote: Bool
        public let reason: String
    }

    /// Decide whether a self-written capability may be PROMOTED to the live binary.
    /// - `ownTestsPassed`: did the full regression gate (incl. the capability's own tests) pass?
    /// - `adversary`: the INDEPENDENT model's attempt to break it.
    /// - `minConfidence`: below this, a "couldn't break it" is a shrug, not a vouch → hold for a human.
    public static func decide(ownTestsPassed: Bool,
                              adversary: AdversaryVerdict,
                              minConfidence: Double = 0.6) -> Decision {
        // 1) Never promote a red build. (Regression net — necessary, not sufficient.)
        guard ownTestsPassed else {
            return Decision(promote: false, reason: "own tests / regression gate failed — never promote a red build")
        }
        // 2) The independent adversary broke it → reject, feed the finding back as the next repair.
        guard adversary.survived else {
            return Decision(promote: false,
                            reason: "independent adversary broke the new capability: \(adversary.attackFound ?? "unspecified hole")")
        }
        // 3) It survived, but the adversary isn't confident → do NOT ship on a weak vouch; hold for a human.
        guard adversary.confidence >= minConfidence else {
            return Decision(promote: false,
                            reason: "survived adversarial review but confidence \(String(format: "%.2f", adversary.confidence)) < \(minConfidence) — hold for a human nod")
        }
        // 4) Green regression gate AND survived a confident independent attack → the only path that ships.
        return Decision(promote: true,
                        reason: "regression gate green AND survived independent adversarial review (\(String(format: "%.2f", adversary.confidence)))")
    }
}
