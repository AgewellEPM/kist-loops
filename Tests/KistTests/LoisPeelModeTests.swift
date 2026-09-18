import XCTest
@testable import Kist

/// Pins the "Lois" wake word → Peel gate contract (Luke 2026-09-17): a leading "lois" token — and
/// ONLY a leading token — activates/releases the mode or fires a PEEL-required research pass.
/// Per-site regression pins at the bottom hold BOTH wiring sites (the REPL interceptor and the
/// runner's `requirePEEL` plumb) so a future edit can't silently orphan one of them.
final class LoisPeelModeTests: XCTestCase {

    // MARK: parser

    func testBareWakeWordActivates() {
        let cases = ["lois", "Lois", "LOIS", "  lois  ", "lois!", "Lois,", "lois."]
        for input in cases {
            XCTAssertEqual(LoisIntent.parse(input), .activate, "input: \(input)")
        }
    }

    func testOffWordsDeactivate() {
        let cases = ["lois off", "Lois stop", "lois done", "lois deactivate", "lois out",
                     "lois OFF", "lois,  off "]
        for input in cases {
            XCTAssertEqual(LoisIntent.parse(input), .deactivate, "input: \(input)")
        }
    }

    func testQuestionBecomesResearch() {
        XCTAssertEqual(LoisIntent.parse("lois what stabilizes hemoglobin"),
                       .research("what stabilizes hemoglobin"))
        XCTAssertEqual(LoisIntent.parse("Lois, compare CRISPR delivery vectors"),
                       .research("compare CRISPR delivery vectors"))
        // An off-word with trailing content is a QUESTION, not a release.
        XCTAssertEqual(LoisIntent.parse("lois off the record what is x"),
                       .research("off the record what is x"))
    }

    /// Multilingual research (Luke 2026-09-18: "our models must understand fluent Chinese/Mandarin/
    /// Japanese"). The research question is carried VERBATIM to the model — the science entry point
    /// must preserve CJK bytes exactly (no ASCII-only truncation, no mojibake) so the model receives
    /// the real question. Model fluency is verified live; this pins the SYSTEM round-trip.
    func testCJKResearchQuestionPreservedVerbatim() {
        XCTAssertEqual(LoisIntent.parse("lois 血红蛋白如何运输氧气"),
                       .research("血红蛋白如何运输氧气"), "Mandarin question preserved")
        XCTAssertEqual(LoisIntent.parse("Lois ミオグロビンとは何ですか"),
                       .research("ミオグロビンとは何ですか"), "Japanese question preserved")
        XCTAssertEqual(LoisIntent.parse("lois 蛋白質の構造を説明して"),
                       .research("蛋白質の構造を説明して"), "mixed Han+Kana preserved")
    }

    func testPureCJKMessageIsNotAWakeWord() {
        // A bare CJK message (no leading "lois") must fall through to a normal model turn, not the
        // gate — the wake word is an explicit ASCII token, never triggered by non-Latin prose.
        for msg in ["血红蛋白是什么", "ミオグロビンとは", "こんにちは"] {
            XCTAssertNil(LoisIntent.parse(msg), "\(msg) must not trip the wake word")
        }
    }

    func testNonWakeInputsNeverFire() {
        let cases = ["loisy", "lois's engine", "ask lois later", "hello lois",
                     "eloise", "/lois", "", "   ", "build the login page"]
        for input in cases {
            XCTAssertNil(LoisIntent.parse(input), "input: \(input)")
        }
    }

    // MARK: mode box

    func testModeBoxTogglesAndDefaultsOff() {
        let mode = LoisPeelMode()
        XCTAssertFalse(mode.isActive, "Peel mode must start OFF — never gate research by default")
        mode.isActive = true
        XCTAssertTrue(mode.isActive)
        mode.isActive = false
        XCTAssertFalse(mode.isActive)
    }

    // MARK: wiring pins — one assertion PER SITE (multi-site fix discipline)

    private func source(_ relativePath: String) throws -> String {
        // Tests run from the package tree; walk up from this file to the package root.
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent()   // Tests/KistTests
            .deletingLastPathComponent()                  // Tests
            .deletingLastPathComponent()                  // package root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testReplInterceptorSiteIsWired() throws {
        let repl = try source("Sources/Kist/KistREPL.swift")
        XCTAssertTrue(repl.contains("LoisIntent.parse(input)"),
                      "KistREPL.swift lost the Lois wake-word interceptor")
        XCTAssertTrue(repl.contains("let peelMode = LoisPeelMode()"),
                      "KistREPL.swift lost the shared Peel-mode box")
    }

    func testRunnerRequirePEELSiteIsWired() throws {
        let runner = try source("Sources/Kist/KistRunner.swift")
        XCTAssertTrue(runner.contains("requirePEEL: loisPeelMode.isActive"),
                      "KistRunner.swift research closure no longer plumbs the Lois Peel mode into requirePEEL")
    }

    func testStatusLineSiteIsWired() throws {
        let selfHeal = try source("Sources/Kist/KistREPL+SelfHeal.swift")
        XCTAssertTrue(selfHeal.contains("peelMode.isActive"),
                      "status line lost the ◫lois indicator — operator can no longer see the armed gate")
    }
}
