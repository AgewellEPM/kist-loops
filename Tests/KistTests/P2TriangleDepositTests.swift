import XCTest
@testable import Kist

/// P2 triangle close — a GROUNDED promotion deposits a recallable "winning approach" auto-lesson so the P1
/// recall→plan wire can surface "you already grew self__X for this" next time. Two contracts pinned:
///  1. `promotionLesson` is deterministic + self-describing (so SHA256 upsert dedups on re-promotion).
///  2. the deposit stays GATED ON THE SMOKE VERDICT (never on promotion alone) — the anti-laundering invariant.
final class P2TriangleDepositTests: XCTestCase {

    func testPromotionLessonIsDeterministicAndNamesTheTool() {
        let a = KistRunner.promotionLesson(tool: "self__add", brief: "sum two integers", description: "Prints the arithmetic sum of two integers")
        let b = KistRunner.promotionLesson(tool: "self__add", brief: "sum two integers", description: "Prints the arithmetic sum of two integers")
        XCTAssertEqual(a, b, "same (tool, brief, description) must yield identical text so the SHA256 id upserts (no duplicate memory)")
        XCTAssertTrue(a.contains("self__add"), "the tool name must be IN the body — it's what the future model reads via recall")
        XCTAssertTrue(a.lowercased().contains("callable next session"), "must state the honest next-session-only contract")
        XCTAssertTrue(a.contains("sum two integers"), "the solved goal must be present so recall matches a similar task")
        XCTAssertFalse(a.contains(":"+"20"), "no smoke-output snippet / no volatile content that would break determinism")
    }

    func testPromotionLessonBoundsAWildBrief() {
        let huge = String(repeating: "x", count: 5000)
        let lesson = KistRunner.promotionLesson(tool: "self__t", brief: huge, description: "d")
        XCTAssertLessThan(lesson.count, 400, "brief is truncated so the deposited lesson stays a compact, recallable hint")
        XCTAssertTrue(lesson.contains("self__t"))
    }

    // Anti-laundering pin (source-level, multi-site discipline): the deposit MUST live inside the smoke gate.
    // If a refactor moves it out to fire on `result.promoted` alone, a promoted-but-smoke-FAILED tool would
    // deposit a lesson claiming it works — exactly the ungrounded-win this whole loop rejects.
    func testDepositIsGatedOnGroundedSmoke() throws {
        let src = try String(contentsOfFile: Self.evolveSourcePath, encoding: .utf8)
        // The remember(...) with kind=auto-lesson deposit appears only within the `if smokeOk, let semantic {` block.
        guard let depositRange = src.range(of: #"if smokeOk, let semantic {"#) else {
            return XCTFail("the smoke-gated deposit block is gone — grounding invariant unpinned")
        }
        let afterGate = String(src[depositRange.lowerBound...].prefix(400))
        XCTAssertTrue(afterGate.contains(#""kind": "auto-lesson""#),
                      "the auto-lesson deposit must sit INSIDE `if smokeOk, let semantic` — grounded-only")
        // And it must NOT be reachable from result.promoted without the smoke check.
        XCTAssertFalse(src.contains(#"if result.promoted { try? await semantic"#),
                       "deposit must never fire on promotion alone (ungrounded)")
    }

    private static var evolveSourcePath: String {
        // Tests run from the package root; resolve the source relative to this test file's module dir.
        let here = URL(fileURLWithPath: #filePath)   // .../Tests/KistTests/P2TriangleDepositTests.swift
        return here.deletingLastPathComponent()      // Tests/KistTests
            .deletingLastPathComponent()             // Tests
            .deletingLastPathComponent()             // package root
            .appendingPathComponent("Sources/Kist/KistRunner+Evolve.swift").path
    }
}
