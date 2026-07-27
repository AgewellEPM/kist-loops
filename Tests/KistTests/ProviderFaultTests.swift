import XCTest
@testable import AgentCore

/// The great-loop routes AROUND a provider only when the cycle failed because the PROVIDER faulted
/// server-side. A 5-model review flagged the original summary-string regex as brittle (false positives when
/// an agent-authored summary merely mentions "server error"; false negatives on rephrasing / non-HTTP
/// errors). Classification now reads the STRUCTURED `AIProviderError`. These pin that: a real provider
/// fault is caught, a code failure / auth / bad key is NOT (routing elsewhere wouldn't help those).
final class ProviderFaultTests: XCTestCase {

    func testServerFaultsAreProviderFaults() {
        XCTAssertTrue(ProviderFault.isProviderFault(AIProviderError.http(status: 500, body: "Internal error")))
        XCTAssertTrue(ProviderFault.isProviderFault(AIProviderError.http(status: 502, body: "Bad Gateway")))
        XCTAssertTrue(ProviderFault.isProviderFault(AIProviderError.http(status: 503, body: "unavailable")))
        XCTAssertTrue(ProviderFault.isProviderFault(AIProviderError.http(status: 504, body: "timeout")))
        XCTAssertTrue(ProviderFault.isProviderFault(AIProviderError.http(status: 429, body: "slow down")))
        XCTAssertTrue(ProviderFault.isProviderFault(AIProviderError.rateLimited))
        XCTAssertTrue(ProviderFault.isProviderFault(AIProviderError.transport("connection reset")))
    }

    func testNonProviderFaultsAreNot() {
        // Auth / missing key / content 4xx / malformed body — routing to another provider won't fix these.
        XCTAssertFalse(ProviderFault.isProviderFault(AIProviderError.http(status: 400, body: "bad request")))
        XCTAssertFalse(ProviderFault.isProviderFault(AIProviderError.http(status: 401, body: "unauthorized")))
        XCTAssertFalse(ProviderFault.isProviderFault(AIProviderError.http(status: 403, body: "forbidden")))
        XCTAssertFalse(ProviderFault.isProviderFault(AIProviderError.invalidAPIKey))
        XCTAssertFalse(ProviderFault.isProviderFault(AIProviderError.missingAPIKey(provider: "gemini")))
        XCTAssertFalse(ProviderFault.isProviderFault(AIProviderError.invalidResponse("garbage")))
        struct Other: Error {}
        XCTAssertFalse(ProviderFault.isProviderFault(Other()))
    }

    func testStructuredBeatsTheBrittleStringMatch() {
        // The exact false positive the review called out: an agent's SUMMARY mentioning "server error" is
        // NOT a provider fault when the underlying error is a code failure — the structured path ignores it.
        struct CodeFailure: Error {}
        XCTAssertFalse(ProviderFault.isProviderFault(CodeFailure()),
                       "a non-provider error is never a provider fault, regardless of any prose")
        // The string fallback (used only when no typed error exists) still recognizes clear phrasings.
        XCTAssertTrue(ProviderFault.fromSummary("The model had a server error on its side."))
        XCTAssertFalse(ProviderFault.fromSummary("Build failed: 3 compile errors"))
    }

    // MARK: cooldown — exclusion is temporary, not permanent (recovery for long runs)

    func testCooldownExcludesThenRecovers() {
        var t = ProviderCooldownTracker(cooldown: 120)
        t.recordFault("gemini", at: 1000)
        XCTAssertEqual(t.active(now: 1000), ["gemini"], "excluded immediately after a fault")
        XCTAssertEqual(t.active(now: 1119), ["gemini"], "still excluded inside the window")
        XCTAssertEqual(t.active(now: 1120), [], "eligible again once the window elapses (next call is the probe)")
    }

    func testCooldownReArmsOnRepeatFault() {
        var t = ProviderCooldownTracker(cooldown: 60)
        t.recordFault("grok", at: 100)
        XCTAssertEqual(t.active(now: 170), [], "recovered after 60s")
        t.recordFault("grok", at: 200)   // faulted again → window restarts
        XCTAssertEqual(t.active(now: 250), ["grok"], "re-excluded after a repeat fault")
    }

    func testCooldownTracksProvidersIndependently() {
        var t = ProviderCooldownTracker(cooldown: 100)
        t.recordFault("gemini", at: 500)
        t.recordFault("deepseek", at: 560)
        XCTAssertEqual(t.active(now: 610), ["deepseek"], "gemini recovered (>100s), deepseek still cooling")
    }
}
