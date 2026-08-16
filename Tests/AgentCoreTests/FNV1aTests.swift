import XCTest
@testable import AgentCore

/// Pins the shared FNV-1a against an independent REFERENCE loop, byte-for-byte — because these values are
/// PERSISTED (OrgFingerprint.orgVersion, EvolutionParentSelector's replayable seed) and a silent drift
/// would invalidate cross-run history. The migration to `FNV1a` must not change any produced value.
final class FNV1aTests: XCTestCase {

    // Independent reference implementations (do NOT call FNV1a) — the ground truth the helper must match.
    private func refHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xCBF29CE484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001B3 }
        return h
    }
    private func refSeed(_ tokens: [String]) -> UInt64 {
        var h: UInt64 = 0xCBF29CE484222325
        for t in tokens {
            let n = UInt64(t.utf8.count)
            for shift in stride(from: 0, to: 64, by: 8) {
                h = (h ^ UInt64(UInt8(truncatingIfNeeded: n >> UInt64(shift)))) &* 0x100000001B3
            }
            for b in t.utf8 { h = (h ^ UInt64(b)) &* 0x100000001B3 }
        }
        return h
    }

    func testEmptyStringIsTheOffsetBasis() {
        XCTAssertEqual(FNV1a.hash64(""), 0xCBF29CE484222325)
        XCTAssertEqual(FNV1a.offsetBasis, 0xCBF29CE484222325)
        XCTAssertEqual(FNV1a.prime, 0x100000001B3)
    }

    func testHash64MatchesReferenceForVariedInputs() {
        for s in ["a", "abc", "provider=claude;model=opus", "unicode→π", "k=v;k2=v2", ""] {
            XCTAssertEqual(FNV1a.hash64(s), refHash(s), "hash64 drift on \"\(s)\"")
        }
    }

    func testSeedMatchesReferenceAndIsBoundaryUnambiguous() {
        XCTAssertEqual(FNV1a.seed("a", "bc"), refSeed(["a", "bc"]))
        XCTAssertEqual(FNV1a.seed("run", "cand", "3"), refSeed(["run", "cand", "3"]))
        // Length-prefixing must distinguish these (a naive concat would collide).
        XCTAssertNotEqual(FNV1a.seed("ab", "c"), FNV1a.seed("a", "bc"))
    }

    func testPersistedCallSitesDidNotDrift() {
        // OrgFingerprint hashes the sorted canonical "k=v;..." string — must equal the reference hash hex.
        let kv = ["model": "opus", "provider": "claude"]
        let canonical = kv.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        XCTAssertEqual(OrgFingerprint.make(kv), String(refHash(canonical), radix: 16))
        // EvolutionParentSelector.seed must equal the length-prefixed reference.
        XCTAssertEqual(EvolutionParentSelector.seed("alpha", "beta"), refSeed(["alpha", "beta"]))
    }
}
