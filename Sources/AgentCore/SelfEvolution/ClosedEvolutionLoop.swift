import Foundation

/// The CLOSED self-evolution loop — the organ kist was missing. Until now `SelfEvolutionEngine.decide()`
/// ended at a text brief; nothing authored code, ran a gate, or shipped. This composes the full
/// propose → gate → veto → adversary → promote pipeline the field runs, but bottoms out on kist's OWN,
/// sounder admission gate instead of a self-scored number — so it cannot growth-hack.
///
/// The soundness ceiling is honest and enforced in the ordering below:
///   1. author (NEURAL, injected)                — writes a candidate + its own tests in a sandbox
///   2. regression/integrity gate (P2, SYMBOLIC) — CIIntegrityGuard (no test-gaming) + real build/test
///   3. symbolic contradiction veto (P3)         — jeeves-floor; a veto the author cannot argue with
///   4. independent adversary (P4)               — a DIFFERENT provider must fail to break it
///   5. promote gate (AdversarialPromoteGate)    — ships only if 2+4 both hold
/// Every "reject" is safe by construction (a filter has no laundering surface). Only step 5 ships, and it
/// ships ONLY into the `self__` runtime namespace — never a user-facing path unattended.
public enum EvolutionOutcome: String, Sendable, Equatable, Codable {
    case promoted              // survived every gate — register into the self__ namespace
    case notApplicable         // not an auto-evolvable extendTool (foreign → spec; other kinds → their path)
    case skippedByLedger       // loop-guard refused (already resolved / rate-capped)
    case authorFailed          // the author produced no candidate
    case rejectedSameProvider  // FAIL-CLOSED: adversary shares the author's provider ⇒ self-certification
    case rejectedGate          // CIIntegrityGuard / build-test (P2) rejected it
    case rejectedVeto          // jeeves-floor symbolic contradiction (P3)
    case rejectedAdversary     // independent adversary broke it, or promote gate held (P4)
}

public struct EvolutionResult: Sendable, Equatable {
    public let outcome: EvolutionOutcome
    public let toolName: String?
    public let reason: String
    public var promoted: Bool { outcome == .promoted }
}

/// A candidate capability the author produced in a sandbox. NOT yet callable.
public struct CapabilityCandidate: Sendable, Equatable {
    public let toolName: String        // MUST be in the self__ namespace
    public let workdir: String         // sandbox path holding the source + tests
    public let contract: String        // NL behavior contract — the input to the symbolic veto (P3)
    public let authorProvider: String  // which provider wrote it — enforced ≠ adversary provider (P4)
    public init(toolName: String, workdir: String, contract: String, authorProvider: String) {
        self.toolName = toolName; self.workdir = workdir; self.contract = contract
        self.authorProvider = authorProvider
    }
}

// MARK: - Injected organs (real implementations at the edge; fakes in tests)

/// NEURAL. Writes a candidate tool + its own tests into a sandbox. Returns nil if it can't.
public protocol CapabilityAuthor: Sendable {
    func author(brief: String, culpritTool: String, signature: String) async -> CapabilityCandidate?
}

/// P2. The regression + integrity gate. Real impl wraps `GreatLoopVerifier` (CIIntegrityGuard +
/// CompletionVerifier) over the candidate's sandbox diff.
public protocol CandidateGate: Sendable {
    func verify(_ candidate: CapabilityCandidate) async -> (passed: Bool, reason: String)
}

/// P3. The symbolic contradiction veto. Real impl calls jeeves-floor `check_contradiction` on the contract.
/// HONEST: this is a VETO oracle, not a proof — it rejects a contradiction, it never certifies correctness,
/// and it abstains (no veto) outside its covered domains.
public protocol SymbolicVeto: Sendable {
    func veto(contract: String) async -> (vetoed: Bool, reason: String)
}

/// P4. The independent adversary — MUST run on a different provider than the author.
public protocol CapabilityAdversary: Sendable {
    var provider: String { get }
    func attack(_ candidate: CapabilityCandidate) async -> AdversaryVerdict
}

public struct ClosedEvolutionLoop: Sendable {

