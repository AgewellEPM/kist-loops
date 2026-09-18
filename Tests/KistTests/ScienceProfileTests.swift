import XCTest
@testable import Kist

/// Pins the science-loops REPL profile (Luke 2026-09-18): the `science` launcher sets
/// KIST_SCIENCE_PROFILE=1 and the SAME kist REPL presents the science identity — green `science`
/// brand in the startup header, science-word hints, and the SCIENCE status block at launch.
/// Per the multi-site fix discipline BOTH render variants are pinned: the science header must
/// carry the science identity AND the default kist header must be byte-stable (no accidental
/// rebrand of the coding REPL).
final class ScienceProfileTests: XCTestCase {

    // MARK: science header variant

    func testScienceHeaderCarriesScienceBrandAndWordHints() {
        let out = StartupHeader.render(mode: "auto-routing", projectRoot: "/tmp/x",
                                       planMode: false, science: true)
        XCTAssertTrue(out.contains("\u{001B}[32;1mscience\u{001B}[0m"),
                      "science profile must brand the header with the green science wordmark")
        XCTAssertFalse(out.contains("\u{001B}[36;1mkist\u{001B}[0m"),
                       "science profile must not ALSO show the kist brand")
        XCTAssertTrue(out.contains("peel = science status"),
                      "hint line must teach the peel word")
        XCTAssertTrue(out.contains("lois = arm the PEEL gate"),
                      "hint line must teach the lois word")
    }

    func testScienceHeaderKeepsModeVersionAndPath() {
        let out = StartupHeader.render(mode: "auto-routing", projectRoot: "/tmp/x",
                                       planMode: false, science: true)
        XCTAssertTrue(out.contains("auto-routing"), "mode survives the rebrand")
        XCTAssertTrue(out.contains(KistBuildInfo.startupLabel), "version survives the rebrand")
        XCTAssertTrue(out.contains("/model to pin"), "model pin hint survives the rebrand")
    }

    func testScienceHeaderColorOffIsPlainText() {
        let out = StartupHeader.render(mode: "auto-routing", projectRoot: "/tmp/x",
                                       planMode: false, color: false, science: true)
        XCTAssertTrue(out.contains("science"))
        XCTAssertFalse(out.contains("\u{001B}["), "color: false must emit no ANSI at all")
    }

    // MARK: default header regression pin (site 2 of 2)

    func testDefaultHeaderIsUnchangedByTheScienceParameter() {
        let out = StartupHeader.render(mode: "auto-routing", projectRoot: "/tmp/x",
                                       planMode: false)
        XCTAssertTrue(out.contains("\u{001B}[36;1mkist\u{001B}[0m"),
                      "default header keeps the cyan kist brand")
        XCTAssertFalse(out.contains("science"),
                       "default header must not leak any science-profile text")
        XCTAssertFalse(out.contains("peel"), "default hint line is untouched")
        XCTAssertTrue(out.contains("↳ just type · /model to pin · /help"))
    }

    // MARK: profile flag plumbing

    func testScienceProfileEnvContract() {
        XCTAssertTrue(KistREPL.scienceProfileDefault(env: ["KIST_SCIENCE_PROFILE": "1"]))
        XCTAssertFalse(KistREPL.scienceProfileDefault(env: [:]),
                       "unset variable means the plain kist identity")
        XCTAssertFalse(KistREPL.scienceProfileDefault(env: ["KIST_SCIENCE_PROFILE": "0"]))
        XCTAssertFalse(KistREPL.scienceProfileDefault(env: ["KIST_SCIENCE_PROFILE": "true"]),
                       "only the literal \"1\" opts in — no truthy parsing")
    }
}
