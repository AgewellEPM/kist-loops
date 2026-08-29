import Foundation

/// The CLOSED self-evolution loop — the organ kist was missing. Until now `SelfEvolutionEngine.decide()`
/// ended at a text brief; nothing authored code, ran a gate, or shipped. This composes the full
/// propose → gate → veto → adversary → promote pipeline the field runs, but bottoms out on kist's OWN,
/// sounder admission gate instead of a self-scored number — so it cannot growth-hack.
///
/// The soundness ceiling is honest and enforced in the ordering below:
///   1. author (NEURAL, injected)                — writes a candidate + its own tests in a sandbox
///   2. regression/integrity gate (SYMBOLIC)     — CIIntegrityGuard (no test-gaming) + real build/test
///   3. symbolic contradiction veto              — jeeves-floor; a veto the author cannot argue with
///   4. adversarial review                       — distinct provider by default; explicit fresh same-model grade
///   5. advisory promote gate                     — nominates only if 2+4 both hold
///   6. monotonic held-out invariant (P3)        — a previously-passing held-out case may NEVER regress
/// Every "reject" is safe by construction (a filter has no laundering surface). Surviving every advisory
/// filter still ends in `.quarantinedHardContainment`; this API has no hard execution authority and therefore
/// cannot ship any `SelfChangeKind`.
public enum EvolutionOutcome: String, Sendable, Equatable, Codable {
    case promoted              // reserved for a future separately typed hard-contained promotion path
    case quarantinedHardContainment // advisory gates passed, but no hard execution authority exists
    case notApplicable         // not an auto-evolvable extendTool (foreign → spec; other kinds → their path)
    case skippedByLedger       // loop-guard refused (already resolved / rate-capped)
    case authorFailed          // the author produced no candidate
    case rejectedSameProvider  // FAIL-CLOSED: adversary shares the author's provider ⇒ self-certification
    case quarantinedSameModel  // useful advisory self-review, but never identity-distinct promotion authority
    case rejectedGate          // CIIntegrityGuard / build-test (P2) rejected it
    case rejectedVeto          // jeeves-floor symbolic contradiction (P3-veto)
    case rejectedAdversary     // adversarial reviewer broke it, or promote gate held (P4)
    case rejectedRegression    // P3: applying the change regressed a previously-passing held-out case (hard reject)
}

public struct EvolutionResult: Sendable, Equatable {
    public let outcome: EvolutionOutcome
    public let toolName: String?
    public let reason: String
    public let review: EvolutionReviewReceipt?
    public var promoted: Bool { outcome == .promoted }

    public init(outcome: EvolutionOutcome, toolName: String?, reason: String,
                review: EvolutionReviewReceipt? = nil) {
        self.outcome = outcome
        self.toolName = toolName
        self.reason = reason
        self.review = review
    }
}

