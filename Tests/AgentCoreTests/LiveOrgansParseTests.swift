import XCTest
@testable import AgentCore

/// The organs' PARSING is deterministic and must be solid (a live model reply is fenced/prose-wrapped). The
/// model OUTPUT quality is what the proof run demonstrates; this pins that we correctly extract it.
final class LiveOrgansParseTests: XCTestCase {

    func testAuthorParsesFencedJSON() {
        let reply = """
        Sure, here's the tool:
        ```json
        {"manifest":{"name":"self__upper","description":"upper-case","interpreter":"/bin/bash",
          "scriptFile":"tool.sh","parameters":[{"name":"text","description":"t","required":true}],
          "contract":"upper-cases text","testArgs":{"text":"hi"},"testExpectSubstring":"HI"},
         "script":"#!/bin/bash\\necho HI"}
        ```
        """
        let out = LiveCapabilityAuthor.parse(reply)
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.manifest.name, "self__upper")
        XCTAssertTrue(out?.script.contains("#!/bin/bash") ?? false)
    }

    func testAuthorRejectsGarbage() {
        XCTAssertNil(LiveCapabilityAuthor.parse("I can't do that."))
    }

    func testAdversaryParsesBreakingInput() {
        let a = LiveCapabilityAdversary.parse(#"{"breakingArgs":{"text":""},"expectContains":"","confidence":0.8}"#)
        XCTAssertEqual(a?.breakingArgs?["text"], "")
        XCTAssertEqual(a?.confidence, 0.8)
    }

    func testAdversaryParsesNoBreakFound() {
        let a = LiveCapabilityAdversary.parse(#"{"breakingArgs":null,"expectContains":null,"confidence":0.9}"#)
        XCTAssertNil(a?.breakingArgs ?? nil)
        XCTAssertEqual(a?.confidence, 0.9)
        XCTAssertNil(a.flatMap(LiveCapabilityAdversary.executableAttack),
                     "opinion-only confidence must not become executable promotion evidence")
    }

    func testAdversaryRequiresANonEmptyExecutionOracle() {
        let emptyOracle = LiveCapabilityAdversary.parse(
            #"{"breakingArgs":{"text":"edge"},"expectContains":"","confidence":0.99}"#)
        XCTAssertNil(emptyOracle.flatMap(LiveCapabilityAdversary.executableAttack))

        let grounded = LiveCapabilityAdversary.parse(
            #"{"breakingArgs":{"text":"edge"},"expectContains":"EDGE","confidence":0.8}"#)
        let plan = grounded.flatMap(LiveCapabilityAdversary.executableAttack)
        XCTAssertEqual(plan?.0, ["text": "edge"])
        XCTAssertEqual(plan?.1, "EDGE")
    }
}
