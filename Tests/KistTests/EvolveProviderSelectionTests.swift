import XCTest
import AgentCore
@testable import Kist

final class EvolveProviderSelectionTests: XCTestCase {
    func testInvalidExplicitCriticResolutionCannotFallBackToAutomaticReviewer() {
        XCTAssertEqual(
            KistRunner.evolutionCriticSelection(
                explicitRequested: true, resolvedRoles: nil),
            .invalidExplicit)
        XCTAssertEqual(
            KistRunner.evolutionCriticSelection(
                explicitRequested: false, resolvedRoles: nil),
            .automatic)

        let roles = RoleBindings(
            default: ProviderBinding(providerId: "codex-cli", model: "gpt-5.6-sol"),
            [.critic: ProviderBinding(providerId: "ollama", model: "qwen2.5-coder:7b")])
        XCTAssertEqual(
            KistRunner.evolutionCriticSelection(
                explicitRequested: true, resolvedRoles: roles),
            .explicit(ProviderBinding(providerId: "ollama", model: "qwen2.5-coder:7b")))
    }

    func testExplicitIndependentCriticAndModelArePreserved() throws {
        let plan = try XCTUnwrap(KistRunner.evolutionProviderPlan(
            primary: ProviderBinding(providerId: "codex-cli", model: "gpt-5.6"),
            explicitCritic: ProviderBinding(providerId: "ollama", model: "qwen2.5-coder:7b"),
            availableProviderIDs: ["codex-cli", "ollama"]
        ))
        XCTAssertEqual(plan.author, ProviderBinding(providerId: "codex-cli", model: "gpt-5.6-sol"))
        XCTAssertEqual(plan.adversary, ProviderBinding(providerId: "ollama", model: "qwen2.5-coder:7b"))
        XCTAssertEqual(plan.reviewGrade, .independent)
        XCTAssertTrue(plan.independent)
    }

    func testAutomaticAdversaryUsesItsOwnDefaultModel() throws {
        let plan = try XCTUnwrap(KistRunner.evolutionProviderPlan(
            primary: ProviderBinding(providerId: "codex-cli", model: "gpt-5.6"),
            explicitCritic: nil,
            availableProviderIDs: ["codex-cli", "claude-cli"]
        ))
        XCTAssertEqual(plan.adversary.providerId, "claude-cli")
        XCTAssertNil(plan.adversary.model, "a Codex model identifier must never be sent to Claude")
    }

    func testSameProviderOrUnavailableExplicitCriticFailsClosed() {
        XCTAssertNil(KistRunner.evolutionProviderPlan(
            primary: ProviderBinding(providerId: "codex-cli"),
            explicitCritic: ProviderBinding(providerId: "codex-cli"),
            availableProviderIDs: ["codex-cli", "ollama"]
        ))
        XCTAssertNil(KistRunner.evolutionProviderPlan(
            primary: ProviderBinding(providerId: "codex-cli"),
            explicitCritic: ProviderBinding(providerId: "ollama"),
            availableProviderIDs: ["codex-cli"]
        ))
    }

    func testUnavailablePrimaryFailsClosedInsteadOfSubstitutingAnAuthor() {
        let plan = KistRunner.evolutionProviderPlan(
            primary: ProviderBinding(providerId: "missing", model: "foreign-model"),
            explicitCritic: nil,
            availableProviderIDs: ["ollama", "codex-cli"]
        )
        XCTAssertNil(plan, "an unavailable requested brain must not be silently replaced")
    }

    func testFreshContextSameModelRequiresExplicitCanonicalIdentityMatch() throws {
        let plan = try XCTUnwrap(KistRunner.evolutionProviderPlan(
            primary: ProviderBinding(providerId: "codex-cli", model: "gpt-5.6"),
            explicitCritic: ProviderBinding(providerId: "codex-cli", model: "gpt-5.6-sol"),
            availableProviderIDs: ["codex-cli"],
            reviewGrade: .freshContextSameModel
        ))
        XCTAssertEqual(plan.authorIdentity, "codex-cli:gpt-5.6-sol")
        XCTAssertEqual(plan.adversaryIdentity, "codex-cli:gpt-5.6-sol")
        XCTAssertEqual(plan.author.model, "gpt-5.6-sol")
        XCTAssertEqual(plan.reviewGrade, .freshContextSameModel)
        XCTAssertFalse(plan.independent)

        XCTAssertNil(KistRunner.evolutionProviderPlan(
            primary: ProviderBinding(providerId: "codex-cli", model: "gpt-5.6-sol"),
            explicitCritic: ProviderBinding(providerId: "codex-cli", model: "other"),
            availableProviderIDs: ["codex-cli"],
            reviewGrade: .freshContextSameModel
        ))
        XCTAssertNil(KistRunner.evolutionProviderPlan(
            primary: ProviderBinding(providerId: "codex-cli", model: "gpt-5.6-sol"),
            explicitCritic: ProviderBinding(providerId: "ollama", model: "gpt-5.6-sol"),
            availableProviderIDs: ["codex-cli", "ollama"],
            reviewGrade: .freshContextSameModel
        ))
    }

    func testSameProviderStillRejectedWithoutFreshContextGrade() {
        XCTAssertNil(KistRunner.evolutionProviderPlan(
            primary: ProviderBinding(providerId: "codex-cli", model: "gpt-5.6-sol"),
            explicitCritic: ProviderBinding(providerId: "codex-cli", model: "gpt-5.6-sol"),
            availableProviderIDs: ["codex-cli"]
        ))
    }

    func testSameModelReviewCannotRenderAnActivationReceipt() {
        let receipt = EvolutionReviewReceipt(
            grade: .freshContextSameModel, independent: false,
            authorIdentity: "codex-cli:gpt-5.6-sol",
            criticIdentity: "codex-cli:gpt-5.6-sol",
            authorInvocationID: "author-call", criticInvocationID: "critic-call",
            freshConversation: true, separateInvocation: true)
        XCTAssertNil(KistRunner.evolutionReviewReceiptLine(receipt),
                     "same-model advisory evidence must never render activated/promoted")
    }

    func testIndependentReviewReceiptLineIsStableJSON() throws {
        let receipt = EvolutionReviewReceipt(
            grade: .independent, independent: true,
            authorIdentity: "codex-cli:gpt-5.6-sol",
            criticIdentity: "claude-cli:claude-opus-4-1",
            authorInvocationID: "author-call", criticInvocationID: "critic-call",
            freshConversation: true, separateInvocation: true)
        let line = try XCTUnwrap(KistRunner.evolutionReviewReceiptLine(receipt))
        XCTAssertTrue(line.hasPrefix("KIST_EVOLUTION_REVIEW_RECEIPT: {"))
        XCTAssertTrue(line.contains("\"grade\":\"independent\""))
        XCTAssertTrue(line.contains("\"independent\":true"))
        XCTAssertTrue(line.contains("\"freshConversation\":true"))
        XCTAssertTrue(line.contains("\"separateInvocation\":true"))
        XCTAssertTrue(line.contains("\"outcome\":\"quarantinedHardContainment\""))
        XCTAssertTrue(line.contains("\"activated\":false"))
    }
}
