import XCTest
import Foundation
@testable import AgentCore

/// The eval HARNESS (roadmap #1): golden suite + baseline + regression detection. Pins the gate logic
/// (a case going passed→fail, or a pass-rate drop, must flag; no baseline must NOT), custom-suite loading,
/// and history baseline selection — so "gate a deploy on a score drop" is trustworthy.
final class EvalHarnessTests: XCTestCase {

    private func summary(_ cases: [String: Bool], version: Int = 1, at: Double = 100) -> EvalRunSummary {
        let passed = cases.values.filter { $0 }.count
        return EvalRunSummary(suiteVersion: version, atEpoch: at, passed: passed, total: cases.count, caseResults: cases)
    }

    // MARK: - Regression detection (the gate)

    func testNoBaselineIsNeverARegression() {
        let reg = EvalRegression.compare(current: summary(["a": false, "b": false]), baseline: nil)
        XCTAssertFalse(reg.isRegression, "first run has nothing to regress against")
        XCTAssertFalse(reg.hadBaseline)
    }

    func testCaseGoingPassedToFailIsARegression() {
        let base = summary(["a": true, "b": true])
        let now = summary(["a": true, "b": false])
        let reg = EvalRegression.compare(current: now, baseline: base)
        XCTAssertTrue(reg.isRegression)
        XCTAssertEqual(reg.regressedCases, ["b"])
        XCTAssertLessThan(reg.passRateDelta, 0)
    }

    func testImprovementIsNotARegression() {
        let base = summary(["a": true, "b": false])
        let now = summary(["a": true, "b": true])
        let reg = EvalRegression.compare(current: now, baseline: base)
        XCTAssertFalse(reg.isRegression)
        XCTAssertEqual(reg.fixedCases, ["b"])
        XCTAssertGreaterThan(reg.passRateDelta, 0)
    }

    func testSameResultsIsNotARegression() {
        let s = summary(["a": true, "b": false])
        XCTAssertFalse(EvalRegression.compare(current: s, baseline: s).isRegression)
    }

    // MARK: - History baseline = most recent of the SAME suite version

    func testBaselineIsLatestOfSameSuiteVersion() throws {
        let dir = ToolContext.canonicalize(
            try makeDir(NSTemporaryDirectory() + "evalhist-\(UUID().uuidString)"))!
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = EvalHistoryStore(projectRoot: dir)
        store.record(summary(["a": true], version: 1, at: 10))
        store.record(summary(["a": false], version: 2, at: 20))     // different suite version — ignored
        store.record(summary(["a": true, "b": true], version: 1, at: 30))
        let base = store.baseline(suiteVersion: 1)
        XCTAssertEqual(base?.atEpoch, 30, "baseline is the most recent run of the SAME suite version")
        XCTAssertEqual(base?.total, 2)
    }

    // MARK: - Custom suite loading (fail-soft)

    func testLoadsCustomSuiteAndIgnoresMalformed() throws {
        let dir = try makeDir(NSTemporaryDirectory() + "evalsuite-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try makeDir(dir + "/.kist/eval")
        let json = #"[{"name":"custom-1","prompt":"do X","assertions":["healthy",{"toolCalled":"read_file"},{"contains":"ok"},{"maxSteps":5}]}]"#
        try json.write(toFile: dir + "/.kist/eval/suite.json", atomically: true, encoding: .utf8)
        let cases = EvalGoldenSuite.cases(projectRoot: dir)
        XCTAssertTrue(cases.contains { $0.name == "custom-1" }, "custom case is loaded")
        XCTAssertTrue(cases.count > EvalGoldenSuite.builtIn.count, "custom cases add to the built-ins")

        // Malformed file → ignored, built-ins still present.
        try "not json".write(toFile: dir + "/.kist/eval/suite.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(EvalGoldenSuite.cases(projectRoot: dir).count, EvalGoldenSuite.builtIn.count)
    }

    @discardableResult private func makeDir(_ p: String) throws -> String {
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true); return p
    }
}
