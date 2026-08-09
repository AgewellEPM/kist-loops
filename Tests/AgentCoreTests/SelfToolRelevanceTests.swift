import XCTest
@testable import AgentCore

/// P2 — the pure self__ surfacing matcher + its fail-open contract, and per-site pins that the loop wires it
/// at BOTH protocol seams while keeping `toolNames` (self-evolution's tool universe) unfiltered.
final class SelfToolRelevanceTests: XCTestCase {

    private func man(_ name: String, _ desc: String, _ contract: String) -> SelfAuthoredManifest {
        SelfAuthoredManifest(name: name, description: desc, interpreter: "/bin/bash", scriptFile: "tool.sh",
                             parameters: [], contract: contract, testArgs: [:], testExpectSubstring: "")
    }

    private var four: [SelfAuthoredManifest] {
        [man("self__add", "Prints the arithmetic sum of two integers", "Given --a and --b, prints their sum."),
         man("self__zipdir", "Compresses a directory into a zip archive", "Given --path, writes a zip."),
         man("self__fetchurl", "Fetches a URL and prints the body", "Given --url, prints the response."),
         man("self__jsonfmt", "Pretty-prints a JSON document", "Given --file, prints formatted JSON.")]
    }

    func testTokenlessToolIsAlwaysSurfaced() {
        // review #2: a tool whose ENTIRE haystack tokenizes to nothing (name/desc/contract all stopwords or
        // <3 chars) can never be positively matched, so it must be surfaced whenever we DO trim — never hidden.
        let degenerate = man("self__use", "use it", "use")   // 'use'/'it' → empty haystack
        let ms = four + [degenerate]                          // 5 tools, >surfaceAllBelow
        let keep = SelfToolRelevance.relevant(goal: "add two numbers", manifests: ms)
        XCTAssertNotNil(keep, "self__add matched, so the set trims")
        XCTAssertTrue(keep!.contains("self__use"), "the token-less tool must ALWAYS be surfaced (fail-open per tool)")
        XCTAssertTrue(keep!.contains("self__add"), "the matched tool is kept")
        XCTAssertFalse(keep!.contains("self__zipdir"), "a real non-matching tool is still trimmed")
    }

    func testSnakeCaseToolNameSplitsIntoMatchableTokens() {
        // review #4: a multi-word snake_case name must contribute its WORDS, not one glued token.
        let snake = man("self__do_thing", "handles it", "does the work")   // name is the only real signal
        let ms = four + [snake]
        let keep = SelfToolRelevance.relevant(goal: "do the thing please", manifests: ms)
        XCTAssertNotNil(keep)
        XCTAssertTrue(keep!.contains("self__do_thing"), "'thing' from the goal must overlap the split name token")
        XCTAssertFalse(keep!.contains("self__zipdir"), "an unrelated tool is trimmed")
    }

    func testPositiveMatchKeepsOnlyRelevant() {
        let keep = SelfToolRelevance.relevant(goal: "add two numbers together", manifests: four)
        XCTAssertEqual(keep, ["self__add"], "only the summing tool overlaps 'add' — the rest are dropped from advertisement")
    }

    func testNoMatchFailsOpen() {
        // A goal that overlaps nothing must return nil (= surface ALL), never an empty set (= hide all).
        XCTAssertNil(SelfToolRelevance.relevant(goal: "xyzzy plugh frobnicate", manifests: four),
                     "no overlap must FAIL OPEN (surface all), never hide every tool")
    }

    func testSmallPopulationFailsOpen() {
        XCTAssertNil(SelfToolRelevance.relevant(goal: "add", manifests: Array(four.prefix(3))),
                     "<= surfaceAllBelow (3) tools ⇒ not worth trimming ⇒ surface all")
    }

    func testEmptyGoalFailsOpen() {
        XCTAssertNil(SelfToolRelevance.relevant(goal: "  ", manifests: four))
        XCTAssertNil(SelfToolRelevance.relevant(goal: "a b c", manifests: four), "no token >= 3 chars ⇒ surface all")
    }

    func testDeterministic() {
        let a = SelfToolRelevance.relevant(goal: "fetch a url and format the json", manifests: four)
        let b = SelfToolRelevance.relevant(goal: "fetch a url and format the json", manifests: four)
        XCTAssertEqual(a, b, "matcher must be a pure function of (goal, manifests) — a native→text downgrade re-derives the same surface")
        XCTAssertEqual(a, ["self__fetchurl", "self__jsonfmt"], "both overlapping tools kept")
    }

    // PER-SITE wiring (multi-site discipline): the filter must be applied at BOTH the text seam (driveText) and
    // the native seam (driveNative), and `toolNames` must stay FULL (self-evolution's universe). A single-site
    // regression (r3/r5/r6 shape) would silently trim one protocol or starve CapabilityDiscovery.
    func testLoopWiresFilterAtBothSeamsAndKeepsToolNamesFull() throws {
        let src = try String(contentsOfFile: Self.loopSourcePath, encoding: .utf8)
        let wired = src.components(separatedBy: "surfaceRelevantSelfTools(Self.conversationalToolset").count - 1
        XCTAssertEqual(wired, 2, "the surfacing filter must wrap conversationalToolset at BOTH seams (text + native), not one")
        XCTAssertTrue(src.contains("public var toolNames: [String] { tools.all().map { $0.name } }"),
                      "toolNames must stay on the FULL registry — self-evolution/CapabilityDiscovery must see every self__ tool")
    }

    private static var loopSourcePath: String {
        let here = URL(fileURLWithPath: #filePath)                 // Tests/AgentCoreTests/…
        return here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCore/HeadlessAgentLoop.swift").path
    }
}
