import XCTest
@testable import AgentCore

/// Exercises the Swift-native retriever against a throwaway estate root, so it's deterministic and
/// never touches the real ~/ or /Volumes. No external dependency (rg) required.
final class EstateSearchTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "estate-\(UUID().uuidString)"
        let fm = FileManager.default
        // A tinkyspeak project with content + a decoy project that must NOT surface for the term.
        try fm.createDirectory(atPath: root + "/tinkyspeak-web", withIntermediateDirectories: true)
        try "# TinkySpeak\nAAC board with tinkyspeak TTS wired to use.html.\n"
            .write(toFile: root + "/tinkyspeak-web/README.md", atomically: true, encoding: .utf8)
        try "the tinkyspeak board renders tiles\n"
            .write(toFile: root + "/tinkyspeak-web/app.js", atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: root + "/other-project", withIntermediateDirectories: true)
        try "nothing relevant here, just widgets\n"
            .write(toFile: root + "/other-project/index.js", atomically: true, encoding: .utf8)
        // Junk tree that must be ignored even though it contains the term.
        try fm.createDirectory(atPath: root + "/tinkyspeak-web/node_modules/pkg", withIntermediateDirectories: true)
        try "tinkyspeak tinkyspeak tinkyspeak\n"
            .write(toFile: root + "/tinkyspeak-web/node_modules/pkg/dep.js", atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func testFindsProjectFilesAndIgnoresJunkAndDecoys() throws {
        let search = EstateSearch(roots: [root], maxFiles: 8, timeout: 8)
        let hits = search.search(terms: ["tinkyspeak"])
        let paths = hits.map { $0.path }

        XCTAssertTrue(paths.contains { $0.hasSuffix("tinkyspeak-web/README.md") }, "the project README must be found")
        XCTAssertTrue(paths.contains { $0.hasSuffix("tinkyspeak-web/app.js") }, "the project source must be found")
        XCTAssertFalse(paths.contains { $0.contains("node_modules") }, "junk trees must be ignored")
        XCTAssertFalse(paths.contains { $0.contains("other-project") }, "decoys without the term must not surface")
        // README (doc-like, path+content hit) ranks ahead of the .js source.
        XCTAssertTrue(paths.first!.hasSuffix("README.md"), "doc-like project files rank first")
    }

    func testGroundingBlockCarriesRealSnippets() throws {
        let search = EstateSearch(roots: [root], maxFiles: 8, timeout: 8)
        let block = search.groundingBlock(for: "find what we did for tinkyspeak")
        let g = try XCTUnwrap(block, "a matching query must produce a grounding block")
        XCTAssertTrue(g.contains("AUTO-RETRIEVED"))
        XCTAssertTrue(g.contains("tinkyspeak-web/README.md"))
        XCTAssertTrue(g.lowercased().contains("aac board"), "the actual file snippet must be inlined")
    }

    func testNoMatchReturnsNilSoTurnFallsThrough() throws {
        let search = EstateSearch(roots: [root], maxFiles: 8, timeout: 8)
        XCTAssertNil(search.groundingBlock(for: "find what we did for nonexistentprojectxyz"))
    }

    func testThreeCharacterSubstringCannotNominateUnrelatedQueueFile() throws {
        try "unrelated planning notes\n"
            .write(toFile: root + "/other-project/request-queue.md", atomically: true, encoding: .utf8)
        let search = EstateSearch(roots: [root], maxFiles: 8, timeout: 8)

        XCTAssertTrue(search.search(terms: ["que"]).isEmpty)
    }

    func testGroundingBlockIsBounded() throws {
        let search = EstateSearch(roots: [root], maxFiles: 8, timeout: 8, maxTotalChars: 400)
        if let g = search.groundingBlock(for: "tinkyspeak") {
            XCTAssertLessThan(g.count, 1_600, "total injected context stays bounded")
        }
    }

    func testRootsEnvOverride() {
        let s = EstateSearch(env: ["KIST_ESTATE_ROOTS": "/a:/b", "HOME": "/should-be-ignored"])
        XCTAssertEqual(s.roots, ["/a", "/b"])
    }

    func testDefaultRootsAreHomeAndVolumes() {
        let s = EstateSearch(env: ["HOME": "/Users/x"])
        XCTAssertEqual(s.roots, ["/Users/x", "/Volumes"])
    }

    /// Manual probe (gated by KIST_ESTATE_LIVE=1) against the REAL estate — confirms a live lookup finds
    /// files and returns within the deadline before shipping. Dormant in CI.
    func testLiveEstateProbe() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KIST_ESTATE_LIVE"] == "1", "set KIST_ESTATE_LIVE=1 to run")
        let query = ProcessInfo.processInfo.environment["KIST_ESTATE_QUERY"] ?? "find what we did for tinkyspeak"
        let start = Date()
        let block = EstateSearch().groundingBlock(for: query)
        let elapsed = Date().timeIntervalSince(start)
        print("‹live-probe› query=\"\(query)\" elapsed=\(String(format: "%.2f", elapsed))s hasResult=\(block != nil)")
        if let block { print("‹live-probe› first 1200 chars:\n" + String(block.prefix(1200))) }
        XCTAssertLessThan(elapsed, 12, "must stay within the bounded deadline")
    }
}
