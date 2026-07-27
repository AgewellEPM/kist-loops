import XCTest
@testable import AgentCore

/// Focused unit contract for the forge seal itself (the cryptographic primitive the gavel's
/// `sealed=1` token rides on). The ledger-integration boundary tests ("hand-crafted JSON rejected on
/// load") land with FleetSignoffLedger in Stage 1.5 — they need the un-ported ledger types.
final class ForgeSealTests: XCTestCase {

    /// Never touch ~/.mythos in tests — force a fresh process-ephemeral key before each test.
    override func setUp() {
        super.setUp()
        ForgeSeal.forceEphemeralKeyForTesting()
    }

    // MARK: round-trip

    func testSignProducesHexTagThatVerifies() {
        let canonical = "project=proj|item=task-a|verdict=green"
        let seal = ForgeSeal.sign(canonical)
        XCTAssertEqual(seal.count, 64, "HMAC-SHA256 → 32 bytes → 64 hex chars")
        XCTAssertTrue(seal.allSatisfy { $0.isHexDigit }, "lowercase hex only")
        XCTAssertTrue(ForgeSeal.verify(canonical, seal: seal), "a real seal verifies")
    }

    func testDeterministicWithinProcess() {
        XCTAssertEqual(ForgeSeal.sign("x"), ForgeSeal.sign("x"), "same key + same canonical → same tag")
    }

    // MARK: forge boundary

    func testTamperedCanonicalFailsVerify() {
        let seal = ForgeSeal.sign("verdict=green")
        XCTAssertFalse(ForgeSeal.verify("verdict=green-TAMPERED", seal: seal),
                       "a seal does not transfer to a different canonical")
    }

    func testFakeAndEmptySealRejected() {
        XCTAssertFalse(ForgeSeal.verify("anything", seal: "deadbeefdeadbeefdeadbeefdeadbeef"),
                       "a hand-crafted hex tag does not verify (no key)")
        XCTAssertFalse(ForgeSeal.verify("anything", seal: ""), "an empty seal never verifies")
    }

    func testKeyActuallyMattersAcrossEphemeralRotation() {
        let s1 = ForgeSeal.sign("z")
        ForgeSeal.forceEphemeralKeyForTesting()      // brand-new random key
        let s2 = ForgeSeal.sign("z")
        XCTAssertNotEqual(s1, s2, "a different install key → a different seal (no universal forge key)")
        XCTAssertFalse(ForgeSeal.verify("z", seal: s1), "the old seal is dead under a rotated key")
    }

    // MARK: field() injectivity — the pipe-collision close

    func testFieldEscapesJoinDelimiters() {
        let f = ForgeSeal.field("a|verdict=green")
        XCTAssertFalse(f.contains("|"), "the | join delimiter is percent-encoded inside a value")
        XCTAssertFalse(f.contains("="), "the = kv delimiter is percent-encoded inside a value")
    }

    func testFieldMakesCanonicalInjective() {
        // Two DIFFERENT logical records must not produce the same canonical string.
        // Without field(), item="a|verdict=green" + verdict="" would collide with
        // item="a" + verdict="green". With field(), they cannot.
        let r1 = "item=\(ForgeSeal.field("a"))|verdict=\(ForgeSeal.field("green"))"
        let r2 = "item=\(ForgeSeal.field("a|verdict=green"))|verdict=\(ForgeSeal.field(""))"
        XCTAssertNotEqual(r1, r2, "field() escaping prevents value/delimiter impersonation")
        XCTAssertNotEqual(ForgeSeal.sign(r1), ForgeSeal.sign(r2), "→ distinct seals for distinct records")
    }

    func testFieldRoundTripsIdenticalInputToIdenticalOutput() {
        XCTAssertEqual(ForgeSeal.field("hello world!"), ForgeSeal.field("hello world!"),
                       "field() is a pure function")
        XCTAssertNotEqual(ForgeSeal.field("a b"), ForgeSeal.field("a  b"),
                          "distinct inputs → distinct escapes (no lossy collapse)")
    }
}
