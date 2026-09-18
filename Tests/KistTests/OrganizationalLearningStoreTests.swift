import XCTest
import AgentCore
@testable import Kist

final class OrganizationalLearningStoreTests: XCTestCase {
    private final class ClockProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let instant: Date
        private var count = 0

        init(_ instant: Date) { self.instant = instant }

        func read() -> Date {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return instant
        }

        var reads: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private func tempRoot() -> String {
        let root = NSTemporaryDirectory() + "kist_learning_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func jsonLine<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func mappedBytes(at path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
    }

    private func writeRepeatedJSONLine(_ line: String, count: Int, to path: String) throws {
        try write("", to: path)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let batchSize = 1_000
        let batch = Data(String(repeating: line + "\n", count: batchSize).utf8)
        for _ in 0..<(count / batchSize) {
            try handle.write(contentsOf: batch)
        }
        let remainder = count % batchSize
        if remainder > 0 {
            try handle.write(contentsOf: Data(
                String(repeating: line + "\n", count: remainder).utf8))
        }
    }

    private func makeRule(id: String, lesson: String, at instant: Date,
                          status: OrganizationalRuleRecord.Status = .active,
                          confidence: Int = 96,
                          updatedAt: Date? = nil,
                          temporal: MemoryTemporalEnvelope? = nil) -> OrganizationalRuleRecord {
        OrganizationalRuleRecord(
            id: id,
            lesson: lesson,
            confidence: confidence,
            reason: "Receipt-bound historical rule fixture.",
            evidence: [],
            sourceCapsuleID: nil,
            status: status,
            createdAt: instant.timeIntervalSince1970,
            updatedAt: (updatedAt ?? instant).timeIntervalSince1970,
            temporal: temporal)
    }

    private func makeCapsule(id: String, at instant: Date,
                             temporal: MemoryTemporalEnvelope? = nil) -> LearningCapsule {
        LearningCapsule(
            id: id,
            taskTitle: "Task \(id)",
            status: .pass,
            summary: "Summary \(id)",
            learned: ["Lesson \(id)"],
            surprises: [],
            slowdowns: [],
            assumptionsToChallenge: [],
            futureEvolution: "Continue \(id)",
            tokenCount: 1,
            at: instant.timeIntervalSince1970,
            temporal: temporal)
    }

    private func makeDebt(id: String, at instant: Date,
                          temporal: MemoryTemporalEnvelope? = nil) -> KnowledgeDebtRecord {
        KnowledgeDebtRecord(
            id: id,
            topic: "Topic \(id)",
            reason: "Reason \(id)",
            visit: "Primary documentation",
            impact: 3,
            priority: .medium,
            estimatedLearning: "one hour",
            expectedBenefit: ["better decisions"],
            sourceCapsuleID: nil,
            status: .open,
            createdAt: instant.timeIntervalSince1970,
            updatedAt: instant.timeIntervalSince1970,
            temporal: temporal)
    }

