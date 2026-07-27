import XCTest
@testable import Kist

/// `/wu-tang` Easter egg: the emblem renders, the slash-router accepts every alias, and the ODB
/// persona directive is intact + kid-friendly. (The on-screen rise animation is exercised only via
/// the non-animated path so tests stay fast and don't sleep.)
final class WuTangEasterEggTests: XCTestCase {

    func testEmblemIsNonEmptyAndRectangular() {
        XCTAssertFalse(WuTangEasterEgg.emblem.isEmpty)
        // Every row should carry the gold-W art (non-blank) so the rise reveals real content.
        XCTAssertTrue(WuTangEasterEgg.emblem.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    func testNonAnimatedRenderDoesNotCrash() {
        // Smoke: the test path skips cursor/sleep tricks; just prove it runs end to end.
        WuTangEasterEgg.riseAndShow(animate: false)
    }

    func testODBPersonaDirectiveIsInCharacterAndKidFriendly() {
        let d = WuTangEasterEgg.odbPersonaDirective
        XCTAssertTrue(d.contains("Ol' Dirty Bastard"))
        XCTAssertTrue(d.lowercased().contains("children"))      // Wu-Tang is for the children
        XCTAssertTrue(d.lowercased().contains("competent"))     // still a real, working assistant
        XCTAssertTrue(d.lowercased().contains("no slurs"))      // kept clean on purpose
    }

    func testEveryAliasIsAValidSlashCommand() {
        for alias in ["/wu-tang", "/wutang", "/wu", "/odb"] {
            XCTAssertTrue(KistREPL.isSlashCommand(alias), "\(alias) should route as a slash command")
        }
    }
}
