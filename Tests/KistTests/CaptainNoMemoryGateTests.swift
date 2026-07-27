import XCTest
import AgentCore
@testable import Kist

/// C3 regression: the simulation gate must compute its decision WITHOUT persisting anything when
/// memory is disabled (`--no-memory`). Previously `runSimulationGate` unconditionally wrote board
/// tasks, specialists, a report file, and a benchmark record — a real side-effect leak.
final class CaptainNoMemoryGateTests: XCTestCase {
    private func tempRoot() -> String {
        let root = NSTemporaryDirectory() + "kist_nomem_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func demoPlan() -> Plan {
        Plan(title: "Kist Captain",
             tasks: [PlanTask(id: 1, title: "ACTION: deploy to production", kind: .action)])
    }

    /// persist:false → decision still computed, but ZERO artifacts on disk and ZERO seeded work.
    func testGatePersistFalseWritesNothing() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = OrganizationalLearningStore(projectRoot: root,
                                                now: { Date(timeIntervalSince1970: 1_700_000_000) })

        let report = store.runSimulationGate(plan: demoPlan(), trajectory: [],
                                             objective: "deploy to production", persist: false)

        // Decision is real (the safety gate still works).
        XCTAssertTrue((1...99).contains(report.estimatedSuccess), "gate must still compute a decision")
        XCTAssertFalse(report.decision.isEmpty)
        // Nothing persisted.
        XCTAssertEqual(report.seededTasks, 0, "no board tasks seeded under --no-memory")
        XCTAssertEqual(report.createdSpecialists, 0, "no specialists created")
        XCTAssertEqual(report.benchmarkRecords, 0, "no benchmark recorded")
        XCTAssertEqual(report.path, "", "no report file written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/.kist/learning"),
                       "no .kist/learning tree created")
        // Codex catch (2026-07-03): measured trials call simulationEnvironment() which durably creates
        // .kist/simulation-{home,tmp}. The persist guard must precede them so --no-memory leaves NONE.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/.kist/simulation-home"),
                       "no .kist/simulation-home leaked by measured trials under --no-memory")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/.kist/simulation-tmp"),
                       "no .kist/simulation-tmp leaked by measured trials under --no-memory")
        // Honest audit fields (Option B): intentional no-write, NOT a failure; decision is contaminated.
        XCTAssertFalse(report.writeSucceeded, "nothing was written — writeSucceeded must be honest")
        XCTAssertFalse(report.persistenceRequired, "persistence was intentionally not required")
        XCTAssertTrue(report.decision.hasPrefix("[NON-PERSISTENT] "),
                      "the ephemeral verdict must be self-labelling so no log mistakes it for a vetted one")
        XCTAssertTrue(PlanStore(projectRoot: root).load().tasks.isEmpty, "the shared plan board is untouched")
    }

    /// The underlying heuristic METRICS are the same with and without persistence — --no-memory suppresses
    /// durable writes + skips measured trials, but the risk/success heuristic that seeds the verdict is
    /// unchanged. The decision STRING differs (the no-persist verdict is self-labelled "[NON-PERSISTENT]"),
    /// and passesGate differs by design (it requires writeSucceeded). The block/allow equivalence is asserted
    /// via the enforcer's shouldBlock below, not via passesGate. (Council-adapted 2026-07-03.)
    func testGateNoPersistComputesRealHeuristicButHonestFields() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = OrganizationalLearningStore(projectRoot: root,
                                                now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let noPersist = store.runSimulationGate(plan: demoPlan(), trajectory: [],
                                                objective: "deploy to production", persist: false)
        let persisted = store.runSimulationGate(plan: demoPlan(), trajectory: [],
                                                objective: "deploy to production", persist: true)
        // Same heuristic metrics (measured trials don't fire in an empty temp root — no manifest to run).
        XCTAssertEqual(noPersist.estimatedSuccess, persisted.estimatedSuccess)
        XCTAssertEqual(noPersist.failureRisk, persisted.failureRisk)
        // Decision string is contaminated on the ephemeral path; strip the label and the core verdict matches.
        XCTAssertEqual(noPersist.decision, "[NON-PERSISTENT] " + persisted.decision)
        // Honest fields: the no-persist path did not write; the persist path did.
        XCTAssertFalse(noPersist.writeSucceeded); XCTAssertFalse(noPersist.persistenceRequired)
        XCTAssertTrue(persisted.writeSucceeded);  XCTAssertTrue(persisted.persistenceRequired)
    }

    /// shouldBlock must (a) NOT fail-closed on the intentional no-write path, (b) STILL fail-closed on a REAL
    /// required-write failure, and (c) STILL enforce the metric thresholds on the no-write path. (Codex.)
    func testShouldBlockHonorsPersistenceRequired() {
        func report(persistReq: Bool, wrote: Bool, success: Int, risk: Int) -> CaptainSimulationGateReport {
            CaptainSimulationGateReport(path: "", text: "", objective: "o", domainTitle: "d",
                                        recommendedStrategy: "s", decision: "x",
                                        acceptanceThreshold: 70, estimatedSuccess: success, failureRisk: risk,
                                        seededTasks: 0, createdSpecialists: 0, benchmarkRecords: 0,
                                        writeSucceeded: wrote, writeError: nil, persistenceRequired: persistReq)
        }
        // (a) no-write path + good metrics + high risk ⇒ PROCEEDS (not blocked for lack of persistence).
        XCTAssertFalse(CaptainSimulationEnforcer.shouldBlock(
            report: report(persistReq: false, wrote: false, success: 90, risk: 5), risk: .high))
        // (b) required write FAILED ⇒ fail-closed BLOCK regardless of metrics/risk.
        XCTAssertTrue(CaptainSimulationEnforcer.shouldBlock(
            report: report(persistReq: true, wrote: false, success: 90, risk: 5), risk: .low))
        // (c) no-write path still enforces metrics: bad success at high risk ⇒ BLOCK.
        XCTAssertTrue(CaptainSimulationEnforcer.shouldBlock(
            report: report(persistReq: false, wrote: false, success: 10, risk: 80), risk: .high))
        // low risk never blocks on metrics alone.
        XCTAssertFalse(CaptainSimulationEnforcer.shouldBlock(
            report: report(persistReq: false, wrote: false, success: 10, risk: 80), risk: .medium))
    }

    /// Contrast: persist:true DOES write (proves the no-write path is the difference, not a broken gate).
    func testGatePersistTrueDoesWrite() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = OrganizationalLearningStore(projectRoot: root,
                                                now: { Date(timeIntervalSince1970: 1_700_000_000) })

        let report = store.runSimulationGate(plan: demoPlan(), trajectory: [],
                                             objective: "deploy to production", persist: true)

        XCTAssertGreaterThan(report.seededTasks, 0, "persist:true seeds the simulation tasks")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/learning"),
                      "persist:true creates the learning tree")
    }

    /// End-to-end: a high-risk fleet preflight with noMemory leaves no simulation artifacts behind.
    func testPreflightNoMemoryLeavesNoArtifacts() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let result = CaptainSimulationEnforcer.preflight(mode: .fleet,
                                                         objective: "deploy the payment service to production",
                                                         projectRoot: root,
                                                         noMemory: true,
                                                         now: { Date(timeIntervalSince1970: 1_700_000_000) })

        // The gate still ran (a decision was reached), but nothing was persisted.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/.kist/learning/simulations"),
                       "--no-memory preflight must not write simulation artifacts")
        XCTAssertTrue(PlanStore(projectRoot: root).load().tasks.isEmpty,
                      "--no-memory preflight must not seed ANY tasks onto the board")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/.kist/plan.json"),
                       "--no-memory preflight must not create the plan file")
        _ = result   // decision content is covered by the enforcer's own tests
    }
}