    /// Run one candidate through the whole pipeline. Pure control flow over injected organs + the real
    /// promote gate, so every path is testable. The caller performs the actual ACTIVATION (registering the
    /// self__ tool) only on `.promoted`, and records the outcome to the ledger.
    public static func run(
        decision: SelfEvolutionDecision,
        author: CapabilityAuthor,
        gate: CandidateGate,
        veto: SymbolicVeto,
        adversary: CapabilityAdversary,
        promoteMinConfidence: Double = 0.6
    ) async -> EvolutionResult {

        // Only a native/self-authored `extendTool` is an auto-evolve target. Foreign tools are spec-only
        // (never blend repos); other recovery kinds ride their own path. The ledger guard already ran in
        // SelfEvolutionEngine.decide() (decision.skipped) — respect it.
        guard decision.kind == .extendTool else {
            return EvolutionResult(outcome: .notApplicable, toolName: decision.culpritTool,
                                   reason: "recovery is \(decision.kind.rawValue), not an auto-evolve")
        }
        if let skip = decision.skipped {
            return EvolutionResult(outcome: .skippedByLedger, toolName: decision.culpritTool, reason: skip)
        }
        guard decision.ownership == .kist || decision.ownership == .selfAuthored else {
            return EvolutionResult(outcome: .notApplicable, toolName: decision.culpritTool,
                                   reason: "\(decision.culpritTool ?? "tool") is foreign — spec-only, never auto-evolve")
        }

        // P1 — author the candidate (neural, sandboxed).
        guard let cand = await author.author(brief: decision.brief,
                                             culpritTool: decision.culpritTool ?? "",
                                             signature: decision.signature ?? "") else {
            return EvolutionResult(outcome: .authorFailed, toolName: decision.culpritTool,
                                   reason: "author produced no candidate")
        }
        // A self-authored tool MUST land in the self__ namespace — mechanical boundary on what evolution creates.
        guard cand.toolName.hasPrefix(kistSelfAuthoredPrefix) else {
            return EvolutionResult(outcome: .rejectedGate, toolName: cand.toolName,
                                   reason: "candidate ‘\(cand.toolName)’ is outside the self__ namespace")
        }

        // P4 PRECONDITION — provider-distinctness, FAIL-CLOSED. If author and adversary share a provider the
        // gate is self-certification with extra steps (the exact thing AdversarialPromoteGate exists to stop).
        guard adversary.provider != cand.authorProvider else {
            return EvolutionResult(outcome: .rejectedSameProvider, toolName: cand.toolName,
                                   reason: "adversary provider == author provider (\(cand.authorProvider)) — refusing to self-certify")
        }

        // P2 — regression + integrity gate (CIIntegrityGuard + real build/test). Reject-only.
        let g = await gate.verify(cand)
        guard g.passed else {
            return EvolutionResult(outcome: .rejectedGate, toolName: cand.toolName, reason: g.reason)
        }

        // P3 — symbolic contradiction veto. A jeeves veto overrides the neural author. Abstain = pass.
        let v = await veto.veto(contract: cand.contract)
        if v.vetoed {
            return EvolutionResult(outcome: .rejectedVeto, toolName: cand.toolName, reason: v.reason)
        }

        // P4 — independent adversary + the promote rule. Ships only if the gate is green AND a DIFFERENT
        // provider couldn't break it at ≥ minConfidence.
        let av = await adversary.attack(cand)
        let decisionGate = AdversarialPromoteGate.decide(ownTestsPassed: g.passed, adversary: av,
                                                         minConfidence: promoteMinConfidence)
        guard decisionGate.promote else {
            return EvolutionResult(outcome: .rejectedAdversary, toolName: cand.toolName, reason: decisionGate.reason)
        }

        // Survived everything → promote into the self__ runtime namespace (activation at the callsite).
        return EvolutionResult(outcome: .promoted, toolName: cand.toolName,
                               reason: "survived gate + symbolic veto + independent adversary (\(av.confidence))")
    }

    /// P5: map a loop outcome to the durable ledger string so the loop-guard's dedup ACTUALLY fires next
    /// time (before this, the live path only ever wrote "attempted", so `decideShouldAttempt` could dedup
    /// nothing — a resolved evolution could be retried forever). nil ⇒ don't record (not a real attempt).
    ///   promoted            → "promoted"          (done — never redo)
    ///   any reject          → "rejected"          (the gate/adversary already said no — don't retry the same)
    ///   notApplicable/skip  → nil                 (foreign spec-only handled elsewhere; ledger-skip already logged)
    public static func ledgerOutcome(for outcome: EvolutionOutcome) -> String? {
        switch outcome {
        case .promoted: return "promoted"
        case .rejectedGate, .rejectedVeto, .rejectedAdversary, .rejectedSameProvider, .authorFailed: return "rejected"
        case .notApplicable, .skippedByLedger: return nil
        }
    }
}
