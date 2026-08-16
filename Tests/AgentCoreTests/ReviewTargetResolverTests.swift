import XCTest
@testable import AgentCore

final class ReviewTargetResolverTests: XCTestCase {

    func testFoundationGlobFallbackPrunesCachesAndHonorsWalkBudget() throws {
        let root = NSTemporaryDirectory() + "review-glob-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        func write(_ relative: String) throws {
            let path = root + "/" + relative
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try "let marker = true\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
        try write("Sources/App.swift")
        try write(".cache/toolchain/Hidden.swift")
        try write("Library/Mobile Documents/Hidden.swift")

        XCTAssertEqual(
            GitRipgrepReviewSources.fallbackGlob("**/*.swift", root: root),
            ["Sources/App.swift"])
        XCTAssertTrue(GitRipgrepReviewSources.fallbackGlob(
            "**/*.swift", root: root, maxWalkEntries: 1).count <= 1)
    }

    /// Stub sources: deterministic, no git/ripgrep needed.
    private struct Stub: ReviewSources {
        var changed: [String] = []
        var byGlob: [String: [String]] = [:]
        var bySymbol: [String: [String]] = [:]
        func changedFiles() -> [String] { changed }
        func filesMatchingGlob(_ pattern: String) -> [String] { byGlob[pattern] ?? [] }
        func filesContainingSymbol(_ symbol: String) -> [String] { bySymbol[symbol] ?? [] }
    }

    func testRecentChangesRoutesToGitChangedSet() {
        let s = Stub(changed: ["Sources/A.swift", "Sources/B.swift", "README.md"])
        let plan = ReviewTargetResolver.resolve(target: "review the recent changes", sources: s)
        XCTAssertEqual(plan.strategy, "changed-files")
        XCTAssertEqual(plan.files, ["Sources/A.swift", "Sources/B.swift"])   // .md filtered out
    }

    func testSubsystemWordRoutesToDirectory() {
        let s = Stub(byGlob: ["**/Security/**/*.swift": ["Sources/AgentCore/Security/SecretScanner.swift"]])
        let plan = ReviewTargetResolver.resolve(target: "review the security layer", sources: s)
        XCTAssertEqual(plan.strategy, "subsystem")
        XCTAssertTrue(plan.files.contains("Sources/AgentCore/Security/SecretScanner.swift"))
    }

    func testSymbolSearchRanksByTokenHits() {
        let s = Stub(bySymbol: [
            "persona": ["Sources/Specialist/TaskPersonaMatcher.swift", "Sources/Other.swift"],
            "matcher": ["Sources/Specialist/TaskPersonaMatcher.swift"],
        ])
        let plan = ReviewTargetResolver.resolve(target: "review the persona matcher logic", sources: s)
        XCTAssertEqual(plan.strategy, "symbol")
        XCTAssertEqual(plan.files.first, "Sources/Specialist/TaskPersonaMatcher.swift")   // 2 token hits → ranked first
    }

    // MiMo MED: subsystem match must be a whole TOKEN — "toolbar" must NOT route to the tool subsystem.
    func testSubsystemMatchesWholeTokenNotSubstring() {
        let s = Stub(byGlob: ["**/Tools/**/*.swift": ["Sources/Tools/X.swift"]])
        // "tool" as a real token → routes to the tool subsystem
        XCTAssertEqual(ReviewTargetResolver.resolve(target: "review the tool layer", sources: s).strategy, "subsystem")
        // "toolbar" must NOT trigger the tool subsystem (substring would have)
        XCTAssertNotEqual(ReviewTargetResolver.resolve(target: "review the toolbar layout", sources: s).strategy, "subsystem")
    }

    // MiMo's LOW finding was FALSE — a version-string token like "v2.0" must NOT trigger the path route
    // (the path route requires .swift / `/` / `*`, not any dot). Pin that it stays correct.
    func testVersionStringDoesNotTriggerPathRoute() {
        let plan = ReviewTargetResolver.resolve(target: "review the v2.0 release notes", sources: Stub())
        XCTAssertNotEqual(plan.strategy, "path")
    }

