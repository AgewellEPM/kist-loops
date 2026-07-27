import XCTest
@testable import AgentCore

/// Phase 3.2 — repo-map: symbol extraction + relevance ranking. Pure over (files, goal).
final class RepoMapTests: XCTestCase {
    func testExtractsSwiftSymbols() {
        let s = "import Foundation\npublic struct Parser {}\nfunc parseToken() {}\nprivate enum Kind { case a }"
        let syms = RepoMap.symbols(in: s, path: "P.swift")
        XCTAssertTrue(syms.contains("Parser"))
        XCTAssertTrue(syms.contains("parseToken"))
        XCTAssertTrue(syms.contains("Kind"))
    }
    func testExtractsMultiLanguage() {
        XCTAssertTrue(RepoMap.symbols(in: "def handle(): pass", path: "x.py").contains("handle"))
        XCTAssertTrue(RepoMap.symbols(in: "export function run() {}", path: "x.ts").contains("run"))
        XCTAssertTrue(RepoMap.symbols(in: "pub fn build() {}", path: "x.rs").contains("build"))
    }
    func testRenderRanksRelevantFilesFirst() {
        let files = [("Sources/Parser.swift", "struct Parser { func parseToken() {} }"),
                     ("Sources/Unrelated.swift", "struct Widget { func draw() {} }")]
        let map = RepoMap.render(files: files, goal: "fix the token parser")
        XCTAssertTrue(map.contains("Repo map"))
        // Parser file (matches 'parser'/'token') ranks before Unrelated.
        let pIdx = map.range(of: "Parser.swift")!.lowerBound
        let uIdx = map.range(of: "Unrelated.swift")?.lowerBound
        if let uIdx { XCTAssertLessThan(pIdx, uIdx) }
    }
    func testEmptyWhenNoSymbols() {
        XCTAssertEqual(RepoMap.render(files: [("readme.md", "just prose here")], goal: "x"), "")
    }
}
