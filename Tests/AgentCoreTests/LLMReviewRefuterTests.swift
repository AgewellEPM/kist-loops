import XCTest
@testable import AgentCore

/// The council's SECOND grounding gate — a skeptic that judges whether a GROUNDED finding is a REAL bug.
/// FAIL-STRICT: refuted unless the model EXPLICITLY confirms VERDICT: REAL; budget-out / failure / any
/// ambiguity all default to refuted (a skeptic never confirms on a maybe).
final class LLMReviewRefuterTests: XCTestCase {

    private func finding() -> GroundedReviewFinding {
        GroundedReviewFinding(severity: "HIGH", file: "Sources/Nope.swift", line: 1,
                      codeQuote: "let x = compute()", claim: "off-by-one")
    }

    /// A temp project root with a REAL source file the finding cites — so codeContext is non-empty and
    /// refute() actually reaches the model (otherwise the source-unavailable short-circuit refutes first).
    private func realRootAndFinding() -> (String, GroundedReviewFinding) {
        let root = NSTemporaryDirectory() + "rfr-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: root + "/Sources", withIntermediateDirectories: true)
        try? "let x = compute()\n".write(toFile: root + "/Sources/Real.swift", atomically: true, encoding: .utf8)
        return (root, GroundedReviewFinding(severity: "HIGH", file: "Sources/Real.swift", line: 1,
                                    codeQuote: "let x = compute()", claim: "off-by-one"))
    }

    // MARK: parseVote — the load-bearing strict parser

    func testParseVoteStrict() {
        XCTAssertFalse(LLMReviewRefuter.parseVote("reasoning...\nVERDICT: REAL").refuted, "explicit REAL clears refutation")
        XCTAssertTrue(LLMReviewRefuter.parseVote("reasoning...\nVERDICT: NOT_A_BUG").refuted, "NOT_A_BUG refutes")
        XCTAssertTrue(LLMReviewRefuter.parseVote("hmm, maybe, could be").refuted, "ambiguous ⇒ refuted (strict default)")
        XCTAssertTrue(LLMReviewRefuter.parseVote("").refuted, "empty ⇒ refuted")
        XCTAssertTrue(LLMReviewRefuter.parseVote("VERDICT: REAL but on reflection VERDICT: NOT_A_BUG").refuted,
                      "both markers ⇒ refuted (never confirm when contradictory)")
        XCTAssertTrue(LLMReviewRefuter.parseVote("this is REAL-ish and real concerning").refuted,
                      "the word 'real' in prose without the VERDICT marker does NOT confirm")
    }

    // The dangerous direction: a SUBSTRING match on "real" would FALSE-CONFIRM. These must all REFUTE.
    func testParseVoteDoesNotFalseConfirmOnRealSubstrings() {
        for adversarial in ["VERDICT: REALLY", "VERDICT: REAL_TALK", "VERDICT: REALITY_CHECK",
                            "VERDICT: REALLY_NOT_A_BUG", "VERDICT: REAL-ish", "VERDICT: REAL1",
                            "VERDICT: REAL/BUT", "the verdict: realistic concern"] {
            XCTAssertTrue(LLMReviewRefuter.parseVote(adversarial).refuted,
                          "'\(adversarial)' must NOT false-confirm (token != 'real')")
        }
        // But a genuine REAL verdict (token exactly 'real', any trailing prose/punct) still confirms.
        XCTAssertFalse(LLMReviewRefuter.parseVote("reasoning.\nVERDICT: REAL — it's a genuine defect").refuted)
        XCTAssertFalse(LLMReviewRefuter.parseVote("VERDICT: real.").refuted)
        // The LAST verdict line wins (a model that reconsiders).
        XCTAssertTrue(LLMReviewRefuter.parseVote("VERDICT: REAL\n...on reflection\nVERDICT: NOT_A_BUG").refuted)
    }

    // MARK: refute() routes the model's verdict into a vote

    func testRefuteConfirmsOnExplicitReal() async {
        let (root, f) = realRootAndFinding()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let reg = ProviderRegistry(providers: [ScriptedRefuterProvider(id: "p", response: "looks real.\nVERDICT: REAL")])
        let r = LLMReviewRefuter(providers: reg, providerId: "p", model: nil, projectRoot: root)
        let vote = await r.refute(f)
        XCTAssertFalse(vote.refuted)
    }

    func testRefuteRefutesOnNotABug() async {
        let (root, f) = realRootAndFinding()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let reg = ProviderRegistry(providers: [ScriptedRefuterProvider(id: "p", response: "false positive.\nVERDICT: NOT_A_BUG")])
        let r = LLMReviewRefuter(providers: reg, providerId: "p", model: nil, projectRoot: root)
        let vote = await r.refute(f)
        XCTAssertTrue(vote.refuted)
    }