/// A candidate self-change the author produced in a sandbox. NOT yet promoted. `kind` (P3) generalizes this
/// beyond tools: the SAME struct now carries a prompt or router-policy change, each confined to its own
/// reserved namespace (`kind.identityPrefix`). `toolName` is the candidate's IDENTITY (name for a tool;
/// label for a prompt/router change) and MUST start with that prefix.
public struct CapabilityCandidate: Sendable, Equatable {
    public let toolName: String        // the candidate's identity — MUST start with kind.identityPrefix
    public let workdir: String         // sandbox path holding the proposed artifact + its tests/eval
    public let contract: String        // NL behavior contract — the input to the symbolic veto (P3)
    public let authorProvider: String  // which provider wrote it — distinct by default (P4)
    public let authorModel: String?
    public let authorCanonicalIdentity: String
    public let authorInvocationID: String
    public let kind: SelfChangeKind    // P3: which kind of self-change this is (defaults to .tool)
    public init(toolName: String, workdir: String, contract: String, authorProvider: String,
                authorModel: String? = nil, authorCanonicalIdentity: String? = nil,
                authorInvocationID: String = UUID().uuidString,
                kind: SelfChangeKind = .tool) {
        self.toolName = toolName; self.workdir = workdir; self.contract = contract
        self.authorProvider = authorProvider
        self.authorModel = authorModel
        self.authorCanonicalIdentity = authorCanonicalIdentity
            ?? authorProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                + ":" + (authorModel ?? "default").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.authorInvocationID = authorInvocationID
        self.kind = kind
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

/// P4. The adversarial reviewer. The default grade MUST use a different provider than the author; the sole
/// explicit exception is a fresh-context same-model review, which is weaker and never labeled independent.
public protocol CapabilityAdversary: Sendable {
    var provider: String { get }
    var reviewContext: EvolutionReviewContext { get }
    func attack(_ candidate: CapabilityCandidate) async -> AdversaryVerdict
}

public struct ClosedEvolutionLoop: Sendable {

    /// Run one candidate through the advisory pipeline. Pure control flow keeps every path testable, but
    /// this API cannot return `.promoted`; a would-be winner is explicitly hard-containment quarantined.
    public static func run(
        decision: SelfEvolutionDecision,
        author: CapabilityAuthor,
        gate: CandidateGate,
        veto: SymbolicVeto,
        adversary: CapabilityAdversary,
        regression: RegressionInvariant? = nil,
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
        // P3 — kind-aware namespace boundary: a promoted change MUST land in its kind's RESERVED namespace
        // (self__ for a tool, selfprompt__ / selfrouter__ for the other kinds). This is the mechanical limit
        // on what evolution can register, generalized from the old tool-only self__ check.
        guard cand.toolName.hasPrefix(cand.kind.identityPrefix) else {
            return EvolutionResult(outcome: .rejectedGate, toolName: cand.toolName,
                                   reason: "candidate ‘\(cand.toolName)’ is outside the \(cand.kind.rawValue) namespace ‘\(cand.kind.identityPrefix)’")
        }

        // P4 PRECONDITION — validate the requested review grade and invocation isolation BEFORE any review
        // can count as evidence. The default remains provider-distinct. The explicit same-model grade is
        // accepted only for the exact same canonical provider/model identity and can never claim independence.
        let reviewContext = adversary.reviewContext
        let authorProvider = cand.authorProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let criticProvider = reviewContext.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let advertisedProvider = adversary.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let authorIdentity = cand.authorCanonicalIdentity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let criticIdentity = reviewContext.canonicalIdentity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let separateInvocation = !cand.authorInvocationID.isEmpty
            && !reviewContext.invocationID.isEmpty
            && cand.authorInvocationID != reviewContext.invocationID
        let identitiesWellFormed = authorIdentity.hasPrefix(authorProvider + ":")
            && criticIdentity.hasPrefix(criticProvider + ":")
            && advertisedProvider == criticProvider
        guard identitiesWellFormed, reviewContext.freshConversation, separateInvocation else {
            return EvolutionResult(
                outcome: .rejectedSameProvider, toolName: cand.toolName,
                reason: "review invocation contract failed (freshConversation=\(reviewContext.freshConversation), separateInvocation=\(separateInvocation)) — refusing review evidence")
        }

        let independent: Bool
        switch reviewContext.grade {
        case .independent:
            guard authorProvider != criticProvider else {
                return EvolutionResult(
                    outcome: .rejectedSameProvider, toolName: cand.toolName,
                    reason: "adversary provider == author provider (\(cand.authorProvider)); independent review requires a distinct provider")
            }
            independent = true
        case .freshContextSameModel:
            guard authorIdentity == criticIdentity else {
                return EvolutionResult(
                    outcome: .rejectedSameProvider, toolName: cand.toolName,
                    reason: "fresh_context_same_model requires identical canonical author/critic identities (author=\(authorIdentity), critic=\(criticIdentity), independent=false)")
            }
            independent = false
        }
        let reviewReceipt = EvolutionReviewReceipt(
            grade: reviewContext.grade,
            independent: independent,
            authorIdentity: authorIdentity,
            criticIdentity: criticIdentity,
            authorInvocationID: cand.authorInvocationID,
            criticInvocationID: reviewContext.invocationID,
            freshConversation: reviewContext.freshConversation,
            separateInvocation: separateInvocation)

        // P2 — regression + integrity gate (CIIntegrityGuard + real build/test). Reject-only.
        let g = await gate.verify(cand)
        guard g.passed else {
            // No critic attack occurred, so do not emit an execution-looking review receipt.
            return EvolutionResult(outcome: .rejectedGate, toolName: cand.toolName, reason: g.reason)
        }

        // P3 — symbolic contradiction veto. A jeeves veto overrides the neural author. Abstain = pass.
        let v = await veto.veto(contract: cand.contract)
        if v.vetoed {
            // No critic attack occurred, so do not emit an execution-looking review receipt.
            return EvolutionResult(outcome: .rejectedVeto, toolName: cand.toolName, reason: v.reason)
        }

        // P4 — adversarial review + promote rule. Review-grade identity constraints were enforced above;
        // shipping still requires a grounded attack at or above minConfidence.
        let av = await adversary.attack(cand)
        let decisionGate = AdversarialPromoteGate.decide(ownTestsPassed: g.passed, adversary: av,
                                                         reviewGrade: reviewContext.grade,
                                                         minConfidence: promoteMinConfidence)
        guard decisionGate.promote else {
            let heldOutcome: EvolutionOutcome = reviewContext.grade == .freshContextSameModel
                && av.survived && av.confidence >= promoteMinConfidence
                ? .quarantinedSameModel : .rejectedAdversary
            return EvolutionResult(outcome: heldOutcome, toolName: cand.toolName,
                                   reason: decisionGate.reason, review: reviewReceipt)
        }

        // P3 — MONOTONIC held-out invariant (anti-gaming, HARD reject). Even after passing the gate + adversary,
        // a change that regresses a previously-passing held-out case at frozen difficulty is refused — no
        // adversary confidence can override it. Skipped when no regression organ is injected (tool path
        // unchanged until wired). This is where a "looks better but quietly breaks things" change dies.
        if let regression {
            let before = await regression.baselinePassing()
            let after = await regression.passingWith(cand)
            let inv = HeldOutInvariant.notRegressed(before: before, after: after)
            guard inv.ok else {
                return EvolutionResult(outcome: .rejectedRegression, toolName: cand.toolName,
                                       reason: inv.reason, review: reviewReceipt)
            }
        }

        // The injected gate/adversary protocols return advisory booleans and prose, not a host-validated
        // hard-containment capability bound to every candidate execution. This API deliberately accepts no
        // optional/default-able receipt: until a separate hard-contained execution path is implemented, a
        // would-be winner is quarantined and can never become promotion authority.
        return EvolutionResult(
            outcome: .quarantinedHardContainment, toolName: cand.toolName,
            reason: "quarantined: advisory gate + symbolic veto + \(reviewContext.grade.evidenceLabel) passed (\(av.confidence)), but no validated hard-containment execution authority is wired",
            review: reviewReceipt)
    }

    /// P5: map a loop outcome to the durable ledger string so the loop-guard's dedup ACTUALLY fires next
    /// time (before this, the live path only ever wrote "attempted", so `decideShouldAttempt` could dedup
    /// nothing — a resolved evolution could be retried forever). nil ⇒ don't record (not a real attempt).
    ///   promoted            → "promoted"          (done — never redo)
    ///   containment hold    → "blocked"           (retryable after the missing authority is wired)
    ///   any reject          → "rejected"          (the gate/adversary already said no — don't retry the same)
    ///   notApplicable/skip  → nil                 (foreign spec-only handled elsewhere; ledger-skip already logged)
    public static func ledgerOutcome(for outcome: EvolutionOutcome) -> String? {
        switch outcome {
        case .promoted: return "promoted"
        case .quarantinedHardContainment: return "blocked"
        case .rejectedGate, .rejectedVeto, .rejectedAdversary, .rejectedSameProvider,
             .quarantinedSameModel, .rejectedRegression, .authorFailed: return "rejected"
        case .notApplicable, .skippedByLedger: return nil
        }
    }
}
