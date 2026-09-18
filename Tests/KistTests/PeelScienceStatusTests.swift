import XCTest
@testable import Kist

/// Pins the "peel" status word contract (Luke 2026-09-17): a leading "peel" token — bare or with
/// "status" — displays the word SCIENCE plus the tool-system status, and NOTHING else fires it.
/// Read-only: parsing "peel" must never change the Lois/Peel mode. Wiring pins at the bottom hold
/// the REPL interceptor site per the multi-site fix discipline.
final class PeelScienceStatusTests: XCTestCase {

    // MARK: parser

    func testBareWordFiresStatus() {
        let cases = ["peel", "Peel", "PEEL", "  peel  ", "peel!", "Peel,", "peel?", "peel status",
                     "peel STATUS"]
        for input in cases {
            XCTAssertEqual(PeelIntent.parse(input), .status, "input: \(input)")
        }
    }

    func testNonStatusInputsNeverFire() {
        let cases = ["peeled", "peeling the api apart", "banana peel", "peel the orange",
                     "ask peel later", "/peel", "", "   ", "build the login page",
                     "peel off the wrapper"]
        for input in cases {
            XCTAssertNil(PeelIntent.parse(input), "input: \(input)")
        }
    }

    // MARK: display

    func testRenderShowsScienceWord() {
        let out = PeelScienceStatus.render(peelActive: false, researchAvailable: false,
                                           projectRoot: "/nonexistent")
        XCTAssertTrue(out.contains("S C I E N C E"), "the SCIENCE headline is the whole point")
        XCTAssertTrue(out.contains("peel gate: advisory"))
        XCTAssertTrue(out.contains("research lane: unavailable"))
        XCTAssertTrue(out.contains("scientist ledger: not found"))
    }

    func testRenderReportsArmedGateAndWiredLane() {
        let out = PeelScienceStatus.render(peelActive: true, researchAvailable: true,
                                           projectRoot: "/nonexistent")
        XCTAssertTrue(out.contains("peel gate: ACTIVE"))
        XCTAssertTrue(out.contains("research lane: wired"))
    }

    // MARK: ledger scan

    func testScanCountsRunsAndEvents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peel-scan-\(UUID().uuidString)")
        let runA = root.appendingPathComponent("scientist/dogfood/run-a")
        let runB = root.appendingPathComponent("scientist/dogfood/run-b")
        let empty = root.appendingPathComponent("scientist/dogfood/no-ledger")
        for dir in [runA, runB, empty] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try "{\"e\":1}\n{\"e\":2}\n".write(to: runA.appendingPathComponent("ledger.jsonl"),
                                           atomically: true, encoding: .utf8)
        try "{\"e\":1}\n".write(to: runB.appendingPathComponent("ledger.jsonl"),
                                atomically: true, encoding: .utf8)

        let scan = PeelScienceStatus.scanScientist(projectRoot: root.path)
        XCTAssertEqual(scan, PeelScienceStatus.LedgerScan(runs: 2, events: 3),
                       "a dir without ledger.jsonl is not a run; events = chained lines")
    }

    func testScanIsNilWithoutScientistPackage() {
        XCTAssertNil(PeelScienceStatus.scanScientist(projectRoot: "/nonexistent-root"),
                     "missing package must read as 'not found', never a fake zero-run success")
    }

    // MARK: wiring pins — one assertion PER SITE (multi-site fix discipline)

    private func source(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent()   // Tests/KistTests
            .deletingLastPathComponent()                  // Tests
            .deletingLastPathComponent()                  // package root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testReplInterceptorSiteIsWired() throws {
        let repl = try source("Sources/Kist/KistREPL.swift")
        XCTAssertTrue(repl.contains("PeelIntent.parse(input)"),
                      "KistREPL.swift lost the peel status-word interceptor")
        XCTAssertTrue(repl.contains("PeelScienceStatus.render(peelActive: peelMode.isActive"),
                      "peel display no longer reads the live Lois/Peel mode box")
    }

    func testPeelNeverMutatesTheMode() {
        // The interceptor is display-only by contract: PeelIntent has no activate/deactivate arm.
        // If a case is ever added, this pin forces the author to reconsider the read-only contract.
        XCTAssertEqual(PeelIntent.parse("peel"), .status)
        let repl = try? source("Sources/Kist/KistREPL.swift")
        if let repl {
            // Within the peel interceptor block there must be no assignment to peelMode.isActive.
            if let range = repl.range(of: "PEEL STATUS WORD"),
               let end = repl.range(of: "NATURAL-LANGUAGE SANDBOX CONTROL") {
                let block = String(repl[range.lowerBound..<end.lowerBound])
                XCTAssertFalse(block.contains("peelMode.isActive = "),
                               "the peel status word must never flip the gate")
            } else {
                XCTFail("could not locate the peel interceptor block boundaries")
            }
        }
    }
}
