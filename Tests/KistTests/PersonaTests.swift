import XCTest
import AgentCore
@testable import Kist

final class PersonaTests: XCTestCase {
    func testCaptainIsDefaultAndInjectsNothing() {
        XCTAssertNil(Persona.directive("captain"))
        XCTAssertNil(Persona.directive("off"))
        XCTAssertNil(Persona.directive(""))
    }

    func testEachPersonaHasADirective() {
        for p in ["minimal", "hacker", "jarvis", "wutang"] {
            XCTAssertNotNil(Persona.directive(p), "\(p) should have a directive")
            XCTAssertTrue(Persona.directive(p)!.hasPrefix(Persona.marker))
        }
    }

    func testSwitchingReplacesThePriorPersonaNoStacking() {
        var t: [ChatMessage] = [ChatMessage(role: .user, content: "hello")]
        _ = Persona.apply("wutang", to: &t)
        XCTAssertEqual(t.filter { Persona.isPersonaMessage($0.content) }.count, 1)
        _ = Persona.apply("jarvis", to: &t)         // switch — must not stack
        let personaMsgs = t.filter { Persona.isPersonaMessage($0.content) }
        XCTAssertEqual(personaMsgs.count, 1)
        XCTAssertTrue(personaMsgs[0].content.contains("JARVIS"))
        XCTAssertEqual(t.first?.content, "hello")    // the real conversation is untouched
    }

    func testOffRemovesThePersonaEntirely() {
        var t: [ChatMessage] = []
        _ = Persona.apply("wutang", to: &t)
        let name = Persona.apply("off", to: &t)
        XCTAssertTrue(t.allSatisfy { !Persona.isPersonaMessage($0.content) })
        XCTAssertEqual(name, "captain")
    }

    func testAliasesCanonicalize() {
        XCTAssertEqual(Persona.canonical("wu-tang"), "wutang")
        XCTAssertEqual(Persona.canonical("off"), "captain")
    }
}
