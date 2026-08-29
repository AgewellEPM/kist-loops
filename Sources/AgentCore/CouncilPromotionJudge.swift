import Foundation

/// THE COUNCIL-OF-MINDS PROMOTION JUDGE — half of Luke's "council decides it's real, worth going live"
/// policy (the other half is the captain's cryptographic gate; see `CaptainGate`).
///
/// Distinct from `AICouncil`, which PLANS work. This council JUDGES a FINISHED, captain-verified
/// integration branch: several minds, each through a DIFFERENT lens (correctness / security / product
/// worth / completeness), vote SHIP or HOLD on the built result. The aggregate is FAIL-CLOSED and
/// VETO-FIRST: a single HOLD from any non-failed mind blocks, and a quorum of SHIP votes is required —
/// because the cost of a false SHIP is a corrupted main, while the cost of a false HOLD is a manual review.
///
/// The council can VETO but it can NEVER AUTHORIZE on its own. `CaptainGate` still requires the captain's
/// crypto sign-off on top. The judgment is advisory INPUT that can only make promotion STRICTER.
public struct PromotionContext: Sendable, Equatable {
    public let goal: String
    public let diffSummary: String        // e.g. `git diff --stat` of the integration branch
    public let testsPassed: Bool
    public let testSummary: String        // e.g. "1959 tests, 0 failures" — or the failure detail
    public let signoffSummary: String     // what the captain actually verified (from the signoff ledger)
    public let completionEvidence: PromotionCompletionEvidence?

    public init(goal: String, diffSummary: String, testsPassed: Bool,
                testSummary: String, signoffSummary: String,
                completionEvidence: PromotionCompletionEvidence? = nil) {
        self.goal = goal; self.diffSummary = diffSummary; self.testsPassed = testsPassed
        self.testSummary = testSummary; self.signoffSummary = signoffSummary
        self.completionEvidence = completionEvidence
    }
}

public struct PromotionMindVote: Sendable, Codable, Equatable {
    public let name: String       // the lens ("Correctness", "Security", …)
    public let shipWorthy: Bool   // SHIP (true) vs HOLD (false)
    public let reason: String
    public let failed: Bool        // the mind's LLM call errored — counts as NEITHER ship nor veto
    /// Concrete route returned by ProviderRegistry after any same-provider model recovery.
    public let providerID: String?
    public let modelID: String?
    /// Host-minted call provenance. A successful same-model review is admissible only when every
    /// completed lens carries a unique invocation ID and was called with a fresh user-only conversation.
    public let invocationID: String?
    public let freshConversation: Bool?

    public init(name: String, shipWorthy: Bool, reason: String, failed: Bool = false,
                providerID: String? = nil, modelID: String? = nil,
                invocationID: String? = nil, freshConversation: Bool? = nil) {
        self.name = name; self.shipWorthy = shipWorthy; self.reason = reason; self.failed = failed
        self.providerID = providerID; self.modelID = modelID
        self.invocationID = invocationID; self.freshConversation = freshConversation
    }
}

public struct CouncilPromotionVerdict: Sendable, Codable, Equatable {
    public let votes: [PromotionMindVote]
    public let isShipWorthy: Bool
    public let threshold: Int
    public let summary: String

    public init(votes: [PromotionMindVote], isShipWorthy: Bool, threshold: Int, summary: String) {
        self.votes = votes; self.isShipWorthy = isShipWorthy; self.threshold = threshold; self.summary = summary
    }

