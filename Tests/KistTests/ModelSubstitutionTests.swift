import XCTest
import AgentCore
@testable import Kist

final class ModelSubstitutionTests: XCTestCase {

    func testWrappedRateLimitTakesPrecedenceOverGenericProtocolFailure() {
        for summary in [
            "The step didn't complete: provider 'openai' error: rateLimited. Nothing was committed — retry, or tell me a different approach.",
            "provider error: rateLimited",
            "provider error: HTTP 429 rate limit",
            "provider error: service unavailable (503)",
        ] {
            XCTAssertEqual(KistREPL.modelSubstitutionReason(success: false, summary: summary),
                           "provider/transient failure", summary)
            XCTAssertTrue(KistREPL.transientProviderFailure(summary: summary), summary)
        }
        XCTAssertEqual(KistREPL.modelSubstitutionReason(success: false,
                        summary: "provider error: connection timed out"), "provider/connectivity failure")
        XCTAssertFalse(KistREPL.transientProviderFailure(summary: "provider error: malformed tool protocol"))
    }
    func testModelSubstitutionChoosesReadyRoleBackupForMalformedFailure() {
        let current = ProviderBinding(providerId: "mimo")
        let roles = RoleBindings(default: current)
            .binding(.coder, to: ProviderBinding(providerId: "deepseek", model: "deepseek-v4-pro"))

        let decision = KistREPL.modelSubstitutionDecision(
            success: false,
            summary: "The model rejected the request as malformed.",
            trajectory: [ActionRecord(tool: "read_file", argsFingerprint: "Sources/App.swift", success: true)],
            current: current,
            roles: roles,
            providerHasKey: { $0 != "openai" },
            providerModels: ["mimo": ["mimo-v2.5-pro"], "deepseek": ["deepseek-v4-pro"]]
        )

        XCTAssertEqual(decision?.replacement, ProviderBinding(providerId: "deepseek", model: "deepseek-v4-pro"))
        XCTAssertEqual(decision?.reason, "provider/protocol failure")
    }

    func testModelSubstitutionFallsBackToPriorityProviderWhenRolesDoNotHelp() {
        let current = ProviderBinding(providerId: "mimo")
        let roles = RoleBindings(default: current)

        let decision = KistREPL.modelSubstitutionDecision(
            success: false,
            summary: "provider error: malformed tool protocol",
            trajectory: [],
            current: current,
            roles: roles,
            providerHasKey: { $0 == "gemini" },
            providerModels: ["mimo": ["mimo-v2.5-pro"], "gemini": ["gemini-2.5-flash"]]
        )

        XCTAssertEqual(decision?.replacement, ProviderBinding(providerId: "gemini"))
        XCTAssertEqual(decision?.reason, "provider/protocol failure")
    }

    func testRefusalAndPermissionStopsDoNotSubstituteAcrossTextOneShotOrVisionLanes() {
        let current = ProviderBinding(providerId: "openai")
        let roles = RoleBindings(default: current)
            .binding(.worker, to: ProviderBinding(providerId: "ollama", model: "local-worker"))
        let summaries = [
            "I cannot help with that request even though it is a normal coding task.",
            "I won’t execute that command.",
            "I’m unable to comply with this request.",
            "provider error: I cannot execute this system action.",
            "provider error: permission denied; previous retry returned 503.",
            "provider error: authorization denied",
            "provider error: approval required",
            "provider error: access denied",
            "provider error: operation not permitted",
            "provider error: blocked by policy",
            "provider error: safety refusal"
        ]
        for summary in summaries {
            XCTAssertNil(KistREPL.modelSubstitutionDecision(
                success: false, summary: summary, trajectory: [], current: current, roles: roles,
                providerHasKey: { _ in true }, providerModels: ["ollama": ["local-worker"]]), summary)
            XCTAssertNil(KistRunner.oneShotSubstitution(
                success: false, summary: summary, trajectory: [], current: current, roles: roles,
                providerHasKey: { _ in true }, providerModels: ["ollama": ["local-worker"]],
                coolingDown: { _ in false }), summary)
            XCTAssertNil(KistREPL.mediaSubstitutionDecision(
                success: false, summary: summary, trajectory: [], failedProviderId: "openai",
                candidates: ["gemini"], mustUseGemini: false, coolingDown: { _ in false }), summary)
            XCTAssertFalse(KistREPL.transientProviderFailure(summary: summary), summary)
        }
        XCTAssertEqual(KistREPL.modelSubstitutionReason(success: false,
            summary: "provider error: connection refused"), "provider/connectivity failure")
    }

