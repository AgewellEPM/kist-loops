import XCTest
@testable import Kist

/// Pins for the 2026-08-03 UI regressions (multi-site fix ⇒ one assertion PER SITE):
/// (1) WHITE-OUT — sticky-turn capture dup2's a pipe onto stdout, so every LIVE
///     `isatty(fileno(stdout))` color decision went false mid-turn (and a TerminalEventSink
///     constructed mid-capture cached color=false for the session). Fix: launch-time snapshot
///     (`TerminalCapabilities.stdoutIsInteractive`), primed in main.swift before any capture.
/// (2) RESIZE CORRUPTION + contract violation — the wrapper force-injected --sticky-turns
///     (19dbb9c) and the compiled default flipped true (ad23c69), both against the project
///     CLAUDE.md "opt-in only" rule. Fix: default false + wrapper passes flags through.
/// (3) DEAD TOOLCHAIN — the wrapper exported a sanitized PATH without /opt/homebrew/bin,
///     so every `brew`/`nasm`/`dosbox-x` run_command died "executable not found".
final class UIRegression20260803Tests: XCTestCase {
    private func repoRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            dir.deleteLastPathComponent()
        }
        return dir
    }
    private func source(_ rel: String) -> String {
        (try? String(contentsOf: repoRoot().appendingPathComponent(rel), encoding: .utf8)) ?? ""
    }

    // MARK: - (1) Launch-time TTY snapshot — one pin per color-decision site

    func testMainPrimesTheSnapshotBeforeAnythingElse() {
        let main = source("Sources/Kist/main.swift")
        let prime = main.range(of: "TerminalCapabilities.prime()")
        let parse = main.range(of: "KistOptions.parse(")
        XCTAssertNotNil(prime, "main.swift must prime the TTY snapshot at startup")
        XCTAssertNotNil(parse)
        if let prime, let parse {
            XCTAssertLessThan(prime.lowerBound, parse.lowerBound,
                              "prime() must run before options/REPL wiring — a lazy static touched mid-capture caches the wrong value")
        }
    }

    func testTerminalEventSinkDefaultUsesSnapshot() {
        let src = source("Sources/Kist/TerminalEventSink.swift")
        XCTAssertTrue(src.contains("color: Bool = (TerminalCapabilities.stdoutIsInteractive"),
                      "TerminalEventSink.init default color must use the launch snapshot")
        XCTAssertFalse(src.contains("isatty(fileno(stdout))"),
                       "TerminalEventSink must not read live isatty — a sink built mid-capture caches color=false")
    }

    func testTerminalInteractorDefaultUsesSnapshot() {
        let src = source("Sources/Kist/TerminalInteractor.swift")
        XCTAssertTrue(src.contains("color: Bool = TerminalCapabilities.stdoutIsInteractive"),
                      "TerminalInteractor.init default color must use the launch snapshot")
        XCTAssertFalse(src.contains("isatty(fileno(stdout))"))
    }

    func testStdoutColorEnabledDefaultUsesSnapshot() {
        let src = source("Sources/Kist/KistREPL+TaskBoard.swift")
        XCTAssertTrue(src.contains("isTTY: Bool = TerminalCapabilities.stdoutIsInteractive"),
                      "stdoutColorEnabled (the central REPL color gate) must use the launch snapshot")
        XCTAssertFalse(src.contains("isatty(fileno(stdout))"))
    }

    func testKistRunnerHasNoLiveIsattyColorDecisions() {
        // The self-test's fail-closed guard may keep live isatty; COLOR decisions must not.
        XCTAssertFalse(source("Sources/Kist/KistRunner.swift").contains("color: isatty(fileno(stdout))"),
                       "KistRunner color args (grounding render, council cards) must use the snapshot")
    }

    func testNoNewLiveIsattyColorSitesCreepIn() throws {
        // Allow-list per SPELLING: the snapshot itself; TerminalMediaRenderer (transport guard for
        // inline-image protocols — emitting APC/DCS into a captured pipe would be wrong); KistRunner's
        // sticky-bar-self-test entry guard; and the STDOUT_FILENO transport guards (the coordinator's
        // own TTY detection + ModelPicker's fail-closed raw-mode gate). Everything else must use
        // TerminalCapabilities.stdoutIsInteractive.
        let allowed: [String: Set<String>] = [
            "isatty(fileno(stdout))": ["TerminalCapabilities.swift", "TerminalMediaRenderer.swift", "KistRunner.swift"],
            "isatty(STDOUT_FILENO)": ["TerminalScreenCoordinator.swift", "ModelPicker.swift"],
        ]
        let kistDir = repoRoot().appendingPathComponent("Sources/Kist")
        let e = FileManager.default.enumerator(at: kistDir, includingPropertiesForKeys: nil)
        var offenders: [String] = []
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "swift", let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (spelling, files) in allowed where !files.contains(url.lastPathComponent) && src.contains(spelling) {
                offenders.append("\(url.lastPathComponent) [\(spelling)]")
            }
        }
        XCTAssertEqual(offenders, [], "live isatty(stdout) reads outside the allow-list: \(offenders) — use TerminalCapabilities.stdoutIsInteractive")
    }

    // MARK: - (2) sticky-turns contract — wrapper site (code-default sites pinned in
    // KistOptionsTests.testStickyTurnsFlag and StickyTurnCoordinatorTests)

    func testWrapperNeverForcesStickyTurns() {
        let wrapper = source("scripts/kist-wrapper")
        XCTAssertFalse(wrapper.isEmpty, "scripts/kist-wrapper is the canonical deployed ~/bin/kist source")
        XCTAssertFalse(wrapper.contains("set -- --sticky-turns"),
                       "CLAUDE.md contract: never force --sticky-turns in the wrapper (19dbb9c regression)")
    }

    // MARK: - (3) wrapper PATH carries the real toolchain

    func testWrapperExportsToolchainPath() throws {
        let wrapper = source("scripts/kist-wrapper")
        XCTAssertTrue(wrapper.contains("/opt/homebrew/bin"),
                      "wrapper PATH must include Homebrew — its absence killed every brew/nasm/dosbox-x step")
        XCTAssertTrue(wrapper.contains("$INSTALL_HOME/bin"),
                      "wrapper PATH must include ~/bin so the perslis/legacy bridges resolve")
        // ORDER pin: system dirs BEFORE the user-writable dirs, on the exported line (not a comment) —
        // a planted /opt/homebrew/bin/git must never shadow /usr/bin/git for the agent runtime.
        let exportLine = try XCTUnwrap(
            wrapper.split(separator: "\n").last { $0.hasPrefix("PATH=") && $0.contains("/opt/homebrew/bin") })
        let usrBin = try XCTUnwrap(exportLine.range(of: "/usr/bin"))
        let homebrew = try XCTUnwrap(exportLine.range(of: "/opt/homebrew/bin"))
        XCTAssertLessThan(usrBin.lowerBound, homebrew.lowerBound,
                          "system dirs must precede user-writable dirs in the exported PATH")
    }
}