    /// FAIL-CLOSED, VETO-FIRST aggregation. Ship-worthy ONLY when: at least `threshold` non-failed minds
    /// voted SHIP **and** ZERO non-failed minds voted HOLD. A failed mind is neither (it shrinks the SHIP
    /// pool, so if enough minds break you can't reach quorum → fail closed). `threshold` is clamped to ≥1
    /// so an empty/zero threshold can never auto-bless.
    public static func tally(_ votes: [PromotionMindVote], threshold: Int) -> CouncilPromotionVerdict {
        let t = max(1, threshold)
        let voting = votes.filter { !$0.failed }
        let yes = voting.filter { $0.shipWorthy }.count
        let no = voting.filter { !$0.shipWorthy }.count
        let failedCount = votes.count - voting.count
        let ship = (yes >= t) && (no == 0)
        let summary: String
        if ship {
            summary = "council blessed: \(yes)/\(votes.count) SHIP (≥\(t) required), 0 HOLD"
        } else if no > 0 {
            let vetoers = voting.filter { !$0.shipWorthy }.map { $0.name }.joined(separator: ", ")
            summary = "council HELD: \(no) veto(s) [\(vetoers)] — any HOLD blocks promotion"
        } else {
            summary = "council short of quorum: \(yes)/\(votes.count) SHIP, need ≥\(t)"
                + (failedCount > 0 ? " (\(failedCount) mind(s) failed)" : "")
        }
        return CouncilPromotionVerdict(votes: votes, isShipWorthy: ship, threshold: t, summary: summary)
    }
}

public struct CouncilPromotionJudge: Sendable {
    private let providers: ProviderRegistry
    private let roles: RoleBindings
    private let recorder: TraceRecorder?
    private let routePolicy: ProviderRoutePolicy
    private let lensDeadlineNanoseconds: UInt64
    private let lensDeadlineDescription: String

    public init(providers: ProviderRegistry, roles: RoleBindings, recorder: TraceRecorder? = nil,
                lensDeadline: TimeInterval = 60,
                routePolicy: ProviderRoutePolicy = .sameProviderAdaptive) {
        let maximumSeconds = Double(UInt64.max) / 1_000_000_000
        let normalized = lensDeadline.isFinite && lensDeadline > 0
            ? min(lensDeadline, maximumSeconds) : 60
        self.providers = providers; self.roles = roles; self.recorder = recorder
        self.routePolicy = routePolicy
        self.lensDeadlineNanoseconds = UInt64(normalized * 1_000_000_000)
        self.lensDeadlineDescription = String(format: "%.3f seconds", normalized)
    }

    /// One lens = (display name, AgentRole for vendor binding, the judging brief).
    struct Lens: Sendable { let name: String; let role: AgentRole; let brief: String }
    static let lenses: [Lens] = [
        Lens(name: "Correctness", role: .critic, brief:
            "Judge whether the change is CORRECT and the tests genuinely cover it. HOLD if tests are weakened, missing for new behavior, or the diff looks like it games the verifier rather than solving the goal."),
        Lens(name: "Security", role: .critic, brief:
            "Judge security/trust. HOLD if the diff widens an attack surface, leaks secrets, bypasses a gate, escapes its declared scope, or weakens a fail-closed check."),
        Lens(name: "Worth", role: .planner, brief:
            "Judge whether this is REAL and WORTH shipping to main against the goal — not a stub, partial, or demo. HOLD if it doesn't actually accomplish the stated goal."),
        Lens(name: "Completeness", role: .worker, brief:
            "Judge completeness. HOLD if the goal implies sibling sites/edge cases the diff didn't touch, or if 'done' is claimed without the evidence (tests green, in-scope)."),
    ]

    /// Run every lens against the built branch, then FAIL-CLOSED tally. `threshold` defaults to a quorum of
    /// 3 of the 4 lenses (with the zero-veto rule on top). The per-mind LLM call is live (not unit-tested,
    /// like `AICouncil.run`); the tally that decides ship/hold is pure and pinned.
    public func judge(_ ctx: PromotionContext, threshold: Int = 3) async -> CouncilPromotionVerdict {
        let indexedVotes = await withTaskGroup(of: IndexedPromotionVote.self) { group in
            for (index, lens) in Self.lenses.enumerated() {
                group.addTask {
                    IndexedPromotionVote(index: index, vote: await ask(lens, ctx))
                }
            }
            var results: [IndexedPromotionVote] = []
            results.reserveCapacity(Self.lenses.count)
            for await result in group { results.append(result) }
            return results
        }
        let votes = indexedVotes.sorted { $0.index < $1.index }.map(\.vote)
        return CouncilPromotionVerdict.tally(votes, threshold: threshold)
    }

