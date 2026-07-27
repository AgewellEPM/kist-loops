import XCTest
@testable import AgentCore

/// Phase 2 — GEPA-style policy evolution: reflective mutation + verified-done fitness + best-per-signature.
final class PolicyEvolverTests: XCTestCase {

    func testMutateDistillsAReviewIntoADirective() {
        let h = PolicyEvolver.mutate(review: "The error path is unhandled; add a guard before the write.",
                                     signature: "sig")
        XCTAssertNotNil(h)
        XCTAssertTrue(h!.hasPrefix("For tasks like this:"))
        XCTAssertTrue(h!.contains("error path"))
    }

    func testMutateIgnoresLGTM() {
        XCTAssertNil(PolicyEvolver.mutate(review: "LGTM — no blocking issues", signature: "sig"))
        XCTAssertNil(PolicyEvolver.mutate(review: "   ", signature: "sig"))
    }

    func testBestPicksHighestVerifiedRate() {
        let cands = [
            PolicyCandidate(signature: "s", hint: "A", wins: 1, trials: 4, at: 1),   // 0.25
            PolicyCandidate(signature: "s", hint: "B", wins: 3, trials: 4, at: 2),   // 0.75
            PolicyCandidate(signature: "s", hint: "C", wins: 0, trials: 0, at: 3),   // 0.0
        ]
        XCTAssertEqual(PolicyEvolver.best(cands)?.hint, "B")
    }

    private func tempRoot() -> String { NSTemporaryDirectory() + "pol-\(UUID().uuidString)" }

    func testStoreRecordsWinsAndEvolvesFromReview() {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let store = PolicyStore(projectRoot: root)

        // A failed cycle (no active hint) with a review seeds a mutated candidate.
        store.record(signature: "s", activeHint: nil, won: false,
                     review: "Missing null check on the parsed input.", at: 1)
        let afterMutation = store.load().filter { $0.signature == "s" }
        XCTAssertEqual(afterMutation.count, 1)
        XCTAssertTrue(afterMutation[0].hint.contains("null check"))

        // Running under that hint and verifying it → a win recorded on the same candidate.
        let hint = store.bestHint(forSignature: "s")!
        store.record(signature: "s", activeHint: hint, won: true, review: nil, at: 2)
        let winner = store.load().first { $0.hint == hint }!
        XCTAssertEqual(winner.wins, 1)
        XCTAssertEqual(winner.trials, 1)
    }

    func testStorePrunesToFrontier() {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let store = PolicyStore(projectRoot: root, maxPerSignature: 2)
        // Seed 4 distinct candidates via 4 failed cycles with different reviews.
        for (i, r) in ["fix the parser edge case", "handle the empty list", "close the file handle", "validate the schema"].enumerated() {
            store.record(signature: "s", activeHint: nil, won: false, review: r, at: Double(i))
        }
        XCTAssertLessThanOrEqual(store.load().filter { $0.signature == "s" }.count, 2, "frontier is bounded")
    }
}
