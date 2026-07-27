import XCTest
@testable import AgentCore

/// Pure-logic tests for the desktop "hands". The CGEvent side effects (real mouse/keyboard) are verified
/// manually; here we pin the deterministic parts a mis-click would hinge on: pixel→point scaling, chord
/// parsing, keycode mapping, and modifier flags.
final class DesktopControlToolTests: XCTestCase {

    // MARK: - Retina pixel → CoreGraphics point scaling (the thing that makes clicks land)

    func testPixelToPointScaleTwo() {
        let p = DesktopControlTool.pointFromPixel(px: 200, py: 100, origin: (0, 0), scale: 2)
        XCTAssertEqual(p.x, 100, accuracy: 0.001)
        XCTAssertEqual(p.y, 50, accuracy: 0.001)
    }

    func testPixelToPointScaleOneIsIdentity() {
        let p = DesktopControlTool.pointFromPixel(px: 640, py: 400, origin: (0, 0), scale: 1)
        XCTAssertEqual(p.x, 640, accuracy: 0.001)
        XCTAssertEqual(p.y, 400, accuracy: 0.001)
    }

    func testPixelToPointHonorsDisplayOrigin() {
        // Secondary display whose CG origin is offset — the point must include the origin.
        let p = DesktopControlTool.pointFromPixel(px: 100, py: 100, origin: (1440, 0), scale: 2)
        XCTAssertEqual(p.x, 1440 + 50, accuracy: 0.001)
        XCTAssertEqual(p.y, 50, accuracy: 0.001)
    }

    func testPixelToPointGuardsAgainstZeroScale() {
        // A degenerate scale must not divide-by-zero; it falls back to 1.
        let p = DesktopControlTool.pointFromPixel(px: 10, py: 20, origin: (0, 0), scale: 0)
        XCTAssertEqual(p.x, 10, accuracy: 0.001)
        XCTAssertEqual(p.y, 20, accuracy: 0.001)
    }

    // MARK: - Chord parsing

    func testParseChordMultipleModifiers() {
        let c = DesktopControlTool.parseChord("cmd+shift+s")
        XCTAssertEqual(c.modifiers, ["cmd", "shift"])
        XCTAssertEqual(c.key, "s")
    }

    func testParseChordBareKey() {
        let c = DesktopControlTool.parseChord("return")
        XCTAssertTrue(c.modifiers.isEmpty)
        XCTAssertEqual(c.key, "return")
    }

    func testParseChordToleratesSpacingAndCase() {
        let c = DesktopControlTool.parseChord("  CMD + S ")
        XCTAssertEqual(c.modifiers, ["cmd"])
        XCTAssertEqual(c.key, "s")
    }

    // MARK: - Keycodes

    func testKeyCodesKnown() {
        XCTAssertEqual(DesktopControlTool.keyCode(for: "a"), 0)
        XCTAssertEqual(DesktopControlTool.keyCode(for: "return"), 36)
        XCTAssertEqual(DesktopControlTool.keyCode(for: "esc"), 53)
        XCTAssertEqual(DesktopControlTool.keyCode(for: "up"), 126)
        XCTAssertEqual(DesktopControlTool.keyCode(for: "A"), 0)   // case-insensitive
    }

    func testKeyCodeUnknownIsNil() {
        XCTAssertNil(DesktopControlTool.keyCode(for: "hyperspace"))
    }

    // MARK: - Modifier flags (raw CGEventFlags bitmask)

    func testModifierFlagsSingle() {
        XCTAssertEqual(DesktopControlTool.modifierFlags(["cmd"]), 0x100000)
        XCTAssertEqual(DesktopControlTool.modifierFlags(["shift"]), 0x20000)
    }

    func testModifierFlagsCombinedAndAliases() {
        let f = DesktopControlTool.modifierFlags(["command", "option", "control"])
        XCTAssertEqual(f, 0x100000 | 0x80000 | 0x40000)
    }

    func testModifierFlagsUnknownFailsLoudly() {
        // A typo'd modifier must NOT be silently dropped (that would fire the wrong command).
        XCTAssertNil(DesktopControlTool.modifierFlags(["banana"]))
        XCTAssertNil(DesktopControlTool.modifierFlags(["cmd", "bogus"]))
    }

    // MARK: - Contract surface

    func testUnknownActionFailsCleanly() async throws {
        let tool = DesktopControlTool()
        let r = try await tool.execute(arguments: ["action": "teleport"], context: ToolContext(projectRoot: NSTemporaryDirectory()))
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("unknown desktop_control action") ?? false)
    }

    func testExplicitBadDisplayIndexFailsLoudly() async throws {
        // Council HIGH: an explicit out-of-range display must FAIL, never silently retarget the main
        // monitor (wrong-target risk). Machine-independent: 99 is out of range on any real setup.
        let tool = DesktopControlTool()
        let r = try await tool.execute(arguments: ["action": "screen_size", "display": 99], context: ToolContext(projectRoot: NSTemporaryDirectory()))
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("display index 99 is out of range") ?? false)
        XCTAssertTrue(r.error?.contains("display(s) attached") ?? false)
    }

    func testNonIntegerDisplayFails() async throws {
        let tool = DesktopControlTool()
        let r = try await tool.execute(arguments: ["action": "screen_size", "display": "left one"], context: ToolContext(projectRoot: NSTemporaryDirectory()))
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.error, "display must be a whole-number index.")
    }

    func testFractionalDisplayFailsNotTruncates() async throws {
        let tool = DesktopControlTool()
        let r = try await tool.execute(arguments: ["action": "screen_size", "display": 1.9], context: ToolContext(projectRoot: NSTemporaryDirectory()))
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("whole-number") ?? false)
    }

    func testUnknownButtonFailsRatherThanLeftClicking() async throws {
        // A bad button must NOT silently become a left click. This path is reached only when Accessibility
        // is granted; when it isn't, the accessibility failure is itself a safe (non-clicking) refusal.
        let tool = DesktopControlTool()
        let r = try await tool.execute(arguments: ["action": "click", "x": 5, "y": 5, "button": "middle"],
                                       context: ToolContext(projectRoot: NSTemporaryDirectory()))
        XCTAssertFalse(r.success)
        // Either "unknown button" (accessibility granted) or the accessibility refusal — never a success.
        XCTAssertTrue((r.error?.contains("unknown button") ?? false) || (r.error?.contains("Accessibility") ?? false))
    }

    func testToolAdvertisesActionVocabulary() {
        let tool = DesktopControlTool()
        XCTAssertEqual(tool.name, "desktop_control")
        XCTAssertTrue(tool.supportedActions.contains("click"))
        XCTAssertTrue(tool.supportedActions.contains("type"))
        XCTAssertTrue(tool.supportedActions.contains("screenshot"))
        // Actions models hallucinate for a "computer control" tool are flagged as unsupported.
        XCTAssertTrue(tool.unsupportedActions.contains("open_app"))
    }
}