    private func ask(_ lens: Lens, _ ctx: PromotionContext) async -> PromotionMindVote {
        let binding = roles.binding(for: lens.role)
        let prompt = Self.judgePrompt(lens: lens, ctx: ctx)
        let invocationID = "builder-review-\(UUID().uuidString.lowercased())"
        let settings = ModelSettings(temperature: 0.0, maxTokens: 600,
                                     systemPrompt: Self.systemPrompt(lens: lens.name),
                                     disableThinking: true)
        let started = Date()
        let race = CouncilLensDeadlineRace()
        let result = await race.run(timeoutNanoseconds: lensDeadlineNanoseconds) {
            do {
                let completion = try await providers.completeWithRoute(
                    providerId: binding.providerId, model: binding.model,
                    messages: [ChatMessage(role: .user, content: prompt)], settings: settings,
                    routePolicy: routePolicy)
                guard !Task.isCancelled else {
                    return .failure("completion cancelled")
                }
                return .success(completion)
            } catch {
                return .failure(String(describing: error))
            }
        }
        switch result {
        case .success(let completion):
            let actualBinding = ProviderBinding(
                providerId: completion.providerId, model: completion.model)
            await record(role: "promote_\(lens.name.lowercased())", binding: actualBinding,
                         usage: completion.usage, promptChars: prompt.count,
                         completionChars: completion.text.count, started: started, status: .ok)
            let (ship, reason) = Self.parseVote(completion.text)
            return PromotionMindVote(
                name: lens.name, shipWorthy: ship, reason: reason,
                providerID: completion.providerId, modelID: completion.model,
                invocationID: invocationID, freshConversation: true)
        case .failure(let message):
            await record(role: "promote_\(lens.name.lowercased())", binding: binding, usage: .zero,
                         promptChars: prompt.count, completionChars: 0, started: started, status: .error)
            // FAIL-CLOSED: a broken mind is `failed` (neither SHIP nor veto), shrinking the SHIP pool.
            return PromotionMindVote(
                name: lens.name, shipWorthy: false, reason: "FAILED: \(message)", failed: true,
                invocationID: invocationID, freshConversation: true)
        case .deadline:
            await record(role: "promote_\(lens.name.lowercased())", binding: binding, usage: .zero,
                         promptChars: prompt.count, completionChars: 0, started: started, status: .error)
            return PromotionMindVote(
                name: lens.name, shipWorthy: false,
                reason: "review deadline exceeded after \(lensDeadlineDescription)", failed: true,
                invocationID: invocationID, freshConversation: true)
        }
    }

    /// Parse a mind's reply. FAIL-CLOSED: only a LINE that is a clean `VERDICT: SHIP` is approval. We scan
    /// per-line and require the line to START with `VERDICT:` (after trimming) — so "I cannot give VERDICT:
    /// SHIP because…" (H4) is NOT approval, and "VERDICT: SHIPWRECK" is NOT SHIP. HOLD wins ties; anything
    /// without a clean SHIP line is HOLD. Substring search on the whole body is the bug, not the fix.
    /// Explicit trailing characters we'll strip off a verdict token — punctuation + ASCII whitespace only.
    /// NOT a "everything non-alphanumeric" rule, which would also eat zero-width/emoji and let a decorated
    /// "SHIP" pass.
    static let strippableTrailers: Set<Character> = [".", "!", "?", ",", ";", ":", "*", " ", "\t", ")", "]", "\"", "'"]
    /// Line trim uses ONLY ASCII space/tab/CR — NOT `CharacterSet.whitespaces`, which also strips a trailing
    /// zero-width space (so a decorated "SHIP\u{200B}" would normalize to "SHIP" and falsely approve).
    static let asciiLineTrim = CharacterSet(charactersIn: " \t\r")