    @discardableResult
    private func runCommand(_ args: [String], cwd: String) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return nil
        }
    }

    private func makeSelfTestRoot() throws -> String {
        let root = tempRoot()
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(name: "SelfTestFixture")
        """, to: root + "/Package.swift")
        try write("""
        private static func runFleet() {
            let domainPreflight = CaptainDomainLearningEnforcer.preflight(mode: .fleet, objective: goal, projectRoot: root)
            let preflight = CaptainSimulationEnforcer.preflight(mode: .fleet, objective: goal, projectRoot: root)
            let fleetBudget = opts.budgetTokens
            let scopeContext = CaptainOrchestrator.deriveScopeContext(fromFiles: []).snapshot
            let planner = FleetPlanner(providers: registry, binding: binding)
            let spawner = PlanExecuteFleetSpawner.make(providers: registry, roles: roles, tools: tools, budget: fleetBudget)
            let launch = await orch.launchFleet(goal: goal, repo: root, assignedTasks: [])
        }
        private struct ScopeRepairFeedback {}

        private static func runPlanExecute() {
            let domainPreflight = CaptainDomainLearningEnforcer.preflight(mode: .planExecute, objective: goal, projectRoot: root)
            let preflight = CaptainSimulationEnforcer.preflight(mode: .planExecute, objective: goal, projectRoot: root)
            let recorder = TraceRecorder(traceId: TraceID.make())
            let pxl = PlanExecuteLoop()
            let pOut = await pxl.run(goal: goal)
        }
        static func terminalInteractor() {}
        """, to: root + "/Sources/Kist/KistRunner.swift")
        try write("""
        struct KistREPL {
            enum DocumentExportRequestResult {
                case notDocumentExport
                case handled(String)
                case failed(String)
            }

            static func handleDocumentExportRequest(_ input: String,
                                                    humanTranscript: [ChatMessage],
                                                    projectRoot: String) -> DocumentExportRequestResult {
                guard DocumentExport.parseIntent(input) != nil else { return .notDocumentExport }
                do {
                    let message = try DocumentExport.writeLatestAssistantDocument(input: input,
                                                                                  transcript: humanTranscript,
                                                                                  projectRoot: projectRoot)
                    return .handled(message)
                } catch {
                    return .failed("document export failed")
                }
            }
        }

        func runNormalTurn() {
            switch KistREPL.handleDocumentExportRequest(messageBody,
                                                        humanTranscript: humanTranscript,
                                                        projectRoot: projectRoot) {
            case .notDocumentExport:
                break
            case .handled(let exportMessage):
                print(exportMessage)
                return
            case .failed:
                openFailureAnalysis(goal: messageBody,
                                    summary: "document export failed",
                                    automaticRepair: true)
                return
            }
            proofStore?.startTurn(goal: messageBody)
            let media = MediaResolver.resolve(messageBody, projectRoot: projectRoot)
            let outcome = await runTurnInterruptible(loop: loop, userInput: messageBody)
        }
        """, to: root + "/Sources/Kist/KistREPL.swift")
        try write("""
        struct DocumentExport {
            enum Format {
                case pdf
                case rtf
            }
            struct Intent {
                let format: Format
            }
            static func parseIntent(_ input: String) -> Intent? {
                let repairWords = ["fix", "malformed", "self-heal"]
                guard !repairWords.contains(where: { input.contains($0) }) else { return nil }
                return Intent(format: input.contains("pdf") ? .pdf : .rtf)
            }
            static func latestAssistantText(from transcript: [ChatMessage]) -> String? {
                transcript.reversed().first { $0.role == .assistant }?.content
            }
            static func writeLatestAssistantDocument(input: String,
                                                     transcript: [ChatMessage],
                                                     projectRoot: String) throws -> String {
                let intent = parseIntent(input)!
                let text = latestAssistantText(from: transcript)!
                switch intent.format {
                case .pdf:
                    try writePDF(text: text, to: URL(fileURLWithPath: projectRoot + "/out.pdf"))
                case .rtf:
                    break
                }
                return "exported"
            }
            private static func writePDF(text: String, to url: URL) throws {}
        }
        """, to: root + "/Sources/Kist/DocumentExport.swift")
        try write("enum CaptainSimulationEnforcer {}\n", to: root + "/Sources/Kist/UX/CaptainSimulationEnforcer.swift")
        try write("enum CaptainDomainLearningEnforcer {}\n", to: root + "/Sources/Kist/UX/CaptainDomainLearningEnforcer.swift")
        try write("enum LocalModelScout {}\n", to: root + "/Sources/Kist/UX/LocalModelScout.swift")
        try write("enum LiveModelMetadataGate {}\n", to: root + "/Sources/Kist/UX/LiveModelMetadataGate.swift")
        try write("enum SymbolicWorkflowCompiler {}\n", to: root + "/Sources/Kist/UX/SymbolicWorkflowCompiler.swift")
        try write("""
        public enum SandboxedProcessRunner {
            public static func runRequired() {
                let message = "OS sandbox required"
                _ = SeatbeltSandbox.wrap
                _ = message
            }
            public static func canApplyRequiredSandbox() -> Bool { true }
        }
        """, to: root + "/Sources/AgentCore/Tools/SandboxedProcessRunner.swift")
        try write("""
        public struct CustomTool {
            func run() {
                _ = SandboxedProcessRunner.runRequired
                _ = RunCommandTool.scrubbedEnvironment
                let metadata = ["sandboxed": "true", "sandbox": "macOS Seatbelt"]
                _ = metadata
            }
        }
        """, to: root + "/Sources/AgentCore/Tools/CustomTool.swift")
        try write("""
        extension KistREPL {
            static func modelSubstitutionDecision() {}
            static let transientProviderFailures = ["rate limit", "server error", "provider/transient failure"]
            static let connectivityFailures = ["timed out", "provider/connectivity failure"]
            static func trajectorySafeToReplayForModelSubstitution() {}
            static func modelSubstitutionReplacement() {
                _ = providerModels[candidate.providerId.lowercased()] == nil
            }
            static func looksLikeRefusalOrPermissionStop() {}
        }
        """, to: root + "/Sources/Kist/KistREPL+ModelSubstitution.swift")
        try write("""
        public struct FleetBlackboard {
            public static let currentSchemaVersion = 2
            public var schemaVersion: Int
        }
        public struct SupervisorInterventionRecord {
            init(from decoder: Decoder) throws {
                delivered = try c.decodeIfPresent(Bool.self, forKey: .delivered) ?? false
            }
            let delivered = false
        }
        public struct SupervisorEscalationRecord {
            init(from decoder: Decoder) throws {
                delivered = try c.decodeIfPresent(Bool.self, forKey: .delivered) ?? false
            }
            let delivered = false
        }
        """, to: root + "/Sources/AgentCore/FleetBlackboard.swift")
        try write("""
        public struct FleetSupervisorPolicy {}
        public struct FleetSupervisorIntervention {}
        public struct FleetSupervisorEscalation {}
        func archiveRejectedDone() {}
        func surrenderKey() {}
        func alreadyRejectedCurrentSurrender() -> Bool {
            let head = headSHA(cell.worktreePath)
            guard !head.isEmpty else { return false }
            return true
        }
        func rejectAgent() {
            let rejectedHead = headSHA(cell.worktreePath)
            let rejectedKey = rejectedHead.isEmpty ? nil : surrenderKey(cell, head: rejectedHead)
            _ = rejectedKey
        }
        func reconcilePendingDeliveries() {
            if !cell.supervisorInterventions[recordIndex].delivered {
                _ = writeIntervention(cell.worktreePath, intervention)
            }
            if !cell.supervisorEscalations[recordIndex].delivered {
                _ = writeEscalation(cell.worktreePath, escalation)
            }
        }
        func continuousIntervention() {
            _ = surrenderKey()
        }
        func continuousEscalation() {
            _ = latestSupervisorInterventionEpoch()
        }
        func applyIntervention() {
            var c = Cell()
            let deliveryFailures: [String] = []
            c.supervisorInterventions.append(SupervisorInterventionRecord(kind: "stale",
                                                                          atEpoch: 1,
                                                                          summary: "repair",
                                                                          evidence: [],
                                                                          delivered: false,
                                                                          deliveryFailures: deliveryFailures))
            _ = FleetScopeValidator.normalize("./Core/Foo.swift")
        }
        func applyEscalation() {
            var c = Cell()
            let deliveryFailures: [String] = []
            c.supervisorEscalations.append(SupervisorEscalationRecord(kind: "blocked",
                                                                      atEpoch: 1,
                                                                      summary: "rescue",
                                                                      evidence: [],
                                                                      assignment: "Captain Rescue Assignment",
                                                                      delivered: false,
                                                                      deliveryFailures: deliveryFailures))
        }
        func latestSupervisorInterventionEpoch() {}
        private func makeIntervention() {}
        """, to: root + "/Sources/AgentCore/FleetSupervisor.swift")
        try write("""
        final class FleetBlackboardStore {
            var _board: Board?
            var _lastLoadError: String?
            static let maxNotesPerCell = 200
            static let maxSupervisorRecordsPerCell = 50
            func lastLoadError() -> String? { _lastLoadError }
            func seed() -> Bool {
                guard persistLocked(initial) else { return false }
                return true
            }
            func foldUpdate() -> Bool {
                guard var current = _board else { return false }
                guard persistLocked(current) else { return false }
                return true
            }
            func foldProgress() -> Bool {
                guard var current = _board else { return false }
                guard persistLocked(current) else { return false }
                return true
            }
            func persistLocked(_ board: Any) -> Bool { true }
            func normalizeForPersistence(_ board: Board) -> Board { board }
        }
        """, to: root + "/Sources/AgentCore/FleetBlackboardStore.swift")
        try write("""
        final class FleetUpdateInbox {
            func readPending() {}
            func acknowledge(_ pending: PendingUpdate) -> Bool { true }
        }
        struct PendingUpdate {}
        """, to: root + "/Sources/AgentCore/FleetUpdateInbox.swift")
        try write("""
        public struct FleetLaunch {
            public let supervisionReady: Bool
        }
        final class CaptainOrchestrator {
            func launchFleet() async {
                let boardStore = FleetBlackboardStore()
                guard boardStore.seed(board) else {
                    return "no agents started"
                }
                _ = GitIsolation.discard(worktree)
                for worker in prepared {
                    guard boardStore.seed(board) else { return "status failed" }
                    let heldBaton = Baton()
                    guard batonStore.save(heldBaton) else { return "baton failed" }
                    spawn(worker)
                }
                let ready = FleetLaunch.supervisionReady
            }
        }
        """, to: root + "/Sources/AgentCore/CaptainOrchestrator.swift")
        try write("""
        func testStaleAgentGetsSupervisorRepairDirectiveBeforeTimeout() {
            XCTAssertTrue(text.contains("SUPERVISOR STALE"))
            XCTAssertEqual(cell.supervisorInterventions.count, 1)
        }
        func testFailedSupervisorDirectiveDeliveryIsRecordedButNotCountedAsDelivered() {
            XCTAssertTrue(text.contains("delivery FAILED"))
            XCTAssertEqual(cell.supervisorInterventions.first?.delivered, false)
        }
        func testFutureProgressTimestampDoesNotBecomeFutureHeartbeat() {
            XCTAssertTrue(text.contains("future-dated progress"))
            XCTAssertLessThan(cell.lastHeartbeatEpoch, 99_999)
        }
        func testOutOfLeaseProgressIsBlockedAsDriftAndInjectedIntoWorkerContext() {
            XCTAssertTrue(text.contains("SUPERVISOR DRIFT"))
            XCTAssertTrue(text.contains("Other/B.swift"))
        }
        func testProgressPathWithDotDotIsBlockedAsNonCanonicalDrift() {
            XCTAssertTrue(text.contains("Core/../Other.swift"))
            XCTAssertTrue(text.contains("non-canonical"))
        }
        func testRejectedDoneMarkerIsConsumedAndNotReprocessedWithoutNewCommit() {
            XCTAssertTrue(text.contains("same rejected .fleet-done"))
            XCTAssertEqual(baton.rejectCount, 1)
        }
        func testRejectedDoneHeadPersistsSoRestartDoesNotReinspectSameCommit() {
            XCTAssertEqual(cell.rejectedDoneHeadSHAs, ["bad-head"])
            XCTAssertEqual(restartInspectCount, 0)
        }
        func testRejectionPersistenceFailureDoesNotArchiveDoneOrAdvanceBaton() {
            XCTAssertFalse(archiveCalled)
            XCTAssertEqual(baton.state, .submitted)
        }
        func testTimeoutPersistenceFailureDoesNotAdvanceBaton() {
            XCTAssertEqual(baton.state, .held)
            XCTAssertEqual(result.persistenceFailures, 1)
        }
        func testWorkerReportedBlockedGetsSupervisorIntervention() {
            XCTAssertEqual(directive?.kind, .blocked)
            XCTAssertTrue(directive?.summary.contains("needs API contract") ?? false)
        }
        func testSupervisorCreatedBlockedStateDoesNotTriggerSecondInterventionByDefault() {
            let policy = FleetSupervisorPolicy(staleAfterSeconds: 60, maxInterventionsPerAgent: 2)
            XCTAssertEqual(interventions, 1)
        }
        func testUnresolvedSupervisorBlockEscalatesToRescueAssignment() {
            XCTAssertTrue(text.contains("SUPERVISOR ESCALATION BLOCKED"))
            XCTAssertEqual(cell.supervisorEscalations.count, 1)
        }
        func testFailedRescueEscalationDeliveryIsAuditedButNotCounted() {
            XCTAssertTrue(text.contains("rescue assignment delivery FAILED"))
            XCTAssertEqual(result.escalations, 0)
        }
        func testWorkerCannotSpoofSupervisorInterventionBudget() {
            let fake = "SUPERVISOR INTERVENTION"
            XCTAssertEqual(cell.supervisorInterventions.count, 1)
        }
        func testProgressPathIsNormalizedBeforeDriftCheck() {
            let path = "./Core/Foo.swift"
            XCTAssertEqual(interventions, 0)
        }
        func testBlackboardPersistenceFailurePreventsAllSignedClaim() {
            XCTAssertFalse(result.allSigned)
            XCTAssertEqual(result.persistenceFailures, 1)
        }
        func testEmptyHeadDoesNotPoisonRejectedSurrenderTracking() {
            XCTAssertTrue(text.contains("unknown HEAD"))
            XCTAssertEqual(cell.rejectedDoneHeadSHAs, [])
        }
        func testPendingSupervisorDirectiveDeliveryIsRecoveredOnNextSweep() {
            XCTAssertTrue(text.contains("INTERVENTION RECOVERY"))
            XCTAssertEqual(cell.supervisorInterventions.first?.delivered, true)
        }
        func testPendingRescueEscalationDeliveryIsRecoveredOnNextSweep() {
            XCTAssertTrue(text.contains("ESCALATION RECOVERY"))
            XCTAssertEqual(cell.supervisorEscalations.first?.delivered, true)
        }
        """, to: root + "/Tests/AgentCoreTests/FleetSupervisorTests.swift")
        try write("""
        func testSupervisorDeliveryRecordsDecodeMissingDeliveredAsUndelivered() {
            XCTAssertFalse(intervention.delivered)
            XCTAssertFalse(escalation.delivered)
        }
        """, to: root + "/Tests/AgentCoreTests/FleetBlackboardTests.swift")
        try write("""
        func testSeedFailureDoesNotPublishInMemoryBoard() {
            XCTAssertFalse(ok)
            XCTAssertNil(store.currentBoard())
        }
        func testFoldUpdateWithoutLoadedBoardFailsSoInboxCanRetry() {
            XCTAssertFalse(ok)
            XCTAssertTrue(error.contains("No fleet blackboard loaded"))
        }
        func testFoldProgressWithoutLoadedBoardFails() {
            XCTAssertFalse(ok)
            XCTAssertTrue(error.contains("No fleet blackboard loaded"))
        }
        func testFoldUpdateFailureDoesNotPublishInMemoryOnlyMutation() {
            XCTAssertFalse(ok)
            XCTAssertEqual(after?.revision, before.revision)
        }
        func testCorruptBoardLoadIsReported() {
            XCTAssertTrue(store.lastLoadError()?.contains("Couldn't load fleet blackboard") ?? false)
        }
        func testSeedCapsUnboundedAppendOnlyLedgers() {
            XCTAssertEqual(cell.keyDecisions.count, 200)
            XCTAssertEqual(cell.supervisorEscalations.count, 50)
        }
        """, to: root + "/Tests/AgentCoreTests/FleetBlackboardStoreTests.swift")
        try write("""
        func testReadPendingKeepsValidDropUntilAcknowledged() {
            XCTAssertEqual(pending.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: "good.json"))
        }
        func testValidDropIsNotAcknowledgedWhenBlackboardHasNoLoadedBoard() {
            XCTAssertEqual(inbox.readPending().count, 1)
            XCTAssertTrue(error.contains("No fleet blackboard loaded"))
        }
        """, to: root + "/Tests/AgentCoreTests/FleetUpdateInboxTests.swift")
        try write("""
        func testBlackboardIsSeededBeforeFirstSpawn() {
            XCTAssertTrue(sawBoard)
            XCTAssertTrue(sawHeldBaton)
        }
        func testBlackboardSeedFailurePreventsSpawnsAndBatons() {
            XCTAssertEqual(spawner.calls.count, 0)
            XCTAssertTrue(summary.contains("no agents started"))
        }
        func testSpawnFailureMarksAgentFailed() {
            XCTAssertFalse(launch.supervisionReady)
            XCTAssertEqual(batons.map(\\.state), [.failed])
        }
        """, to: root + "/Tests/AgentCoreTests/CaptainOrchestratorTests.swift")
        try write("""
        func testBatonSaveFailureDoesNotPublishInMemoryBaton() {
            XCTAssertFalse(ok)
            XCTAssertTrue(store.all().isEmpty)
        }
        """, to: root + "/Tests/AgentCoreTests/FleetBatonStoreTests.swift")
        try write("""
        let a = "self-heal-researcher"
        let b = "self-heal-builder"
        let c = "self-heal-critic"
        let d = "self-heal-captain-gate"
        struct LearningEvidenceRecord {}
        let evidenceLedgerPath = ".kist/learning/evidence-ledger.jsonl"
        func recordSpecialistEvidenceLedger() {}
        struct SpecialistArtifact {
            var updatedTaskIDs: [Int]
            var evidenceLedgerRecorded: Bool
        }
        func runSimulationGate() {
            var writeSucceeded = false
            var writeError: String?
            let decision = "HOLD EXECUTION; simulation evidence report could not be persisted."
            _ = writeSucceeded
            _ = writeError
            _ = decision
            if writeSucceeded && run.passesGate {
                recordSimulationBenchmark(run: run)
            }
        }
        """, to: root + "/Sources/Kist/UX/OrganizationalLearningStore.swift")
        try write("""
        struct CaptainSimulationGateReport {
            var writeSucceeded: Bool
            var writeError: String?
            var estimatedSuccess: Int
            var acceptanceThreshold: Int
            var failureRisk: Int
            var passesGate: Bool {
                writeSucceeded && estimatedSuccess >= acceptanceThreshold && failureRisk <= 100 - acceptanceThreshold
            }
        }
        """, to: root + "/Sources/Kist/UX/CaptainSimulationLab.swift")
        try write("""
        enum CaptainSimulationEnforcer {
            static func blockReasons(report: CaptainSimulationGateReport) -> [String] {
                if !report.writeSucceeded {
                    return ["simulation evidence report was not persisted"]
                }
                return []
            }
        }
        """, to: root + "/Sources/Kist/UX/CaptainSimulationEnforcer.swift")
        try write("""
        func testRunnerKeepsFleetDomainLearningPreflightBeforeSideEffects() throws {
            let source = try runnerSource()
            let fleetBody = try XCTUnwrap(source.range(of: "private static func runFleet"))
            assertOrder("CaptainDomainLearningEnforcer.preflight(mode: .fleet", before: "CaptainSimulationEnforcer.preflight(mode: .fleet", in: source)
            assertOrder("CaptainDomainLearningEnforcer.preflight(mode: .fleet", before: "CaptainOrchestrator.deriveScopeContext", in: source)
        }
        func testRunnerKeepsPlanExecuteDomainLearningPreflightBeforeSideEffects() throws {
            let source = try runnerSource()
            let planExecuteBody = try XCTUnwrap(source.range(of: "private static func runPlanExecute"))
            assertOrder("CaptainDomainLearningEnforcer.preflight(mode: .planExecute", before: "CaptainSimulationEnforcer.preflight(mode: .planExecute", in: source)
            assertOrder("CaptainDomainLearningEnforcer.preflight(mode: .planExecute", before: "TraceRecorder(traceId", in: source)
        }
        func testRegulatedDomainLearningGateBlocksExecutionUntilUnderstandingClears() {
            XCTAssertFalse(result.canExecute)
            XCTAssertTrue(reasons.contains { $0.contains("understanding confidence") })
        }
        func testRedactedDomainLearningModeDoesNotPersistRawSensitiveObjective() throws {
            XCTAssertFalse(text.contains("sk-live-abc123"))
            XCTAssertTrue(text.contains("Redacted mandatory domain-learning safety evidence"))
        }
        func testRunnerKeepsFleetSimulationPreflightBeforeSideEffects() throws {
            let source = try runnerSource()
            let fleetBody = try XCTUnwrap(source.range(of: "private static func runFleet"))
            assertOrder("CaptainSimulationEnforcer.preflight(mode: .fleet", before: "let fleetBudget", in: source)
        }
        func testRunnerKeepsPlanExecuteSimulationPreflightBeforeSideEffects() throws {
            let source = try runnerSource()
            let planExecuteBody = try XCTUnwrap(source.range(of: "private static func runPlanExecute"))
            assertOrder("CaptainSimulationEnforcer.preflight(mode: .planExecute", before: "TraceRecorder(traceId", in: source)
        }
        func testRedactedEvidenceModeDoesNotPersistRawSensitiveObjective() throws {
            XCTAssertFalse(text.contains("sk-live-abc123"))
            XCTAssertTrue(text.contains("Redacted mandatory simulation safety evidence"))
        }
        func testRiskSignalsUseTokenBoundariesAndDoNotMatchSubstrings() {
            XCTAssertEqual(CaptainSimulationEnforcer.riskLevel(mode: .planExecute, objective: "explain prefix notation"), .low)
            XCTAssertEqual(CaptainSimulationEnforcer.riskLevel(mode: .planExecute, objective: "compare digital product ideas"), .low)
        }
        func testRiskSignalsCatchDestructiveAuthAndPaymentTerms() {
            XCTAssertEqual(CaptainSimulationEnforcer.riskLevel(mode: .planExecute, objective: "rotate api key"), .critical)
        }
        """, to: root + "/Tests/KistTests/KistRunnerSafetyTests.swift")
        try write("""
        func testModelSubstitutionChoosesReadyRoleBackupForMalformedFailure() {
            XCTAssertEqual("deepseek-v4-pro", "deepseek-v4-pro")
            XCTAssertEqual("provider/protocol failure", "provider/protocol failure")
        }
        func testModelSubstitutionFallsBackToPriorityProviderWhenRolesDoNotHelp() {
            XCTAssertEqual("gemini", "gemini")
            XCTAssertEqual("provider/protocol failure", "provider/protocol failure")
        }
        func testRefusalAndPermissionStopsDoNotSubstituteAcrossTextOneShotOrVisionLanes() {
            XCTAssertTrue("permission denied oneShotSubstitution mediaSubstitutionDecision".contains("permission denied"))
            XCTAssertNil(Optional<String>.none)
        }
        func testModelSubstitutionFallsBackOnTransientProviderFailure() {
            XCTAssertTrue("rate-limited".contains("rate"))
            XCTAssertEqual("provider/transient failure", "provider/transient failure")
        }
        func testModelSubstitutionFallsBackOnProviderConnectivityFailure() {
            XCTAssertTrue("timed out".contains("timed"))
            XCTAssertEqual("provider/connectivity failure", "provider/connectivity failure")
        }
        func testModelSubstitutionDoesNotReplayAfterMutatingWork() {
            XCTAssertTrue("write_file".contains("write_file"))
            XCTAssertNil(Optional<String>.none)
        }
        func testModelSubstitutionDoesNotChooseProviderMissingFromKnownCatalog() {
            let providerModels = ["mimo": ["mimo-v2.5-pro"]]
            XCTAssertTrue(providerModels.keys.contains("mimo"))
            XCTAssertNil(providerModels["openai"])
        }
        func testModelSubstitutionDoesNotShopAroundHardSafetyStop() {
            XCTAssertTrue("malware steal credentials".contains("malware"))
            XCTAssertNil(Optional<String>.none)
        }
        """, to: root + "/Tests/KistTests/KistREPLTests.swift")
        try write("""
        func testParsesPriorAnswerPDFRequest() {
            XCTAssertEqual("hreay cna i have this as a pdf", "hreay cna i have this as a pdf")
            XCTAssertEqual("turn this into a document", "turn this into a document")
        }
        func testDoesNotStealSelfHealPDFDebugRequest() {
            XCTAssertTrue("fix the code malformed issue".contains("malformed"))
        }
        func testLatestAssistantTextUsesMostRecentAssistantAnswer() {
            XCTAssertEqual("new", "new")
        }
        func testWritesPDFDocumentFromLatestAssistantAnswer() {
            XCTAssertTrue("exported PDF".contains("PDF"))
            XCTAssertEqual("%PDF", "%PDF")
        }
        func testREPLHandlesPDFExportBeforeNormalModelTurn() {
            XCTAssertTrue("handleDocumentExportRequest".contains("DocumentExport"))
            XCTAssertTrue("exported PDF".contains("PDF"))
        }
        func testREPLDocumentExportDoesNotStealDebugRequest() {
            XCTAssertEqual(".notDocumentExport", ".notDocumentExport")
        }
        func testREPLDocumentExportReportsNoPriorAssistantText() {
            XCTAssertTrue("No prior assistant answer".contains("prior assistant"))
        }
        """, to: root + "/Tests/KistTests/DocumentExportTests.swift")
        try write("""
        func testRunUsesRequiredOSSandboxEvenWhenContextSandboxDisabled() {
            XCTAssertTrue(metadata["sandboxed"] == "true")
            XCTAssertEqual(metadata["sandbox"], "macOS Seatbelt")
        }
        func testRunCustomToolCannotWriteOutsideRootWithoutOuterSandboxFlag() {
            XCTAssertTrue(output.contains("sandbox-blocked"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: escapedPath))
        }
        """, to: root + "/Tests/AgentCoreTests/CustomToolTests.swift")
        try write("""
        func testSimulationGateWriteFailureBlocksExecution() {
            XCTAssertFalse(report.writeSucceeded)
            XCTAssertFalse(report.passesGate)
            XCTAssertTrue(report.decision.contains("could not be persisted"))
        }
        func testSelfHealSpecialistOutputIsArchivedIndexedLedgeredAndAttachedToTasks() {
            XCTAssertTrue(artifact.evidenceLedgerRecorded)
            XCTAssertEqual(artifact.updatedTaskIDs.count, artifact.taskEvidenceUpdated)
            XCTAssertTrue(text.contains("evidence-ledger.jsonl"))
            _ = LearningEvidenceRecord.self
        }
        func testDomainLearningSpecialistOutputIsArchivedIndexedLedgeredAndAttachedToTasks() {
            XCTAssertTrue(artifact.evidenceLedgerRecorded)
            XCTAssertEqual(artifact.updatedTaskIDs.count, artifact.taskEvidenceUpdated)
            XCTAssertTrue(text.contains("evidence-ledger.jsonl"))
            _ = LearningEvidenceRecord.self
        }
        """, to: root + "/Tests/KistTests/OrganizationalLearningStoreTests.swift")
        return root
    }

    private func selfTestCheck(_ title: String, in report: CaptainSelfTestReport,
                               file: StaticString = #filePath,
                               line: UInt = #line) throws -> CaptainSelfTestCheck {
        try XCTUnwrap(report.checks.first { $0.title == title }, file: file, line: line)
    }

    func testRecordTurnWritesCapsuleWithoutPromotingDashboardHintsToDebt() {
        let base = tempRoot()
        let root = base + "/kist-loops"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let store = OrganizationalLearningStore(projectRoot: root,
                                                now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let plan = Plan(title: "Kist Captain",
                        tasks: [PlanTask(id: 1,
                                         title: "ACTION: Captain Intelligence Layer",
                                         status: .done,
                                         kind: .action)])
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let spans = [AgentSpan(id: "s1", traceId: "t", kind: .llmCall, vendor: "openai",
                               promptTokens: 100, completionTokens: 25,
                               startedAt: now, endedAt: now)]
        let trajectory = [ActionRecord(tool: "read_file", argsFingerprint: "a", success: true)]

        let capsule = store.recordTurn(plan: plan, spans: spans, trajectory: trajectory,
                                       outcomeSummary: "Built Captain Intelligence Layer",
                                       success: true)

        XCTAssertEqual(capsule.taskTitle, "Captain Intelligence Layer")
        XCTAssertEqual(capsule.status, .pass)
        XCTAssertEqual(store.latestCapsule()?.id, capsule.id)
        XCTAssertTrue(store.openKnowledgeDebt().isEmpty,
                      "render-time suggestions must not become permanent unresolved work")
        XCTAssertTrue(store.renderLatestReflection().contains("WHAT WE LEARNED"))
    }

    func testKnowledgeDebtCanBeAddedAndClosed() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = OrganizationalLearningStore(projectRoot: root)

        let record = try XCTUnwrap(store.addKnowledgeDebt(
            topic: "Study Cursor background agents",
            reason: "Task persistence",
            impact: 5,
            priority: .high))

        XCTAssertTrue(store.renderKnowledgeDebt().contains(record.id))
        XCTAssertTrue(store.markKnowledgeDebtDone(record.id))
        XCTAssertFalse(store.renderKnowledgeDebt().contains(record.id))
    }

    func testCurrentObjectiveWinsOverStaleCompletedBoardTaskForCapsuleTitle() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = OrganizationalLearningStore(projectRoot: root,
                                                now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let stale = Plan(tasks: [PlanTask(id: 1,
                                          title: "RESEARCH: Verify current Kist agent/orchestration capabilities",
                                          status: .done,
                                          kind: .research)])

        let capsule = store.recordTurn(plan: stale, spans: [], trajectory: [],
                                       outcomeSummary: "Fixed the leading whitespace.", success: true,
                                       objective: "fix the amount of empty space at the start")

        XCTAssertEqual(capsule.taskTitle, "fix the amount of empty space at the start")
        XCTAssertFalse(capsule.taskTitle.contains("agent/orchestration"))
    }

    func testBoardMeetingWritesReportAndSeedsResearchTasks() throws {
        // The strategic-intelligence competitor watch-list is Kist's own roadmap → only seeded inside a
        // Kist project now; use a kist-named root so this test exercises it.
        let base = tempRoot()
        let root = base + "/kist-loops"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let plan = Plan(title: "Kist Captain",
                        tasks: [PlanTask(id: 1,
                                         title: "ACTION: wire Captain orchestration",
                                         detail: "assign models to workers and gate the swarm",
                                         kind: .action)])
        PlanStore(projectRoot: root).save(plan)
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_001)
        let store = OrganizationalLearningStore(projectRoot: root,
                                                now: { fixedNow },
                                                specialistRegistry: {
                                                    SpecialistRegistry(projectRoot: $0, userDir: nil,
                                                                       claudeUserDir: nil)
                                                })
        let eligibleAt = fixedNow.addingTimeInterval(-20)
        let rawLatestAt = fixedNow.addingTimeInterval(-10)
        let eligibleTemporal = try MemoryTemporalEnvelope(
            createdAt: eligibleAt, decayRate: .medium)
        let notYetTemporal = try MemoryTemporalEnvelope(
            createdAt: rawLatestAt,
            validFrom: fixedNow.addingTimeInterval(60),
            decayRate: .medium)
        XCTAssertTrue(store.appendJSON(
            makeCapsule(id: "board-eligible", at: eligibleAt,
                        temporal: eligibleTemporal),
            to: store.capsulesPath))
        XCTAssertTrue(store.appendJSON(
            makeCapsule(id: "board-raw-latest-ineligible", at: rawLatestAt,
                        temporal: notYetTemporal),
            to: store.capsulesPath))

        let report = store.runBoardMeeting(plan: plan,
                                           trajectory: [ActionRecord(tool: "read_file",
                                                                     argsFingerprint: "a",
                                                                     success: true)])

        XCTAssertTrue(report.text.contains("Kist Evolution Board Meeting"))
        XCTAssertTrue(report.text.contains("Captain Strategy"))
        XCTAssertTrue(report.text.contains("CAPTAIN STRATEGY PIPELINE"))
        XCTAssertTrue(report.text.contains("CURRENT UNDERSTANDING"))
        XCTAssertTrue(report.text.contains("MISSING KNOWLEDGE"))
        XCTAssertTrue(report.text.contains("Captain Memory Architecture"))
        XCTAssertTrue(report.text.contains("Context Window is RAM. Everything else is disk."))
        XCTAssertTrue(report.text.contains("Knowledge Index [disk]"))
        XCTAssertTrue(report.text.contains("Organizational Rules [disk]"))
        XCTAssertTrue(report.text.contains("Captain Retrieval"))
        XCTAssertTrue(report.text.contains("CAPTAIN RETRIEVAL CONTEXT"))
        XCTAssertTrue(report.text.contains("DECISION CARDS"))
        XCTAssertTrue(report.text.contains("Strategic Intelligence"))
        XCTAssertTrue(report.text.contains("Source target:"))
        XCTAssertTrue(report.text.contains("Compare against:"))
        XCTAssertTrue(report.text.contains("Evolution Proposal"))
        XCTAssertTrue(report.text.contains("Teachable rule:"))
        XCTAssertTrue(report.text.contains("Teach Captain"))
        XCTAssertTrue(report.text.contains("Permanent Organizational Rules"))
        XCTAssertTrue(report.text.contains("Industry Research Agenda"))
        XCTAssertTrue(report.text.contains("Task board-eligible"))
        XCTAssertFalse(report.text.contains("Task board-raw-latest-ineligible"))
        XCTAssertTrue(report.text.contains("Strategic intelligence records:"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + report.path))
        XCTAssertGreaterThan(report.seededResearchTasks, 0)
        XCTAssertGreaterThan(report.createdSpecialists, 0)
        XCTAssertEqual(report.promotedRules, 0)
        XCTAssertTrue(PlanStore(projectRoot: root).load().tasks.contains { $0.kind == .research })
        XCTAssertTrue(PlanStore(projectRoot: root).load().tasks.contains {
            $0.kind == .research && $0.boardTitle.contains("Compare:")
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/agents/agent-orchestration-architect.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/learning/knowledge-index.jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/learning/organizational-rules.jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/learning/research-archive"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/learning/industry-intelligence.jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/learning/evolution-proposals.jsonl"))
        XCTAssertNotNil(FileManager.default.enumerator(atPath: root + "/.kist/learning/research-archive/strategic-intelligence")?.nextObject())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/learning/benchmarks.jsonl"))
        XCTAssertTrue(store.renderOrganizationalRules().contains("Permanent Organizational Rules"))
        XCTAssertTrue(store.renderOrganizationalRules().contains("Proposed Rules Awaiting Evidence"))
        XCTAssertTrue(store.renderOrganizationalRules().contains("Strategic Intelligence must compare Kist"))
        XCTAssertTrue(store.renderOrganizationalRules().contains("High-impact knowledge debt is not paid"))
        XCTAssertTrue(store.renderCaptainMemoryArchitecture().contains("Project History [disk]"))
    }

    func testSelfHealMissionSeedsAssignedAgentsAndGatedTasks() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let plan = Plan(title: "Kist Self Heal",
                        tasks: [PlanTask(id: 1,
                                         title: "ACTION: make Captain follow its own advice",
                                         detail: "turn observations into assigned agents, evidence, review, benchmarks, and Teach Captain",
                                         kind: .action)])
        PlanStore(projectRoot: root).save(plan)
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_321)
        let store = OrganizationalLearningStore(projectRoot: root,
                                                now: { fixedNow },
                                                specialistRegistry: {
                                                    SpecialistRegistry(projectRoot: $0, userDir: nil,
                                                                       claudeUserDir: nil)
                                                })
        let eligibleAt = fixedNow.addingTimeInterval(-20)
        let rawLatestAt = fixedNow.addingTimeInterval(-10)
        let eligibleTemporal = try MemoryTemporalEnvelope(
            createdAt: eligibleAt, decayRate: .medium)
        let notYetTemporal = try MemoryTemporalEnvelope(
            createdAt: rawLatestAt,
            validFrom: fixedNow.addingTimeInterval(60),
            decayRate: .medium)
        XCTAssertTrue(store.appendJSON(
            makeCapsule(id: "self-heal-eligible", at: eligibleAt,
                        temporal: eligibleTemporal),
            to: store.capsulesPath))
        XCTAssertTrue(store.appendJSON(
            makeCapsule(id: "self-heal-raw-latest-ineligible", at: rawLatestAt,
                        temporal: notYetTemporal),
            to: store.capsulesPath))

        let report = store.runSelfHealMission(plan: plan,
                                              trajectory: [ActionRecord(tool: "read_file",
                                                                        argsFingerprint: "a",
                                                                        success: true)])

        XCTAssertTrue(report.text.contains("Captain Self-Heal Mission"))
        XCTAssertTrue(report.text.contains("Agent Dispatch"))
        XCTAssertTrue(report.text.contains("self-heal-researcher"))
        XCTAssertTrue(report.text.contains("self-heal-builder"))
        XCTAssertTrue(report.text.contains("self-heal-critic"))
        XCTAssertTrue(report.text.contains("self-heal-captain-gate"))
        XCTAssertTrue(report.text.contains("Acceptance Gate"))
        XCTAssertTrue(report.text.contains("Task self-heal-eligible"))
        XCTAssertFalse(report.text.contains("Task self-heal-raw-latest-ineligible"))
        XCTAssertTrue(report.agentAssignments.first { $0.specialistName == "self-heal-builder" }?.task.contains("VERIFY: <command/check> => PASS|FAIL") == true)
        XCTAssertTrue(report.agentAssignments.first { $0.specialistName == "self-heal-critic" }?.task.contains("VERIFY: <command/check> => PASS|FAIL") == true)
        XCTAssertTrue(report.agentAssignments.first { $0.specialistName == "self-heal-captain-gate" }?.task.contains("VERIFY: <command/check> => PASS|FAIL") == true)
        XCTAssertEqual(report.dispatchCommand, "/self-heal run")
        XCTAssertTrue(report.writeSucceeded)
        XCTAssertNil(report.writeError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + report.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/agents/self-heal-researcher.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/agents/self-heal-critic.md"))
        XCTAssertGreaterThanOrEqual(report.seededTasks, 6)

        let seeded = PlanStore(projectRoot: root).load()
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .plan && $0.owner == "captain" && $0.status == .inProgress },
                      seeded.render())
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .research && $0.owner == "self-heal-researcher" })
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .action && $0.owner == "self-heal-builder" })
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .review && $0.owner == "self-heal-critic" })
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .test && $0.owner == "self-heal-captain-gate" })
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .decision && $0.owner == "self-heal-captain-gate" })
    }

    func testSelfHealMissionWriteFailureBlocksDispatchClaim() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("not a directory", to: root + "/.kist/learning/self-heal")
        let plan = Plan(title: "Kist Self Heal",
                        tasks: [PlanTask(id: 1,
                                         title: "ACTION: repair Captain loop",
                                         detail: "self heal",
                                         kind: .action)])
        let store = OrganizationalLearningStore(projectRoot: root,
                                                now: { Date(timeIntervalSince1970: 1_700_000_331) },
                                                specialistRegistry: {
                                                    SpecialistRegistry(projectRoot: $0, userDir: nil,
                                                                       claudeUserDir: nil)
                                                })

        let report = store.runSelfHealMission(plan: plan, trajectory: [])

        XCTAssertFalse(report.writeSucceeded)
        XCTAssertNotNil(report.writeError)
        XCTAssertTrue(report.text.contains("Evidence Persistence"), report.text)
        XCTAssertTrue(report.text.contains("Dispatch gate: HOLD"), report.text)
    }

    func testSelfHealSpecialistOutputIsArchivedIndexedAndAttachedToTasks() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let plan = Plan(title: "Kist Self Heal",
                        tasks: [PlanTask(id: 1,
                                         title: "ACTION: make Captain follow its own advice",
                                         detail: "turn observations into assigned agents, evidence, review, benchmarks, and Teach Captain",
                                         kind: .action)])
        PlanStore(projectRoot: root).save(plan)
        let store = OrganizationalLearningStore(projectRoot: root,
                                                now: { Date(timeIntervalSince1970: 1_700_000_341) },
                                                specialistRegistry: {
                                                    SpecialistRegistry(projectRoot: $0, userDir: nil,
                                                                       claudeUserDir: nil)
                                                })
        let report = store.runSelfHealMission(plan: plan, trajectory: [])
        let assignment = try XCTUnwrap(report.agentAssignments.first { $0.specialistName == "self-heal-critic" })

        let artifact = try XCTUnwrap(store.recordSelfHealSpecialistOutput(
            objective: "repair Captain loop",
            assignment: assignment,
            summary: "Critique captured. secret sk-abcdefghijklmnopqrstuvwxyzABCDEFGH123456 should be redacted."))

        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + artifact.path))
        XCTAssertTrue(artifact.memoryRecorded)
        XCTAssertGreaterThan(artifact.taskEvidenceUpdated, 0)
        XCTAssertEqual(artifact.updatedTaskIDs.count, artifact.taskEvidenceUpdated)
        XCTAssertTrue(artifact.evidenceLedgerRecorded)
        let text = try String(contentsOfFile: root + "/" + artifact.path, encoding: .utf8)
        XCTAssertTrue(text.contains("Self-Heal Specialist Output"))
        XCTAssertTrue(text.contains("Critique captured"))
        XCTAssertFalse(text.contains("sk-abcdefghijklmnopqrstuvwxyzABCDEFGH123456"))

        let updatedPlan = PlanStore(projectRoot: root).load()
        XCTAssertTrue(updatedPlan.tasks.contains {
            $0.owner == "self-heal-critic" && $0.evidence.contains(artifact.path)
        }, updatedPlan.render())
        let ledgerLines = try String(contentsOfFile: root + "/.kist/learning/evidence-ledger.jsonl",
                                     encoding: .utf8)
            .split(separator: "\n")
        let ledger = try XCTUnwrap(ledgerLines.compactMap {
            try? JSONDecoder().decode(LearningEvidenceRecord.self, from: Data($0.utf8))
        }.last)
        XCTAssertEqual(ledger.kind, .selfHealSpecialist)
        XCTAssertEqual(ledger.specialistName, "self-heal-critic")
        XCTAssertEqual(ledger.artifactPath, artifact.path)
        XCTAssertEqual(ledger.taskIDs, artifact.updatedTaskIDs)
        XCTAssertEqual(ledger.taskEvidenceUpdated, artifact.taskEvidenceUpdated)
        XCTAssertTrue(ledger.memoryRecorded)
        let retrieved = KistREPL.handleRetrieveCommand(
            "self-heal critic critique captured", projectRoot: root,
            now: { Date(timeIntervalSince1970: 1_700_000_341) })
        XCTAssertTrue(retrieved.contains("Self-Heal Specialist") || retrieved.contains("Critique captured"),
                      retrieved)
        XCTAssertTrue(retrieved.contains("Evidence Ledger: self-heal-critic"), retrieved)
        XCTAssertTrue(retrieved.contains("Task IDs:"), retrieved)
    }

    func testSelfHealCommandAndCaptainAliasCreateMission() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        PlanStore(projectRoot: root).save(Plan(title: "Kist",
                                               tasks: [PlanTask(id: 1,
                                                                title: "ACTION: repair Captain loop",
                                                                detail: "self heal",
                                                                kind: .action)]))

        let report = KistREPL.handleSelfHealCommand("fix-self now", projectRoot: root)

        XCTAssertTrue(KistREPL.isSelfHealIntent("fix-self now"))
        XCTAssertTrue(KistREPL.selfHealShouldRun("fix-self now"))
        XCTAssertTrue(report.text.contains("Captain Self-Heal Mission"))
        XCTAssertTrue(report.text.contains("Manual sequence"))
    }

    func testSelfTestPassesOnMinimalHealthyKistTree() throws {
        let root = try makeSelfTestRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let report = CaptainSelfTestSuite(projectRoot: root,
                                          now: { Date(timeIntervalSince1970: 1_700_003_000) }).run()

        XCTAssertEqual(report.failures, 0)
        XCTAssertEqual(report.warnings, 0)
        XCTAssertEqual(report.seededTasks, 0)
        XCTAssertEqual(report.checks.map(\.title), [
            "Swift package manifest",
            "Simulation enforcer source",
            "Domain learning enforcer source",
            "Local model scout source",
            "Live model metadata gate source",
            "Symbolic workflow compiler source",
            "Kist runner source",
            "Continuous supervisor source",
            "Required OS sandbox runner source",
            "Custom tool source",
            "Document export source",
            "Model substitution source",
            "Safety regression tests",
            "Fleet domain-learning preflight before fleet side effects",
            "Fleet simulation preflight before fleet side effects",
            "Plan-execute domain-learning preflight before planner loop",
            "Plan-execute simulation preflight before planner loop",
            "Simulation gate regression coverage",
            "Document export regression coverage",
            "Model substitution regression coverage",
            "Continuous supervisor regression coverage",
            "Supervisor recovery and board hardening regression coverage",
            "Required OS sandbox runner contract",
            "Custom tool required OS sandbox",
            "Simulation evidence persistence gate",
            "Immune-system regression coverage",
            "Required OS sandbox live probe",
            "Custom tool sandbox live probe",
            "Simulation report persistence live probe",
            "Blackboard durability regression coverage",
            "Self-heal specialist organization",
            "Specialist evidence ledger persistence",
            "Task board blocked work",
            "Task board contract quality",
            "Task board evidence ledger health"
        ])
        for check in report.checks {
            XCTAssertEqual(check.status, .pass, check.title)
        }
        XCTAssertTrue(report.text.contains("Static Kist Self-Check"))
        XCTAssertTrue(report.text.contains("Static outcome: STATIC PASS"))
        XCTAssertTrue(report.text.contains("Recommended Next Test Commands"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + report.path))
        let persisted = try String(contentsOfFile: root + "/" + report.path, encoding: .utf8)
        XCTAssertEqual(persisted, report.text + "\n")
        XCTAssertTrue(report.writeSucceeded)
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/self-test"))
        XCTAssertFalse(InputCompleter.builtInCommands.contains("/no-such-command-xyz"))   // sentinel: a real absent command (/audit is now real)
        XCTAssertNil(KistREPL.selfTestUsageIfNeeded(""))
        XCTAssertNil(KistREPL.selfTestUsageIfNeeded("check"))
        XCTAssertNil(KistREPL.selfTestUsageIfNeeded("run"))
        XCTAssertNil(KistREPL.selfTestUsageIfNeeded("--seed"))
        XCTAssertNotNil(KistREPL.selfTestUsageIfNeeded("dry-run"))
    }

    func testSelfTestSeedsRepairTasksWhenArchitectureChecksFail() throws {
        let root = try makeSelfTestRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("""
        private static func runFleet() {
            let domainPreflight = CaptainDomainLearningEnforcer.preflight(mode: .fleet, objective: goal, projectRoot: root)
            let fleetBudget = opts.budgetTokens
            let scopeContext = CaptainOrchestrator.deriveScopeContext(fromFiles: []).snapshot
            let preflight = CaptainSimulationEnforcer.preflight(mode: .fleet, objective: goal, projectRoot: root)
            let planner = FleetPlanner(providers: registry, binding: binding)
            let spawner = PlanExecuteFleetSpawner.make(providers: registry, roles: roles, tools: tools, budget: fleetBudget)
            let launch = await orch.launchFleet(goal: goal, repo: root, assignedTasks: [])
        }
        private struct ScopeRepairFeedback {}
        private static func runPlanExecute() {
            let domainPreflight = CaptainDomainLearningEnforcer.preflight(mode: .planExecute, objective: goal, projectRoot: root)
            let preflight = CaptainSimulationEnforcer.preflight(mode: .planExecute, objective: goal, projectRoot: root)
            let recorder = TraceRecorder(traceId: TraceID.make())
            let pxl = PlanExecuteLoop()
            let pOut = await pxl.run(goal: goal)
        }
        static func terminalInteractor() {}
        """, to: root + "/Sources/Kist/KistRunner.swift")

        let report = CaptainSelfTestSuite(projectRoot: root,
                                          now: { Date(timeIntervalSince1970: 1_700_003_100) }).run(seedFindings: true)

        XCTAssertEqual(report.failures, 1)
        XCTAssertEqual(report.seededTasks, 1)
        XCTAssertTrue(report.text.contains("What Needs Fixing"))
        let fleetCheck = try selfTestCheck("Fleet simulation preflight before fleet side effects", in: report)
        XCTAssertEqual(fleetCheck.status, .fail)
        XCTAssertTrue(fleetCheck.detail.contains("let fleetBudget"))
        XCTAssertTrue(fleetCheck.detail.contains("CaptainOrchestrator.deriveScopeContext"))
        XCTAssertEqual(try selfTestCheck("Plan-execute simulation preflight before planner loop", in: report).status, .pass)
        let plan = PlanStore(projectRoot: root).load()
        XCTAssertNil(plan.active)
        let task = try XCTUnwrap(plan.tasks.first { $0.owner == "captain-self-test" })
        XCTAssertEqual(task.kind, .action)
        XCTAssertEqual(task.status, .todo)
        XCTAssertTrue(task.title.contains("Fleet simulation preflight"))
        XCTAssertTrue(task.acceptance.contains("resolved"))
        XCTAssertTrue(task.verification.contains("/self-test"))
        XCTAssertTrue(task.evidence.contains(report.path))

        let taskCountBeforeCheckOnlyCommand = PlanStore(projectRoot: root).load().tasks.count
        let command = KistREPL.handleSelfTestCommand("", projectRoot: root)
        XCTAssertTrue(command.text.contains("Static Kist Self-Check"))
        XCTAssertEqual(command.seededTasks, 0)
        XCTAssertEqual(PlanStore(projectRoot: root).load().tasks.count, taskCountBeforeCheckOnlyCommand)

        _ = PlanStore(projectRoot: root).update(id: task.id, status: .done)
        let reopened = CaptainSelfTestSuite(projectRoot: root,
                                           now: { Date(timeIntervalSince1970: 1_700_003_200) }).run(seedFindings: true)
        XCTAssertEqual(reopened.seededTasks, 1)
    }

    func testSelfTestRejectsPlaceholderSafetyCoverage() throws {
        let root = try makeSelfTestRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("""
        // testRunnerKeepsFleetSimulationPreflightBeforeSideEffects
        func testRunnerKeepsPlanExecuteSimulationPreflightBeforeSideEffects() {}
        func testRedactedEvidenceModeDoesNotPersistRawSensitiveObjective() {}
        func testRiskSignalsCatchDestructiveAuthAndPaymentTerms() {}
        """, to: root + "/Tests/KistTests/KistRunnerSafetyTests.swift")

        let report = CaptainSelfTestSuite(projectRoot: root,
                                          now: { Date(timeIntervalSince1970: 1_700_003_300) }).run()

        let coverage = try selfTestCheck("Simulation gate regression coverage", in: report)
        XCTAssertEqual(coverage.status, .fail)
        XCTAssertTrue(coverage.detail.contains("missing testRunnerKeepsFleetSimulationPreflightBeforeSideEffects"))
        XCTAssertTrue(coverage.detail.contains("weak testRunnerKeepsPlanExecuteSimulationPreflightBeforeSideEffects"))
    }

    func testSelfTestRejectsMissingDocumentExportCoverage() throws {
        let root = try makeSelfTestRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("""
        struct DocumentExport {
            static func parseIntent(_ input: String) -> Intent? { nil }
        }
        """, to: root + "/Sources/Kist/DocumentExport.swift")
        try write("""
        struct KistREPL {}
        """, to: root + "/Sources/Kist/KistREPL.swift")
        try write("""
        func testParsesPriorAnswerPDFRequest() {
            XCTAssertTrue(true)
        }
        """, to: root + "/Tests/KistTests/DocumentExportTests.swift")

        let report = CaptainSelfTestSuite(projectRoot: root,
                                          now: { Date(timeIntervalSince1970: 1_700_003_310) }).run()

        let coverage = try selfTestCheck("Document export regression coverage", in: report)
        XCTAssertEqual(coverage.status, .fail)
        XCTAssertTrue(coverage.detail.contains("missing source marker let repairWords"), coverage.detail)
        XCTAssertTrue(coverage.detail.contains("missing REPL marker static func handleDocumentExportRequest"), coverage.detail)
        XCTAssertTrue(coverage.detail.contains("weak test testParsesPriorAnswerPDFRequest"), coverage.detail)
        XCTAssertTrue(coverage.detail.contains("missing test testREPLDocumentExportReportsNoPriorAssistantText"),
                      coverage.detail)
    }

    func testSelfTestRejectsMissingModelSubstitutionCoverage() throws {
        let root = try makeSelfTestRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("""
        extension KistREPL {
            static func modelSubstitutionDecision() {}
        }
        """, to: root + "/Sources/Kist/KistREPL+ModelSubstitution.swift")
        try write("""
        func testModelSubstitutionChoosesReadyRoleBackupForMalformedFailure() {
            XCTAssertTrue(true)
        }
        """, to: root + "/Tests/KistTests/KistREPLTests.swift")

        let report = CaptainSelfTestSuite(projectRoot: root,
                                          now: { Date(timeIntervalSince1970: 1_700_003_320) }).run()

        let coverage = try selfTestCheck("Model substitution regression coverage", in: report)
        XCTAssertEqual(coverage.status, .fail)
        XCTAssertTrue(coverage.detail.contains("missing source marker trajectorySafeToReplayForModelSubstitution"),
                      coverage.detail)
        XCTAssertTrue(coverage.detail.contains("weak test testModelSubstitutionChoosesReadyRoleBackupForMalformedFailure"),
                      coverage.detail)
        XCTAssertTrue(coverage.detail.contains("missing test testModelSubstitutionDoesNotReplayAfterMutatingWork"),
                      coverage.detail)
    }

    func testSelfTestRejectsPlaceholderContinuousSupervisorCoverage() throws {
        let root = try makeSelfTestRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("""
        struct FleetSupervisorPolicy {}
        struct FleetSupervisorIntervention {}
        func continuousIntervention() {}
        func applyIntervention() {}
        let banner = "Captain Continuous Supervisor"
        """, to: root + "/Sources/AgentCore/FleetSupervisor.swift")
        try write("""
        func testStaleAgentGetsSupervisorRepairDirectiveBeforeTimeout() { XCTAssertTrue(true) }
        func testOutOfLeaseProgressIsBlockedAsDriftAndInjectedIntoWorkerContext() { XCTAssertTrue(true) }
        func testSupervisorDoesNotRepeatSameInterventionEverySweep() { XCTAssertTrue(true) }
        """, to: root + "/Tests/AgentCoreTests/FleetSupervisorTests.swift")

        let report = CaptainSelfTestSuite(projectRoot: root,
                                          now: { Date(timeIntervalSince1970: 1_700_003_350) }).run()

        let coverage = try selfTestCheck("Continuous supervisor regression coverage", in: report)
        XCTAssertEqual(coverage.status, .fail)
        XCTAssertTrue(coverage.detail.contains("missing source marker public struct FleetSupervisorPolicy"))
        XCTAssertTrue(coverage.detail.contains("missing test testWorkerReportedBlockedGetsSupervisorIntervention"))
    }

    func testSelfTestRejectsMissingSupervisorRecoveryHardening() throws {
        let root = try makeSelfTestRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("""
        struct FleetBlackboard {
            static let currentSchemaVersion = 2
            var schemaVersion: Int
        }
        struct SupervisorInterventionRecord {
            let delivered = true
        }
        struct SupervisorEscalationRecord {
            let delivered = true
        }
        """, to: root + "/Sources/AgentCore/FleetBlackboard.swift")
        try write("""
        final class FleetBlackboardStore {
            var _board: Board?
            func seed() -> Bool { true }
            func persistLocked(_ board: Any) -> Bool { true }
        }
        """, to: root + "/Sources/AgentCore/FleetBlackboardStore.swift")
        try write("""
        func applyIntervention() {}
        func applyEscalation() {}
        func alreadyRejectedCurrentSurrender() -> Bool { true }
        """, to: root + "/Sources/AgentCore/FleetSupervisor.swift")
        try write("""
        func testPendingSupervisorDirectiveDeliveryIsRecoveredOnNextSweep() { XCTAssertTrue(true) }
        """, to: root + "/Tests/AgentCoreTests/FleetSupervisorTests.swift")

        let report = CaptainSelfTestSuite(projectRoot: root,
                                          now: { Date(timeIntervalSince1970: 1_700_003_355) }).run()

        let coverage = try selfTestCheck("Supervisor recovery and board hardening regression coverage", in: report)
        XCTAssertEqual(coverage.status, .fail)
        XCTAssertTrue(coverage.detail.contains("missing source marker reconcilePendingDeliveries"), coverage.detail)
        XCTAssertTrue(coverage.detail.contains("missing test testEmptyHeadDoesNotPoisonRejectedSurrenderTracking"), coverage.detail)
    }

    func testSelfTestRejectsMissingSpecialistEvidenceLedger() throws {
        let root = try makeSelfTestRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("""
        let a = "self-heal-researcher"
        let b = "self-heal-builder"
        let c = "self-heal-critic"
        let d = "self-heal-captain-gate"
        func runSimulationGate() {
            var writeSucceeded = false
            var writeError: String?
            let decision = "HOLD EXECUTION; simulation evidence report could not be persisted."
            _ = writeSucceeded
            _ = writeError
            _ = decision
            if writeSucceeded && run.passesGate {
                recordSimulationBenchmark(run: run)
            }
        }
        """, to: root + "/Sources/Kist/UX/OrganizationalLearningStore.swift")
        try write("""
        func testSimulationGateWriteFailureBlocksExecution() {
            XCTAssertFalse(report.writeSucceeded)
            XCTAssertFalse(report.passesGate)
            XCTAssertTrue(report.decision.contains("could not be persisted"))
        }
        """, to: root + "/Tests/KistTests/OrganizationalLearningStoreTests.swift")

        let report = CaptainSelfTestSuite(projectRoot: root,
                                          now: { Date(timeIntervalSince1970: 1_700_003_356) }).run()

        let coverage = try selfTestCheck("Specialist evidence ledger persistence", in: report)
        XCTAssertEqual(coverage.status, .fail)
        XCTAssertTrue(coverage.detail.contains("LearningEvidenceRecord"), coverage.detail)
        XCTAssertTrue(coverage.detail.contains("evidenceLedgerPath"), coverage.detail)
    }

    func testSelfTestWarnsWhenActiveOrDoneTaskLacksEvidenceLedgerProof() throws {
        let root = try makeSelfTestRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        PlanStore(projectRoot: root).save(Plan(title: "Proof Health",
                                               tasks: [
                                                PlanTask(id: 1,
                                                         title: "ACTION: finish unproven repair",
                                                         status: .done,
                                                         kind: .action,
                                                         acceptance: "Repair completed.",
                                                         verification: "Evidence is attached."),
                                                PlanTask(id: 2,
                                                         title: "REVIEW: old specialist artifact",
                                                         status: .inProgress,
                                                         kind: .review,
                                                         acceptance: "Review proof is ledgered.",
                                                         verification: "Read ledger.",
                                                         evidence: [".kist/learning/self-heal/specialists/old.md"])
                                               ],
                                               nextId: 3))

        let report = CaptainSelfTestSuite(projectRoot: root,
                                          now: { Date(timeIntervalSince1970: 1_700_003_357) }).run()

        let check = try selfTestCheck("Task board evidence ledger health", in: report)
        XCTAssertEqual(report.failures, 0)
        XCTAssertGreaterThan(report.warnings, 0)
        XCTAssertTrue(report.text.contains("Static outcome: STATIC WARN"), report.text)
        XCTAssertTrue(report.text.contains("## What Needs Attention"), report.text)
        XCTAssertFalse(report.text.contains("## What Needs Fixing"), report.text)
        XCTAssertEqual(check.status, .warn)
        XCTAssertTrue(check.detail.contains("[1] finish unproven repair has no attached evidence"), check.detail)
        XCTAssertTrue(check.detail.contains("specialist evidence without ledger"), check.detail)
    }

    func testSelfTestWriteFailureMakesOutcomeFail() throws {
        let root = tempRoot()
        try? FileManager.default.removeItem(atPath: root)
        try "not a directory".write(toFile: root, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let report = CaptainSelfTestSuite(projectRoot: root,
                                          now: { Date(timeIntervalSince1970: 1_700_003_360) }).run()

        XCTAssertFalse(report.writeSucceeded)
        XCTAssertGreaterThan(report.failures, 0)
        XCTAssertTrue(report.text.contains("Static outcome: STATIC FAIL"))
        XCTAssertTrue(report.text.contains("Self-test report persistence"))
    }

    func testImmuneSystemPassWritesReportWithoutRepairMission() throws {
        let root = try makeSelfTestRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let report = CaptainImmuneSystem(projectRoot: root,
                                         now: { Date(timeIntervalSince1970: 1_700_003_500) })
            .run(seedRepairs: false)

        XCTAssertEqual(report.status, .pass)
        XCTAssertTrue(report.writeSucceeded)
        XCTAssertNil(report.writeError)
        XCTAssertTrue(report.blockers.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + report.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + report.selfTestPath))
        XCTAssertNil(report.selfHealPath)
        XCTAssertNil(report.simulationPath)
        XCTAssertEqual(report.seededTasks, 0)
        XCTAssertTrue(report.text.contains("Captain Immune System"))
        XCTAssertTrue(report.text.contains("Status: PASS"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/immune"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/immune-system"))
    }

    func testImmuneSystemWatchUsesWatchObjectiveForWarningOnlyFindings() throws {
        let root = try makeSelfTestRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        PlanStore(projectRoot: root).save(Plan(title: "Kist Watch",
                                               tasks: [PlanTask(id: 1,
                                                                title: "REVIEW: inspect nested sandbox host",
                                                                status: .blocked,
                                                                kind: .review,
                                                                acceptance: "Warning is accepted or resolved with evidence.",
                                                                verification: "/self-test shows no blocked task warning.")],
                                               nextId: 2))

        let report = CaptainImmuneSystem(projectRoot: root,
                                         now: { Date(timeIntervalSince1970: 1_700_003_550) })
            .run(seedRepairs: false)

        XCTAssertEqual(report.status, .watch)
        XCTAssertTrue(report.blockers.isEmpty)
        XCTAssertNil(report.selfHealPath)
        XCTAssertNil(report.simulationPath)
        XCTAssertEqual(report.seededTasks, 0)
        XCTAssertTrue(report.text.contains("Status: WATCH"), report.text)
        XCTAssertTrue(report.text.contains("Watch objective: Captain immune-system watch: Task board blocked work"), report.text)
        XCTAssertTrue(report.text.contains("## Watch Mission"), report.text)
        XCTAssertTrue(report.text.contains("No watch mission seeded in check-only mode."), report.text)
        XCTAssertFalse(report.text.contains("Repair objective:"), report.text)
        XCTAssertTrue(report.text.contains("Mode: check-only"), report.text)
    }

    func testImmuneSystemFindingsCreateRepairMissionAndSimulationGate() throws {
        let root = try makeSelfTestRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.removeItem(atPath: root + "/Sources/Kist/UX/CaptainDomainLearningEnforcer.swift")

        let report = CaptainImmuneSystem(projectRoot: root,
                                         now: { Date(timeIntervalSince1970: 1_700_003_600) })
            .run(seedRepairs: true)

        XCTAssertEqual(report.status, .hold)
        XCTAssertTrue(report.writeSucceeded)
        XCTAssertGreaterThan(report.seededTasks, 0)
        XCTAssertTrue(report.blockers.contains { $0.contains("self-test failure") }, report.blockers.joined(separator: "\n"))
        let selfHealPath = try XCTUnwrap(report.selfHealPath)
        let simulationPath = try XCTUnwrap(report.simulationPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + selfHealPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + simulationPath))
        XCTAssertTrue(report.text.contains("Repair Mission"), report.text)
        XCTAssertTrue(report.text.contains("Simulation Gate"), report.text)
        XCTAssertTrue(report.text.contains("Captain immune-system repair"), report.text)

        let plan = PlanStore(projectRoot: root).load()
        XCTAssertTrue(plan.tasks.contains { $0.owner == "captain-self-test" }, plan.render())
        XCTAssertTrue(plan.tasks.contains { $0.owner == "self-heal-builder" }, plan.render())
        XCTAssertTrue(plan.tasks.contains { $0.owner == "simulation-architect" }, plan.render())
    }

    func testImmuneSystemReportWriteFailureMakesOutcomeHold() throws {
        let root = try makeSelfTestRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("not a directory", to: root + "/.kist/learning/immune")

        let report = CaptainImmuneSystem(projectRoot: root,
                                         now: { Date(timeIntervalSince1970: 1_700_003_650) })
            .run(seedRepairs: false)

        XCTAssertEqual(report.status, .hold)
        XCTAssertFalse(report.writeSucceeded)
        XCTAssertNotNil(report.writeError)
        XCTAssertTrue(report.blockers.contains { $0.contains("immune report did not persist") })
        XCTAssertTrue(report.text.contains("Status: HOLD"), report.text)
        XCTAssertTrue(report.text.contains("Evidence Persistence"), report.text)
    }

    func testImmuneCommandDefaultsToRepairQueueAndCheckDoesNotSeed() throws {
        let root = try makeSelfTestRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.removeItem(atPath: root + "/Sources/Kist/UX/CaptainDomainLearningEnforcer.swift")

        let check = KistREPL.handleImmuneCommand("check", projectRoot: root)

        XCTAssertEqual(check.status, .hold)
        XCTAssertEqual(check.seededTasks, 0)
        XCTAssertFalse(KistREPL.immuneShouldSeedRepairs("check"))
        XCTAssertTrue(KistREPL.immuneShouldSeedRepairs(""))
        XCTAssertNil(KistREPL.immuneUsageIfNeeded("repair"))
        XCTAssertNotNil(KistREPL.immuneUsageIfNeeded("unknown"))

        let run = KistREPL.handleImmuneCommand("", projectRoot: root)

        XCTAssertEqual(run.status, .hold)
        XCTAssertGreaterThan(run.seededTasks, 0)
    }

    func testSimulationGateSeedsTasksWithoutBenchmarkWhenGateHolds() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let plan = Plan(title: "Kist Simulation",
                        tasks: [PlanTask(id: 1,
                                         title: "ACTION: refactor MCP startup path",
                                         detail: "software change with customer-visible failure risk",
                                         kind: .action)])
        PlanStore(projectRoot: root).save(plan)
        try? "swift-tools-version: 6.0\n".write(toFile: root + "/Package.swift",
                                               atomically: true,
                                               encoding: .utf8)
        let store = OrganizationalLearningStore(projectRoot: root,
                                                now: { Date(timeIntervalSince1970: 1_700_000_654) },
                                                specialistRegistry: {
                                                    SpecialistRegistry(projectRoot: $0, userDir: nil,
                                                                       claudeUserDir: nil)
                                                })

        let report = store.runSimulationGate(plan: plan,
                                             trajectory: [ActionRecord(tool: "read_file",
                                                                       argsFingerprint: "a",
                                                                       success: true)],
                                             objective: "simulate a software refactor before touching customers")

        XCTAssertTrue(report.text.contains("Captain Simulation Gate"))
        XCTAssertTrue(report.text.contains("Sandbox Simulation"))
        XCTAssertTrue(report.text.contains("Probabilistic Trials"))
        XCTAssertTrue(report.text.contains("Compare Strategies"))
        XCTAssertTrue(report.text.contains("Execution Gate"))
        XCTAssertEqual(report.domainTitle, "Software sandbox")
        XCTAssertGreaterThan(report.estimatedSuccess, 0)
        XCTAssertGreaterThan(report.failureRisk, 0)
        XCTAssertGreaterThanOrEqual(report.seededTasks, 6)
        XCTAssertGreaterThanOrEqual(report.createdSpecialists, 2)
        XCTAssertEqual(report.benchmarkRecords, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + report.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/agents/simulation-architect.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/agents/risk-model-critic.md"))

        let seeded = PlanStore(projectRoot: root).load()
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .plan && $0.owner == "captain" && $0.boardTitle.contains("Simulation gate") })
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .research && $0.owner == "simulation-architect" })
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .test && $0.owner == "simulation-architect" })
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .review && $0.owner == "risk-model-critic" })
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .decision && $0.owner == "captain" })

        let retrieve = KistREPL.handleRetrieveCommand("software refactor simulation risk",
                                                      projectRoot: root)
        XCTAssertTrue(retrieve.contains("Benchmark Evidence") || retrieve.contains("Simulation Gate"))
        XCTAssertTrue(retrieve.contains("simulation"))
    }

    func testSimulationGateRunsExecutableSandboxTrialWhenSafeEntrypointExists() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        guard runCommand(["git", "init"], cwd: root) == 0 else {
            throw XCTSkip("git unavailable")
        }
        guard SandboxedProcessRunner.canApplyRequiredSandbox(root: root) else {
            throw XCTSkip("required OS sandbox unavailable in this test environment")
        }
        try write("""
        #!/bin/sh
        echo measured-pass
        exit 0
        """, to: root + "/test.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/test.sh")
        XCTAssertEqual(runCommand(["git", "add", "test.sh"], cwd: root), 0)
        let plan = Plan(title: "Executable Simulation",
                        tasks: [PlanTask(id: 1,
                                         title: "ACTION: simulate risky software refactor",
                                         detail: "prove the sandbox command before execution",
                                         kind: .action)])
        let store = OrganizationalLearningStore(projectRoot: root,
                                                now: { Date(timeIntervalSince1970: 1_700_000_777) },
                                                specialistRegistry: {
                                                    SpecialistRegistry(projectRoot: $0, userDir: nil,
                                                                       claudeUserDir: nil)
                                                })

        let report = store.runSimulationGate(plan: plan,
                                             trajectory: [],
                                             objective: "simulate software refactor with real tests",
                                             measuredTrialMode: .interactive)

        XCTAssertTrue(report.text.contains("Executable Sandbox Trials"), report.text)
        XCTAssertTrue(report.text.contains("- ./test.sh"), report.text)
        XCTAssertTrue(report.text.contains("Status: passed"), report.text)
        XCTAssertTrue(report.text.contains("Output: measured-pass"), report.text)
        XCTAssertTrue(report.text.contains("Measured-adjusted success"), report.text)
        XCTAssertTrue(report.decision.contains("executable sandbox trials passed"), report.decision)
        XCTAssertTrue(report.passesGate)
        XCTAssertEqual(report.benchmarkRecords, 1)
    }

    func testSimulationExecutableTrialRunsInsideOSSandbox() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        guard runCommand(["git", "init"], cwd: root) == 0 else {
            throw XCTSkip("git unavailable")
        }
        guard SandboxedProcessRunner.canApplyRequiredSandbox(root: root) else {
            throw XCTSkip("required OS sandbox unavailable in this test environment")
        }
        let externalRoot = NSHomeDirectory() + "/.kist-simulation-escape-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: externalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: externalRoot) }
        let externalTarget = externalRoot + "/escaped.txt"
        try write("""
        #!/bin/sh
        if echo escaped > '\(externalTarget)'; then
          echo escaped
          exit 42
        fi
        echo sandbox-blocked
        exit 0
        """, to: root + "/test.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/test.sh")
        XCTAssertEqual(runCommand(["git", "add", "test.sh"], cwd: root), 0)
        let plan = Plan(title: "Executable Simulation",
                        tasks: [PlanTask(id: 1,
                                         title: "ACTION: simulate risky software refactor",
                                         detail: "prove OS sandbox confinement before execution",
                                         kind: .action)])
        let store = OrganizationalLearningStore(projectRoot: root,
                                                now: { Date(timeIntervalSince1970: 1_700_000_776) },
                                                specialistRegistry: {
                                                    SpecialistRegistry(projectRoot: $0, userDir: nil,
                                                                       claudeUserDir: nil)
                                                })

        let report = store.runSimulationGate(plan: plan,
                                             trajectory: [],
                                             objective: "simulate software refactor with real tests",
                                             measuredTrialMode: .interactive)

        XCTAssertFalse(FileManager.default.fileExists(atPath: externalTarget))
        XCTAssertTrue(report.text.contains("Sandbox: macOS Seatbelt"), report.text)
        XCTAssertTrue(report.text.contains("Output: sandbox-blocked"), report.text)
        XCTAssertTrue(report.text.contains("Status: passed"), report.text)
        XCTAssertTrue(report.passesGate, report.text)
    }

    func testSimulationGateBlocksWhenExecutableSandboxTrialFails() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        guard runCommand(["git", "init"], cwd: root) == 0 else {
            throw XCTSkip("git unavailable")
        }
        guard SandboxedProcessRunner.canApplyRequiredSandbox(root: root) else {
            throw XCTSkip("required OS sandbox unavailable in this test environment")
        }
        try write("""
        #!/bin/sh
        echo measured-fail
        exit 7
        """, to: root + "/test.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/test.sh")
        XCTAssertEqual(runCommand(["git", "add", "test.sh"], cwd: root), 0)
        let plan = Plan(title: "Executable Simulation",
                        tasks: [PlanTask(id: 1,
                                         title: "ACTION: simulate risky software refactor",
                                         detail: "block execution when sandbox proof fails",
                                         kind: .action)])
        let store = OrganizationalLearningStore(projectRoot: root,
                                                now: { Date(timeIntervalSince1970: 1_700_000_778) },
                                                specialistRegistry: {
                                                    SpecialistRegistry(projectRoot: $0, userDir: nil,
                                                                       claudeUserDir: nil)
                                                })

        let report = store.runSimulationGate(plan: plan,
                                             trajectory: [],
                                             objective: "simulate software refactor with real tests",
                                             measuredTrialMode: .interactive)

        XCTAssertTrue(report.text.contains("- ./test.sh"), report.text)
        XCTAssertTrue(report.text.contains("Status: failed"), report.text)
        XCTAssertTrue(report.text.contains("Exit: 7"), report.text)
        XCTAssertTrue(report.text.contains("Output: measured-fail"), report.text)
        XCTAssertTrue(report.decision.contains("HOLD EXECUTION"), report.decision)
        XCTAssertFalse(report.passesGate)
        XCTAssertGreaterThanOrEqual(report.failureRisk, 55)
        XCTAssertEqual(report.benchmarkRecords, 0)
    }

    func testSimulationGateWriteFailureBlocksExecution() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "WriteFailureProbe")
        """, to: root + "/Package.swift")
        try write("not a directory", to: root + "/.kist/learning")
        let plan = Plan(title: "Executable Simulation",
                        tasks: [PlanTask(id: 1,
                                         title: "ACTION: simulate risky software refactor",
                                         detail: "block execution when evidence cannot persist",
                                         kind: .action)])
        let store = OrganizationalLearningStore(projectRoot: root,
                                                now: { Date(timeIntervalSince1970: 1_700_000_780) },
                                                specialistRegistry: {
                                                    SpecialistRegistry(projectRoot: $0, userDir: nil,
                                                                       claudeUserDir: nil)
                                                })

        let report = store.runSimulationGate(plan: plan,
                                             trajectory: [],
                                             objective: "simulate software refactor",
                                             measuredTrialMode: .interactive)

        XCTAssertFalse(report.writeSucceeded)
        XCTAssertNotNil(report.writeError)
        XCTAssertFalse(report.passesGate)
        XCTAssertEqual(report.benchmarkRecords, 0)
        XCTAssertTrue(report.decision.contains("could not be persisted"), report.decision)
        XCTAssertTrue(report.text.contains("Evidence Persistence"), report.text)
        XCTAssertTrue(report.text.contains("Status: FAILED"), report.text)
        XCTAssertFalse(report.text.contains("Decision: PROCEED"), report.text)
    }

    func testPlainSimulationCommandDoesNotExecuteProjectTestEntrypoint() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        guard runCommand(["git", "init"], cwd: root) == 0 else {
            throw XCTSkip("git unavailable")
        }
        guard SandboxedProcessRunner.canApplyRequiredSandbox(root: root) else {
            throw XCTSkip("required OS sandbox unavailable in this test environment")
        }
        try write("""
        #!/bin/sh
        echo should-not-run > marker.txt
        exit 0
        """, to: root + "/test.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/test.sh")
        XCTAssertEqual(runCommand(["git", "add", "test.sh"], cwd: root), 0)

        let report = KistREPL.handleSimulationCommand("simulate software refactor",
                                                      projectRoot: root)

        XCTAssertFalse(KistREPL.simulationShouldRunExecutableTrials("simulate software refactor"))
        XCTAssertTrue(KistREPL.simulationShouldRunExecutableTrials("simulate run software refactor"))
        XCTAssertTrue(KistREPL.simulationShouldRunExecutableTrials("run simulate software refactor"))
        XCTAssertEqual(KistREPL.normalizedSimulationObjective("run simulate software refactor"),
                       "software refactor")
        XCTAssertEqual(KistREPL.normalizedSimulationObjective("simulate run simulate software refactor"),
                       "software refactor")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/marker.txt"))
        XCTAssertTrue(report.text.contains("git diff --check"), report.text)
        XCTAssertFalse(report.text.contains("should-not-run"), report.text)
        XCTAssertTrue(report.decision.contains("HOLD EXECUTION"), report.decision)
        XCTAssertFalse(report.passesGate)
    }

    func testSimulationGateDoesNotProceedWhenExecutableSandboxCoverageIsSkipped() {
        let strategy = CaptainSimulationStrategy(
            name: "Containerized integration sandbox",
            sandbox: "Run the plan in Docker.",
            reason: "Integration risk needs runtime proof.",
            trials: 72,
            passedTrials: 64,
            failedTrials: 8,
            estimatedSuccess: 89,
            failureRisk: 11,
            expectedValue: 95,
            failureModes: ["container/runtime mismatch"],
            requiredEvidence: ["container startup log"],
            verificationCommands: ["docker compose config", "docker compose up --abort-on-container-exit"])
        let run = CaptainSimulationRun(id: "sim-test",
                                       objective: "Kist executable simulation trial layer",
                                       domain: .software,
                                       strategies: [strategy],
                                       recommendedStrategy: strategy,
                                       measuredTrials: [],
                                       decision: "PROCEED TO EXECUTION ONLY AFTER THE REQUIRED EVIDENCE IS ATTACHED.",
                                       acceptanceThreshold: 78,
                                       generatedAt: 1_700_000_779)

        let updated = CaptainSimulationLab.attachingMeasuredTrials([
            CaptainSimulationMeasuredTrial(command: "docker compose config",
                                           status: .skipped,
                                           exitCode: nil,
                                           timedOut: false,
                                           elapsedSeconds: 0,
                                           sandbox: "not executed",
                                           outputExcerpt: "unsupported command for automatic sandbox execution"),
            CaptainSimulationMeasuredTrial(command: "git diff --check",
                                           status: .passed,
                                           exitCode: 0,
                                           timedOut: false,
                                           elapsedSeconds: 0.01,
                                           sandbox: "macOS Seatbelt",
                                           outputExcerpt: "")
        ], to: run)

        XCTAssertFalse(updated.passesGate)
        XCTAssertEqual(updated.estimatedSuccess, 77)
        XCTAssertGreaterThan(updated.failureRisk, 22)
        XCTAssertTrue(updated.decision.contains("coverage is incomplete"), updated.decision)
    }

    func testSimulationCommandAndCaptainAliasCreateGate() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        PlanStore(projectRoot: root).save(Plan(title: "Kist",
                                               tasks: [PlanTask(id: 1,
                                                                title: "ACTION: validate risky product launch",
                                                                detail: "market simulation",
                                                                kind: .action)]))

        let report = KistREPL.handleSimulationCommand("simulate pricing experiment", projectRoot: root)

        XCTAssertTrue(KistREPL.isSimulationIntent("simulate pricing experiment"))
        XCTAssertEqual(KistREPL.normalizedSimulationObjective("simulate run pricing experiment"),
                       "pricing experiment")
        XCTAssertTrue(KistREPL.simulationShouldRunExecutableTrials("simulate run pricing experiment"))
        XCTAssertTrue(report.text.contains("Captain Simulation Gate"))
        XCTAssertEqual(report.domainTitle, "Product / market sandbox")
    }

    func testLocalModelScoutRanksCandidatesAndAppliesHardwareFit() {
        let codePlan = LocalModelScout.plan(objective: "Swift code refactor worker", hardwareMemoryGB: 16)

        XCTAssertEqual(codePlan.first?.modelID, "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
        XCTAssertTrue(codePlan.contains { $0.provider == "ollama" })
        XCTAssertTrue(codePlan.allSatisfy { !$0.onboardingSteps.contains { $0.hasPrefix("curl ") } })
        XCTAssertTrue(codePlan.allSatisfy { !$0.onboardingSteps.contains { $0.contains("huggingface-cli download") } })
        XCTAssertTrue(codePlan.allSatisfy { $0.onboardingSteps.contains { $0.contains("/model vet") } })
        XCTAssertTrue(codePlan.contains { candidate in
            candidate.provider == "mlx" && candidate.onboardingSteps.contains { $0.contains("manifest-approved") }
        })

        let tightPlan = LocalModelScout.plan(objective: "tiny offline assistant", hardwareMemoryGB: 8)

        XCTAssertLessThanOrEqual(tightPlan.first?.estimatedMemoryGB ?? 99, 8)
        XCTAssertTrue(tightPlan.first?.risks.contains { $0.contains("Memory fit") || $0.contains("exceeds host memory") } == false)
    }

    func testLocalModelScoutCommandWritesArchiveSeedsGatesAndRetrieval() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let report = KistREPL.handleLocalModelScoutCommand("scout Swift code refactor worker",
                                                           projectRoot: root)

        XCTAssertTrue(report.text.contains("Safe Local Model Scout"))
        XCTAssertTrue(report.text.contains("This is a scout report only. It does not download"))
        XCTAssertTrue(report.text.contains("Promotion Gate"))
        XCTAssertGreaterThanOrEqual(report.candidates.count, 2)
        XCTAssertGreaterThanOrEqual(report.seededTasks, 4)
        XCTAssertEqual(report.memoryRecords, 1)
        XCTAssertTrue(report.writeSucceeded)
        XCTAssertNil(report.writeError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + report.path))

        let seeded = PlanStore(projectRoot: root).load()
        XCTAssertTrue(seeded.tasks.contains { $0.owner == "local-model-scout" && $0.kind == .research })
        XCTAssertTrue(seeded.tasks.contains { $0.owner == "local-model-scout" && $0.kind == .test })
        XCTAssertTrue(seeded.tasks.contains { $0.owner == "captain" && $0.kind == .decision })

        let retrieve = KistREPL.handleRetrieveCommand("safe local model qwen coder scout",
                                                      projectRoot: root)
        XCTAssertTrue(retrieve.contains("Safe Local Model Scout"), retrieve)
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/local-model"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/model-scout"))
    }

    func testLocalModelScoutReportWriteFailurePublishesNoGenericMemory() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_444)
        let objective = "Swift write-failure model scout"
        let store = OrganizationalLearningStore(projectRoot: root, now: { fixedNow })
        store.ensureMemoryArchitecture()
        XCTAssertTrue(store.appendGenericMemory(
            DiskMemoryRecord(
                id: "scout-failure-sentinel", title: "Existing generic memory",
                summary: "Must remain byte-identical.", body: nil, source: nil,
                confidence: 80, impact: 4, tags: ["sentinel"]),
            to: store.knowledgeIndexPath, decayRate: .medium, at: fixedNow))
        let before = try mappedBytes(at: store.knowledgeIndexPath)
        let blockedReportPath = store.localModelsRoot
            + "/\(Int(fixedNow.timeIntervalSince1970))-\(OrganizationalLearningStore.slug(objective)).md"
        try FileManager.default.createDirectory(
            atPath: blockedReportPath, withIntermediateDirectories: true)

        let report = store.runLocalModelScout(objective: objective)

        XCTAssertFalse(report.writeSucceeded)
        XCTAssertNotNil(report.writeError)
        XCTAssertEqual(report.memoryRecords, 0)
        XCTAssertEqual(try mappedBytes(at: store.knowledgeIndexPath), before)
        XCTAssertEqual(store.loadJSONL(
            DiskMemoryRecord.self, path: store.knowledgeIndexPath).map(\.id),
            ["scout-failure-sentinel"])
    }

    func testLocalModelAcquisitionReportWriteFailurePublishesNoGenericMemory() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_445)
        let store = OrganizationalLearningStore(projectRoot: root, now: { fixedNow })
        store.ensureMemoryArchitecture()
        XCTAssertTrue(store.appendGenericMemory(
            DiskMemoryRecord(
                id: "acquisition-failure-sentinel", title: "Existing generic memory",
                summary: "Must remain byte-identical.", body: nil, source: nil,
                confidence: 80, impact: 4, tags: ["sentinel"]),
            to: store.knowledgeIndexPath, decayRate: .medium, at: fixedNow))
        let before = try mappedBytes(at: store.knowledgeIndexPath)
        let blockedReportPath = store.localModelsRoot
            + "/\(Int(fixedNow.timeIntervalSince1970))-acquire-missing-manifest-path.md"
        try FileManager.default.createDirectory(
            atPath: blockedReportPath, withIntermediateDirectories: true)

        let report = store.runLocalModelAcquisitionPreflight(manifestPath: "")

        XCTAssertFalse(report.writeSucceeded)
        XCTAssertNotNil(report.writeError)
        XCTAssertEqual(report.memoryRecords, 0)
        XCTAssertEqual(try mappedBytes(at: store.knowledgeIndexPath), before)
        XCTAssertEqual(store.loadJSONL(
            DiskMemoryRecord.self, path: store.knowledgeIndexPath).map(\.id),
            ["acquisition-failure-sentinel"])
    }

    func testSymbolicWorkflowCompileAndRunSeedsDeterministicGates() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let plan = Plan(title: "Kist Symbolic",
                        tasks: [
                            PlanTask(id: 1,
                                     title: "RESEARCH: compare model routing",
                                     detail: "read source and benchmark notes",
                                     kind: .research),
                            PlanTask(id: 2,
                                     title: "ACTION: implement routing gate",
                                     detail: "small scoped change",
                                     kind: .action),
                            PlanTask(id: 3,
                                     title: "TEST: verify routing gate",
                                     kind: .test,
                                     verification: "swift test --filter Routing"),
                            PlanTask(id: 4,
                                     title: "REVIEW: independent routing review",
                                     kind: .review)
                        ],
                        nextId: 5)
        PlanStore(projectRoot: root).save(plan)
        let store = SymbolicWorkflowStore(projectRoot: root,
                                          now: { Date(timeIntervalSince1970: 1_700_001_000) })

        let compiled = store.compile(plan: plan,
                                     objective: "safe model routing workflow before customer-impacting release",
                                     trajectory: [ActionRecord(tool: "apply_patch",
                                                               argsFingerprint: "a",
                                                               success: true)])

        XCTAssertTrue(compiled.text.contains("Symbolic Workflow Compiled"))
        XCTAssertTrue(compiled.record.gates.contains { $0.kind == SymbolicWorkflowGate.Kind.research })
        XCTAssertTrue(compiled.record.gates.contains { $0.kind == SymbolicWorkflowGate.Kind.simulation })
        XCTAssertTrue(compiled.record.gates.contains { $0.kind == SymbolicWorkflowGate.Kind.action })
        XCTAssertTrue(compiled.record.gates.contains { $0.kind == SymbolicWorkflowGate.Kind.test })
        XCTAssertTrue(compiled.record.gates.contains { $0.kind == SymbolicWorkflowGate.Kind.review })
        XCTAssertTrue(compiled.record.gates.contains { $0.kind == SymbolicWorkflowGate.Kind.decision })
        XCTAssertTrue(compiled.record.gates.contains { $0.kind == SymbolicWorkflowGate.Kind.teach })
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + compiled.path))

        PlanStore(projectRoot: root).clear()
        let run = store.run(id: compiled.record.id, input: "new model import flow")

        XCTAssertEqual(run?.record.id, compiled.record.id)
        XCTAssertGreaterThanOrEqual(run?.seededTasks ?? 0, 7)
        let seeded = PlanStore(projectRoot: root).load()
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .research })
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .test && $0.owner == "simulation-architect" })
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .decision && $0.owner == "captain" })
        XCTAssertTrue(seeded.tasks.contains { $0.boardTitle.contains("new model import flow") })
    }

    func testSymbolicCommandCompilesAndListsWorkflow() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        PlanStore(projectRoot: root).save(Plan(title: "Kist",
                                               tasks: [PlanTask(id: 1,
                                                                title: "ACTION: repeatable audit",
                                                                kind: .action)]))

        let compiled = KistREPL.handleSymbolicWorkflowCommand("compile repeatable audit workflow",
                                                              projectRoot: root,
                                                              trajectory: [])
        let listed = KistREPL.handleSymbolicWorkflowCommand("", projectRoot: root)

        XCTAssertTrue(compiled.contains("Symbolic Workflow Compiled"))
        XCTAssertTrue(listed.contains("Symbolic Workflows"))
        XCTAssertTrue(listed.contains("/symbolic run"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/symbolic"))
    }

    func testKnowledgeCommandAddAndDone() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let added = KistREPL.handleKnowledgeCommand(
            "add Apple Foundation Models | reason: local reasoning roadmap | impact: 5 | priority: high",
            projectRoot: root)
        let id = OrganizationalLearningStore.debtID("Apple Foundation Models")

        XCTAssertTrue(added.contains(id))
        XCTAssertTrue(KistREPL.handleKnowledgeCommand("done \(id)", projectRoot: root).contains("closed"))
    }

    func testTeachCommandKeepsStringEvidenceAdvisory() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let added = KistREPL.handleTeachCommand(
            "add Medical projects require DICOM research before planning | confidence: 97 | reason: regulated domain risk | evidence: tests: swift test passed; benchmark: live-eval score 0.96 passed",
            projectRoot: root)
        let id = OrganizationalLearningStore.ruleID("Medical projects require DICOM research before planning")

        XCTAssertTrue(added.contains(id))
        XCTAssertTrue(added.contains("organizational rule proposed"))
        let store = OrganizationalLearningStore(projectRoot: root)
        XCTAssertTrue(store.permanentRules().isEmpty)
        let listing = KistREPL.handleTeachCommand("", projectRoot: root)
        XCTAssertTrue(listing.contains("Proposed Rules Awaiting Evidence"))
        XCTAssertTrue(listing.contains("confidence 97%"))
        XCTAssertTrue(listing.contains("regulated domain risk"))
        XCTAssertTrue(listing.contains("exact receipt-bound rule verification"))
    }

    func testTeachCommandQuarantinesWeakRuleAsProposedKnowledgeDebt() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let added = KistREPL.handleTeachCommand(
            "add New architecture ideas should become permanent immediately | confidence: 91 | reason: sounds right | evidence: board review",
            projectRoot: root)
        let listing = KistREPL.handleTeachCommand("", projectRoot: root)

        XCTAssertTrue(added.contains("organizational rule proposed"))
        XCTAssertTrue(listing.contains("Proposed Rules Awaiting Evidence"))
        let store = OrganizationalLearningStore(projectRoot: root)
        XCTAssertTrue(store.permanentRules().isEmpty)
        XCTAssertTrue(store.renderKnowledgeDebt().contains("Prove organizational rule"))
    }

    func testRetrieveCommandRendersRankedMemoryAndDecisionCards() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let store = OrganizationalLearningStore(projectRoot: root, now: { fixedNow })
        _ = store.addKnowledgeDebt(topic: "Agent orchestration benchmarks",
                                   reason: "Need benchmark proof before model-routing changes",
                                   impact: 5,
                                   priority: .high)
        let untrustedActive = makeRule(
            id: "OR-untrusted-active",
            lesson: "Agent-orchestration work requires competitor/runtime comparison before implementation.",
            at: fixedNow,
            temporal: try? MemoryTemporalEnvelope(createdAt: fixedNow, decayRate: .verySlow))
        XCTAssertTrue(store.appendJSON(untrustedActive, to: store.rulesPath))

        let text = KistREPL.handleRetrieveCommand("improve Captain agent orchestration benchmarks",
                                                  projectRoot: root, now: { fixedNow })

        XCTAssertTrue(text.contains("CAPTAIN RETRIEVAL CONTEXT"))
        XCTAssertTrue(text.contains("context window policy"))
        XCTAssertTrue(text.contains("Advisory rule proposal (not operating policy)"))
        XCTAssertTrue(text.contains("UNVERIFIED—DO NOT APPLY AS POLICY"))
        XCTAssertTrue(text.contains("Knowledge Debt: Agent orchestration benchmarks"))
        XCTAssertTrue(text.contains("DECISION CARDS"))
        XCTAssertTrue(text.contains("Benchmark Gate"))
        XCTAssertFalse(text.contains("Applicable Organizational Rules"))
    }

    func testLegacyOrganizationalMemoryProjectsTemporalMetadataWithoutRewriting() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let store = OrganizationalLearningStore(
            projectRoot: root, now: { instant.addingTimeInterval(10 * 86_400) })
        try write(#"{"id":"LC-legacy","taskTitle":"Legacy task","status":"PASS","summary":"legacy summary","learned":["one"],"surprises":[],"slowdowns":[],"assumptionsToChallenge":[],"futureEvolution":"","tokenCount":2,"at":1700000000}"# + "\n",
                  to: store.capsulesPath)
        let before = try Data(contentsOf: URL(fileURLWithPath: store.capsulesPath))

        let capsule = try XCTUnwrap(store.latestCapsule())
        XCTAssertNil(capsule.temporal)
        let projected = try XCTUnwrap(capsule.temporalProjection)
        XCTAssertEqual(projected.createdAt, instant)
        XCTAssertEqual(projected.updatedAt, instant)
        XCTAssertEqual(projected.decayRate, .medium)
        XCTAssertNil(projected.lastConfirmedAt)
        XCTAssertNil(projected.seasonalWindow)
        _ = store.memoryCandidates(at: instant.addingTimeInterval(10 * 86_400))

        let after = try Data(contentsOf: URL(fileURLWithPath: store.capsulesPath))
        XCTAssertEqual(after, before, "legacy projection must never migrate or reinforce on read")
    }

    func testStoredTemporalClockAgreementKeepsRawAuditButRejectsContradictoryProjection() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let updated = base.addingTimeInterval(10)
        let evaluationAt = base.addingTimeInterval(60)
        let store = OrganizationalLearningStore(projectRoot: root, now: { evaluationAt })

        let capsuleEnvelope = try MemoryTemporalEnvelope(
            createdAt: base, decayRate: .medium)
        var capsuleWithin = makeCapsule(
            id: "capsule-within", at: base, temporal: capsuleEnvelope)
        capsuleWithin.at += 0.000_5
        var capsuleAtBoundary = makeCapsule(
            id: "capsule-at-boundary", at: base, temporal: capsuleEnvelope)
        capsuleAtBoundary.at += OrganizationalMemoryTemporal.storedClockAgreementTolerance
        var capsuleBeyond = makeCapsule(
            id: "capsule-beyond", at: base, temporal: capsuleEnvelope)
        capsuleBeyond.at += 0.002
        XCTAssertNotNil(capsuleAtBoundary.temporalProjection,
                        "the one-millisecond agreement boundary is inclusive")
        try write(try [capsuleWithin, capsuleBeyond]
            .map { try jsonLine($0) }.joined(separator: "\n") + "\n",
            to: store.capsulesPath)

        let capsuleAudit = store.capsules(limit: 10)
        XCTAssertEqual(capsuleAudit.map(\.id), ["capsule-within", "capsule-beyond"])
        XCTAssertNotNil(capsuleAudit[0].temporalProjection)
        XCTAssertNil(capsuleAudit[1].temporalProjection)
        XCTAssertEqual(store.latestCapsule()?.id, "capsule-beyond")
        XCTAssertEqual(store.latestTemporallyEligibleCapsule(at: evaluationAt)?.id,
                       "capsule-within")
        XCTAssertNil(store.loadJSONLForMutation(
            LearningCapsule.self, path: store.capsulesPath))

        let debtEnvelope = try MemoryTemporalEnvelope(
            createdAt: base, updatedAt: updated, decayRate: .slow)
        var debtWithin = makeDebt(id: "debt-within", at: base, temporal: debtEnvelope)
        debtWithin.createdAt += 0.000_5
        debtWithin.updatedAt = updated.timeIntervalSince1970 + 0.000_5
        var debtBeyond = makeDebt(id: "debt-beyond", at: base, temporal: debtEnvelope)
        debtBeyond.updatedAt = updated.timeIntervalSince1970 + 0.002
        try write(try [debtWithin, debtBeyond]
            .map { try jsonLine($0) }.joined(separator: "\n") + "\n",
            to: store.debtPath)

        let debtAudit = store.loadJSONL(KnowledgeDebtRecord.self, path: store.debtPath)
        XCTAssertEqual(debtAudit.map(\.id), ["debt-within", "debt-beyond"])
        XCTAssertNotNil(debtAudit[0].temporalProjection)
        XCTAssertNil(debtAudit[1].temporalProjection)
        XCTAssertNil(store.loadJSONLForMutation(
            KnowledgeDebtRecord.self, path: store.debtPath))

        let ruleEnvelope = try MemoryTemporalEnvelope(
            createdAt: base, updatedAt: updated, decayRate: .verySlow)
        var ruleWithin = makeRule(
            id: "rule-within", lesson: "within clock tolerance",
            at: base, temporal: ruleEnvelope)
        ruleWithin.updatedAt = updated.timeIntervalSince1970 + 0.000_5
        var ruleBeyond = makeRule(
            id: "rule-beyond", lesson: "beyond clock tolerance",
            at: base, temporal: ruleEnvelope)
        ruleBeyond.updatedAt = updated.timeIntervalSince1970 + 0.002
        try write(try [ruleWithin, ruleBeyond]
            .map { try jsonLine($0) }.joined(separator: "\n") + "\n",
            to: store.rulesPath)

        let ruleAudit = store.loadJSONL(OrganizationalRuleRecord.self, path: store.rulesPath)
        XCTAssertEqual(ruleAudit.map(\.id), ["rule-within", "rule-beyond"])
        XCTAssertNotNil(ruleAudit[0].temporalProjection)
        XCTAssertNil(ruleAudit[1].temporalProjection)
        XCTAssertNil(store.loadJSONLForMutation(
            OrganizationalRuleRecord.self, path: store.rulesPath))
    }

    func testOrganizationalCreationUsesSharedDecayRatesExplicitSeasonAndOneClock() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let rawNow = Date(timeIntervalSince1970: 1_700_000_000.123_456)
        let store = OrganizationalLearningStore(projectRoot: root, now: { rawNow })
        let season = try SeasonalMemoryWindow(
            months: [1, 2], timeZoneIdentifier: "UTC",
            inSeasonBoost: 1.4, offSeasonFactor: 0.2)
        let capsule = store.recordTurn(
            plan: Plan(title: "Temporal memory"), spans: [], trajectory: [],
            outcomeSummary: "Captured a seasonal episode.", success: true,
            seasonalWindow: season)
        let debt = try XCTUnwrap(store.addKnowledgeDebt(
            topic: "Winter release playbook", seasonalWindow: season))
        let rule = try XCTUnwrap(store.promoteOrganizationalRule(
            lesson: "Winter releases require explicit seasonal verification windows.",
            confidence: 100,
            evidence: ["tests passed", "artifact: /tmp/report"],
            seasonalWindow: season))

        XCTAssertEqual(capsule.temporal?.decayRate, .medium)
        XCTAssertEqual(debt.temporal?.decayRate, .slow)
        XCTAssertEqual(rule.temporal?.decayRate, .verySlow)
        XCTAssertEqual(capsule.temporal?.seasonalWindow, season)
        XCTAssertEqual(debt.temporal?.seasonalWindow, season)
        XCTAssertEqual(rule.temporal?.seasonalWindow, season)
        XCTAssertEqual(capsule.at, capsule.temporal?.createdAt.timeIntervalSince1970)
        XCTAssertEqual(debt.createdAt, debt.temporal?.createdAt.timeIntervalSince1970)
        XCTAssertEqual(rule.createdAt, rule.temporal?.createdAt.timeIntervalSince1970)
        XCTAssertEqual(rule.status, .proposed)
        XCTAssertNil(rule.temporal?.lastConfirmedAt)
    }

    func testKnowledgeDebtExactHalfLifeChangesCaptainRelevance() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let store = OrganizationalLearningStore(projectRoot: root, now: { created })
        let debt = try XCTUnwrap(store.addKnowledgeDebt(
            topic: "Temporal orchestration benchmark", impact: 5, priority: .high))
        let envelope = try XCTUnwrap(debt.temporalProjection)
        let atCreation = envelope.evaluate(at: created)
        let halfLife = created.addingTimeInterval(MemoryDecayRate.slow.halfLifeDays * 86_400)
        let atHalfLife = envelope.evaluate(at: halfLife)

        XCTAssertEqual(atCreation.salience, 0.8, accuracy: 0.000_000_1)
        XCTAssertEqual(atHalfLife.salience, 0.4, accuracy: 0.000_000_1)
        let fullCandidate = try XCTUnwrap(
            store.memoryCandidates(at: created).first { $0.recordID == debt.id })
        let halfCandidate = try XCTUnwrap(
            store.memoryCandidates(at: halfLife).first { $0.recordID == debt.id })
        XCTAssertEqual(halfCandidate.baseRelevance * 2, fullCandidate.baseRelevance)
    }

    func testSeasonalRuleProposalFallsOutAndReactivatesWithoutReadMutation() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let created = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 UTC
        let offSeason = Date(timeIntervalSince1970: 1_751_328_000) // 2025-07-01 UTC
        let nextSeason = Date(timeIntervalSince1970: 1_768_435_200) // 2026-01-15 UTC
        let season = try SeasonalMemoryWindow(
            months: [1], timeZoneIdentifier: "UTC",
            inSeasonBoost: 1.5, offSeasonFactor: 0.01)
        let envelope = try MemoryTemporalEnvelope(
            createdAt: created, seasonalWindow: season, decayRate: .verySlow)
        let rule = makeRule(id: "OR-seasonal", lesson: "January release evidence review",
                            at: created, temporal: envelope)
        let store = OrganizationalLearningStore(projectRoot: root, now: { offSeason })
        XCTAssertTrue(store.appendJSON(rule, to: store.rulesPath))
        let before = try Data(contentsOf: URL(fileURLWithPath: store.rulesPath))

        XCTAssertFalse(store.memoryCandidates(at: offSeason).contains { $0.recordID == rule.id })
        XCTAssertTrue(store.memoryCandidates(at: nextSeason).contains { $0.recordID == rule.id })
        XCTAssertEqual(envelope.evaluate(at: offSeason).inSeason, false)
        XCTAssertEqual(envelope.evaluate(at: nextSeason).inSeason, true)
        XCTAssertGreaterThan(envelope.evaluate(at: nextSeason).salience,
                             envelope.evaluate(at: offSeason).salience)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.rulesPath)), before)
    }

    func testSeasonalCapsulesFilterBeforeLimitAndOrderBySalienceEventAndOrdinal() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let target = Date(timeIntervalSince1970: 1_768_435_200) // 2026-01-15 UTC
        let offSeason = Date(timeIntervalSince1970: 1_782_864_000) // 2026-07-01 UTC
        let clock = ClockProbe(target)
        let store = OrganizationalLearningStore(projectRoot: root, now: { clock.read() })
        let season = try SeasonalMemoryWindow(
            months: [1], timeZoneIdentifier: "UTC",
            inSeasonBoost: 1.5, offSeasonFactor: 0)

        let highAt = target.addingTimeInterval(-600)
        let tieOlderAt = target.addingTimeInterval(-500)
        let tieNewerAt = target.addingTimeInterval(-400)
        let sharedEvidenceAnchor = target.addingTimeInterval(-300)
        let highTemporal = try MemoryTemporalEnvelope(
            createdAt: highAt, lastConfirmedAt: sharedEvidenceAnchor,
            seasonalWindow: season,
            decayRate: .medium, baseSalience: 0.6)
        let tieOlderTemporal = try MemoryTemporalEnvelope(
            createdAt: tieOlderAt, lastConfirmedAt: sharedEvidenceAnchor,
            seasonalWindow: season,
            decayRate: .medium, baseSalience: 0.4)
        let tieNewerTemporal = try MemoryTemporalEnvelope(
            createdAt: tieNewerAt, lastConfirmedAt: sharedEvidenceAnchor,
            seasonalWindow: season,
            decayRate: .medium, baseSalience: 0.4)
        let eligible = [
            makeCapsule(id: "seasonal-high", at: highAt, temporal: highTemporal),
            makeCapsule(id: "seasonal-tie-older", at: tieOlderAt,
                        temporal: tieOlderTemporal),
            makeCapsule(id: "seasonal-tie-first", at: tieNewerAt,
                        temporal: tieNewerTemporal),
            makeCapsule(id: "seasonal-tie-second", at: tieNewerAt,
                        temporal: tieNewerTemporal),
        ]
        for capsule in eligible {
            XCTAssertTrue(store.appendJSON(capsule, to: store.capsulesPath))
        }

        for index in 0..<80 {
            let eventAt = target.addingTimeInterval(-100 + Double(index))
            let notYet = try MemoryTemporalEnvelope(
                createdAt: eventAt,
                validFrom: target.addingTimeInterval(60),
                seasonalWindow: season,
                decayRate: .medium,
                baseSalience: 0.99,
                pinned: true)
            XCTAssertTrue(store.appendJSON(
                makeCapsule(id: "newer-ineligible-\(index)",
                            at: eventAt, temporal: notYet),
                to: store.capsulesPath))
        }

        let historyIDs = store.memoryCandidates(at: target)
            .filter { $0.layerID == .projectHistory }
            .map(\.recordID)
        XCTAssertEqual(historyIDs, [
            "seasonal-high",
            "seasonal-tie-second",
            "seasonal-tie-first",
            "seasonal-tie-older",
        ])
        XCTAssertTrue(store.memoryCandidates(at: offSeason)
            .filter { $0.layerID == .projectHistory }.isEmpty,
            "an explicit zero off-season factor must filter the capsules")
        XCTAssertEqual(store.capsules(limit: 200).count, 84,
                       "raw audit retains every temporally ineligible row")
        XCTAssertEqual(store.latestCapsule()?.id, "newer-ineligible-79")
        XCTAssertEqual(store.latestTemporallyEligibleCapsule(at: target)?.id,
                       "seasonal-tie-second")
        XCTAssertEqual(store.latestTemporallyEligibleCapsule()?.id,
                       "seasonal-tie-second")
        XCTAssertEqual(clock.reads, 1, "operational latest captures the injected clock once")
    }

    func testLifecycleAndValidityExcludePinnedRuleProposalsBeforeRanking() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let created = now.addingTimeInterval(-1_000)
        let futureCreated = now.addingTimeInterval(
            MemoryTemporalEnvelope.maximumFutureEvidenceSkew + 1)
        let eligible = try MemoryTemporalEnvelope(createdAt: created, decayRate: .verySlow,
                                                  pinned: true)
        let lifecycleAt = now.addingTimeInterval(-1)
        let retired = try MemoryTemporalEnvelope(
            createdAt: created, updatedAt: lifecycleAt, pinned: true, status: .retired,
            retiredAt: lifecycleAt, retiredReason: "retired")
        let expired = try MemoryTemporalEnvelope(
            createdAt: created, validFrom: created,
            validUntil: now, decayRate: .verySlow, pinned: true)
        let future = try MemoryTemporalEnvelope(
            createdAt: futureCreated,
            decayRate: .verySlow, pinned: true)
        let notYet = try MemoryTemporalEnvelope(
            createdAt: created, validFrom: now.addingTimeInterval(1),
            decayRate: .verySlow, pinned: true)
        let superseded = try MemoryTemporalEnvelope(
            createdAt: created, updatedAt: lifecycleAt, pinned: true, status: .superseded,
            retiredAt: lifecycleAt, retiredReason: "superseded by replacement",
            supersededBy: "replacement")
        let rules = [
            makeRule(id: "eligible", lesson: "eligible temporal advisory", at: created,
                     temporal: eligible),
            makeRule(id: "retired", lesson: "retired temporal advisory", at: created,
                     updatedAt: lifecycleAt, temporal: retired),
            makeRule(id: "expired", lesson: "expired temporal advisory", at: created,
                     temporal: expired),
            makeRule(id: "future", lesson: "future temporal advisory", at: futureCreated,
                     temporal: future),
            makeRule(id: "not-yet", lesson: "not yet temporal advisory", at: created,
                     temporal: notYet),
            makeRule(id: "superseded", lesson: "superseded temporal advisory", at: created,
                     updatedAt: lifecycleAt, temporal: superseded),
        ]
        let store = OrganizationalLearningStore(projectRoot: root, now: { now })
        for rule in rules { XCTAssertTrue(store.appendJSON(rule, to: store.rulesPath)) }

        let currentIDs = Set(store.proposedRules(limit: 20).map(\.id))
        let candidateIDs = Set(store.memoryCandidates(at: now).map(\.recordID))
        XCTAssertEqual(currentIDs, ["eligible"])
        XCTAssertTrue(candidateIDs.contains("eligible"))
        XCTAssertTrue(candidateIDs.isDisjoint(with: ["retired", "expired", "future", "not-yet", "superseded"]))
        XCTAssertTrue(store.permanentRules().isEmpty,
                      "source status alone must never create constitutional policy")
    }

    func testRuleAuditOrderingMalformedRowsAndLowSalienceFloor() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recentEnvelope = try MemoryTemporalEnvelope(createdAt: now, decayRate: .verySlow)
        let oldInstant = now.addingTimeInterval(-10 * 365 * 86_400)
        let oldEnvelope = try MemoryTemporalEnvelope(createdAt: oldInstant, decayRate: .verySlow)
        let first = makeRule(id: "z-first-physical", lesson: "first physical proposal",
                             at: now, temporal: recentEnvelope)
        let second = makeRule(id: "a-second-physical", lesson: "second physical proposal",
                              at: now, temporal: recentEnvelope)
        let faded = makeRule(id: "faded-audit", lesson: "low salience audit proposal",
                             at: oldInstant, confidence: 80, temporal: oldEnvelope)
        let invalidTemporal = #"{"id":"invalid-temporal","lesson":"invalid temporal row","confidence":96,"reason":"invalid","evidence":[],"status":"active","createdAt":1800000000,"updatedAt":1800000000,"temporal":{"created_at":1800000000,"base_salience":2}}"#
        let text = try jsonLine(first) + "\n{malformed-json\n" + invalidTemporal
            + "\n" + jsonLine(second)
            + "\n" + jsonLine(faded) + "\n"
        let store = OrganizationalLearningStore(projectRoot: root, now: { now })
        try write(text, to: store.rulesPath)

        let listed = store.proposedRules(limit: 20)
        XCTAssertEqual(Array(listed.prefix(2).map(\.id)), [first.id, second.id],
                       "equal ties use physical JSONL ordinal, not lexical ID")
        XCTAssertTrue(listed.contains { $0.id == faded.id },
                      "audit/list view retains eligible low-salience history")
        XCTAssertLessThan(try XCTUnwrap(faded.temporalProjection).evaluate(at: now).salience,
                          MemoryTemporalEnvelope.confidenceFloor)
        XCTAssertFalse(store.memoryCandidates(at: now).contains { $0.recordID == faded.id })
        XCTAssertEqual(store.loadJSONL(OrganizationalRuleRecord.self, path: store.rulesPath).count, 3,
                       "malformed and invalid-temporal lines must not hide adjacent safe rows")
    }

    func testReadsDoNotTouchReinforceOrRewriteOrganizationalMemory() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = OrganizationalLearningStore(projectRoot: root, now: { now })
        _ = store.recordTurn(plan: Plan(title: "Read immutability"), spans: [], trajectory: [],
                             outcomeSummary: "read memory", success: true)
        _ = store.addKnowledgeDebt(topic: "Read-only temporal memory")
        _ = store.promoteOrganizationalRule(
            lesson: "Read operations must never reinforce organizational evidence.",
            confidence: 100, evidence: ["tests passed", "report: exists"])
        let paths = [store.capsulesPath, store.debtPath, store.rulesPath]
        let before = try paths.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }

        _ = store.capsules()
        _ = store.openKnowledgeDebt()
        _ = store.proposedRules()
        _ = store.retrievalContext(
            objective: "read temporal organizational memory",
            strategy: CaptainStrategist.plan(objective: "read temporal organizational memory"))

        let after = try paths.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        XCTAssertEqual(after, before)
        for envelope in [store.latestCapsule()?.temporal,
                         store.openKnowledgeDebt().first?.temporal,
                         store.proposedRules().first?.temporal].compactMap({ $0 }) {
            XCTAssertEqual(envelope.accessCount, 0)
            XCTAssertEqual(envelope.reinforcementCount, 0)
            XCTAssertNil(envelope.lastConfirmedAt)
        }
    }

    func testRetrievalSamplesInjectedClockExactlyOnce() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let clock = ClockProbe(Date(timeIntervalSince1970: 1_800_000_000))
        let store = OrganizationalLearningStore(projectRoot: root, now: { clock.read() })

        _ = store.retrievalContext(
            objective: "single clock retrieval",
            strategy: CaptainStrategist.plan(objective: "single clock retrieval"))

        XCTAssertEqual(clock.reads, 1)
    }

    func testRuleStringUpdatePreservesEveryEvidenceFieldAndRemainsAdvisory() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let now = created.addingTimeInterval(10_000)
        let confirmed = created.addingTimeInterval(10)
        let season = try SeasonalMemoryWindow(months: [1], timeZoneIdentifier: "UTC")
        let envelope = try MemoryTemporalEnvelope(
            createdAt: created,
            updatedAt: created.addingTimeInterval(20),
            accessedAt: created.addingTimeInterval(5),
            validFrom: created.addingTimeInterval(-10),
            validUntil: now.addingTimeInterval(10_000),
            lastConfirmedAt: confirmed,
            seasonalWindow: season,
            accessCount: 2,
            reinforcementCount: 3,
            decayRate: .verySlow,
            baseSalience: 0.7,
            pinned: true,
            supersedes: "older-rule")
        let lesson = "Receipt-bound rules must preserve confirmation across advisory text updates."
        var original = makeRule(id: OrganizationalLearningStore.ruleID(lesson), lesson: lesson,
                                at: created, temporal: envelope)
        original.updatedAt = envelope.updatedAt.timeIntervalSince1970
        let store = OrganizationalLearningStore(projectRoot: root, now: { now })
        XCTAssertTrue(store.appendJSON(original, to: store.rulesPath))
        try write("artifact", to: root + "/claimed-proof.txt")

        let returned = try XCTUnwrap(store.promoteOrganizationalRule(
            lesson: lesson,
            confidence: 100,
            evidence: ["tests: all passed", root + "/claimed-proof.txt"]))
        let stored = try XCTUnwrap(store.loadJSONL(
            OrganizationalRuleRecord.self, path: store.rulesPath).first)
        let updated = try XCTUnwrap(stored.temporal)

        XCTAssertEqual(returned.status, .proposed)
        XCTAssertEqual(store.organizationalRulePromotionDecision(
            lesson: lesson, confidence: 100,
            evidence: ["tests: all passed", root + "/claimed-proof.txt"]).verifiedEvidenceCount, 0)
        XCTAssertEqual(updated.createdAt, envelope.createdAt)
        XCTAssertEqual(updated.accessedAt, envelope.accessedAt)
        XCTAssertEqual(updated.validFrom, envelope.validFrom)
        XCTAssertEqual(updated.validUntil, envelope.validUntil)
        XCTAssertEqual(updated.lastConfirmedAt, envelope.lastConfirmedAt)
        XCTAssertEqual(updated.seasonalWindow, envelope.seasonalWindow)
        XCTAssertEqual(updated.accessCount, envelope.accessCount)
        XCTAssertEqual(updated.reinforcementCount, envelope.reinforcementCount)
        XCTAssertEqual(updated.decayRate, envelope.decayRate)
        XCTAssertEqual(updated.baseSalience, envelope.baseSalience)
        XCTAssertEqual(updated.pinned, envelope.pinned)
        XCTAssertEqual(updated.status, envelope.status)
        XCTAssertEqual(updated.supersedes, envelope.supersedes)
        XCTAssertEqual(updated.updatedAt, OrganizationalMemoryTemporal.canonicalInstant(now))
        XCTAssertTrue(store.permanentRules().isEmpty)
        XCTAssertTrue(store.proposedRules().contains { $0.id == original.id })
    }

    func testLegacyGenericMemoryRemainsAuditOnlyAndReadDoesNotRewriteIt() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = OrganizationalLearningStore(projectRoot: root, now: { now })
        let legacy = DiskMemoryRecord(
            id: "legacy-generic", title: "Unknown-age conclusion",
            summary: "Preserve this historical row for audit.", body: nil,
            source: "legacy/import.json", confidence: 90, impact: 5,
            tags: ["legacy"])
        try write(try jsonLine(legacy) + "\n", to: store.knowledgeIndexPath)
        let before = try mappedBytes(at: store.knowledgeIndexPath)

        let audit = try XCTUnwrap(store.loadJSONL(
            DiskMemoryRecord.self, path: store.knowledgeIndexPath).first)
        XCTAssertEqual(audit.id, legacy.id)
        XCTAssertNil(audit.createdAt)
        XCTAssertNil(audit.updatedAt)
        XCTAssertNil(audit.temporalProjection)
        XCTAssertFalse(store.memoryCandidates(at: now).contains {
            $0.recordID == "legacy-generic"
        })
        XCTAssertEqual(try mappedBytes(at: store.knowledgeIndexPath), before,
                       "operational recall must not invent clocks or migrate a legacy row")
    }

    func testMemoryArchitectureSurfacesGenericTemporalAdmissionDebt() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let store = OrganizationalLearningStore(projectRoot: root, now: { instant })
        let legacy = DiskMemoryRecord(
            id: "legacy-dashboard-row", title: "Unknown-age row",
            summary: nil, body: nil, source: nil, confidence: nil, impact: nil, tags: nil)
        try write(try jsonLine(legacy) + "\n", to: store.industryIntelligencePath)
        XCTAssertTrue(store.appendGenericMemory(
            DiskMemoryRecord(
                id: "clocked-dashboard-row", title: "Clocked row",
                summary: nil, body: nil, source: nil, confidence: nil, impact: nil, tags: nil),
            to: store.evolutionProposalsPath, decayRate: .medium, at: instant))

        let readiness = store.genericMemoryTemporalReadiness()
        XCTAssertEqual(readiness.operational, 1)
        XCTAssertEqual(readiness.auditOnly, 1)
        XCTAssertTrue(store.renderCaptainMemoryArchitecture().contains(
            "Generic temporal admission: 1 clocked row(s); 1 legacy or invalid row(s) remain raw audit-only."))
    }

    func testGenericTemporalAdmissionRejectsPartialContradictoryAndPrivilegedRows() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let store = OrganizationalLearningStore(projectRoot: root, now: { created })
        let ordinary = try MemoryTemporalEnvelope(createdAt: created, decayRate: .medium)
        let contradictory = try MemoryTemporalEnvelope(createdAt: created, decayRate: .medium)
        let pinned = try MemoryTemporalEnvelope(
            createdAt: created, decayRate: .medium, pinned: true)
        let noDecay = try MemoryTemporalEnvelope(createdAt: created, decayRate: .none)
        let confirmed = try MemoryTemporalEnvelope(
            createdAt: created, lastConfirmedAt: created, decayRate: .medium)
        let reinforced = try MemoryTemporalEnvelope(
            createdAt: created, reinforcementCount: 1, decayRate: .medium)

        let rows = [
            DiskMemoryRecord(
                id: "partial-clock", title: "partial", summary: nil, body: nil,
                source: nil, confidence: 80, impact: 5, tags: nil,
                createdAt: created.timeIntervalSince1970, updatedAt: nil, temporal: nil),
            DiskMemoryRecord(
                id: "contradictory-clock", title: "contradictory", summary: nil,
                body: nil, source: nil, confidence: 80, impact: 5, tags: nil,
                createdAt: created.timeIntervalSince1970 + 0.002,
                updatedAt: created.timeIntervalSince1970, temporal: contradictory),
            DiskMemoryRecord(
                id: "pinned-generic", title: "pinned", summary: nil, body: nil,
                source: nil, confidence: 80, impact: 5, tags: nil,
                createdAt: created.timeIntervalSince1970,
                updatedAt: created.timeIntervalSince1970, temporal: pinned),
            DiskMemoryRecord(
                id: "no-decay-generic", title: "none", summary: nil, body: nil,
                source: nil, confidence: 80, impact: 5, tags: nil,
                createdAt: created.timeIntervalSince1970,
                updatedAt: created.timeIntervalSince1970, temporal: noDecay),
            DiskMemoryRecord(
                id: "confirmed-generic", title: "confirmed", summary: nil, body: nil,
                source: nil, confidence: 80, impact: 5, tags: nil,
                createdAt: created.timeIntervalSince1970,
                updatedAt: created.timeIntervalSince1970, temporal: confirmed),
            DiskMemoryRecord(
                id: "reinforced-generic", title: "reinforced", summary: nil, body: nil,
                source: nil, confidence: 80, impact: 5, tags: nil,
                createdAt: created.timeIntervalSince1970,
                updatedAt: created.timeIntervalSince1970, temporal: reinforced),
        ]
        XCTAssertNotNil(ordinary,
                        "fixture proves an ordinary matching envelope remains constructible")
        for (index, row) in rows.enumerated() {
            XCTAssertFalse(store.appendJSON(
                row, to: store.learningRoot + "/rejected-\(index).jsonl"),
                "unsafe generic temporal metadata must be rejected at append")
        }

        try write(try rows.map { try jsonLine($0) }.joined(separator: "\n") + "\n",
                  to: store.knowledgeIndexPath)
        let before = try mappedBytes(at: store.knowledgeIndexPath)
        XCTAssertEqual(store.loadJSONL(
            DiskMemoryRecord.self, path: store.knowledgeIndexPath).count, rows.count,
            "raw audit remains fail-soft and exposes independently decodable rows")
        XCTAssertNil(store.loadJSONLForMutation(
            DiskMemoryRecord.self, path: store.knowledgeIndexPath))
        let rejectedIDs = Set(rows.compactMap(\.id))
        XCTAssertTrue(Set(store.memoryCandidates(at: created).map(\.recordID))
            .isDisjoint(with: rejectedIDs))
        XCTAssertEqual(try mappedBytes(at: store.knowledgeIndexPath), before)
    }

    func testGenericMemoryExactHalfLifeHalvesCaptainRelevance() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let store = OrganizationalLearningStore(projectRoot: root, now: { created })
        XCTAssertTrue(store.appendGenericMemory(
            DiskMemoryRecord(
                id: "generic-half-life", title: "Temporal routing observation",
                summary: "A bounded advisory observation.", body: nil, source: nil,
                confidence: 80, impact: 5, tags: ["temporal"]),
            to: store.knowledgeIndexPath, decayRate: .medium, at: created))
        let halfLife = created.addingTimeInterval(
            MemoryDecayRate.medium.halfLifeDays * 86_400)

        let full = try XCTUnwrap(store.memoryCandidates(at: created).first {
            $0.recordID == "generic-half-life"
        })
        let half = try XCTUnwrap(store.memoryCandidates(at: halfLife).first {
            $0.recordID == "generic-half-life"
        })
        XCTAssertEqual(full.baseRelevance, 32)
        XCTAssertEqual(half.baseRelevance, 16)
        XCTAssertEqual(half.baseRelevance * 2, full.baseRelevance)
    }

    func testSeasonalGenericMemoryDisappearsAndReactivatesWithoutReadMutation() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let created = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 UTC
        let offSeason = Date(timeIntervalSince1970: 1_751_328_000) // 2025-07-01 UTC
        let nextSeason = Date(timeIntervalSince1970: 1_768_435_200) // 2026-01-15 UTC
        let season = try SeasonalMemoryWindow(
            months: [1], timeZoneIdentifier: "UTC",
            inSeasonBoost: 1.5, offSeasonFactor: 0)
        let store = OrganizationalLearningStore(projectRoot: root, now: { offSeason })
        XCTAssertTrue(store.appendGenericMemory(
            DiskMemoryRecord(
                id: "generic-january", title: "January release advisory",
                summary: "Run the January release checks.", body: nil, source: nil,
                confidence: 100, impact: 5, tags: ["release"]),
            to: store.knowledgeIndexPath, decayRate: .medium,
            seasonalWindow: season, at: created))
        let before = try mappedBytes(at: store.knowledgeIndexPath)

        XCTAssertTrue(store.memoryCandidates(at: created).contains {
            $0.recordID == "generic-january"
        })
        XCTAssertFalse(store.memoryCandidates(at: offSeason).contains {
            $0.recordID == "generic-january"
        })
        XCTAssertTrue(store.memoryCandidates(at: nextSeason).contains {
            $0.recordID == "generic-january"
        })
        XCTAssertEqual(try mappedBytes(at: store.knowledgeIndexPath), before,
                       "seasonal recall is a projection and must never reinforce on read")
    }

    func testGenericStableIDUpsertPreservesEvidenceAnchorSeasonAndNoReinforcement() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let created = Date(timeIntervalSince1970: 1_735_689_600)
        let updatedAt = created.addingTimeInterval(3_600)
        let season = try SeasonalMemoryWindow(
            months: [1], timeZoneIdentifier: "UTC",
            inSeasonBoost: 1.4, offSeasonFactor: 0.2)
        let store = OrganizationalLearningStore(projectRoot: root, now: { updatedAt })
        XCTAssertTrue(store.appendGenericMemory(
            DiskMemoryRecord(
                id: "stable-generic", title: "Original observation",
                summary: "Original body", body: nil, source: nil,
                confidence: 80, impact: 4, tags: ["original"]),
            to: store.knowledgeIndexPath, decayRate: .medium,
            seasonalWindow: season, at: created))
        let original = try XCTUnwrap(store.loadJSONL(
            DiskMemoryRecord.self, path: store.knowledgeIndexPath).first)
        let originalEnvelope = try XCTUnwrap(original.temporal)

        XCTAssertTrue(store.upsertGenericMemory(
            DiskMemoryRecord(
                id: "stable-generic", title: "Updated observation",
                summary: "Updated body", body: nil, source: nil,
                confidence: 90, impact: 5, tags: ["updated"]),
            to: store.knowledgeIndexPath, decayRate: .medium, at: updatedAt))
        let records = store.loadJSONL(
            DiskMemoryRecord.self, path: store.knowledgeIndexPath)
        XCTAssertEqual(records.count, 1)
        let updated = try XCTUnwrap(records.first)
        let envelope = try XCTUnwrap(updated.temporal)
        XCTAssertEqual(updated.title, "Updated observation")
        XCTAssertEqual(updated.createdAt, original.createdAt)
        XCTAssertEqual(updated.updatedAt,
                       OrganizationalMemoryTemporal.canonicalInstant(updatedAt)
                        .timeIntervalSince1970)
        XCTAssertEqual(envelope.createdAt, originalEnvelope.createdAt)
        XCTAssertEqual(envelope.updatedAt,
                       OrganizationalMemoryTemporal.canonicalInstant(updatedAt))
        XCTAssertEqual(envelope.accessedAt, originalEnvelope.accessedAt)
        XCTAssertEqual(envelope.lastConfirmedAt, originalEnvelope.lastConfirmedAt)
        XCTAssertEqual(envelope.seasonalWindow, season)
        XCTAssertEqual(envelope.decayRate, .medium)
        XCTAssertEqual(envelope.accessCount, 0)
        XCTAssertEqual(envelope.reinforcementCount, 0)
    }

    func testGenericDuplicateDedupeUsesNewestEligibleObservation() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldAt = now.addingTimeInterval(-1_000)
        let newerAt = now.addingTimeInterval(-100)
        let newestAt = now.addingTimeInterval(-10)
        let store = OrganizationalLearningStore(projectRoot: root, now: { now })
        XCTAssertTrue(store.appendGenericMemory(
            DiskMemoryRecord(
                id: "duplicate-generic", title: "Old eligible", summary: nil,
                body: nil, source: nil, confidence: 80, impact: 5, tags: nil),
            to: store.knowledgeIndexPath, decayRate: .medium, at: oldAt))
        XCTAssertTrue(store.appendGenericMemory(
            DiskMemoryRecord(
                id: "duplicate-generic", title: "New eligible", summary: nil,
                body: nil, source: nil, confidence: 80, impact: 5, tags: nil),
            to: store.knowledgeIndexPath, decayRate: .medium, at: newerAt))
        let notYet = try MemoryTemporalEnvelope(
            createdAt: newestAt, validFrom: now.addingTimeInterval(60),
            decayRate: .medium)
        XCTAssertTrue(store.appendJSON(
            DiskMemoryRecord(
                id: "duplicate-generic", title: "Newest but not yet valid",
                summary: nil, body: nil, source: nil, confidence: 100, impact: 5,
                tags: nil, createdAt: newestAt.timeIntervalSince1970,
                updatedAt: newestAt.timeIntervalSince1970, temporal: notYet),
            to: store.knowledgeIndexPath))

        XCTAssertEqual(store.loadJSONL(
            DiskMemoryRecord.self, path: store.knowledgeIndexPath).count, 3)
        let candidates = store.memoryCandidates(at: now).filter {
            $0.recordID == "duplicate-generic"
        }
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.title, "New eligible")
    }

    func testUnindexedResearchArchiveIsExcludedFromOperationalRecall() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = OrganizationalLearningStore(projectRoot: root, now: { now })
        let artifactPath = store.researchArchiveRoot + "/unindexed-seasonal-study.md"
        try write("# Unindexed study\nunique-unindexed-research-conclusion\n",
                  to: artifactPath)
        let before = try mappedBytes(at: artifactPath)

        XCTAssertTrue(store.rawResearchArchiveAuditCandidates(limit: 10).contains {
            $0.excerpt.contains("unique-unindexed-research-conclusion")
        }, "the raw archive remains available to an explicit audit reader")
        let operational = store.memoryCandidates(at: now)
        XCTAssertFalse(operational.contains { $0.layerID == .researchArchive })
        XCTAssertFalse(operational.contains {
            $0.excerpt.contains("unique-unindexed-research-conclusion")
        })
        XCTAssertEqual(try mappedBytes(at: artifactPath), before)
    }

    func testRawResearchAuditRefusesSymlinkHardlinkAndOversizedArtifacts() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = OrganizationalLearningStore(projectRoot: root)
        try FileManager.default.createDirectory(
            atPath: store.researchArchiveRoot, withIntermediateDirectories: true)

        let symlinkTarget = root + "/outside-symlink.md"
        try write("symlink-secret-marker\n", to: symlinkTarget)
        try FileManager.default.createSymbolicLink(
            atPath: store.researchArchiveRoot + "/symlink.md",
            withDestinationPath: symlinkTarget)

        let hardlinkTarget = root + "/outside-hardlink.md"
        try write("hardlink-secret-marker\n", to: hardlinkTarget)
        try FileManager.default.linkItem(
            atPath: hardlinkTarget,
            toPath: store.researchArchiveRoot + "/hardlink.md")

        try write(String(repeating: "z", count: 1_024 * 1_024 + 1),
                  to: store.researchArchiveRoot + "/oversized.md")

        let audit = store.rawResearchArchiveAuditCandidates(limit: 40)
        XCTAssertFalse(audit.contains { $0.excerpt.contains("symlink-secret-marker") })
        XCTAssertFalse(audit.contains { $0.excerpt.contains("hardlink-secret-marker") })
        XCTAssertFalse(audit.contains { $0.title.contains("oversized") })
    }

    func testEvidenceLedgerRecallDecaysWithoutDeletingRawEvidence() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let store = OrganizationalLearningStore(projectRoot: root, now: { created })
        let evidence = LearningEvidenceRecord(
            id: "evidence-decay", kind: .selfHealSpecialist,
            objective: "verify temporal recall", specialistName: "evidence-probe",
            role: "verification", preferredModel: "gpt",
            artifactPath: ".kist/learning/self-heal/evidence-probe.md",
            memoryRecorded: true, taskIDs: [32], taskEvidenceUpdated: 1,
            createdAt: created.timeIntervalSince1970)
        XCTAssertTrue(store.appendJSON(evidence, to: store.evidenceLedgerPath))
        let before = try mappedBytes(at: store.evidenceLedgerPath)
        let halfLife = created.addingTimeInterval(
            MemoryDecayRate.slow.halfLifeDays * 86_400)
        let faded = created.addingTimeInterval(
            MemoryDecayRate.slow.halfLifeDays * 6 * 86_400)

        let full = try XCTUnwrap(store.evidenceLedgerCandidates(
            limit: 10, at: created).first { $0.recordID == evidence.id })
        let half = try XCTUnwrap(store.evidenceLedgerCandidates(
            limit: 10, at: halfLife).first { $0.recordID == evidence.id })
        XCTAssertEqual(full.baseRelevance, 32)
        XCTAssertEqual(half.baseRelevance, 16)
        XCTAssertFalse(store.evidenceLedgerCandidates(limit: 10, at: faded).contains {
            $0.recordID == evidence.id
        })
        XCTAssertEqual(store.evidenceLedger(limit: 10), [evidence],
                       "recall decay must never delete the durable evidence ledger")
        XCTAssertEqual(try mappedBytes(at: store.evidenceLedgerPath), before)
    }

    func testUnboundedDecodedValuesAreClampedBeforeCaptainArithmetic() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = OrganizationalLearningStore(projectRoot: root, now: { now })
        let debt = KnowledgeDebtRecord(
            id: "unbounded-debt",
            topic: String(repeating: "x", count: 10_000),
            reason: "overflow regression",
            visit: "docs",
            impact: Int.max,
            priority: .high,
            estimatedLearning: "unknown",
            expectedBenefit: Array(repeating: "benefit", count: 1_000),
            sourceCapsuleID: nil,
            status: .open,
            createdAt: now.timeIntervalSince1970,
            updatedAt: now.timeIntervalSince1970)
        XCTAssertTrue(store.appendJSON(debt, to: store.debtPath))
        XCTAssertTrue(store.appendGenericMemory(
            DiskMemoryRecord(id: "unbounded-generic", title: "generic overflow",
                             summary: nil, body: nil, source: nil,
                             confidence: Int.max, impact: Int.max, tags: nil),
            to: store.knowledgeIndexPath, decayRate: .medium, at: now))

        let loaded = try XCTUnwrap(store.openKnowledgeDebt().first)
        XCTAssertEqual(loaded.impact, 5)
        XCTAssertEqual(loaded.topic.count, 2_048)
        XCTAssertEqual(loaded.expectedBenefit.count, 64)
        let candidates = store.memoryCandidates(at: now)
        XCTAssertTrue(candidates.contains { $0.recordID == debt.id })
        XCTAssertTrue(candidates.contains { $0.recordID == "unbounded-generic" })
        XCTAssertTrue(candidates.allSatisfy { (0...100).contains($0.baseRelevance) })
    }

    func testRewriteRefusesMalformedLedgerAndPreservesExactBytes() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let store = OrganizationalLearningStore(projectRoot: root)
        let existing = makeDebt(id: "existing", at: instant)
        let replacement = makeDebt(id: "replacement", at: instant)
        try write(try jsonLine(existing) + "\n{malformed-json\n", to: store.debtPath)
        let before = try mappedBytes(at: store.debtPath)

        XCTAssertEqual(store.loadJSONL(
            KnowledgeDebtRecord.self, path: store.debtPath).map(\.id), ["existing"],
            "raw audit reads remain fail-soft around a malformed physical row")
        XCTAssertFalse(store.upsert(replacement))
        XCTAssertEqual(try mappedBytes(at: store.debtPath), before)
    }

    func testPublicMutationAPIsReportRefusalAndDoNotCreateFollowOnDebt() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = OrganizationalLearningStore(projectRoot: root)

        try write("{malformed-rule\n", to: store.rulesPath)
        let ruleBefore = try mappedBytes(at: store.rulesPath)
        XCTAssertNil(store.promoteOrganizationalRule(
            lesson: "A refused rule write must never be reported as taught.",
            confidence: 100,
            evidence: ["receipt:a", "receipt:b"]))
        XCTAssertEqual(try mappedBytes(at: store.rulesPath), ruleBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.debtPath),
                       "a refused rule must not seed follow-on debt")

        try write("{malformed-debt\n", to: store.debtPath)
        let debtBefore = try mappedBytes(at: store.debtPath)
        XCTAssertNil(store.addKnowledgeDebt(topic: "Refused persistence"))
        XCTAssertEqual(try mappedBytes(at: store.debtPath), debtBefore)
    }

    func testRewriteRefusesOneHundredThousandAndOneRowsWithoutTruncation() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let store = OrganizationalLearningStore(projectRoot: root)
        let existing = makeDebt(id: "existing", at: instant)
        let replacement = makeDebt(id: "replacement", at: instant)
        try writeRepeatedJSONLine(
            try jsonLine(existing),
            count: OrganizationalLearningStore.maximumJSONLRows + 1,
            to: store.debtPath)
        let before = try mappedBytes(at: store.debtPath)

        XCTAssertFalse(store.upsert(replacement))
        XCTAssertEqual(try mappedBytes(at: store.debtPath), before)
    }

    func testRewriteRefusesOversizedLineAndFileWithoutTruncation() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let store = OrganizationalLearningStore(projectRoot: root)
        let existing = makeDebt(id: "existing", at: instant)
        var oversizedLine = makeDebt(id: "oversized-line", at: instant)
        oversizedLine.reason = String(
            repeating: "x", count: OrganizationalLearningStore.maximumJSONLLineBytes)
        try write(try jsonLine(existing) + "\n" + jsonLine(oversizedLine) + "\n",
                  to: store.debtPath)
        let lineBefore = try mappedBytes(at: store.debtPath)

        XCTAssertFalse(store.markKnowledgeDebtDone(existing.id))
        XCTAssertEqual(try mappedBytes(at: store.debtPath), lineBefore)

        try write(try jsonLine(existing) + "\n", to: store.debtPath)
        do {
            let handle = try FileHandle(
                forWritingTo: URL(fileURLWithPath: store.debtPath))
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(
                OrganizationalLearningStore.maximumJSONLFileBytes + 1))
        }
        let fileBefore = try mappedBytes(at: store.debtPath)
        XCTAssertFalse(store.upsert(makeDebt(id: "replacement", at: instant)))
        XCTAssertEqual(try mappedBytes(at: store.debtPath), fileBefore)
    }

    func testGiantCombiningGraphemeIsBoundedByUTF8BytesOnDecodeAndEncode() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let raw = "e" + String(repeating: "\u{0301}", count: 100_000)
        XCTAssertEqual(raw.count, 1, "the regression fixture is one extended grapheme")
        var debt = makeDebt(id: "giant-grapheme", at: instant)
        debt.topic = raw
        let store = OrganizationalLearningStore(projectRoot: root)

        let maliciousPath = store.learningRoot + "/giant-raw.jsonl"
        try write(try jsonLine(debt) + "\n", to: maliciousPath)
        let decoded = try XCTUnwrap(store.loadJSONL(
            KnowledgeDebtRecord.self, path: maliciousPath).first)
        XCTAssertLessThanOrEqual(decoded.topic.utf8.count, 2_048)
        XCTAssertFalse(decoded.topic.contains("\u{FFFD}"))

        let encodedPath = store.learningRoot + "/giant-encoded.jsonl"
        XCTAssertTrue(store.appendJSON(debt, to: encodedPath))
        let encoded = try mappedBytes(at: encodedPath)
        XCTAssertLessThanOrEqual(encoded.count,
                                 OrganizationalLearningStore.maximumJSONLLineBytes + 1)
        let roundTrip = try XCTUnwrap(store.loadJSONL(
            KnowledgeDebtRecord.self, path: encodedPath).first)
        XCTAssertLessThanOrEqual(roundTrip.topic.utf8.count, 2_048)
        XCTAssertFalse(roundTrip.topic.contains("\u{FFFD}"))
    }

    func testRetrievalIncludesCaptainLearningBenchmarkEvidence() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_300)
        let samples = (0..<3).map { i in
            CaptainLearningSample(taskSignature: "fix Swift routing eval with tests",
                                  taskTags: ["coding", "reasoning", "verification"],
                                  language: "Swift",
                                  role: "coder",
                                  providerId: "deepseek",
                                  model: "deepseek-chat",
                                  source: i == 0 ? .benchmark : .liveEval,
                                  success: true,
                                  judgeScore: 0.91,
                                  tokens: 1_200 + i,
                                  latencyMs: 3_000 + i,
                                  toolFailures: 0,
                                  atEpoch: 1_700_000_000 + Double(i))
        }
        CaptainLearningStore(projectRoot: root).record(samples)

        let text = KistREPL.handleRetrieveCommand("improve Swift routing eval benchmarks",
                                                  projectRoot: root, now: { fixedNow })

        XCTAssertTrue(text.contains("Unsigned Scorecard Observations: deepseek for coder"))
        XCTAssertEqual(text.components(
            separatedBy: "Unsigned Scorecard Observations: deepseek for coder").count - 1, 1)
        XCTAssertTrue(text.contains("Source: .kist/captain-learning.jsonl"))
        XCTAssertTrue(text.contains("Status: route-bias eligible"))
        XCTAssertTrue(text.contains("Success: 3/3"))
        XCTAssertTrue(text.contains("Benchmark Gate"))
    }

    func testCaptainLearningReportShowsPromotionAndShadowEvidence() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_300)
        let store = CaptainLearningStore(projectRoot: root)
        store.record((0..<3).map { i in
            CaptainLearningSample(taskSignature: "fix Swift routing eval with tests",
                                  taskTags: ["coding", "reasoning"],
                                  language: "Swift",
                                  role: "coder",
                                  providerId: "deepseek",
                                  model: "deepseek-chat",
                                  source: .liveEval,
                                  success: true,
                                  judgeScore: 0.9,
                                  tokens: 1_000,
                                  latencyMs: 2_000,
                                  toolFailures: 0,
                                  atEpoch: 1_700_000_100 + Double(i))
        })
        store.record(CaptainLearningSample(taskSignature: "research docs",
                                           taskTags: ["research"],
                                           language: nil,
                                           role: "worker",
                                           providerId: "gemini",
                                           model: "gemini-2.5-flash",
                                           source: .benchmark,
                                           success: true,
                                           tokens: 500,
                                           latencyMs: 900,
                                           toolFailures: 0,
                                           atEpoch: 1_700_000_200))

        let text = KistREPL.handleCaptainLearningCommand(
            "", projectRoot: root, now: { fixedNow })

        XCTAssertTrue(text.contains("Captain Learning"))
        XCTAssertTrue(text.contains("Unsigned route-bias eligibility gate"))
        XCTAssertTrue(text.contains("Unsigned Route-Bias Profiles"))
        XCTAssertTrue(text.contains("deepseek / coder"))
        XCTAssertTrue(text.contains("status=route-bias-eligible"))
        XCTAssertTrue(text.contains("Unsigned Shadow Profiles"))
        XCTAssertTrue(text.contains("gemini / worker"))
        XCTAssertTrue(text.contains("status=shadow-only"))
        XCTAssertTrue(text.contains("How Captain uses this"))
    }

    func testCaptainLearningReportExplainsColdStart() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let text = KistREPL.handleCaptainLearningCommand("", projectRoot: root)

        XCTAssertTrue(text.contains("No benchmark or live-eval samples yet."))
        XCTAssertTrue(text.contains("Run `/bench <task>` or `/eval <task>`"))
    }

    func testStrategicIntelligenceCommandShowsRecordsAfterEvolve() {
        let base = tempRoot()
        let root = base + "/kist-loops"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let plan = Plan(title: "Kist Strategic Intelligence",
                        tasks: [PlanTask(id: 1,
                                         title: "ACTION: build Strategic Intelligence",
                                         detail: "compare Kist against competitors, papers, standards, and benchmarks",
                                         kind: .action)])
        PlanStore(projectRoot: root).save(plan)
        let store = OrganizationalLearningStore(projectRoot: root,
                                                now: { Date(timeIntervalSince1970: 1_700_000_123) },
                                                specialistRegistry: {
                                                    SpecialistRegistry(projectRoot: $0, userDir: nil,
                                                                       claudeUserDir: nil)
                                                })

        _ = store.runBoardMeeting(plan: plan, trajectory: [])
        let text = KistREPL.handleStrategicIntelligenceCommand("", projectRoot: root)

        XCTAssertTrue(text.contains("Strategic Intelligence"))
        XCTAssertTrue(text.contains("Industry Radar"))
        XCTAssertTrue(text.contains("Evolution Proposals"))
        XCTAssertTrue(text.contains("Claude Code subagents"))
        XCTAssertTrue(text.contains("Strategic Intelligence must compare Kist"))
    }

    func testStrategicArchiveWriteFailurePublishesNoGenericMemory() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fixedNow = Date(timeIntervalSince1970: 1_700_003_900)
        let store = OrganizationalLearningStore(projectRoot: root, now: { fixedNow })
        store.ensureMemoryArchitecture()
        XCTAssertTrue(store.appendGenericMemory(
            DiskMemoryRecord(
                id: "industry-failure-sentinel", title: "Existing industry memory",
                summary: "Must remain byte-identical.", body: nil, source: nil,
                confidence: 80, impact: 4, tags: ["sentinel"]),
            to: store.industryIntelligencePath, decayRate: .fast, at: fixedNow))
        XCTAssertTrue(store.appendGenericMemory(
            DiskMemoryRecord(
                id: "proposal-failure-sentinel", title: "Existing proposal memory",
                summary: "Must remain byte-identical.", body: nil, source: nil,
                confidence: 80, impact: 4, tags: ["sentinel"]),
            to: store.evolutionProposalsPath, decayRate: .medium, at: fixedNow))
        let industryBefore = try mappedBytes(at: store.industryIntelligencePath)
        let proposalsBefore = try mappedBytes(at: store.evolutionProposalsPath)
        try write("not a directory",
                  to: store.researchArchiveRoot + "/strategic-intelligence")
        let snapshot = StrategicIntelligenceSnapshot(
            id: "SI-write-failure",
            objective: "prove archive-first strategic memory",
            generatedAt: fixedNow.timeIntervalSince1970,
            sourceTargets: [StrategicIntelligenceTarget(
                id: "strategic-target-must-not-publish",
                title: "Unpublished strategic target",
                category: .benchmark,
                priority: .high,
                sourceTarget: "https://example.invalid/strategic-source",
                compareAgainst: ["current runtime"],
                researchQuestion: "Does artifact persistence precede indexing?",
                reason: "A failed archive cannot support an operational conclusion.",
                likelyKistGap: "Indexing before persistence",
                expectedImpact: 5,
                benchmarkPlan: "Force archive persistence failure.",
                proposedEvolution: "Publish memory only after the archive exists.")],
            proposals: [StrategicEvolutionProposal(
                id: "strategic-proposal-must-not-publish",
                title: "Unpublished strategic proposal",
                reason: "The archive write was forced to fail.",
                expectedImpact: 5,
                evidenceNeeded: ["persisted archive"],
                benchmarkPlan: "Verify both JSONL shelves are unchanged.",
                teachableRule: "Strategic memory requires a persisted archive.")],
            assumptionsToChallenge: [],
            questions: [])

        XCTAssertFalse(store.writeStrategicArchive(snapshot))
        XCTAssertEqual(store.recordStrategicIntelligence(snapshot), 0)
        XCTAssertEqual(try mappedBytes(at: store.industryIntelligencePath), industryBefore)
        XCTAssertEqual(try mappedBytes(at: store.evolutionProposalsPath), proposalsBefore)
        XCTAssertFalse(store.loadJSONL(
            DiskMemoryRecord.self, path: store.industryIntelligencePath).contains {
                $0.id == "strategic-target-must-not-publish"
            })
        XCTAssertFalse(store.loadJSONL(
            DiskMemoryRecord.self, path: store.evolutionProposalsPath).contains {
                $0.id == "strategic-proposal-must-not-publish"
            })
    }

    func testDomainLearningPreflightWritesDossierSeedsGatesAndSpecialists() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "MedicalFixture")
        """, to: root + "/Package.swift")
        PlanStore(projectRoot: root).save(Plan(title: "Unfamiliar Domain",
                                               tasks: [PlanTask(id: 1,
                                                                title: "ACTION: build unfamiliar platform",
                                                                detail: "medical imaging",
                                                                kind: .action)]))
        let fixedNow = Date(timeIntervalSince1970: 1_700_004_000)
        let store = OrganizationalLearningStore(projectRoot: root,
                                                now: { fixedNow },
                                                specialistRegistry: {
                                                    SpecialistRegistry(projectRoot: $0, userDir: nil,
                                                                       claudeUserDir: nil)
                                                })

        let report = store.runDomainLearningPreflight(
            plan: PlanStore(projectRoot: root).load(),
            trajectory: [ActionRecord(tool: "read_file", argsFingerprint: "a", success: true)],
            objective: "build a medical imaging platform with DICOM HIPAA Hugging Face local models and symbolic workflow rules")

        XCTAssertTrue(report.text.contains("Captain Domain Learning Preflight"))
        XCTAssertTrue(report.text.contains("Research before expertise. Expertise before organization. Organization before execution."))
        XCTAssertTrue(report.text.contains("Temporary Subject-Matter Expert Gate"))
        XCTAssertTrue(report.text.contains("HOLD: Captain is not qualified yet."))
        XCTAssertTrue(report.text.contains("Safe Local Model Acquisition"))
        XCTAssertTrue(report.text.contains("Symbolic Rule Path"))
        XCTAssertLessThan(report.understandingConfidence, report.confidenceThreshold)
        XCTAssertFalse(report.canExecute)
        XCTAssertGreaterThanOrEqual(report.seededTasks, 9)
        XCTAssertGreaterThanOrEqual(report.knowledgeDebtCreated, 8)
        XCTAssertGreaterThanOrEqual(report.createdSpecialists, 5)
        XCTAssertEqual(report.memoryRecords, 1)
        XCTAssertTrue(report.writeSucceeded)
        XCTAssertNil(report.writeError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + report.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/agents/domain-research-lead.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/agents/domain-architecture-critic.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/agents/simulation-and-risk-engineer.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/agents/local-model-scout.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/agents/symbolic-rule-compiler.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/agents/regulated-domain-researcher.md"))

        let seeded = PlanStore(projectRoot: root).load()
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .plan && $0.owner == "captain" && $0.status == .inProgress })
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .research && $0.owner == "domain-research-lead" })
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .decision && $0.boardTitle.contains("Temporary subject-matter expert gate") })
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .handoff && $0.owner == "captain" })
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .test && $0.owner == "simulation-and-risk-engineer" })
        XCTAssertTrue(seeded.tasks.contains { $0.kind == .review && $0.owner == "domain-architecture-critic" })
        XCTAssertTrue(seeded.tasks.contains { $0.owner == "local-model-scout" })
        XCTAssertTrue(seeded.tasks.contains { $0.owner == "symbolic-rule-compiler" })

        let retrieve = KistREPL.handleRetrieveCommand(
            "medical imaging DICOM domain learning", projectRoot: root,
            now: { fixedNow })
        XCTAssertTrue(retrieve.contains("Domain Learning Preflight"), retrieve)
        XCTAssertTrue(retrieve.contains("Research Gate"))

        _ = store.runDomainLearningPreflight(plan: PlanStore(projectRoot: root).load(),
                                             trajectory: [],
                                             objective: report.objective)
        let knowledgeIndex = try String(contentsOfFile: root + "/.kist/learning/knowledge-index.jsonl",
                                        encoding: .utf8)
        let domainRecordLines = knowledgeIndex.split(separator: "\n").filter {
            $0.contains(#""id":"AA-domain-learning-"#)
        }
        XCTAssertEqual(domainRecordLines.count, 1)
    }

    func testDomainLearningReportWriteFailurePublishesNoGenericMemory() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fixedNow = Date(timeIntervalSince1970: 1_700_004_050)
        let store = OrganizationalLearningStore(
            projectRoot: root, now: { fixedNow },
            specialistRegistry: {
                SpecialistRegistry(projectRoot: $0, userDir: nil, claudeUserDir: nil)
            })
        store.ensureMemoryArchitecture()
        XCTAssertTrue(store.appendGenericMemory(
            DiskMemoryRecord(
                id: "domain-failure-sentinel", title: "Existing generic memory",
                summary: "Must remain byte-identical.", body: nil, source: nil,
                confidence: 80, impact: 4, tags: ["sentinel"]),
            to: store.knowledgeIndexPath, decayRate: .medium, at: fixedNow))
        let before = try mappedBytes(at: store.knowledgeIndexPath)
        try write("not a directory",
                  to: store.researchArchiveRoot + "/domain-learning")
        let plan = Plan(
            title: "Domain write-failure probe",
            tasks: [PlanTask(
                id: 1, title: "ACTION: learn an unfamiliar regulated domain",
                detail: "prove report persistence precedes generic indexing", kind: .action)])

        let report = store.runDomainLearningPreflight(
            plan: plan, trajectory: [],
            objective: "medical imaging report persistence failure")

        XCTAssertFalse(report.writeSucceeded)
        XCTAssertNotNil(report.writeError)
        XCTAssertEqual(report.memoryRecords, 0)
        XCTAssertEqual(try mappedBytes(at: store.knowledgeIndexPath), before)
        XCTAssertEqual(store.loadJSONL(
            DiskMemoryRecord.self, path: store.knowledgeIndexPath).map(\.id),
            ["domain-failure-sentinel"])
    }

    func testDomainLearningSpecialistOutputIsArchivedIndexedAndAttachedToTasks() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "SpecialistOutputFixture")
        """, to: root + "/Package.swift")
        let store = OrganizationalLearningStore(projectRoot: root,
                                                now: { Date(timeIntervalSince1970: 1_700_004_100) },
                                                specialistRegistry: {
                                                    SpecialistRegistry(projectRoot: $0, userDir: nil,
                                                                       claudeUserDir: nil)
                                                })
        let report = store.runDomainLearningPreflight(
            plan: PlanStore(projectRoot: root).load(),
            trajectory: [],
            objective: "learn medical imaging workflow before execution")
        let assignment = try XCTUnwrap(report.agentAssignments.first { $0.specialistName == "domain-research-lead" })

        let artifact = try XCTUnwrap(store.recordDomainLearningSpecialistOutput(
            objective: report.objective,
            assignment: assignment,
            summary: "DICOM evidence captured. secret sk-abcdefghijklmnopqrstuvwxyzABCDEFGH123456 should be redacted."))

        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + artifact.path))
        XCTAssertTrue(artifact.memoryRecorded)
        XCTAssertGreaterThan(artifact.taskEvidenceUpdated, 0)
        XCTAssertEqual(artifact.updatedTaskIDs.count, artifact.taskEvidenceUpdated)
        XCTAssertTrue(artifact.evidenceLedgerRecorded)
        let text = try String(contentsOfFile: root + "/" + artifact.path, encoding: .utf8)
        XCTAssertTrue(text.contains("Domain Learning Specialist Output"))
        XCTAssertTrue(text.contains("DICOM evidence captured"))
        XCTAssertFalse(text.contains("sk-abcdefghijklmnopqrstuvwxyzABCDEFGH123456"))

        let plan = PlanStore(projectRoot: root).load()
        XCTAssertTrue(plan.tasks.contains {
            $0.owner == "domain-research-lead" && $0.evidence.contains(artifact.path)
        }, plan.render())
        let ledgerLines = try String(contentsOfFile: root + "/.kist/learning/evidence-ledger.jsonl",
                                     encoding: .utf8)
            .split(separator: "\n")
        let ledger = try XCTUnwrap(ledgerLines.compactMap {
            try? JSONDecoder().decode(LearningEvidenceRecord.self, from: Data($0.utf8))
        }.last)
        XCTAssertEqual(ledger.kind, .domainLearningSpecialist)
        XCTAssertEqual(ledger.specialistName, "domain-research-lead")
        XCTAssertEqual(ledger.artifactPath, artifact.path)
        XCTAssertEqual(ledger.taskIDs, artifact.updatedTaskIDs)
        XCTAssertEqual(ledger.taskEvidenceUpdated, artifact.taskEvidenceUpdated)
        XCTAssertTrue(ledger.memoryRecorded)
        let retrieved = KistREPL.handleRetrieveCommand("domain-research-lead DICOM evidence",
                                                       projectRoot: root)
        XCTAssertTrue(retrieved.contains("Domain Learning Specialist") || retrieved.contains("DICOM evidence"),
                      retrieved)
    }

    func testDomainLearningCommandAndCaptainLearnAlias() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let report = KistREPL.handleDomainLearningCommand("research-first medical imaging",
                                                          projectRoot: root)

        XCTAssertTrue(KistREPL.isDomainLearningIntent("learn medical imaging"))
        XCTAssertTrue(KistREPL.isDomainLearningIntent("research-first medical imaging"))
        XCTAssertTrue(KistREPL.domainLearningShouldRun("domain run medical imaging"))
        XCTAssertEqual(KistREPL.normalizedDomainLearningObjective("domain run medical imaging"),
                       "medical imaging")
        XCTAssertFalse(KistREPL.domainLearningShouldRun("domain learn how to run migrations"))
        XCTAssertEqual(KistREPL.normalizedDomainLearningObjective("domain learn how to run migrations"),
                       "learn how to run migrations")
        XCTAssertTrue(report.text.contains("Captain Domain Learning Preflight"))
        XCTAssertTrue(report.dispatchCommand.hasPrefix("/domain run"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/domain"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/domain-learning"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/research-first"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/sme"))
    }

    func testCaptainCommandRendersStrategyBrief() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let text = KistREPL.handleCaptainStrategyCommand("research-first Captain orchestration", projectRoot: root)

        XCTAssertTrue(text.contains("CAPTAIN STRATEGY PIPELINE"))
        XCTAssertTrue(text.contains("CAPTAIN MEMORY ARCHITECTURE"))
        XCTAssertTrue(text.contains("CAPTAIN RETRIEVAL CONTEXT"))
        XCTAssertTrue(text.contains("DECISION CARDS"))
        XCTAssertTrue(text.contains("RESEARCH QUESTIONS"))
        XCTAssertTrue(text.contains("agent-orchestration-architect"))
    }
}
