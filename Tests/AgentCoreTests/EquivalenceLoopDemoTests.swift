import XCTest
@testable import AgentCore

/// L0 harness shakedown — the whole equivalence loop closing on a realistic (payroll-flavored) stateless
/// transform. This is the "see it run" proof: point the harness at an ORIGINAL and a CANDIDATE port over a
/// corpus, and it returns an HONEST verdict — equivalent when the port is right, a localized regression
/// when it's subtly wrong, and captureFailed when the original isn't deterministically sealed.
///
/// The transform: lines of `employee,hours,rate` → a JSON array of `{"employee":…,"gross":cents}` sorted
/// by employee, gross = round(hours*rate*100) cents. Stateless, clean I/O boundary — the plan's ideal L0.
final class EquivalenceLoopDemoTests: XCTestCase {

    /// The "legacy" original: the behavior we must preserve.
    private static func original(_ input: String) -> String {
        rows(input).map { #"{"employee":"\#($0.name)","gross":\#(cents($0.hours, $0.rate))}"# }
            .joined(separator: "\n")
    }

    private static func rows(_ input: String) -> [(name: String, hours: Double, rate: Double)] {
        input.split(separator: "\n").compactMap { line in
            let f = line.split(separator: ",")
            guard f.count == 3, let h = Double(f[1]), let r = Double(f[2]) else { return nil }
            return (String(f[0]), h, r)
        }.sorted { $0.name < $1.name }
    }
    private static func cents(_ hours: Double, _ rate: Double) -> Int { Int((hours * rate * 100).rounded()) }

    private let corpus: [EquivalenceRun.Case] = [
        .init(id: "basic", input: "bob,40,25.0\nana,10,15.5"),
        .init(id: "rounding-edge", input: "cara,3,33.335"),     // 3*33.335*100 = 10000.5 → rounds to 10001
        .init(id: "empty", input: ""),
        .init(id: "single", input: "zoe,1,0.01"),
        .init(id: "many", input: "d,8,20\nc,8,20\nb,8,20\na,8,20"),
    ]

    func testCorrectPortIsEvidenceBoundedEquivalentAcrossCorpus() {
        let report = EquivalenceRun.run(corpus, oracle: Self.original, candidate: Self.original)
        XCTAssertEqual(report.overall, .evidenceBoundedEquivalent)
        XCTAssertTrue(report.isCutoverEligible)
        XCTAssertEqual(report.count(.equivalent), corpus.count)
    }

    func testSubtleRoundingRegressionIsCaughtAndLocalized() {
        // A candidate that TRUNCATES instead of rounding — passes most inputs, breaks on the .5-cent edge.
        func buggy(_ input: String) -> String {
            Self.rows(input).map { #"{"employee":"\#($0.name)","gross":\#(Int($0.hours * $0.rate * 100))}"# }
                .joined(separator: "\n")
        }
        let report = EquivalenceRun.run(corpus, oracle: Self.original, candidate: buggy)
        XCTAssertEqual(report.overall, .regressed)                 // weakest link, not "80% passed"
        XCTAssertEqual(report.count(.notEquivalent), 1)            // exactly the rounding-edge case
        // The rest still verified equivalent — the failure is localized, not smeared.
        XCTAssertEqual(report.count(.equivalent), corpus.count - 1)
    }

    func testKeyOrderReformatStillEquivalent() {
        // A candidate that emits the same data with different JSON key order must NOT read as a regression
        // (canonicalization kills that noise).
        func reordered(_ input: String) -> String {
            Self.rows(input).map { #"{"gross":\#(Self.cents($0.hours, $0.rate)),"employee":"\#($0.name)"}"# }
                .joined(separator: "\n")
        }
        // Each line is a JSON object; canonicalization sorts keys per line only if the whole output parses
        // as JSON — here it's newline-joined objects (text), so compare object-per-object via a corpus of
        // single-row inputs where each output is one JSON object.
        let singleRow: [EquivalenceRun.Case] = [.init(id: "one", input: "ana,10,15.5")]
        let report = EquivalenceRun.run(singleRow, oracle: Self.original, candidate: reordered)
        XCTAssertEqual(report.overall, .evidenceBoundedEquivalent)
    }

    func testUnsealedTimestampInOriginalTripsGate0() {
        // An "original" that is NOT deterministically sealed (stamps the current tick) must be caught by
        // Gate 0 as captureFailed — the harness refuses to emit an equivalence verdict on broken capture.
        var tick = 0
        func leaky(_ input: String) -> String { tick += 1; return Self.original(input) + "\n#\(tick)" }
        let report = EquivalenceRun.run([corpus[0]], oracle: leaky, candidate: Self.original)
        XCTAssertEqual(report.overall, .captureFailed)
        XCTAssertFalse(report.isCutoverEligible)
    }

    func testDeclaringTheTimestampVolatileRecoversAValidVerdict() {
        // Same leaky original, but the tick line is DECLARED volatile → sealed → the loop can judge again.
        var tick = 0
        func leaky(_ input: String) -> String { tick += 1; return Self.original(input) + "\n#\(tick)" }
        let report = EquivalenceRun.run([corpus[0]], volatiles: [VolatileField(pattern: #"#\d+"#, placeholder: "#<N>")],
                                        oracle: leaky, candidate: { Self.original($0) + "\n#0" })
        XCTAssertEqual(report.overall, .evidenceBoundedEquivalent)
    }
}