    static func parseVote(_ text: String) -> (shipWorthy: Bool, reason: String) {
        var sawShip = false, sawHold = false
        for raw in text.split(whereSeparator: { $0 == "\n" }) {
            // CASE-SENSITIVE by contract — NO `.uppercased()`. Unicode case-folding would map a lookalike
            // ("ſHıP" long-s/dotless-i, or "Ship") onto "SHIP". The protocol demands literal uppercase
            // "VERDICT: SHIP"/"VERDICT: HOLD"; anything else → HOLD (fail-closed, a wrong HOLD costs a review).
            let line = raw.trimmingCharacters(in: Self.asciiLineTrim)
            guard line.hasPrefix("VERDICT:") else { continue }
            // The remainder after "VERDICT:" must be EXACTLY SHIP/HOLD (trailing punctuation tolerated, but
            // NOT extra words). So "VERDICT: SHIP." → ship; "VERDICT: SHIPWRECK", "VERDICT: SHIP but … HOLD"
            // → neither (→ HOLD via fail-closed). Stricter than a leading-token grab, which a mixed line beats.
            var rem = String(line.dropFirst("VERDICT:".count)).trimmingCharacters(in: Self.asciiLineTrim)
            // Strip ONLY an explicit allowlist of trailing punctuation/whitespace. Anything else (a digit,
            // a zero-width space, an emoji, any other Unicode) stays in the token, so it won't match SHIP/
            // HOLD → HOLD (fail-closed). "VERDICT: SHIP." → SHIP; "VERDICT: SHIP1"/"SHIP\u{200B}" → HOLD.
            while let last = rem.last, Self.strippableTrailers.contains(last) { rem.removeLast() }
            if rem == "SHIP" { sawShip = true } else if rem == "HOLD" { sawHold = true }
        }
        let reason = extractReason(text)
        if sawHold { return (false, reason) }                 // HOLD wins ties
        if sawShip { return (true, reason) }
        return (false, reason.isEmpty ? "no clean VERDICT: SHIP line — treated as HOLD (fail-closed)" : reason)
    }

