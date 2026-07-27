import XCTest
import AgentCore
@testable import Kist

/// Pins the `/config` panel logic: intent classification, key=value parsing, apply + change tracking.
final class ConfigPanelTests: XCTestCase {

    func testBareShowsPanel() {
        XCTAssertEqual(ConfigPanel.classify(""), .show)
        XCTAssertEqual(ConfigPanel.classify("   "), .show)
    }

    func testHelpIntent() {
        XCTAssertEqual(ConfigPanel.classify("--help"), .help)
        XCTAssertEqual(ConfigPanel.classify("help"), .help)
    }

    func testParseSingleAndMultipleAssignments() {
        XCTAssertEqual(ConfigPanel.parseAssignments("theme=high-contrast"),
                       [.init(key: "theme", value: "high-contrast")])
        XCTAssertEqual(ConfigPanel.parseAssignments("theme=mono reasoning=on"),
                       [.init(key: "theme", value: "mono"), .init(key: "reasoning", value: "on")])
    }

    func testParseDropsFragmentsWithoutEquals() {
        XCTAssertEqual(ConfigPanel.parseAssignments("theme mono"), [], "no '=' ⇒ nothing parsed")
        XCTAssertEqual(ConfigPanel.parseAssignments("theme= =on"), [], "empty key or value dropped")
    }

    func testApplyAllTracksChangedKeysAndFlagsErrors() {
        let (settings, lines, changed) = ConfigPanel.applyAll(
            KistSettings(), [.init(key: "theme", value: "dark"),
                             .init(key: "bogus", value: "x"),
                             .init(key: "sandbox", value: "nope")])
        XCTAssertEqual(settings.theme, "dark")
        XCTAssertEqual(changed, ["theme"], "only the valid assignment counts as changed")
        XCTAssertTrue(lines.contains { $0.contains("theme = dark") })
        XCTAssertTrue(lines.contains { $0.contains("unknown key 'bogus'") })
        XCTAssertTrue(lines.contains { $0.contains("sandbox") && $0.contains("invalid") })
    }

    func testApplyAllEmptyReportsNothingToSet() {
        let (_, lines, changed) = ConfigPanel.applyAll(KistSettings(), [])
        XCTAssertTrue(changed.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("nothing to set") })
    }

    func testApplyAllMonoThemeEmitsNoAnsi() {
        // Regression (Codex): status lines hardcoded green/red, bypassing mono/NO_COLOR. Under the mono
        // theme every status line must be escape-free so screen readers don't read ANSI aloud.
        let (_, lines, _) = ConfigPanel.applyAll(
            KistSettings(), [.init(key: "theme", value: "dark"),
                             .init(key: "bogus", value: "x")], theme: .mono)
        for line in lines { XCTAssertFalse(line.contains("\u{001B}"), "mono status line must be escape-free: \(line)") }
        XCTAssertTrue(lines.contains { $0.contains("✓") && $0.contains("theme = dark") })
        XCTAssertTrue(lines.contains { $0.contains("✗") && $0.contains("bogus") }, "glyph survives without color")
    }

    func testApplyAllStandardThemeStillColors() {
        let (_, lines, _) = ConfigPanel.applyAll(KistSettings(), [.init(key: "theme", value: "dark")], theme: .standard)
        XCTAssertTrue(lines.contains { $0.contains("\u{001B}[") }, "non-mono keeps color")
    }

    func testRenderShowsEveryKeyAndCurrentValue() {
        let out = ConfigPanel.render(KistSettings(model: "gemini", theme: "dark"),
                                     scopeNote: "test")
        for entry in KistSettings.schema { XCTAssertTrue(out.contains(entry.key), "panel lists \(entry.key)") }
        XCTAssertTrue(out.contains("gemini"))
        XCTAssertTrue(out.contains("dark"))
    }
}
