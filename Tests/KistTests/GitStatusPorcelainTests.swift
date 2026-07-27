import XCTest
@testable import Kist

/// `workingTreeChangedFiles` must include UNTRACKED files — a from-scratch task's files are all untracked
/// (the loop never `git add`s), and the old `git diff HEAD` missed them entirely, emptying the continuity
/// note → the loop re-created work → DUPLICATE packages. These pin the porcelain parser.
final class GitStatusPorcelainTests: XCTestCase {

    func testParsesUntrackedModifiedAndAdded() {
        let out = """
        ?? Package.swift
        ?? Sources/MathKit/MathKit.swift
         M README.md
        A  Tests/MathKitTests/MathKitTests.swift
        """
        XCTAssertEqual(KistRunner_parse(out), [
            "Package.swift", "Sources/MathKit/MathKit.swift", "README.md", "Tests/MathKitTests/MathKitTests.swift",
        ])
    }

    func testRenameTakesNewPath() {
        XCTAssertEqual(KistRunner_parse("R  old/name.swift -> new/name.swift"), ["new/name.swift"])
    }

    func testUnquotesOddPaths() {
        XCTAssertEqual(KistRunner_parse(#"?? "Sources/My Dir/File.swift""#), ["Sources/My Dir/File.swift"])
    }

    func testEmptyAndBlankLinesIgnored() {
        XCTAssertEqual(KistRunner_parse("\n\n?? a.swift\n"), ["a.swift"])
    }

    // KistREPL.parseGitStatusPorcelain is on KistREPL; alias for readability.
    private func KistRunner_parse(_ s: String) -> [String] { KistREPL.parseGitStatusPorcelain(s) }
}