    private static func extractReason(_ text: String) -> String {
        for raw in text.split(whereSeparator: { $0 == "\n" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("REASON:") {
                return String(line.dropFirst("REASON:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240).description
    }

    private static func systemPrompt(lens: String) -> String {
        """
        You are the \(lens) judge on an AI promotion council deciding whether a built change is good
        enough to ship. Be skeptical and honest, and judge the ACTUAL built result, not the intent.

        HOLD ONLY for a BLOCKING defect through your lens: the code is broken or doesn't run, it doesn't
        accomplish the goal, it has a real security/trust hole, or risky new logic ships with no coverage.
        Do NOT HOLD for cosmetic or style NITS — a trailing newline, formatting, naming, an unfamiliar
        file type, or minor cleanup. If the change works and meets the goal, vote SHIP and put the nit in
        REASON. A nit is never a reason to block a working change. When a real defect is in doubt, HOLD.

        Answer in EXACTLY this shape, nothing else:
        VERDICT: SHIP   (or)   VERDICT: HOLD
        REASON: <one concrete sentence>
        """
    }

    static func completionEvidencePrompt(_ evidence: PromotionCompletionEvidence?) -> String {
        guard let evidence else {
            return "HOST COMPLETION EVIDENCE: unavailable. HOLD because no typed packet was supplied."
        }
        let commands = evidence.commandReceipts.map {
            "- tool=\($0.tool); verifier=\($0.verifierStatus.rawValue); exit=\($0.exitCode); "
                + "allowed=\($0.allowedExitCodes); semantic=\($0.semanticStatus); "
                + "argsFingerprint=\($0.argsFingerprint); outputSHA256=\($0.outputDigest); "
                + "outputExcerpt=\($0.outputExcerpt); evidenceSHA256=\($0.evidenceDigest)"
        }.joined(separator: "\n")
        let requiredSupport = evidence.requiredSupportingObligations.map {
            "- id=\($0.id); kind=\($0.kind.rawValue)"
        }.joined(separator: "\n")
        let supporting = evidence.supportingCommandReceipts
            .sorted { $0.captureOrdinal < $1.captureOrdinal }
            .map {
                let executable = SecretMasker.mask($0.executable)
                let argv = $0.argv.map(SecretMasker.mask).joined(separator: " | ")
                let cwd = SecretMasker.mask($0.workingDirectory ?? "<default>")
                let excerpt = SecretMasker.mask($0.boundedRedactedOutputExcerpt)
                return "- SUPPORTING ONLY; obligations=\($0.satisfiedObligationIDs.joined(separator: ",")); "
                    + "ordinal=\($0.captureOrdinal); frontier=\($0.mutationFrontierOrdinal.map(String.init) ?? "none"); "
                    + "executable=\(executable); argv=[\(argv)]; cwd=\(cwd); "
                    + "stdinProvided=\($0.hasStandardInput); stdinSHA256=\($0.standardInputDigest ?? "none"); "
                    + "stdinBytes=\($0.standardInputByteCount); exit=\($0.actualExitCode); "
                    + "allowed=\($0.allowedExitCodes); signalled=\($0.wasSignalled); timeout=\($0.timedOut); "
                    + "semantic=\($0.semanticStatus); verificationEligible=\($0.verificationEligible); "
                    + "argsFingerprint=\($0.argsFingerprint); commandFingerprint=\($0.commandFingerprint); "
                    + "outputSHA256=\($0.outputDigest); outputExcerpt=\(excerpt); "
                    + "policyFingerprint=\($0.executionPolicyFingerprint); manifestSHA256=\($0.workspaceManifestDigest); "
                    + "workspaceSHA256=\($0.governedWorkspaceDigest); evidenceSHA256=\($0.evidenceDigest)"
            }.joined(separator: "\n")
        let finalReplay: String
        if let final = evidence.finalVerificationReceipt {
            let executable = SecretMasker.mask(final.invocation.executable)
            let argv = final.invocation.argv.map(SecretMasker.mask).joined(separator: " | ")
            finalReplay = "- FINAL VERIFIER; ordinal=\(final.captureOrdinal); "
                + "executable=\(executable); argv=[\(argv)]; exit=\(final.actualExitCode); "
                + "expected=\(final.expectedExitCode); outputSHA256=\(final.outputDigest); "
                + "outputExcerpt=\(SecretMasker.mask(final.boundedRedactedOutputExcerpt)); "
                + "workspaceSHA256=\(final.governedWorkspaceDigest); evidenceSHA256=\(final.evidenceDigest)"
        } else {
            finalReplay = "- unavailable"
        }
        let checks = evidence.hostChecks.map {
            "- \($0.name): \($0.passed ? "PASS" : "FAIL") — \($0.details)"
        }.joined(separator: "\n")
        let acceptedChildSubjects = evidence.acceptedVerificationSubjectDigests.keys.sorted().map {
            "- node=\($0); verifierSubjectSHA256=\(evidence.acceptedVerificationSubjectDigests[$0]!)"
        }.joined(separator: "\n")
        var mutationLines: [String] = []
        for receipt in evidence.mutationReceipts {
            for operation in receipt.operations {
                let imageDigests = "preimageSHA256=\(operation.preimageSHA256 ?? "absent"); "
                    + "postimageSHA256=\(operation.postimageSHA256 ?? "absent")"
                mutationLines.append(
                    "- node=\(receipt.nodeID); attempt=\(receipt.attempt); "
                        + "kind=\(operation.kind.rawValue); path=\(operation.path); "
                        + imageDigests + "; transactionWorkspaceSHA256=\(receipt.workspaceDigest); "
                        + "verifierSubjectSHA256=\(receipt.verifierSubjectDigest ?? "unavailable"); "
                        + "receiptSHA256=\(receipt.receiptDigest)")
            }
        }
        let mutations = mutationLines.joined(separator: "\n")
        return """
        HOST COMPLETION EVIDENCE (typed host facts; packet SHA-256: \(evidence.packetDigest)):
        contractID: \(evidence.contractID)
        objectiveFingerprint: \(evidence.objectiveFingerprint)
        completionMode: \(evidence.completionMode.rawValue)
        verificationSubject: \(evidence.verificationSubject)
        baselineDigest: \(evidence.baselineDigest)
        verifiedDigest: \(evidence.verifiedDigest)
        reviewEntryDigest: \(evidence.reviewEntryDigest)
        verifiedAt: \(evidence.verifiedAt)
        mutationPolicy: \(evidence.completionMode == .verificationOnly ? "digest equality and no workspace changes are REQUIRED" : "a governed digest change is REQUIRED")
        producerIdentities: \(evidence.producerIdentities.joined(separator: ", "))
        reviewerIdentityForThisInvocation: \(evidence.reviewerIdentity)
        reviewGrade: \(evidence.reviewGrade.rawValue)
        independent: \(evidence.reviewGrade.claimsIndependence)
        reviewerDistinctFromEveryProducer: \(evidence.reviewGrade.claimsIndependence)
        hadChanges: \(evidence.hadChanges)
        changedPaths: \(evidence.changedPaths.joined(separator: ", "))

        SEALED GOVERNED MUTATION OBSERVATIONS (authoritative; git diff is advisory only):
        \(mutations.isEmpty ? "- none observed" : mutations)

        ACCEPTED PRE-MERGE CHILD VERIFIER SUBJECTS (fleet only; packet-bound):
        \(acceptedChildSubjects.isEmpty ? "- not a fleet promotion" : acceptedChildSubjects)

        REQUIRED SUPPORTING OBLIGATIONS:
        \(requiredSupport.isEmpty ? "- none declared" : requiredSupport)

        SUPPORTING FUNCTIONAL COMMAND RECEIPTS (coverage only; NEVER freshness/verifier proof):
        \(supporting.isEmpty ? "- none supplied" : supporting)

        SOLE FRESH FINAL VERIFIER:
        \(finalReplay)

        DIGEST-BOUND BUILDER COMMAND RECEIPTS:
        \(commands)

        HOST CHECKS:
        \(checks)

        REVIEW PROTOCOL:
        - This is the pre-verdict input. Your current call CREATES the \(evidence.reviewGrade.evidenceLabel) receipt.
        - A fresh_context_same_model review is explicitly weaker evidence and never claims independence.
        - A final review receipt cannot exist yet and MUST NOT be demanded as input.
        - For verificationOnly, unchanged baseline/verified/review-entry digests and no diff are success proof, not missing mutation proof.
        - Planned free-form reviews and grounded_answer text are not authoritative; only typed host facts above are evidence.
        - TEST STATUS, HOST CHECKS, sealed mutations, and digest-bound command receipts are authoritative. Generic worker/model "failed" or "unverified" self-verdict prose is not.
        - Never infer permission errors, nonzero exits, missing files, or failed builds unless a typed command receipt or host check above explicitly records that failure.
        - A real command whose exit is outside its allowed exits remains visible in DIGEST-BOUND BUILDER COMMAND RECEIPTS and may justify HOLD; do not suppress actual failures.
        - Supporting receipts prove functional coverage only. Never count them as final freshness or as the deterministic verifier.
        - An allowed nonzero exit with semantic expected_domain_status is successful domain support, not a failed build.
        - Every required supporting obligation must have a matching receipt; missing support requires HOLD.
        - The host will rehash the workspace after your verdict before persisting final acceptance.
        """
    }

    private static func judgePrompt(lens: Lens, ctx: PromotionContext) -> String {
        """
        Lens: \(lens.name)
        Your job: \(lens.brief)

        GOAL the change was supposed to accomplish:
        \(ctx.goal)

        TEST STATUS: \(ctx.testsPassed ? "PASSING" : "NOT PASSING") — \(ctx.testSummary)

        CAPTAIN SIGN-OFF (what was verified in-process):
        \(ctx.signoffSummary)

        \(completionEvidencePrompt(ctx.completionEvidence))

        BUILD RESULT (sealed Builder mutations are authoritative; git text is optional advisory only):
        \(String(ctx.diffSummary.prefix(8000)))

        Decide: is this REAL and worth merging to main through YOUR lens? Output only the VERDICT/REASON shape.
        """
    }

    private func record(role: String, binding: ProviderBinding, usage: TokenUsage,
                        promptChars: Int, completionChars: Int, started: Date, status: SpanStatus) async {
        guard let recorder else { return }
        let measured = usage.isZero
            ? TokenUsage.estimate(promptChars: promptChars, completionChars: completionChars) : usage
        await recorder.record(AgentSpan(id: TraceID.make(), traceId: recorder.traceId, kind: .llmCall,
                                        role: role, vendor: binding.providerId, model: binding.model,
                                        promptTokens: measured.promptTokens,
                                        completionTokens: measured.completionTokens,
                                        finishReason: nil, startedAt: started, endedAt: Date(), status: status))
    }
}

private struct IndexedPromotionVote: Sendable {
    let index: Int
    let vote: PromotionMindVote
}

private enum CouncilLensCallResult: Sendable {
    case success(ProviderRegistry.RoutedCompletion)
    case failure(String)
    case deadline
}

/// `withTaskGroup` correctly propagates TaskLocal telemetry, but its scope must await every child even
/// after cancellation. A provider that ignores cancellation before returning its stream could therefore
/// hold the entire promotion gate open forever. This small non-detached race preserves TaskLocal values,
/// cancels the real registry completion at the deadline, and resumes the lens without waiting for a
/// non-cooperative provider. A late result cannot replace the already-sealed deadline result.
private final class CouncilLensDeadlineRace: @unchecked Sendable {
    private let lock = NSLock()
    private var result: CouncilLensCallResult?
    private var continuation: CheckedContinuation<CouncilLensCallResult, Never>?
    private var operationTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var operationStarted = false
    private var operationStartContinuation: CheckedContinuation<Void, Never>?

    func run(timeoutNanoseconds: UInt64,
             operation: @escaping @Sendable () async -> CouncilLensCallResult) async
        -> CouncilLensCallResult {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                install(continuation)
                let operationTask = Task { [self] in
                    markOperationStarted()
                    guard !Task.isCancelled else { return }
                    resolve(await operation())
                }
                let timerTask = Task { [self] in
                    // Count the provider deadline from an operation that has actually been
                    // scheduled. Under a saturated executor the timer could otherwise win
                    // before the provider task entered at all, producing a deadline verdict
                    // without ever exercising (or cancelling) the routed completion.
                    await waitForOperationStart()
                    guard !Task.isCancelled else { return }
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
                    catch { return }
                    resolve(.deadline)
                }
                install(operationTask: operationTask, timerTask: timerTask)
            }
        }, onCancel: { [self] in
            resolve(.failure("completion cancelled"))
        })
    }

    private func install(_ continuation: CheckedContinuation<CouncilLensCallResult, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    private func install(operationTask: Task<Void, Never>, timerTask: Task<Void, Never>) {
        lock.lock()
        if result != nil {
            lock.unlock()
            operationTask.cancel()
            timerTask.cancel()
            return
        }
        self.operationTask = operationTask
        self.timerTask = timerTask
        lock.unlock()
    }

    private func markOperationStarted() {
        lock.lock()
        operationStarted = true
        let continuation = operationStartContinuation
        operationStartContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    private func waitForOperationStart() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if operationStarted || result != nil {
                lock.unlock()
                continuation.resume()
                return
            }
            operationStartContinuation = continuation
            lock.unlock()
        }
    }

    private func resolve(_ result: CouncilLensCallResult) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        let operationTask = self.operationTask
        let timerTask = self.timerTask
        let operationStartContinuation = self.operationStartContinuation
        self.continuation = nil
        self.operationTask = nil
        self.timerTask = nil
        self.operationStartContinuation = nil
        lock.unlock()

        operationTask?.cancel()
        timerTask?.cancel()
        operationStartContinuation?.resume()
        continuation?.resume(returning: result)
    }
}
