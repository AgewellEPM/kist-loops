import XCTest
import AgentCore
@testable import Kist

final class CaptainLoopStopTests: XCTestCase {
    private actor Calls {
        var names: [String] = []
        func add(_ name: String) { names.append(name) }
    }

    private func fixture() throws -> (String, KistREPL) {
        let root = NSTemporaryDirectory() + "captain-loop-stop-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        let recorder = TrajectoryRecorder()
        let loop = HeadlessAgentLoop(providers: ProviderRegistry(providers: []), providerId: "none", model: nil,
            tools: .headless(), context: ToolContext(projectRoot: root), recorder: recorder)
        let repl = KistREPL(loop: loop, commands: KistCommands(templates: [:]))
        repl.projectRoot = root
        repl.recorder = recorder
        repl.perm = PermissionController(mode: .normal, sensitive: [], edit: [])
        return (root, repl)
    }

    func testAuthorizationFailurePersistsCapsuleWithoutSeedingOrDispatchingRepairs() async throws {
        let (root, repl) = try fixture()
        repl.recorder?.record(tool: "list_files", argsFingerprint: "path=/outside", success: false,
            failureDetail: "path '/outside' escapes the project root (\(root)) — refused")
        repl.runSpecialist = { _, _, _, _ in
            XCTFail("a surfaceBlocked verdict must never dispatch a repair specialist")
            return nil
        }
        let report = await repl.openFailureAnalysis(goal: "inspect the external repository",
            summary: "provider request limit reached (40/40)", automaticRepair: true)
        XCTAssertTrue(report.writeSucceeded)
        XCTAssertEqual(report.seededTasks, 0)
        XCTAssertEqual(report.capsule.likelyLayer, .authorization)
        XCTAssertTrue(PlanStore(projectRoot: root).load().tasks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/.kist/learning/self-heal"))
    }

    func testProviderFailuresAndProgressStopsDoNotStartFreshRepairBudgets() async throws {
        for summary in ["provider error: quota exhausted", "provider request limit reached (40/40)",
                        "stopped early — repeated searches produced no new evidence"] {
            let (root, repl) = try fixture()
            repl.runSpecialist = { _, _, _, _ in XCTFail("unexpected dispatch"); return nil }
            let report = await repl.openFailureAnalysis(goal: "inspect source", summary: summary, automaticRepair: true)
            XCTAssertTrue(report.writeSucceeded)
            XCTAssertEqual(report.seededTasks, 0)
            XCTAssertTrue(PlanStore(projectRoot: root).load().tasks.isEmpty)
        }
    }

    func testUnavailableResearcherHaltsDispatch() async throws {
        let (root, repl) = try fixture()
        let report = KistREPL.handleSelfHealCommand("self-heal run fix parsing", projectRoot: root)
        XCTAssertTrue(report.writeSucceeded)
        let calls = Calls()
        repl.runSpecialist = { name, _, _, _ in await calls.add(name); return nil }
        await repl.dispatchSelfHealAgents(report: report, objective: "fix parsing", automatic: false)
        let names = await calls.names
        XCTAssertEqual(names, ["self-heal-researcher"])
    }

    func testTokenAndCostStopsAreClassifiedWithoutNewRepairWork() async throws {
        for summary in ["budget would be exceeded by the next model call — raise --budget / --max-cost to continue",
                        "token budget exceeded (65000/65000 tokens)",
                        "cost budget exceeded ($0.5000/$0.5000)"] {
            let (root, repl) = try fixture()
            repl.runSpecialist = { _, _, _, _ in XCTFail("spending ceiling started another agent"); return nil }
            let report = await repl.openFailureAnalysis(goal: "fix parser", summary: summary, automaticRepair: true)
            XCTAssertTrue(report.writeSucceeded)
            XCTAssertEqual(report.capsule.likelyLayer, .spendingBudget)
            XCTAssertEqual(report.seededTasks, 0)
            XCTAssertTrue(PlanStore(projectRoot: root).load().tasks.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/.kist/learning/self-heal"))
        }
    }

    func testEvidenceWriteFailureHaltsBeforeBuilder() async throws {
        let (root, repl) = try fixture()
        let report = KistREPL.handleSelfHealCommand("self-heal run fix parsing", projectRoot: root)
        let specialistDirectory = root + "/.kist/learning/self-heal/specialists"
        try "not a directory".write(toFile: specialistDirectory, atomically: true, encoding: .utf8)
        let calls = Calls()
        let handoff = SelfHealHandoff(rootCause: "parser drops quotes", confidence: 0.9,
            targetFiles: ["Sources/Parser.swift"], repairSpec: "preserve escaped quotes",
            reproductionCommand: "swift test --filter ParserTests",
            verificationCommands: ["swift test --filter ParserTests"])
        let summary = String(decoding: try JSONEncoder().encode(handoff), as: UTF8.self)
        repl.runSpecialist = { name, _, _, _ in await calls.add(name); return summary }
        await repl.dispatchSelfHealAgents(report: report, objective: "fix parsing", automatic: false)
        let names = await calls.names
        XCTAssertEqual(names, ["self-heal-researcher"])
    }

    func testLongUnicodeObjectivesProduceDistinctDurableEvidenceFiles() throws {
        let (root, _) = try fixture()
        let report = KistREPL.handleSelfHealCommand("self-heal run fix parsing", projectRoot: root)
        let assignment = try XCTUnwrap(report.agentAssignments.first)
        let store = OrganizationalLearningStore(projectRoot: root, now: { Date(timeIntervalSince1970: 1_700_000_341) })
        let objective = String(repeating: "GoldenEye 路径 repair ", count: 400)
        let first = try XCTUnwrap(store.recordSelfHealSpecialistOutput(
            objective: objective, assignment: assignment, summary: "Observed a path denial."))
        let second = try XCTUnwrap(store.recordSelfHealSpecialistOutput(
            objective: objective + " second", assignment: assignment, summary: "Another observation."))
        XCTAssertNotEqual(first.path, second.path)
        for artifact in [first, second] {
            XCTAssertLessThan((artifact.path as NSString).lastPathComponent.utf8.count, 255)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + artifact.path))
        }
    }
}
