import XCTest
@testable import Kist

/// Pins the `/ablation <arg>` → corpus routing per-branch. A missing `recall` branch previously routed
/// `/ablation recall` to the golden cold-vs-warm run (the P1 A/B never fired); these per-arg assertions
/// name the regressed branch directly.
final class AblationCorpusRoutingTests: XCTestCase {

    func testEachArgRoutesToItsOwnCorpus() {
        let cases: [(String, String)] = [
            ("recall",     "recall"),        // P1's isolated injection A/B
            ("recall foo", "recall"),        // prefix match, trailing words ignored
            ("capability", "capability"),
            ("cap",        "capability"),
            ("golden",     "golden"),
            ("",           "golden"),        // bare /ablation defaults to golden
            ("nonsense",   "golden"),
            ("  Recall ",  "recall"),        // trimmed + case-insensitive
        ]
        for (arg, expected) in cases {
            XCTAssertEqual(KistREPL.ablationCorpus(forArg: arg), expected,
                           "‘\(arg)’ must route to \(expected)")
        }
    }
}
