import XCTest
import Foundation
@testable import AgentCore

/// Pins safety-net #2: native→text downgrade fires for a tool-protocol rejection and ONLY for that.
/// A misfire (downgrading on auth/quota/content errors) would mask real faults; a miss (not downgrading
/// on a tool-history 400) would kill the loop. Both are tested.
final class NativeProtocolDowngradeTests: XCTestCase {

    // MARK: classifier — fires for tool-protocol rejections

    func testHTTP400NamingFunctionsDowngrades() {
        XCTAssertTrue(NativeProtocolDowngrade.shouldDowngrade(
            from: AIProviderError.http(status: 400, body: "Tool use with function calling is unsupported for this model")))
    }

    func testHTTP400NamingToolUseDowngrades() {
        XCTAssertTrue(NativeProtocolDowngrade.shouldDowngrade(
            from: AIProviderError.http(status: 400, body: "messages with tool_use blocks are invalid here")))
    }

    func testHTTP422NamingToolsDowngrades() {
        XCTAssertTrue(NativeProtocolDowngrade.shouldDowngrade(
            from: AIProviderError.http(status: 422, body: "tools are not allowed with this request")))
    }

    func testInvalidResponseNamingFunctionDoesNotDowngrade() {
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(
            from: AIProviderError.invalidResponse("functionDeclarations cannot be combined with code_execution")))
    }

    // MARK: classifier — does NOT fire when switching protocols wouldn't help

    func testHTTP400WithoutToolKeywordsDoesNotDowngrade() {
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(
            from: AIProviderError.http(status: 400, body: "invalid request: image too large")))
    }

    func testAuthErrorDoesNotDowngrade() {
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(from: AIProviderError.invalidAPIKey))
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(
            from: AIProviderError.http(status: 401, body: "tool access denied — invalid key")))  // 401 not downgradable
    }

    func testRateLimitAndServerErrorsDoNotDowngrade() {
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(from: AIProviderError.rateLimited))
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(
            from: AIProviderError.http(status: 500, body: "tool server crashed")))   // 5xx is retryable, not a protocol issue
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(
            from: AIProviderError.http(status: 429, body: "function quota exceeded")))
    }

    func testTransportAndNonProviderErrorsDoNotDowngrade() {
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(from: AIProviderError.transport("connection reset")))
        struct Other: Error {}
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(from: Other()))
    }

    // MARK: first native call — a tool-request rejection (even a generic 5xx) downgrades

    func testInitialCallGeneric500DoesNotDowngrade() {
        // A GENERIC 5xx (body doesn't name tools) is a likely TRANSIENT outage, NOT a schema rejection —
        // verified by live replay (the exact escalated tool request returns 200). It must NOT downgrade
        // (which would silently kill native tools on a blip); it flows to retry + provider route-around.
        let generic = AIProviderError.http(status: 500, body: "{\"error\":{\"code\":500,\"message\":\"Internal error encountered.\",\"status\":\"INTERNAL\"}}")
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(from: generic), "mid-run: generic 500 not downgraded")
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(from: generic, initialToolCall: true),
                       "first call: a GENERIC 5xx is a transient outage, not a schema rejection — do not downgrade")
    }

    func testInitialCall5xxNamingToolsDoesNotDowngrade() {
        // Server failures remain server failures even when their message mentions schema parsing.
        let named = AIProviderError.http(status: 500, body: "functionDeclarations could not be parsed")
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(from: named, initialToolCall: true))
    }

    func testInitialCallGenericClientErrorsDoNotDowngrade() {
        // Status alone is not tool-protocol evidence: these can be context, model, endpoint, or policy errors.
        let generic = AIProviderError.http(status: 400, body: "Invalid request")
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(from: generic))
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(from: generic, initialToolCall: true))
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(
            from: AIProviderError.http(status: 404, body: "model not found"), initialToolCall: true))
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(
            from: AIProviderError.http(status: 422, body: "context is invalid"), initialToolCall: true))
    }

    func testGenericErrorsMentioningToolFieldsDoNotDowngrade() {
        for (status, body) in [
            (400, "context length exceeded while parsing tools parameter"),
            (404, "model not found; function calling is supported by a different model"),
            (422, "invalid image payload; see the function calling documentation"),
        ] {
            XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(
                from: AIProviderError.http(status: status, body: body), initialToolCall: true),
                "incidental tool wording is not capability-rejection evidence: \(body)")
        }
    }

    func testStructuredCapabilityCodeDowngradesWithoutMessageGuessing() {
        let body = #"{"error":{"code":"tool_calling_not_supported","message":"request rejected"}}"#
        XCTAssertEqual(
            NativeProtocolDowngrade.decision(
                from: AIProviderError.http(status: 400, body: body), initialToolCall: true),
            .cacheableCapabilityMismatch)
    }

    func testInitialTurnErrorWithPriorToolHistoryIsRunLocalNotCacheable() {
        let error = AIProviderError.http(
            status: 400, body: "tool_call history is unsupported in this request")

        XCTAssertEqual(
            NativeProtocolDowngrade.decision(
                from: error, initialToolCall: true, hasToolProtocolHistory: false),
            .cacheableCapabilityMismatch)
        XCTAssertEqual(
            NativeProtocolDowngrade.decision(
                from: error, initialToolCall: true, hasToolProtocolHistory: true),
            .currentRunOnly)
    }

    func testPreviouslyAcceptedSchemaIsNeverNegativeCached() {
        let error = AIProviderError.http(
            status: 400, body: "function calling is unsupported in this context")
        XCTAssertEqual(
            NativeProtocolDowngrade.decision(
                from: error, initialToolCall: true,
                hasToolProtocolHistory: false, capabilityAlreadyProven: true),
            .currentRunOnly)
    }

    func testBareFunctionalityWordIsNotCacheableProtocolEvidence() {
        let error = AIProviderError.http(
            status: 400, body: "content policy rejected the requested functionality")
        XCTAssertNil(
            NativeProtocolDowngrade.decision(
                from: error, initialToolCall: true, hasToolProtocolHistory: false))
    }

    func testPositiveCapabilityEvictsAndBlocksNegativeCache() async {
        let cache = NativeToolCapabilityCache(ttl: 60)
        let positive = NativeToolPositiveState(
            providerId: "provider", model: "model", toolSchemaFingerprint: "schema")
        await cache.recordPositive(positive)
        await cache.record(NativeToolFallbackState(
            providerId: "provider", model: "model", toolSchemaFingerprint: "schema"))

        let cachedNegative = await cache.observation(
            providerId: "provider", model: "model", schema: "schema")
        let cachedPositive = await cache.hasPositive(
            providerId: "provider", model: "model", schema: "schema")
        XCTAssertNil(cachedNegative)
        XCTAssertTrue(cachedPositive)
    }

    func testCapabilityCacheRejectsExpiredAndFutureObservations() async {
        let now = Date()
        let cache = NativeToolCapabilityCache(ttl: 60)
        await cache.record(NativeToolFallbackState(
            providerId: "provider", model: "model", toolSchemaFingerprint: "expired",
            recordedAt: now.addingTimeInterval(-61)))
        await cache.record(NativeToolFallbackState(
            providerId: "provider", model: "model", toolSchemaFingerprint: "future",
            recordedAt: now.addingTimeInterval(3_600)))

        let expired = await cache.observation(
            providerId: "provider", model: "model", schema: "expired", now: now)
        let future = await cache.observation(
            providerId: "provider", model: "model", schema: "future", now: now)
        XCTAssertNil(expired)
        XCTAssertNil(future)
    }

    func testCapabilityCacheIsolatedByExactSchemaFingerprint() async {
        let cache = NativeToolCapabilityCache(ttl: 60)
        await cache.record(NativeToolFallbackState(
            providerId: "provider", model: "model", toolSchemaFingerprint: "schema-a"))

        let exactNegative = await cache.observation(
            providerId: "provider", model: "model", schema: "schema-a")
        let otherSchema = await cache.observation(
            providerId: "provider", model: "model", schema: "schema-b")
        XCTAssertNotNil(exactNegative)
        XCTAssertNil(otherSchema)
        await cache.recordPositive(NativeToolPositiveState(
            providerId: "provider", model: "model", toolSchemaFingerprint: "schema-b"))
        let retainedNegative = await cache.observation(
            providerId: "provider", model: "model", schema: "schema-a")
        XCTAssertNotNil(retainedNegative,
            "a positive for another schema must not erase this exact negative key")
    }

    func testHistoryDetectionUsesCrashRepairedEffectiveTranscript() {
        let valid: [ChatMessage] = [
            ChatMessage(role: .assistant, content: "",
                        toolCalls: [ToolCallRef(id: "1", name: "read_file", argumentsJSON: "{}")]),
            ChatMessage.toolResult(callId: "1", content: "ok"),
        ]
        let interrupted: [ChatMessage] = [
            ChatMessage(role: .assistant, content: "",
                        toolCalls: [ToolCallRef(id: "2", name: "write_file", argumentsJSON: "{}")]),
            ChatMessage(role: .user, content: "interrupted; verify before retrying"),
        ]

        XCTAssertTrue(NativeProtocolDowngrade.hasToolProtocolHistory(
            TranscriptRepair.repairForNativeTools(valid)))
        XCTAssertFalse(NativeProtocolDowngrade.hasToolProtocolHistory(
            TranscriptRepair.repairForNativeTools(interrupted)))
    }

    func testInitialCallStillDoesNotDowngradeAuthOrQuota() {
        // Auth/quota can't be fixed by switching protocols — even on the first call, don't mask them.
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(
            from: AIProviderError.http(status: 401, body: "unauthorized"), initialToolCall: true))
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(
            from: AIProviderError.http(status: 403, body: "forbidden"), initialToolCall: true))
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(
            from: AIProviderError.http(status: 429, body: "quota exceeded"), initialToolCall: true))
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(
            from: AIProviderError.rateLimited, initialToolCall: true))
    }

    func testMidRun5xxNamingToolsDoesNotDowngrade() {
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(
            from: AIProviderError.http(status: 503, body: "functionDeclarations rejected by backend")))
    }

    // MARK: flatten — strips native-only structures, preserves work

    func testFlattenStripsToolCallsAndToolRole() {
        let msgs: [ChatMessage] = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "do the thing"),
            ChatMessage(role: .assistant, content: "calling now",
                        toolCalls: [ToolCallRef(id: "1", name: "echo", argumentsJSON: "{\"text\":\"hi\"}")]),
            ChatMessage.toolResult(callId: "1", content: "hi"),
            ChatMessage(role: .assistant, content: "all done"),
        ]
        let flat = NativeProtocolDowngrade.flattenForText(msgs)

        // No native-only structures survive.
        XCTAssertTrue(flat.allSatisfy { ($0.toolCalls?.isEmpty ?? true) })
        XCTAssertFalse(flat.contains { $0.role == .tool })

        // Work is preserved: the tool call is described, the observation folded in as user context.
        XCTAssertEqual(flat[0].role, .system)
        XCTAssertEqual(flat[1].content, "do the thing")
        XCTAssertTrue(flat[2].content.contains("called echo"))
        XCTAssertTrue(flat[2].content.contains("calling now"))
        XCTAssertEqual(flat[3].role, .user)
        XCTAssertTrue(flat[3].content.contains("Observation:"))
        XCTAssertTrue(flat[3].content.contains("hi"))
        XCTAssertEqual(flat[4].content, "all done")
        XCTAssertEqual(flat.count, msgs.count)
    }

    func testFlattenAssistantWithEmptyContentStillDescribesCall() {
        let msgs: [ChatMessage] = [
            ChatMessage(role: .assistant, content: "",
                        toolCalls: [ToolCallRef(id: "9", name: "write_file", argumentsJSON: "{\"path\":\"a\"}")]),
        ]
        let flat = NativeProtocolDowngrade.flattenForText(msgs)
        XCTAssertTrue(flat[0].content.contains("called write_file"))
        XCTAssertNil(flat[0].toolCalls?.isEmpty == false ? flat[0].toolCalls : nil)
    }
}
