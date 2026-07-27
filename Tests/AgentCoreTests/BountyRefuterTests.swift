import XCTest
@testable import AgentCore

/// The panel skeptics: the LLM refuter fails CLOSED (ambiguous/empty/no-response ⇒ refuted), and the
/// deterministic fallback refutes below a severity floor.
final class BountyRefuterTests: XCTestCase {

    func finding(_ sev: SecurityFinding.Severity = .high) -> SecurityFinding {
        SecurityFinding(severity: sev, category: .codeInjection, rule: "eval-use", title: "eval()",
                        file: "a.py", line: 1, evidence: "eval(x)", recommendation: "don't")
    }
    func refuterReturning(_ text: String?) -> LLMFindingRefuter {
        LLMFindingRefuter(complete: { _, _ in text })
    }

    func testExplicitConfirmIsNotRefuted() async {
        let v = await refuterReturning("CONFIRM\nreachable from the request handler").refute(finding())
        XCTAssertFalse(v.refuted)
    }
    func testExplicitRefuteIsRefuted() async {
        let v = await refuterReturning("REFUTE\nnot reachable in context").refute(finding())
        XCTAssertTrue(v.refuted)
    }
    func testNoResponseFailsClosedToRefuted() async {
        let nilResp = await refuterReturning(nil).refute(finding()).refuted
        let blankResp = await refuterReturning("   ").refute(finding()).refuted
        XCTAssertTrue(nilResp)
        XCTAssertTrue(blankResp)
    }
    func testAmbiguousResponseFailsClosedToRefuted() async {
        let v = await refuterReturning("hmm, maybe, it depends").refute(finding())
        XCTAssertTrue(v.refuted)
    }
    func testConfirmMustBeCleanNotAlsoRefute() async {
        // a line hedging both ways is not a clean confirm ⇒ refuted.
        let v = await refuterReturning("CONFIRM but honestly i'd REFUTE").refute(finding())
        XCTAssertTrue(v.refuted)
    }

    // REGRESSION (panel review, fail-open #4): substrings containing "confirm" must NOT confirm.
    func testCannotConfirmIsRefuted() async {
        let v = await refuterReturning("cannot confirm this is reachable").refute(finding()).refuted
        XCTAssertTrue(v)
    }
    func testConfirmedFalsePositiveIsRefuted() async {
        let v = await refuterReturning("confirmed false positive — not exploitable").refute(finding()).refuted
        XCTAssertTrue(v)
    }
    func testUnableToConfirmIsRefuted() async {
        let v = await refuterReturning("unable to confirm reachability").refute(finding()).refuted
        XCTAssertTrue(v)
    }

    func testSeverityFloorRefutesBelowMedium() async {
        let r = SeverityThresholdRefuter(minConfirmable: .medium)
        let low = await r.refute(finding(.low)).refuted
        let info = await r.refute(finding(.info)).refuted
        let high = await r.refute(finding(.high)).refuted
        let medium = await r.refute(finding(.medium)).refuted
        XCTAssertTrue(low)
        XCTAssertTrue(info)
        XCTAssertFalse(high)
        XCTAssertFalse(medium)
    }
}
