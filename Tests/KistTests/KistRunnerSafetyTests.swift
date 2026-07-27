import XCTest
import AgentCore
@testable import Kist

final class KistRunnerSafetyTests: XCTestCase {
    private func tempRoot() -> String {
        let root = NSTemporaryDirectory() + "kist_runner_safety_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func repoRoot() -> String {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = url.appendingPathComponent("Sources/Kist/KistRunner.swift").path
            if FileManager.default.fileExists(atPath: candidate) { return url.path }
            url.deleteLastPathComponent()
        }
        return FileManager.default.currentDirectoryPath
    }

    private func runnerSource() throws -> String {
        try String(contentsOfFile: repoRoot() + "/Sources/Kist/KistRunner.swift", encoding: .utf8)
    }

    private func assertOrder(_ first: String, before second: String, in text: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let firstRange = text.range(of: first) else {
            return XCTFail("missing marker: \(first)", file: file, line: line)
        }
        guard let secondRange = text.range(of: second) else {
            return XCTFail("missing marker: \(second)", file: file, line: line)
        }
        XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound,
                          "\(first) must stay before \(second)", file: file, line: line)
    }

    // High-blast-radius tools (arbitrary shell / code / network / OS) stay approval-gated.
    // ast_grep_apply spawns the external ast-grep binary to rewrite files → high-risk, gated.
    func testHighRiskToolsRequireApproval() {
        for tool in ["run_command", "custom_tool", "browse", "computer_control", "desktop_control", "ui_elements", "ax_press",
                     "tap", "locate", "look", "wait_for_screen", "watch_screen", "computer_use_selftest",
                     "visual_verify", "research_run", "ast_grep_apply", "pentest"] {
            XCTAssertTrue(KistRunner.sensitiveTools.contains(tool), "\(tool) must be approval-gated in the REPL")
        }
    }

    // FILE-TREE TRUST (deliberate): file mutations are confined to the project root by ConfinedRoot
    // (no escape possible), so they are NOT approval-gated. Gating every mkdir/write caused an
    // approval-deadlock that burned ~250k tokens on a single build. Read tools stay low-friction too.
    // ast_grep is read-only (structural search + rewrite preview) → not gated.
    func testConfinedFileMutationsAndReadsAreNotGated() {
        for tool in ["write_file", "edit_file", "apply_patch", "move_file", "make_dir",
                     "read_file", "search_code", "view_image", "generate_image", "ast_grep", "git", "symbols"] {
            XCTAssertFalse(KistRunner.sensitiveTools.contains(tool), "\(tool) is confined/safe — must NOT be gated")
        }
    }

    func testLowRiskPlanExecuteCanSkipSimulationGate() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let result = CaptainSimulationEnforcer.preflight(mode: .planExecute,
                                                         objective: "explain current architecture",
                                                         projectRoot: root,
                                                         now: { Date(timeIntervalSince1970: 1_700_002_000) })

        XCTAssertTrue(result.canExecute)
        XCTAssertNil(result.report)
        guard case .notRequired(let reason) = result.decision else {
            return XCTFail("expected low-risk plan-execute to skip simulation")
        }
        XCTAssertTrue(reason.contains("read-only"))
    }

    func testRoutinePlanExecuteCanSkipDomainLearningGate() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let result = CaptainDomainLearningEnforcer.preflight(mode: .planExecute,
                                                             objective: "explain current architecture",
                                                             projectRoot: root,
                                                             now: { Date(timeIntervalSince1970: 1_700_002_010) })

        XCTAssertTrue(result.canExecute)
        XCTAssertNil(result.report)
        guard case .notRequired(let reason) = result.decision else {
            return XCTFail("expected routine objective to skip domain learning")
        }
        XCTAssertTrue(reason.contains("does not signal unfamiliar"))
    }

    func testRegulatedDomainLearningGateBlocksExecutionUntilUnderstandingClears() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try? "swift-tools-version: 6.0\n".write(toFile: root + "/Package.swift",
                                               atomically: true,
                                               encoding: .utf8)

        let result = CaptainDomainLearningEnforcer.preflight(
            mode: .planExecute,
            objective: "build a medical imaging platform with DICOM HIPAA workflows",
            projectRoot: root,
            now: { Date(timeIntervalSince1970: 1_700_002_020) })

        XCTAssertFalse(result.canExecute)
        guard case .blocked(let report, let reasons) = result.decision else {
            return XCTFail("expected regulated domain to block below confidence threshold")
        }
        XCTAssertFalse(report.canExecute)
        XCTAssertTrue(report.writeSucceeded)
        XCTAssertTrue(reasons.contains { $0.contains("understanding confidence") })
        XCTAssertTrue(result.terminalLines.contains { $0.contains("domain learning gate · blocked") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + report.path))
    }

    func testRedactedDomainLearningModeDoesNotPersistRawSensitiveObjective() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "swift-tools-version: 6.0\n".write(toFile: root + "/Package.swift",
                                               atomically: true,
                                               encoding: .utf8)
        let sensitive = "build medical billing workflow with api key sk-live-abc123"

        let result = CaptainDomainLearningEnforcer.preflight(mode: .planExecute,
                                                             objective: sensitive,
                                                             projectRoot: root,
                                                             evidenceMode: .redacted,
                                                             now: { Date(timeIntervalSince1970: 1_700_002_030) })

        guard let report = result.report else {
            return XCTFail("expected a mandatory domain-learning report")
        }
        XCTAssertEqual(report.objective, "Redacted mandatory domain-learning safety evidence")
        let text = try String(contentsOfFile: root + "/" + report.path, encoding: .utf8)
        XCTAssertFalse(text.contains("sk-live-abc123"))
        XCTAssertFalse(text.contains("medical billing"))
        XCTAssertTrue(text.contains("Redacted mandatory domain-learning safety evidence"))
    }

    func testFleetAlwaysRunsSimulationPreflightBeforeLaunch() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try? "swift-tools-version: 6.0\n".write(toFile: root + "/Package.swift",
                                               atomically: true,
                                               encoding: .utf8)

        let result = CaptainSimulationEnforcer.preflight(mode: .fleet,
                                                         objective: "build a software refactor with tests",
                                                         projectRoot: root,
                                                         now: { Date(timeIntervalSince1970: 1_700_002_100) })

        XCTAssertFalse(result.canExecute)
        guard case .blocked(let report, let risk, let reasons) = result.decision else {
            return XCTFail("expected fleet preflight to block until executable sandbox evidence is attached")
        }
        XCTAssertEqual(risk, .high)
        XCTAssertFalse(report.passesGate)
        XCTAssertTrue(reasons.contains { $0.contains("estimated success") || $0.contains("failure risk") },
                      reasons.joined(separator: "\n"))
        XCTAssertTrue(report.path.contains(".kist/learning/simulations"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + report.path))
        XCTAssertTrue(result.terminalLines.contains { $0.contains("simulation gate · blocked") })

        let seeded = PlanStore(projectRoot: root).load()
        XCTAssertTrue(seeded.tasks.contains { $0.owner == "simulation-architect" })
        XCTAssertTrue(seeded.tasks.contains { $0.owner == "risk-model-critic" })
    }

    func testRunnerKeepsFleetSimulationPreflightBeforeSideEffects() throws {
        let source = try runnerSource()
        let fleetStart = try XCTUnwrap(source.range(of: "private static func runFleet"))
        let planExecuteStart = try XCTUnwrap(source.range(of: "private static func runPlanExecute"))
        let fleetBody = String(source[fleetStart.lowerBound..<planExecuteStart.lowerBound])

        assertOrder("CaptainSimulationEnforcer.preflight(mode: .fleet",
                    before: "let fleetBudget",
                    in: fleetBody)
        assertOrder("CaptainDomainLearningEnforcer.preflight(mode: .fleet",
                    before: "CaptainSimulationEnforcer.preflight(mode: .fleet",
                    in: fleetBody)
        assertOrder("CaptainDomainLearningEnforcer.preflight(mode: .fleet",
                    before: "CaptainOrchestrator.deriveScopeContext",
                    in: fleetBody)
        assertOrder("CaptainSimulationEnforcer.preflight(mode: .fleet",
                    before: "CaptainOrchestrator.deriveScopeContext",
                    in: fleetBody)
        assertOrder("CaptainSimulationEnforcer.preflight(mode: .fleet",
                    before: "FleetPlanner(",
                    in: fleetBody)
        assertOrder("CaptainSimulationEnforcer.preflight(mode: .fleet",
                    before: "PlanExecuteFleetSpawner",
                    in: fleetBody)
    }

    func testRunnerKeepsFleetDomainLearningPreflightBeforeSideEffects() throws {
        let source = try runnerSource()
        let fleetStart = try XCTUnwrap(source.range(of: "private static func runFleet"))
        let planExecuteStart = try XCTUnwrap(source.range(of: "private static func runPlanExecute"))
        let fleetBody = String(source[fleetStart.lowerBound..<planExecuteStart.lowerBound])

        assertOrder("CaptainDomainLearningEnforcer.preflight(mode: .fleet",
                    before: "CaptainSimulationEnforcer.preflight(mode: .fleet",
                    in: fleetBody)
        assertOrder("CaptainDomainLearningEnforcer.preflight(mode: .fleet",
                    before: "CaptainOrchestrator.deriveScopeContext",
                    in: fleetBody)
        assertOrder("CaptainDomainLearningEnforcer.preflight(mode: .fleet",
                    before: "PlanExecuteFleetSpawner",
                    in: fleetBody)
    }

    func testRunnerKeepsPlanExecuteSimulationPreflightBeforeSideEffects() throws {
        let source = try runnerSource()
        let planExecuteStart = try XCTUnwrap(source.range(of: "private static func runPlanExecute"))
        let interactorStart = try XCTUnwrap(source.range(of: "static func terminalInteractor"))
        let planExecuteBody = String(source[planExecuteStart.lowerBound..<interactorStart.lowerBound])

        assertOrder("CaptainDomainLearningEnforcer.preflight(mode: .planExecute",
                    before: "CaptainSimulationEnforcer.preflight(mode: .planExecute",
                    in: planExecuteBody)
        assertOrder("CaptainDomainLearningEnforcer.preflight(mode: .planExecute",
                    before: "TraceRecorder(traceId",
                    in: planExecuteBody)
        assertOrder("CaptainSimulationEnforcer.preflight(mode: .planExecute",
                    before: "TraceRecorder(traceId",
                    in: planExecuteBody)
        assertOrder("CaptainSimulationEnforcer.preflight(mode: .planExecute",
                    before: "PlanExecuteLoop(",
                    in: planExecuteBody)
        assertOrder("CaptainSimulationEnforcer.preflight(mode: .planExecute",
                    before: "pxl.run",
                    in: planExecuteBody)
    }

    func testRunnerKeepsPlanExecuteDomainLearningPreflightBeforeSideEffects() throws {
        let source = try runnerSource()
        let planExecuteStart = try XCTUnwrap(source.range(of: "private static func runPlanExecute"))
        let interactorStart = try XCTUnwrap(source.range(of: "static func terminalInteractor"))
        let planExecuteBody = String(source[planExecuteStart.lowerBound..<interactorStart.lowerBound])

        assertOrder("CaptainDomainLearningEnforcer.preflight(mode: .planExecute",
                    before: "CaptainSimulationEnforcer.preflight(mode: .planExecute",
                    in: planExecuteBody)
        assertOrder("CaptainDomainLearningEnforcer.preflight(mode: .planExecute",
                    before: "TraceRecorder(traceId",
                    in: planExecuteBody)
        assertOrder("CaptainDomainLearningEnforcer.preflight(mode: .planExecute",
                    before: "pxl.run",
                    in: planExecuteBody)
    }

    func testRiskSignalsUseTokenBoundariesAndDoNotMatchSubstrings() {
        XCTAssertEqual(CaptainSimulationEnforcer.riskLevel(mode: .planExecute,
                                                           objective: "explain prefix notation"),
                       .low)
        XCTAssertEqual(CaptainSimulationEnforcer.riskLevel(mode: .planExecute,
                                                           objective: "compare digital product ideas"),
                       .medium)
        XCTAssertEqual(CaptainSimulationEnforcer.riskLevel(mode: .planExecute,
                                                           objective: "review widget layout"),
                       .medium)
    }

    func testRiskSignalsCatchDestructiveAuthAndPaymentTerms() {
        let criticalObjectives = [
            "truncate user records",
            "purge stale sessions",
            "rotate api key",
            "revoke access for old token",
            "refund failed transactions",
            "overwrite production config"
        ]

        for objective in criticalObjectives {
            XCTAssertEqual(CaptainSimulationEnforcer.riskLevel(mode: .planExecute,
                                                               objective: objective),
                           .critical,
                           objective)
        }
    }

    func testRedactedEvidenceModeDoesNotPersistRawSensitiveObjective() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "swift-tools-version: 6.0\n".write(toFile: root + "/Package.swift",
                                               atomically: true,
                                               encoding: .utf8)
        let sensitive = "rotate api key sk-live-abc123 for customer billing"

        let result = CaptainSimulationEnforcer.preflight(mode: .planExecute,
                                                         objective: sensitive,
                                                         projectRoot: root,
                                                         evidenceMode: .redacted,
                                                         now: { Date(timeIntervalSince1970: 1_700_002_200) })

        guard let report = result.report else {
            return XCTFail("expected a mandatory simulation report")
        }
        XCTAssertEqual(report.objective, "Redacted mandatory simulation safety evidence")
        XCTAssertTrue(report.path.contains("redacted-mandatory-simulation-safety"))
        let text = try String(contentsOfFile: root + "/" + report.path, encoding: .utf8)
        XCTAssertFalse(text.contains("sk-live-abc123"))
        XCTAssertFalse(text.contains("customer billing"))
        XCTAssertTrue(text.contains("Redacted mandatory simulation safety evidence"))
    }

    func testHighRiskFailedSimulationBlocksExecution() {
        let report = CaptainSimulationGateReport(
            path: ".kist/learning/simulations/bad.md",
            text: "Captain Simulation Gate",
            objective: "direct production change",
            domainTitle: "Security lab sandbox",
            recommendedStrategy: "Direct target probing",
            decision: "HOLD EXECUTION; run another research/simulation pass before acting.",
            acceptanceThreshold: 82,
            estimatedSuccess: 70,
            failureRisk: 30,
            seededTasks: 0,
            createdSpecialists: 0,
            benchmarkRecords: 0,
            writeSucceeded: true,
            writeError: nil)

        XCTAssertTrue(CaptainSimulationEnforcer.shouldBlock(report: report, risk: .high))
        XCTAssertTrue(CaptainSimulationEnforcer.shouldBlock(report: report, risk: .critical))
        XCTAssertFalse(CaptainSimulationEnforcer.shouldBlock(report: report, risk: .medium))
    }

    func testEvidencePersistenceFailureBlocksEvenMediumRiskSimulation() {
        let report = CaptainSimulationGateReport(
            path: ".kist/learning/simulations/missing.md",
            text: "Captain Simulation Gate",
            objective: "benchmark refactor",
            domainTitle: "Software sandbox",
            recommendedStrategy: "Disposable repo test sandbox",
            decision: "HOLD EXECUTION; simulation evidence report could not be persisted.",
            acceptanceThreshold: 78,
            estimatedSuccess: 99,
            failureRisk: 1,
            seededTasks: 0,
            createdSpecialists: 0,
            benchmarkRecords: 0,
            writeSucceeded: false,
            writeError: "permission denied")

        XCTAssertTrue(CaptainSimulationEnforcer.shouldBlock(report: report, risk: .medium))
    }
}