    // Codex MED: a finding citing a file we CANNOT read is refused (can't confirm without the source) —
    // WITHOUT calling the model (a tripwire provider that would throw if invoked proves no spend).
    func testSourceUnavailableRefutesWithoutCallingModel() async {
        let reg = ProviderRegistry(providers: [TripwireProvider(id: "p")])
        let r = LLMReviewRefuter(providers: reg, providerId: "p", model: nil, projectRoot: NSTemporaryDirectory())
        let vote = await r.refute(finding())   // cites Sources/Nope.swift — unreadable
        XCTAssertTrue(vote.refuted)
        XCTAssertTrue(vote.reason.contains("could not be read"), vote.reason)
    }

    // Budget already exceeded ⇒ abstain by REFUTING, WITHOUT calling the provider (a tripwire provider
    // that would fail the test if invoked proves no spend happened).
    func testBudgetExceededAbstainsWithoutCallingProvider() async {
        let budget = BudgetLedger(maxTokens: 0)   // spent(0) >= cap(0) ⇒ already exceeded
        let reg = ProviderRegistry(providers: [TripwireProvider(id: "p")])
        let r = LLMReviewRefuter(providers: reg, providerId: "p", model: nil, projectRoot: NSTemporaryDirectory(), budget: budget)
        let vote = await r.refute(finding())
        XCTAssertTrue(vote.refuted)
        XCTAssertTrue(vote.reason.contains("budget"), vote.reason)
    }

    // A provider that throws ⇒ abstain by refuting (skeptic default on failure), no crash. Uses a REAL
    // file so the source-unavailable short-circuit doesn't pre-empt the provider call (we want the throw).
    func testProviderFailureAbstains() async {
        let (root, f) = realRootAndFinding()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let reg = ProviderRegistry(providers: [TripwireProvider(id: "p")])
        let r = LLMReviewRefuter(providers: reg, providerId: "p", model: nil, projectRoot: root)
        let vote = await r.refute(f)
        XCTAssertTrue(vote.refuted, "a failed refuter call defaults to refuted")
    }

    // Integration with verify(): a panel of refuters that all CONFIRM (don't refute) ⇒ .confirmed; all
    // refute ⇒ .refutedPanel. (Grounding handled separately; here the finding's code is real in a temp file.)
    func testPanelDrivesConfirmedVsRefuted() async {
        let root = NSTemporaryDirectory() + "rfp-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: root + "/Sources", withIntermediateDirectories: true)
        try? "let total = items.reduce(0, +)\n".write(toFile: root + "/Sources/Sum.swift", atomically: true, encoding: .utf8)
        let f = GroundedReviewFinding(severity: "MED", file: "Sources/Sum.swift", line: 1,
                              codeQuote: "let total = items.reduce(0, +)", claim: "overflow risk")

        let confirmReg = ProviderRegistry(providers: [ScriptedRefuterProvider(id: "p", response: "VERDICT: REAL")])
        let confirmPanel: [ReviewFindingRefuter] = [LLMReviewRefuter(providers: confirmReg, providerId: "p", model: nil, projectRoot: root)]
        let confirmed = await ReviewFindingVerifier.verify(findings: [f], projectRoot: root, panel: confirmPanel)
        XCTAssertEqual(confirmed.first?.verdict, .confirmed, "a grounded finding the skeptic doesn't refute is confirmed")

        let refuteReg = ProviderRegistry(providers: [ScriptedRefuterProvider(id: "p", response: "VERDICT: NOT_A_BUG")])
        let refutePanel: [ReviewFindingRefuter] = [LLMReviewRefuter(providers: refuteReg, providerId: "p", model: nil, projectRoot: root)]
        let refuted = await ReviewFindingVerifier.verify(findings: [f], projectRoot: root, panel: refutePanel)
        XCTAssertEqual(refuted.first?.verdict, .refutedPanel, "a grounded finding the skeptic refutes is dropped")
    }
}

/// Minimal ChatProvider that yields one fixed response — for routing the refuter's verdict in tests.
private struct ScriptedRefuterProvider: ChatProvider {
    let id: String
    var name: String { id }
    let iconName = "cpu"
    let requiresAPIKey = false
    var keyAccount: String { id }
    var defaultModel: String { "\(id)-default" }
    var availableModels: [AIModel] { [AIModel(id: "\(id)-default")] }
    let response: String
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let r = response
        return AsyncThrowingStream { c in c.yield(.delta(r)); c.finish() }
    }
}

/// A provider that THROWS if its stream is ever started — proves a code path did NOT call the model.
private struct TripwireProvider: ChatProvider {
    let id: String
    var name: String { id }
    let iconName = "cpu"
    let requiresAPIKey = false
    var keyAccount: String { id }
    var defaultModel: String { "\(id)-default" }
    var availableModels: [AIModel] { [AIModel(id: "\(id)-default")] }
    struct Tripped: Error {}
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        throw Tripped()
    }
}
