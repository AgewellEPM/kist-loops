import XCTest
import AgentCore
@testable import Kist

/// A deterministic ReviewSources for tests — no real git/ripgrep.
private struct FixedReviewSources: ReviewSources {
    var changed: [String] = []
    var glob: [String] = []
    var symbol: [String] = []
    func changedFiles() -> [String] { changed }
    func filesMatchingGlob(_ pattern: String) -> [String] { glob }
    func filesContainingSymbol(_ s: String) -> [String] { symbol }
}

final class ReviewContextTests: XCTestCase {

    func testDoesNotRenderForNonReviewRequest() {
        let ctx = ReviewContext.renderIfNeeded(request: "build the parser", projectRoot: "/repo",
                                               sources: FixedReviewSources()) { _, _ in "" }
        XCTAssertNil(ctx)
    }

    // CHANGED-FILES FALLBACK: a generic "review recent changes" resolves nothing specific, so it falls back
    // to the git-changed set (status + last-5-commits) and renders it through the tier-aware Prompts.review.
    func testChangedFilesFallbackRendersResolvedFilesViaReviewPrompt() {
        let ctx = ReviewContext.renderIfNeeded(request: "review the latest changes", projectRoot: "/repo",
                                               sources: FixedReviewSources()) { _, args in
            if args == ["status", "--porcelain"] {
                return """
                 M Sources/Kist/KistRunner.swift
                ?? Sources/Kist/ReviewContext.swift
                R  old.swift -> Sources/Kist/NewName.swift
                """
            }
            if args == ["log", "-n", "5", "--name-only", "--format="] {
                return "Sources/AgentCore/PromptCompiler.swift\nTests/KistTests/ReviewContextTests.swift"
            }
            return nil
        }!

        XCTAssertTrue(ctx.contains("strategy: changed-files"), ctx)
        XCTAssertTrue(ctx.contains("STRICT CODE REVIEW"))          // rendered via Prompts.review
        XCTAssertTrue(ctx.contains("Sources/Kist/KistRunner.swift"))
        XCTAssertTrue(ctx.contains("Sources/Kist/NewName.swift"))   // rename → new name
        XCTAssertTrue(ctx.contains("Sources/AgentCore/PromptCompiler.swift"))
        XCTAssertTrue(ctx.contains("file:line"))                    // no-fabrication rule preserved
    }

    // TARGETED SYMBOL REVIEW (the newly-wired capability): a request naming code resolves via the symbol
    // strategy to the files that mention it — no directory dump — and renders those exact files.
    func testResolvesSymbolTargetIntoReviewPrompt() {
        let sources = FixedReviewSources(symbol: ["Sources/AgentCore/BudgetLedger.swift"])
        let ctx = ReviewContext.renderIfNeeded(request: "review the budget reserve logic", projectRoot: "/repo",
                                               providerId: "anthropic", model: "claude-opus-4-8",
                                               sources: sources) { _, _ in "" }!
        XCTAssertTrue(ctx.contains("strategy: symbol"), ctx)
        XCTAssertTrue(ctx.contains("Sources/AgentCore/BudgetLedger.swift"))
        XCTAssertTrue(ctx.contains("STRICT CODE REVIEW"))
    }

    // No resolution + nothing changed ⇒ an honest "name a target / REVIEW INCOMPLETE", never a fabricated review.
    func testUnresolvableReviewAsksForATargetAndForbidsFabrication() {
        let ctx = ReviewContext.renderIfNeeded(request: "please review", projectRoot: "/repo",
                                               sources: FixedReviewSources()) { _, _ in "" }!
        XCTAssertTrue(ctx.contains("none resolved"))
        XCTAssertTrue(ctx.contains("REVIEW INCOMPLETE"))
        // HARD negative: an unresolved review must NOT also render a review prompt — no fabricated review body.
        XCTAssertFalse(ctx.contains("STRICT CODE REVIEW"))
        XCTAssertFalse(ctx.contains("REVIEW TARGETING · strategy:"))
    }

    func testUnsafePathsAreFilteredFromReviewTargets() {
        let files = ReviewContext.reviewTargets(projectRoot: "/repo") { _, args in
            if args == ["status", "--porcelain"] {
                return """
                ?? ../escape.swift
                ?? /tmp/absolute.swift
                ?? Sources/Safe.swift
                ?? .git/config
                """
            }
            return ""
        }

        XCTAssertEqual(files, ["Sources/Safe.swift"])
    }

    func testReviewLikeDetectionCoversAuditAndFailureLanguage() {
        XCTAssertTrue(ReviewContext.isReviewLike("audit this for vulnerabilities"))
        XCTAssertTrue(ReviewContext.isReviewLike("what is broken in the new work"))
        XCTAssertTrue(ReviewContext.isReviewLike("find failure points"))
        XCTAssertFalse(ReviewContext.isReviewLike("implement the feature"))
    }
}