    func testModelSubstitutionFallsBackOnTransientProviderFailure() {
        let current = ProviderBinding(providerId: "mimo")
        let roles = RoleBindings(default: current)

        let decision = KistREPL.modelSubstitutionDecision(
            success: false,
            summary: "MiMo is rate-limited or over quota right now.",
            trajectory: [ActionRecord(tool: "search_code", argsFingerprint: "router", success: true)],
            current: current,
            roles: roles,
            providerHasKey: { $0 == "openai" },
            providerModels: ["mimo": ["mimo-v2.5-pro"], "openai": ["gpt-5.5"]]
        )

        XCTAssertEqual(decision?.replacement, ProviderBinding(providerId: "openai"))
        XCTAssertEqual(decision?.reason, "provider/transient failure")
    }

    func testModelSubstitutionFallsBackOnProviderConnectivityFailure() {
        let current = ProviderBinding(providerId: "mimo")
        let roles = RoleBindings(default: current)

        let decision = KistREPL.modelSubstitutionDecision(
            success: false,
            summary: "The connection to MiMo timed out.",
            trajectory: [ActionRecord(tool: "read_file", argsFingerprint: "Sources/App.swift", success: true)],
            current: current,
            roles: roles,
            providerHasKey: { $0 == "ollama" },
            providerModels: ["mimo": ["mimo-v2.5-pro"], "ollama": ["llama3.1"]]
        )

        XCTAssertEqual(decision?.replacement, ProviderBinding(providerId: "ollama"))
        XCTAssertEqual(decision?.reason, "provider/connectivity failure")
    }

    func testModelSubstitutionDoesNotReplayAfterMutatingWork() {
        let current = ProviderBinding(providerId: "mimo")
        let roles = RoleBindings(default: current)

        let decision = KistREPL.modelSubstitutionDecision(
            success: false,
            summary: "provider error: bad request malformed",
            trajectory: [ActionRecord(tool: "write_file", argsFingerprint: "Sources/App.swift", success: true)],
            current: current,
            roles: roles,
            providerHasKey: { _ in true },
            providerModels: ["mimo": ["mimo-v2.5-pro"], "openai": ["gpt-5.5"]]
        )

        XCTAssertNil(decision)
    }

    func testModelSubstitutionDoesNotChooseProviderMissingFromKnownCatalog() {
        let current = ProviderBinding(providerId: "mimo")
        let roles = RoleBindings(default: current)

        let decision = KistREPL.modelSubstitutionDecision(
            success: false,
            summary: "provider error: bad request malformed",
            trajectory: [],
            current: current,
            roles: roles,
            providerHasKey: { _ in true },
            providerModels: ["mimo": ["mimo-v2.5-pro"]]
        )

        XCTAssertNil(decision)
    }

    func testModelSubstitutionDoesNotShopAroundHardSafetyStop() {
        let current = ProviderBinding(providerId: "mimo")
        let roles = RoleBindings(default: current)

        let decision = KistREPL.modelSubstitutionDecision(
            success: false,
            summary: "I can't help create malware or steal credentials.",
            trajectory: [],
            current: current,
            roles: roles,
            providerHasKey: { _ in true },
            providerModels: ["mimo": ["mimo-v2.5-pro"], "openai": ["gpt-5.5"]]
        )

        XCTAssertNil(decision)
    }
}
