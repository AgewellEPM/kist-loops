import XCTest
@testable import AgentCore

/// Role→vendor binding: the abstraction that turns a run into a heterogeneous team.
final class RoleBindingsTests: XCTestCase {

    func testFallbackUsedForUnboundRoles() {
        let r = RoleBindings(default: ProviderBinding(providerId: "openai"))
        XCTAssertEqual(r.binding(for: .planner).providerId, "openai")
        XCTAssertEqual(r.binding(for: .critic).providerId, "openai")
        XCTAssertFalse(r.isHeterogeneous)
    }

    func testExplicitBindingOverridesFallback() {
        let r = RoleBindings(default: ProviderBinding(providerId: "openai"),
                             [.critic: ProviderBinding(providerId: "gemini")])
        XCTAssertEqual(r.binding(for: .planner).providerId, "openai")   // fallback
        XCTAssertEqual(r.binding(for: .critic).providerId, "gemini")    // bound
        XCTAssertTrue(r.isHeterogeneous)
    }

    func testBindingCopyHelper() {
        let r = RoleBindings(default: ProviderBinding(providerId: "openai"))
            .binding(.critic, to: ProviderBinding(providerId: "gemini", model: "gemini-2.5-flash"))
        XCTAssertEqual(r.binding(for: .critic).providerId, "gemini")
        XCTAssertEqual(r.binding(for: .critic).model, "gemini-2.5-flash")
    }

    func testSameProviderDifferentRoleIsNotHeterogeneous() {
        let r = RoleBindings(default: ProviderBinding(providerId: "openai", model: "gpt-4o"),
                             [.critic: ProviderBinding(providerId: "openai", model: "gpt-4o-mini")])
        XCTAssertFalse(r.isHeterogeneous)   // same provider, different model ≠ cross-vendor
    }

    func testSummary() {
        let r = RoleBindings(default: ProviderBinding(providerId: "openai"),
                             [.critic: ProviderBinding(providerId: "gemini")])
        XCTAssertTrue(r.summary.contains("planner=openai"))
        XCTAssertTrue(r.summary.contains("critic=gemini"))
    }

    // MARK: - ProviderBinding.parse

    func testParseProviderOnly() {
        let b = ProviderBinding.parse("gemini")
        XCTAssertEqual(b?.providerId, "gemini")
        XCTAssertNil(b?.model)
    }

    func testParseProviderAndModel() {
        let b = ProviderBinding.parse("openai:gpt-4o")
        XCTAssertEqual(b?.providerId, "openai")
        XCTAssertEqual(b?.model, "gpt-4o")
    }

    func testParseTrimsAndRejectsEmpty() {
        XCTAssertEqual(ProviderBinding.parse("  grok  ")?.providerId, "grok")
        XCTAssertNil(ProviderBinding.parse(""))
        XCTAssertNil(ProviderBinding.parse("   "))
        XCTAssertNil(ProviderBinding.parse(":gpt-4o"))     // empty provider
    }
}