    func testExplicitPathRoutesDirectly() {
        let s = Stub(byGlob: ["Sources/AgentCore/Prompts/Prompts.swift": ["Sources/AgentCore/Prompts/Prompts.swift"]])
        let plan = ReviewTargetResolver.resolve(target: "review Sources/AgentCore/Prompts/Prompts.swift", sources: s)
        XCTAssertEqual(plan.strategy, "path")
    }

    func testUnresolvableTargetIsHonestNotFabricated() {
        let plan = ReviewTargetResolver.resolve(target: "review the flarbleglorp", sources: Stub())
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.strategy, "unresolved")
        XCTAssertTrue(plan.rationale.contains("ask the user"))   // doesn't invent files
    }

    func testCapLimitsFileCount() {
        let many = (1...30).map { "Sources/F\($0).swift" }
        let plan = ReviewTargetResolver.resolve(target: "recent changes", sources: Stub(changed: many), limit: 5)
        XCTAssertEqual(plan.files.count, 5)
    }

    // MARK: ModelTier + Prompts

    func testModelTierClassification() {
        XCTAssertEqual(ModelTier.of(providerId: "anthropic", model: "claude-opus-4"), .strong)
        XCTAssertEqual(ModelTier.of(providerId: "openai", model: "gpt-5"), .strong)
        XCTAssertEqual(ModelTier.of(providerId: "mimo", model: "mimo-v2.5-pro"), .weak)        // unknown provider → weak
        XCTAssertEqual(ModelTier.of(providerId: "gemini", model: "gemini-2.5-flash"), .weak)   // flash → weak
        XCTAssertEqual(ModelTier.of(providerId: "ollama", model: "llama3.1"), .weak)
    }

    func testBatcherSplitsLargeReviewByTier() {
        let files = (1...10).map { "F\($0).swift" }
        let plan = ReviewPlan(files: files, strategy: "symbol", rationale: "matched X")
        let weakPasses = ReviewBatcher.passes(plan, tier: .weak)   // 3/pass → 4 passes (3,3,3,1)
        XCTAssertEqual(weakPasses.count, 4)
        XCTAssertEqual(weakPasses[0].files, ["F1.swift", "F2.swift", "F3.swift"])
        XCTAssertEqual(weakPasses[3].files, ["F10.swift"])
        XCTAssertTrue(weakPasses[1].rationale.contains("pass 2 of 4"))
        let strongPasses = ReviewBatcher.passes(plan, tier: .strong)  // 8/pass → 2 passes
        XCTAssertEqual(strongPasses.count, 2)
        // a small review is one pass
        XCTAssertEqual(ReviewBatcher.passes(ReviewPlan(files: ["A.swift"], strategy: "x", rationale: "y"), tier: .weak).count, 1)
        XCTAssertTrue(ReviewBatcher.passes(ReviewPlan(files: [], strategy: "x", rationale: "y"), tier: .weak).isEmpty)
    }

    func testWeakReviewPromptHasHeavyScaffolding() {
        let plan = ReviewPlan(files: ["A.swift", "B.swift"], strategy: "symbol", rationale: "matched X")
        let weak = Prompts.review(plan: plan, tier: .weak)
        XCTAssertTrue(weak.contains("read EACH one fully"))
        XCTAssertTrue(weak.contains("do NOT list directories"))
        XCTAssertTrue(weak.contains("1. A.swift"))                 // the resolved files are handed over
        XCTAssertTrue(weak.contains("file:line"))                  // no-fabrication rule present
        let strong = Prompts.review(plan: plan, tier: .strong)
        XCTAssertFalse(strong.contains("do NOT list directories")) // lighter scaffolding for strong models
        XCTAssertTrue(strong.contains("file:line"))
    }
}
