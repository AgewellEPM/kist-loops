import XCTest
@testable import AgentCore

/// Quota exhaustion vs rate limit (0.17.63). Born from the 2026-09-27 build-lane census: a
/// drained OpenAI balance answers 429 `insufficient_quota`, which every stream site collapsed
/// into `.rateLimited` before reading the body — retried three times per call, benched for five
/// minutes, and re-picked by every build turn for weeks.
final class ProviderQuotaExhaustionTests: XCTestCase {
    private let openAIQuotaBody = #"{"error":{"message":"You have no credits remaining. Add credits to continue using the API.","type":"insufficient_quota","code":"credit_balance_exhausted"}}"#
    private let geminiQuotaBody = #"{"error":{"code":429,"message":"You exceeded your current quota, please check your plan and billing details.","status":"RESOURCE_EXHAUSTED"}}"#
    private let limiterBody = #"{"error":{"message":"Rate limit reached for gpt-5.5: 60 RPM","type":"requests","code":"rate_limit_exceeded"}}"#

    // MARK: classification

    func testOpenAIInsufficientQuotaClassifiesAsNonRetryableHTTP429() {
        let error = ProviderQuotaExhaustion.classify(status: 429, body: openAIQuotaBody)
        guard case .http(let status, let body) = error else { return XCTFail("expected .http, got \(error)") }
        XCTAssertEqual(status, 429)
        XCTAssertTrue(body.hasPrefix(ProviderQuotaExhaustion.bodyTag + ":"), "body must carry the quota tag")
        XCTAssertFalse(error.isRetryable, "a drained account never clears within the registry's retry delays")
        XCTAssertTrue(ProviderQuotaExhaustion.isQuotaExhausted(error))
        XCTAssertTrue(error.errorDescription?.contains("out of credits/quota") == true,
                      "operator message must say billing, not rate limit: \(error.errorDescription ?? "")")
    }

    func testGeminiQuotaWordingClassifiesAsQuotaExhaustion() {
        let error = ProviderQuotaExhaustion.classify(status: 429, body: geminiQuotaBody)
        XCTAssertTrue(ProviderQuotaExhaustion.isQuotaExhausted(error))
        XCTAssertFalse(error.isRetryable)
    }

    func testGenericResourceExhaustedIsNotQuota() {
        // Gemini uses RESOURCE_EXHAUSTED for a plain per-minute limiter too; the generic status
        // word alone must not bench a provider for hours.
        let error = ProviderQuotaExhaustion.classify(
            status: 429, body: #"{"error":{"status":"RESOURCE_EXHAUSTED","message":"Quota exceeded for requests per minute"}}"#)
        // "quota exceeded" is deliberately NOT a marker (per-minute quotas say it too).
        XCTAssertEqual(error, .rateLimited)
    }

    func testPlainRateLimitStaysRateLimitedAndRetryable() {
        let error = ProviderQuotaExhaustion.classify(status: 429, body: limiterBody)
        XCTAssertEqual(error, .rateLimited)
        XCTAssertTrue(error.isRetryable)
        XCTAssertFalse(ProviderQuotaExhaustion.isQuotaExhausted(error))
    }

    func testEmpty429BodyStaysRateLimited() {
        XCTAssertEqual(ProviderQuotaExhaustion.classify(status: 429, body: ""), .rateLimited)
    }

    func testPaymentRequired402IsQuotaExhaustion() {
        let error = ProviderQuotaExhaustion.classify(status: 402, body: "Insufficient Balance")
        XCTAssertTrue(ProviderQuotaExhaustion.isQuotaExhausted(error))
        XCTAssertFalse(error.isRetryable)
    }

    func testOtherStatusesPassThroughAsHTTPWithBoundedBody() {
        let long = String(repeating: "x", count: 2_000)
        let error = ProviderQuotaExhaustion.classify(status: 503, body: long)
        guard case .http(let status, let body) = error else { return XCTFail("expected .http") }
        XCTAssertEqual(status, 503)
        XCTAssertEqual(body.count, 600, "retained body stays bounded")
        XCTAssertTrue(error.isRetryable, "5xx keeps its retry policy")
    }

    func testMentionedRecognizesTagAndMarkersInSummaries() {
        XCTAssertTrue(ProviderQuotaExhaustion.mentioned(in: "provider 'openai' error: quota_exhausted: {...}"))
        XCTAssertTrue(ProviderQuotaExhaustion.mentioned(in: "The provider account is out of credits/quota (billing)"))
        XCTAssertTrue(ProviderQuotaExhaustion.mentioned(in: "HTTP 429 insufficient_quota"))
        XCTAssertTrue(ProviderQuotaExhaustion.mentioned(in: "CLI provider 'codex' exited 1: You've hit your usage limit."))
        XCTAssertFalse(ProviderQuotaExhaustion.mentioned(in: "provider 'gemini' error: rateLimited"))
    }

    func testQuotaCooldownIsHoursNotMinutes() {
        XCTAssertGreaterThanOrEqual(ProviderQuotaExhaustion.cooldownTTL, 3_600)
        XCTAssertGreaterThan(ProviderQuotaExhaustion.cooldownTTL, ProviderCooldownStore.defaultTTL)
    }

    // MARK: per-site pins (multi-site fix discipline: every 429 throw site names itself)

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // AgentCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// (label, file, expected number of classify sites)
    private let streamSites: [(String, String, Int)] = [
        ("openai-compatible stream", "Sources/AgentCore/OpenAICompatibleProvider.swift", 2),
        ("gemini stream", "Sources/AgentCore/Providers/GeminiProvider.swift", 2),
    ]

    func testEveryHTTPStreamSiteReadsTheBodyBeforeDeciding429() throws {
        for (label, file, expected) in streamSites {
            let src = try source(file)
            XCTAssertFalse(src.contains("statusCode == 429 { throw AIProviderError.rateLimited }"),
                           "\(label) (\(file)) still collapses every 429 into rateLimited before reading the body")
            let sites = src.components(separatedBy: "ProviderQuotaExhaustion.classify(status: http.statusCode, body: body)").count - 1
            XCTAssertEqual(sites, expected,
                           "\(label) (\(file)) must route all \(expected) non-200 sites through the shared 429 policy")
        }
    }
}
