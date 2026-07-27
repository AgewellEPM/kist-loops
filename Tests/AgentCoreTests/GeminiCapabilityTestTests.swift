import XCTest
@testable import AgentCore

final class GeminiCapabilityTestTests: XCTestCase {

    func testRunAllPreservesOrderAndRunsEach() async {
        let probes = ["a", "b", "c"].map { name in
            GeminiCapabilityTest.Probe(name: name) { .init(name: name, ok: name != "b", detail: "d-\(name)") }
        }
        let results = await GeminiCapabilityTest.runAll(probes)
        XCTAssertEqual(results.map { $0.name }, ["a", "b", "c"])     // serial, order preserved
        XCTAssertEqual(results.map { $0.ok }, [true, false, true])
    }

    func testRenderSummaryAndRows() {
        let results = [
            GeminiCapabilityTest.Result(name: "embeddings", ok: true, detail: "ok (768-dim)"),
            GeminiCapabilityTest.Result(name: "image_gen", ok: false, detail: "http 400 ..."),
        ]
        let out = GeminiCapabilityTest.render(results)
        XCTAssertTrue(out.contains("1/2 passed"))
        XCTAssertTrue(out.contains("✓ embeddings"))
        XCTAssertTrue(out.contains("✗ image_gen"))
        XCTAssertTrue(out.contains("http 400"))
    }

    func testGuardedTurnsThrowAndNilIntoFailure() async {
        struct Boom: Error {}
        let threw = await GeminiCapabilityTest.guarded("x") { throw Boom() }
        XCTAssertFalse(threw.ok)
        let nilDetail = await GeminiCapabilityTest.guarded("y") { nil }
        XCTAssertFalse(nilDetail.ok)
        XCTAssertEqual(nilDetail.detail, "empty/invalid response")
        let good = await GeminiCapabilityTest.guarded("z") { "ok" }
        XCTAssertTrue(good.ok)
        XCTAssertEqual(good.detail, "ok")
    }

    func testProbesCoverTheClientsAndChatPath() {
        let keyOnly = GeminiCapabilityTest.probes(geminiKey: "stub").map { $0.name }
        XCTAssertEqual(Set(keyOnly), ["count_tokens", "embeddings", "image_gen", "tts", "grounded_chat"])
        // translate probe is added only when a registry is supplied.
        XCTAssertFalse(keyOnly.contains("translate_doc"))
    }
}
