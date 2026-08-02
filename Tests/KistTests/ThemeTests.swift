import XCTest
import AgentCore
@testable import Kist

/// Pins the /theme palette system, with emphasis on the accessibility guarantees.
final class ThemeTests: XCTestCase {

    func testResolveKnownNames() {
        XCTAssertEqual(Theme.resolve("dark", noColorEnv: false).name, "dark")
        XCTAssertEqual(Theme.resolve("high-contrast", noColorEnv: false).name, "high-contrast")
        XCTAssertEqual(Theme.resolve("colorblind", noColorEnv: false).name, "daltonized", "alias maps to daltonized")
        XCTAssertEqual(Theme.resolve("hc", noColorEnv: false).name, "high-contrast", "alias")
    }

    func testResolveUnknownAndAutoFallBackToDefault() {
        XCTAssertEqual(Theme.resolve("auto", noColorEnv: false).name, "default")
        XCTAssertEqual(Theme.resolve(nil, noColorEnv: false).name, "default")
        XCTAssertEqual(Theme.resolve("nonsense", noColorEnv: false).name, "default")
    }

    func testNoColorEnvForcesMono() {
        XCTAssertEqual(Theme.resolve("dark", noColorEnv: true).name, "mono",
                       "NO_COLOR wins over any configured theme")
    }

    func testREPLColorDecisionHonorsConfiguredMonoAndTTY() throws {
        let root = NSTemporaryDirectory() + "kist-theme-output-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = KistSettingsStore(projectRoot: root)

        XCTAssertTrue(store.save(KistSettings(theme: "mono"), to: .project))
        XCTAssertFalse(KistREPL.stdoutColorEnabled(projectRoot: root, isTTY: true, noColorEnv: false),
                       "configured mono must suppress ANSI even on a TTY")

        XCTAssertTrue(store.save(KistSettings(theme: "dark"), to: .project))
        XCTAssertTrue(KistREPL.stdoutColorEnabled(projectRoot: root, isTTY: true, noColorEnv: false))
        XCTAssertFalse(KistREPL.stdoutColorEnabled(projectRoot: root, isTTY: false, noColorEnv: false),
                       "redirected stdout must remain plain")
        XCTAssertFalse(KistREPL.stdoutColorEnabled(projectRoot: root, isTTY: true, noColorEnv: true),
                       "NO_COLOR must override a configured color theme")
    }

    // MARK: accessibility invariants

    func testMonoEmitsNoAnsiEscapes() {
        let m = Theme.mono
        for styled in [m.accent("x"), m.success("x"), m.warning("x"), m.error("x"), m.dim("x"), m.prompt("x")] {
            XCTAssertEqual(styled, "x", "mono must be plain text — screen readers read ANSI aloud")
            XCTAssertFalse(styled.contains("\u{001B}"), "no escape byte")
        }
        XCTAssertFalse(m.swatch().contains("\u{001B}"), "even the swatch is escape-free in mono")
    }

    func testHighContrastDimIsNotTheFaintCode() {
        // Low-vision users can't see the faint `2` (dim) code; high-contrast must use a readable dim.
        XCTAssertNotEqual(Theme.highContrast.dimCode, "2")
        XCTAssertFalse(Theme.highContrast.dim("hint").isEmpty)
    }

    func testDaltonizedDoesNotRelyOnRedGreenForStatus() {
        // Deuteranopia/protanopia confuse red(31)/green(32). Success/error must avoid that pair.
        let d = Theme.daltonized
        XCTAssertNotEqual(d.successCode, "32")
        XCTAssertNotEqual(d.errorCode, "31")
        XCTAssertNotEqual(d.successCode, d.errorCode, "success and error stay distinguishable")
    }

    func testSwatchColorizedFalseEmitsNoAnsi() {
        // Regression (Codex): listing /theme under mono sprayed other palettes' ANSI. colorized:false must
        // render the same words escape-free regardless of the palette's own codes.
        for t in Theme.all {
            let plain = t.swatch(colorized: false)
            XCTAssertFalse(plain.contains("\u{001B}"), "\(t.name) plain swatch must be escape-free")
            XCTAssertTrue(plain.contains("success") && plain.contains("error"), "words still present")
        }
        XCTAssertTrue(Theme.dark.swatch(colorized: true).contains("\u{001B}["), "colorized default still paints")
    }

    func testNonMonoThemesActuallyColor() {
        XCTAssertTrue(Theme.dark.accent("x").contains("\u{001B}["))
        XCTAssertTrue(Theme.standard.success("x").contains("\u{001B}["))
    }

    func testAllPalettesAreListedAndNamedUniquely() {
        let names = Theme.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "no duplicate theme names")
        for expected in ["default", "dark", "light", "daltonized", "high-contrast", "mono"] {
            XCTAssertTrue(names.contains(expected), "palette list includes \(expected)")
        }
    }
}
