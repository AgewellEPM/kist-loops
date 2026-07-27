import XCTest
@testable import AgentCore

final class SearchCodeRipgrepTests: XCTestCase {
    private var root: String!
    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "search-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base + "/src", withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
        try "func alpha() {}\nlet x = 1\n".write(toFile: root + "/src/a.swift", atomically: true, encoding: .utf8)
        try "TODO: fix\nfunc beta() {}\n".write(toFile: root + "/src/b.swift", atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(atPath: root) } }
    private var ctx: ToolContext { ToolContext(projectRoot: root) }

    func testContentModeFindsMatches() async throws {
        let r = try await SearchCodeTool().execute(arguments: ["pattern": "func \\w+", "output_mode": "content"], context: ctx)
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("a.swift"))
        XCTAssertTrue(r.output.contains("alpha"))
    }

    func testFilesModeReturnsPathsOnly() async throws {
        let r = try await SearchCodeTool().execute(arguments: ["pattern": "func", "output_mode": "files"], context: ctx)
        XCTAssertTrue(r.output.contains("a.swift"))
        if r.metadata["engine"] == "ripgrep" {
            XCTAssertFalse(r.output.contains("alpha"))   // true files mode → no match text (rg only)
        }
    }

    func testRipgrepEngineUsedWhenAvailable() async throws {
        // Documents which engine ran (rg on a real dev box, foundation in a bare sandbox) — both valid.
        let r = try await SearchCodeTool().execute(arguments: ["pattern": "func"], context: ctx)
        XCTAssertTrue(["ripgrep", "foundation"].contains(r.metadata["engine"] ?? ""))
    }

    func testNoMatch() async throws {
        let r = try await SearchCodeTool().execute(arguments: ["pattern": "zzznotfound"], context: ctx)
        XCTAssertTrue(r.output.contains("(no matches)"))
    }

    func testPathEscapeRefused() async {
        do {
            _ = try await SearchCodeTool().execute(arguments: ["pattern": "x", "path": "../.."], context: ctx)
            XCTFail("escaping search path must throw")
        } catch { /* expected pathEscape */ }
    }

    // The pure-Foundation fallback must work identically when ripgrep is absent.
    func testFoundationFallbackFindsMatches() throws {
        let confined = try ctx.confinedRoot()
        let r = try SearchCodeTool().swiftWalkSearch(pattern: "beta", base: ".", glob: nil,
                                                     caseInsensitive: false, limit: 200, confined: confined)
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("b.swift"))
        XCTAssertEqual(r.metadata["engine"], "foundation")
    }

    func testInvalidRegexInFallback() throws {
        let confined = try ctx.confinedRoot()
        let r = try SearchCodeTool().swiftWalkSearch(pattern: "(unclosed", base: ".", glob: nil,
                                                     caseInsensitive: false, limit: 10, confined: confined)
        XCTAssertFalse(r.success)
    }
}
