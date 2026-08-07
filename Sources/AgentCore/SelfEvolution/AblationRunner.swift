import Foundation

/// Runs one COLD-vs-WARM ablation: the SAME held-out eval corpus through a COLD arm (an agent with NO
/// accumulated memory / self__ tools / scorecard) and a WARM arm (with them), then feeds the two sets of
/// GROUNDED per-case outcomes to `AblationHarness`. The arms are injected closures, so this orchestration is
/// testable without live models; the runtime wires the real cold/warm kist agents at the edge.
///
/// Grounding note: `EvalCaseResult.passed` is decided by the case's DETERMINISTIC assertions over the run's
/// output + trajectory — never the model's self-report. So the advantage the oracle reports is
/// execution-grounded by construction.
public struct AblationRunner: Sendable {

    public static func run(
        heldOut: [EvalCase],
        accumulatedFrom: Set<String>,
        corpusHash: String,
        epoch: Double,
        cold: EvalRunner.Agent,
        warm: EvalRunner.Agent,
        maxIterations: Int = 12,
        judge: EvalRunner.Judge? = nil
    ) async -> AblationResult? {
        // Refuse a contaminated corpus BEFORE spending any runs — the held-out set must be disjoint from
        // whatever fed the warm state, or the measurement is meaningless (and expensive to fake).
        let ids = heldOut.map { $0.name }
        guard !ids.isEmpty, AblationHarness.heldOutIsClean(heldOut: Set(ids), accumulatedFrom: accumulatedFrom) else {
            return nil
        }
        let runner = EvalRunner(maxIterations: maxIterations)
        let coldReport = await runner.run(heldOut, agent: cold, judge: judge)
        let warmReport = await runner.run(heldOut, agent: warm, judge: judge)

        func passedByName(_ report: EvalReport) -> [String: Bool] {
            Dictionary(report.results.map { ($0.name, $0.passed) }, uniquingKeysWith: { a, _ in a })
        }
        let coldP = passedByName(coldReport), warmP = passedByName(warmReport)
        let coldGrounded = ids.map { coldP[$0] ?? false }
        let warmGrounded = ids.map { warmP[$0] ?? false }

        return AblationHarness.measure(coldGrounded: coldGrounded, warmGrounded: warmGrounded,
                                       heldOutIDs: ids, accumulatedFrom: accumulatedFrom,
                                       corpusHash: corpusHash, epoch: epoch)
    }
}
