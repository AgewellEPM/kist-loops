import XCTest
@testable import Kist
@testable import AgentCore

/// Regression (dogfood 2026-08-06): `--council-execute` on a benign COBOL report tweak was
/// hard-blocked because the builder brief embeds the ENTIRE council markdown transcript into
/// the objective, and the risk classifier keyword-scanned that blob — an incidental
/// "auth/safety/exploit" word (or an org-store "Security lab sandbox" domain mislabel) flipped
/// the whole build to CRITICAL. The safety gates must classify risk on the USER'S goal, not the
/// council transcript. (We can't drive the full private runPlanExecute here, so we pin the
/// invariant at the classifier boundary that produced the wrong verdict.)
final class CouncilExecuteRiskObjectiveTests: XCTestCase {

    // The benign user goal stays sub-critical…
    func testBenignBuildGoalIsNotCritical() {
        let goal = "Enhance the existing COBOL payroll app in this directory: add a DEDUCTIONS column "
            + "(10 percent of gross pay) and a NET PAY column to the report, recompile with cobc, run it."
        let risk = CaptainSimulationEnforcer.riskLevel(mode: .planExecute, objective: goal)
        XCTAssertLessThan(risk, .critical, "a COBOL report tweak must not classify as critical risk")
    }

    // …while the council BUILDER BRIEF (which embeds the transcript) DOES trip critical on an
    // incidental security word — proving why risk must be judged on the user goal, not this string.
    func testCouncilBriefWithEmbeddedTranscriptCanFalselyTripCritical() {
        let userGoal = "add a NET PAY column to the payroll report and recompile with cobc"
        let markdown = """
        | Ready | Add columns | coder | ... |
        | Backlog | Research auth-token handling for the report exporter | researcher | ... |
        """
        let builderBrief = AICouncil.renderBuilderBrief(goal: userGoal, markdown: markdown)
        // The embedded transcript carries "auth" / "token" → critical on the WRONG string.
        XCTAssertEqual(CaptainSimulationEnforcer.riskLevel(mode: .planExecute, objective: builderBrief), .critical)
        // …but the user's own goal is not critical — which is what the gate must now use.
        XCTAssertLessThan(CaptainSimulationEnforcer.riskLevel(mode: .planExecute, objective: userGoal), .critical)
    }

    // Source pin: the council→plan-execute hand-off passes the user goal as the risk objective.
    func testCouncilHandoffThreadsRiskObjective() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: repo.appendingPathComponent("Sources/Kist/KistRunner.swift"),
                             encoding: .utf8)
        XCTAssertTrue(src.contains("riskObjective: goal"),
                      "council-execute must hand the user's original goal as the gate risk objective")
        XCTAssertTrue(src.contains("let gateObjective = riskObjective ?? goal"),
                      "the safety gates must classify risk on gateObjective (user goal), not the builder blob")
    }
}
