import XCTest
@testable import AgentCore

/// Phase 2.2 — the GATED DGM bridge: proven policies queue for review, never auto-apply.
final class PromotionBridgeTests: XCTestCase {
    func testGateRequiresProvenEvidence() {
        XCTAssertTrue(PromotionGate.qualifies(wins: 3, trials: 3))
        XCTAssertTrue(PromotionGate.qualifies(wins: 4, trials: 5))    // 0.8 ≥ 0.75
        XCTAssertFalse(PromotionGate.qualifies(wins: 2, trials: 2), "too few wins")
        XCTAssertFalse(PromotionGate.qualifies(wins: 3, trials: 5), "0.6 < 0.75 rate")
        XCTAssertFalse(PromotionGate.qualifies(wins: 0, trials: 0), "no evidence — fail closed")
    }
    func testStoreQueuesAndDedupes() {
        let root = NSTemporaryDirectory() + "prom-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = PromotionCandidateStore(projectRoot: root)
        let c = PromotionCandidate(signature: "s", hint: "do X", wins: 3, trials: 3, at: 1)
        XCTAssertTrue(store.export(c), "first export queues it")
        XCTAssertFalse(store.export(c), "same (signature,hint) not re-queued")
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(store.load().first?.rate ?? 0, 1.0, accuracy: 0.001)
    }
}
