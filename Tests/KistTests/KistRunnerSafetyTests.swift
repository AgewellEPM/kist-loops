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

    // BUG 2 regression: the default provider must be the STRONGEST keyed cloud provider, not
    // whatever sorts first in the catalog (MiMo, which 400s on multi-turn tool history). Pin it
    // on the real source so nobody reintroduces the "first with a key" default.
    func testDefaultProviderPicksStrongestKeyedNotFirstInCatalog() throws {
        let source = try runnerSource()
        XCTAssertTrue(source.contains("ModelEscalator.rank"),
                      "resolveProvider must rank keyed providers by strength")
        XCTAssertFalse(source.contains("if let cloud = registry.providers.first(where: { $0.requiresAPIKey && registry.hasKey(for: $0) })"),
                       "the old first-with-key default (which made MiMo the silent default) must be gone")
    }

    // Dogfood 2026-08-06 ("why only gemini"): the single-model default must ALSO consider available
    // subscription CLIs (claude-cli/codex-cli), which outrank the keyed-cloud APIs — otherwise gemini
    // always wins because the CLIs (requiresAPIKey == false) were excluded from the pool entirely.
    // Luke's call: strongest leads, team stays opt-in (/council, /ultra, /role).
    func testDefaultProviderConsidersAvailableSubscriptionCLIs() throws {
        let source = try runnerSource()
        XCTAssertTrue(source.contains("isLocallyAvailable()"),
                      "resolveProvider must include subscription CLIs that pass the bounded availability probe")
        XCTAssertTrue(source.contains("let eligible = subscriptionReady + keyedCloud"),
                      "the default pool must be subscription-ready CLIs UNION keyed cloud, ranked together")
    }

    // The ranking that makes 'strongest leads' true: claude-cli/codex-cli outrank the cloud APIs.
    func testSubscriptionCLIsOutrankKeyedCloudInEscalator() {
        XCTAssertGreaterThan(ModelEscalator.rank("claude-cli"), ModelEscalator.rank("gemini"))
        XCTAssertGreaterThan(ModelEscalator.rank("codex-cli"), ModelEscalator.rank("gemini"))
        XCTAssertGreaterThan(ModelEscalator.rank("gemini"), ModelEscalator.rank("deepseek"))
    }

    // BUG 3 regression: self-heal repair specialists that inherit the model must be escalated to the
    // strongest available provider (not the weak session default). Pin the wiring on real source.
    func testSelfHealRepairSpecialistsEscalateToStrongestModel() throws {
        let source = try runnerSource()
        XCTAssertTrue(source.contains("def.source == \"captain-self-heal\""),
                      "runSpecialist must special-case self-heal repair agents")
        XCTAssertTrue(source.contains("ModelEscalator.pick(tier: .frontier"),
                      "self-heal repair must escalate to the frontier (strongest) model")
        // Codex P2: repair escalation must not route to keyless LOCAL providers (mlx/ollama) that may be
        // a dead endpoint — restrict to keyed cloud + keyless subscription hitters.
        XCTAssertTrue(source.contains("subscriptionHitters"),
                      "repair escalation must exclude unreachable local providers (keyed cloud + claude-cli/codex-cli only)")
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

    // MARK: - one-shot plan-execute preflight judges its OWN trials (2026-07-29 dogfood catch)
    // Preflight runs only `git diff --check`, but incomplete-ness demanded the interactive
    // suite's evidence — so every high-risk one-shot goal scored threshold-1 and bricked
    // (one-shot mode has no /simulate to attach evidence). High risk now judges preflight's
    // own trials; FLEET (pinned above) and CRITICAL risk keep the strict full-suite demand.

    @discardableResult
    private func git(_ args: [String], cwd: String) -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return nil }
    }

    private func makeCleanGitRoot() throws -> String {
        let root = tempRoot()
        try "print(1)\n".write(toFile: root + "/main.swift", atomically: true, encoding: .utf8)
        guard git(["init", "-q"], cwd: root) == 0 else { throw XCTSkip("git unavailable") }
        git(["-c", "user.email=t@t", "-c", "user.name=t", "add", "."], cwd: root)
        git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"], cwd: root)
        return root
    }

    func testPlanExecutePreflightPassesWhenItsOwnTrialsPass() throws {
        let root = try makeCleanGitRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let objective = "build the helper and write the report file"
        XCTAssertEqual(CaptainSimulationEnforcer.riskLevel(mode: .planExecute, objective: objective), .high)
        let result = CaptainSimulationEnforcer.preflight(mode: .planExecute, objective: objective,
                                                         projectRoot: root,
                                                         now: { Date(timeIntervalSince1970: 1_700_002_200) })
        XCTAssertTrue(result.canExecute,
                      "a passing preflight trial must not be judged 'incomplete' against commands preflight never runs: \(result.terminalLines)")
    }

    func testPlanExecutePreflightStillBlocksCriticalRisk() throws {
        let root = try makeCleanGitRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let objective = "deploy the billing service to production"
        XCTAssertEqual(CaptainSimulationEnforcer.riskLevel(mode: .planExecute, objective: objective), .critical)
        let result = CaptainSimulationEnforcer.preflight(mode: .planExecute, objective: objective,
                                                         projectRoot: root,
                                                         now: { Date(timeIntervalSince1970: 1_700_002_300) })
        XCTAssertFalse(result.canExecute, "critical risk keeps the strict full-suite demand")
    }

    func testPlanExecutePreflightBlocksWhenItsOwnTrialFails() throws {
        let root = try makeCleanGitRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // Unstaged trailing-whitespace change → `git diff --check` exits nonzero → trial FAILS.
        try "print(1) \n".write(toFile: root + "/main.swift", atomically: true, encoding: .utf8)
        let result = CaptainSimulationEnforcer.preflight(mode: .planExecute,
                                                         objective: "build the helper and write the report file",
                                                         projectRoot: root,
                                                         now: { Date(timeIntervalSince1970: 1_700_002_400) })
        XCTAssertFalse(result.canExecute, "a FAILED preflight trial still blocks — leniency is about coverage, not failures")
    }

    // 2026-08-04: "build me a win98 hangman app" was hard-refused TWICE on the gate's own invented
    // 64-68% estimate. An EXPLICIT user request below critical risk downgrades a sub-threshold
    // verdict to ADVISORY (inform + proceed) — the human already decided. Same failing-trial setup
    // as the autonomous test above, so the ONLY variable is the initiator.
    func testUserRequestedPlanExecuteProceedsWithAdvisoryOnSubThresholdVerdict() throws {
        let root = try makeCleanGitRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "print(1) \n".write(toFile: root + "/main.swift", atomically: true, encoding: .utf8)
        let result = CaptainSimulationEnforcer.preflight(mode: .planExecute,
                                                         objective: "build me a win98 hangman app",
                                                         projectRoot: root,
                                                         initiator: .userRequest,
                                                         now: { Date(timeIntervalSince1970: 1_700_002_500) })
        XCTAssertTrue(result.canExecute,
                      "an explicit user build must not be vetoed by the gate's estimate: \(result.terminalLines)")
        XCTAssertTrue(result.terminalLines.contains { $0.contains("simulation gate · advisory") },
                      "the verdict must still be SHOWN as an advisory, not silently swallowed")
        XCTAssertTrue(result.terminalLines.contains { $0.contains("proceeding") })
    }

    func testUserRequestedCriticalRiskStillBlocks() throws {
        let root = try makeCleanGitRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let objective = "deploy the billing service to production"
        XCTAssertEqual(CaptainSimulationEnforcer.riskLevel(mode: .planExecute, objective: objective), .critical)
        let result = CaptainSimulationEnforcer.preflight(mode: .planExecute, objective: objective,
                                                         projectRoot: root,
                                                         initiator: .userRequest,
                                                         now: { Date(timeIntervalSince1970: 1_700_002_600) })
        XCTAssertFalse(result.canExecute,
                       "critical-risk signals (production/billing) hard-block even for an explicit user request")
    }

    func testRunnerPassesUserRequestInitiatorToPlanExecuteGate() throws {
        // Source pin: runPlanExecute is only reachable from explicit user commands, so it must
        // declare initiator: .userRequest — losing this line silently restores the hard veto.
        let source = try runnerSource()
        let planExecuteStart = try XCTUnwrap(source.range(of: "private static func runPlanExecute"))
        let body = String(source[planExecuteStart.lowerBound...].prefix(4000))
        XCTAssertTrue(body.contains("initiator: .userRequest"),
                      "runPlanExecute's simulation preflight must pass initiator: .userRequest")
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
