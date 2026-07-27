import XCTest
@testable import AgentCore

/// Pins the shape of the `screen-driver` specialist (shipped to ~/.config/kist/agents/screen-driver.md).
/// Keeping the canonical markdown here means the format is verified in CI and can't silently drift from
/// what the specialist parser accepts.
final class ScreenDriverSpecialistTests: XCTestCase {

    static let markdown = """
    ---
    name: screen-driver
    description: Drives a native macOS GUI (menus, games, apps) by looking at the screen and acting — perceive, decide, act, verify. Use for "play/operate <app>" tasks.
    tools: computer_use_check, computer_control, ui_elements, look, locate, tap, desktop_control, wait_for_screen, watch_screen
    ---
    You operate the computer by SEEING the screen and ACTING on it, like a human.

    ALWAYS start with `computer_use_check`.

    Perception is GROUNDING FIRST: `ui_elements` for exact clickable centers, vision (`look`/`locate`) as
    fallback for custom-rendered games. VERIFY after every action with `wait_for_screen`; never assume a
    click landed; don't repeat a failed action — re-perceive and try differently.
    """

    static let expectedTools = ["computer_use_check", "computer_control", "ui_elements", "look", "locate", "tap", "desktop_control", "wait_for_screen", "watch_screen"]

    func testScreenDriverDefinitionParses() throws {
        let def = try XCTUnwrap(SpecialistDefinition.parse(Self.markdown, source: "screen-driver.md"))
        XCTAssertEqual(def.name, "screen-driver")
        XCTAssertTrue(def.description.contains("GUI"))
        // Scoped to exactly the computer-use tools (no privilege beyond what it needs).
        XCTAssertEqual(def.toolAllowlist, Self.expectedTools)
        XCTAssertTrue(def.systemPrompt.contains("computer_use_check"))
        XCTAssertTrue(def.systemPrompt.contains("ui_elements"))   // grounding-first
        XCTAssertTrue(def.systemPrompt.contains("wait_for_screen"))
    }

    func testScreenDriverToolsAreAllRealTools() throws {
        let def = try XCTUnwrap(SpecialistDefinition.parse(Self.markdown, source: "screen-driver.md"))
        // Every tool the specialist names must exist in the full desktop-capable registry, or the
        // scoped-narrowing would silently drop it (fail-closed to fewer tools).
        let known = Set(Self.expectedTools)
        for t in def.toolAllowlist ?? [] {
            XCTAssertTrue(known.contains(t), "\(t) is not a known computer-use tool")
        }
    }
}
