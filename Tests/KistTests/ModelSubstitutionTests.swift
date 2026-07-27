import XCTest
import AgentCore
@testable import Kist

final class ModelSubstitutionTests: XCTestCase {
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
            summary: "I cannot help with that request even though it is a normal coding task.",
            trajectory: [],
            current: current,
            roles: roles,
            providerHasKey: { $0 == "gemini" },
            providerModels: ["mimo": ["mimo-v2.5-pro"], "gemini": ["gemini-2.5-flash"]]
        )

        XCTAssertEqual(decision?.replacement, ProviderBinding(providerId: "gemini"))
        XCTAssertEqual(decision?.reason, "model refusal/non-cooperation")
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
