import Foundation
import Dispatch
import AgentCore

struct CaptainSelfTestCheck: Sendable, Equatable {
    enum Status: String, Sendable, Codable, Equatable {
        case pass = "PASS"
        case warn = "WARN"
        case fail = "FAIL"
    }

    var title: String
    var status: Status
    var detail: String
    var fix: String
    var evidence: [String]
}

struct CaptainSelfTestReport: Sendable, Equatable {
    var path: String
    var text: String
    var checks: [CaptainSelfTestCheck]
    var seededTasks: Int
    var recommendedCommands: [String]
    var writeSucceeded: Bool
    var writeError: String?

    var failures: Int { checks.filter { $0.status == .fail }.count }
    var warnings: Int { checks.filter { $0.status == .warn }.count }
    var passed: Int { checks.filter { $0.status == .pass }.count }
}

struct CaptainSelfTestSuite: Sendable {
    let projectRoot: String
    private let now: @Sendable () -> Date

    init(projectRoot: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.projectRoot = ToolContext.canonicalize(projectRoot) ?? projectRoot
        self.now = now
    }

    func run(seedFindings: Bool = false) -> CaptainSelfTestReport {
        var checks = buildChecks()
        let timestamp = Int(now().timeIntervalSince1970)
        let root = projectRoot + "/.kist/learning/self-tests"
        let path = root + "/\(timestamp)-\(UUID().uuidString.lowercased().prefix(8))-self-test.md"
        let relativePath = Self.relative(path, root: projectRoot)
        let commands = recommendedCommands()
        var text = render(checks: checks,
                          reportPath: relativePath,
                          seededTasks: 0,
                          seedFindings: seedFindings,
                          recommendedCommands: commands)
        var writeSucceeded = false
        var writeError: String?
        do {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            writeSucceeded = true
        } catch {
            writeError = String(describing: error)
            let persistence = CaptainSelfTestCheck(title: "Self-test report persistence",
                                                   status: .fail,
                                                   detail: "Could not write report \(relativePath): \(writeError ?? "unknown error").",
                                                   fix: "Restore write access to .kist/learning/self-tests before relying on self-test evidence.",
                                                   evidence: [relativePath])
            checks.append(persistence)
            text = render(checks: checks,
                          reportPath: relativePath,
                          seededTasks: 0,
                          seedFindings: seedFindings,
                          recommendedCommands: commands)
        }
        var seeded = 0
        if writeSucceeded && seedFindings {
            seeded = seedTasks(for: checks, reportPath: relativePath)
            text = render(checks: checks,
                          reportPath: relativePath,
                          seededTasks: seeded,
                          seedFindings: seedFindings,
                          recommendedCommands: commands)
            try? (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        return CaptainSelfTestReport(path: relativePath,
                                     text: text,
                                     checks: checks,
                                     seededTasks: seeded,
                                     recommendedCommands: commands,
                                     writeSucceeded: writeSucceeded,
                                     writeError: writeError)
    }

    private func buildChecks() -> [CaptainSelfTestCheck] {
        var checks: [CaptainSelfTestCheck] = []
        checks.append(fileCheck("Swift package manifest",
                                path: "Package.swift",
                                failFix: "Run self-test from the Kist source root or teach Captain the project test entrypoint."))
        checks.append(fileCheck("Simulation enforcer source",
                                path: "Sources/Kist/UX/CaptainSimulationEnforcer.swift",
                                failFix: "Restore the mandatory simulation enforcement layer before fleet/plan-execute changes."))
        checks.append(fileCheck("Domain learning enforcer source",
                                path: "Sources/Kist/UX/CaptainDomainLearningEnforcer.swift",
                                failFix: "Restore the mandatory domain-learning preflight before fleet/plan-execute changes."))
        checks.append(fileCheck("Local model scout source",
                                path: "Sources/Kist/UX/LocalModelScout.swift",
                                failFix: "Restore safe local/Hugging Face model scouting before any model acquisition work."))
        checks.append(fileCheck("Live model metadata gate source",
                                path: "Sources/Kist/UX/LiveModelMetadataGate.swift",
                                failFix: "Restore live metadata/license/provenance gating before any model download."))
        checks.append(fileCheck("Symbolic workflow compiler source",
                                path: "Sources/Kist/UX/SymbolicWorkflowCompiler.swift",
                                failFix: "Restore workflow compilation before promoting gates into rulebook policy."))
        checks.append(fileCheck("Kist runner source",
                                path: "Sources/Kist/KistRunner.swift",
                                failFix: "Restore KistRunner source so Captain can audit launch-order gates."))
        checks.append(fileCheck("Continuous supervisor source",
                                path: "Sources/AgentCore/FleetSupervisor.swift",
                                failFix: "Restore FleetSupervisor before adding autonomous worker layers."))
        checks.append(fileCheck("Required OS sandbox runner source",
                                path: "Sources/AgentCore/Tools/SandboxedProcessRunner.swift",
                                failFix: "Restore the required OS sandbox runner before allowing executable simulations or generated tools."))
        checks.append(fileCheck("Custom tool source",
                                path: "Sources/AgentCore/Tools/CustomTool.swift",
                                failFix: "Restore custom_tool so generated helper tools can run through required OS sandboxing."))
        checks.append(fileCheck("Document export source",
                                path: "Sources/Kist/DocumentExport.swift",
                                failFix: "Restore local PDF/RTF export before routing document-export requests through a model."))
        checks.append(fileCheck("Model substitution source",
                                path: "Sources/Kist/KistREPL+ModelSubstitution.swift",
                                failFix: "Restore model substitution failover before relying on automatic recovery from provider refusals or malformed model turns."))
        checks.append(fileCheck("Safety regression tests",
                                path: "Tests/KistTests/KistRunnerSafetyTests.swift",
                                failFix: "Add or restore KistRunnerSafetyTests before changing autonomy gates."))
        checks.append(contentsOf: runnerOrderChecks())
        checks.append(contentsOf: testCoverageChecks())
        checks.append(contentsOf: documentExportChecks())
        checks.append(contentsOf: modelSubstitutionChecks())
        checks.append(contentsOf: continuousSupervisorChecks())
        checks.append(contentsOf: supervisorRecoveryAndBoardHardeningChecks())
        checks.append(contentsOf: immuneSystemChecks())
        checks.append(contentsOf: liveImmuneSystemChecks())
        checks.append(contentsOf: blackboardDurabilityChecks())
        checks.append(contentsOf: selfHealChecks())
        checks.append(contentsOf: boardHealthChecks())
        return checks
    }

    private func fileCheck(_ title: String, path: String, failFix: String) -> CaptainSelfTestCheck {
        if path == "Package.swift" {
            return packageManifestCheck(title: title, path: path, failFix: failFix)
        }
        let exists = FileManager.default.fileExists(atPath: projectRoot + "/" + path)
        return CaptainSelfTestCheck(title: title,
                                    status: exists ? .pass : .fail,
                                    detail: exists ? "\(path) exists." : "\(path) is missing.",
                                    fix: exists ? "No action needed." : failFix,
                                    evidence: [path])
    }

    private func packageManifestCheck(title: String, path: String, failFix: String) -> CaptainSelfTestCheck {
        guard let manifest = read(path) else {
            return CaptainSelfTestCheck(title: title,
                                        status: .fail,
                                        detail: "\(path) is missing.",
                                        fix: failFix,
                                        evidence: [path])
        }
        let ok = manifest.contains("// swift-tools-version") && manifest.contains("Package(")
        return CaptainSelfTestCheck(title: title,
                                    status: ok ? .pass : .fail,
                                    detail: ok
                                        ? "\(path) looks like a Swift package manifest."
                                        : "\(path) exists but does not contain a Swift tools-version comment and Package(...) declaration.",
                                    fix: ok ? "No action needed." : "Restore a valid Swift Package.swift manifest before trusting self-test results.",
                                    evidence: [path])
    }

    private func runnerOrderChecks() -> [CaptainSelfTestCheck] {
        guard let source = read("Sources/Kist/KistRunner.swift") else {
            return [CaptainSelfTestCheck(title: "Runner launch-order audit",
                                         status: .fail,
                                         detail: "Could not read KistRunner.swift.",
                                         fix: "Restore KistRunner.swift and rerun /self-test.",
                                         evidence: ["Sources/Kist/KistRunner.swift"])]
        }
        let fleetBody = functionBody(named: "runFleet", in: source)
        let planBody = functionBody(named: "runPlanExecute", in: source)
        return [
            orderCheck(title: "Fleet domain-learning preflight before fleet side effects",
                       body: fleetBody,
                       first: "CaptainDomainLearningEnforcer.preflight(mode: .fleet",
                       markers: ["CaptainSimulationEnforcer.preflight", "let fleetBudget",
                                 "CaptainOrchestrator.deriveScopeContext", "FleetPlanner(",
                                 "PlanExecuteFleetSpawner", "launchFleet"],
                       fix: "Move fleet domain-learning preflight above simulation, budget creation, scope derivation, planning, worker assignment, and worker launch."),
            orderCheck(title: "Fleet simulation preflight before fleet side effects",
                       body: fleetBody,
                       first: "CaptainSimulationEnforcer.preflight(mode: .fleet",
                       markers: ["let fleetBudget", "CaptainOrchestrator.deriveScopeContext",
                                 "FleetPlanner(", "PlanExecuteFleetSpawner", "launchFleet"],
                       fix: "Move fleet preflight above budget creation, scope derivation, planning, worker assignment, and worker launch."),
            orderCheck(title: "Plan-execute domain-learning preflight before planner loop",
                       body: planBody,
                       first: "CaptainDomainLearningEnforcer.preflight(mode: .planExecute",
                       markers: ["CaptainSimulationEnforcer.preflight", "TraceRecorder(traceId",
                                 "PlanExecuteLoop(", "pxl.run"],
                       fix: "Move plan-execute domain-learning preflight above simulation, TraceRecorder, PlanExecuteLoop, approval, planner, and tools."),
            orderCheck(title: "Plan-execute simulation preflight before planner loop",
                       body: planBody,
                       first: "CaptainSimulationEnforcer.preflight(mode: .planExecute",
                       markers: ["TraceRecorder(traceId", "PlanExecuteLoop(", "pxl.run"],
                       fix: "Move plan-execute preflight above TraceRecorder, PlanExecuteLoop, approval, planner, and tools.")
        ]
    }

    private func orderCheck(title: String,
                            body: String?,
                            first: String,
                            markers: [String],
                            fix: String) -> CaptainSelfTestCheck {
        guard let body else {
            return CaptainSelfTestCheck(title: title,
                                        status: .fail,
                                        detail: "Could not isolate the audited runner body.",
                                        fix: fix,
                                        evidence: ["Sources/Kist/KistRunner.swift"])
        }
        guard let gate = body.range(of: first) else {
            return CaptainSelfTestCheck(title: title,
                                        status: .fail,
                                        detail: "Mandatory preflight marker is missing.",
                                        fix: fix,
                                        evidence: ["Sources/Kist/KistRunner.swift"])
        }
        var missing: [String] = []
        var late: [String] = []
        for marker in markers {
            guard let range = body.range(of: marker) else {
                missing.append(marker)
                continue
            }
            if gate.lowerBound > range.lowerBound { late.append(marker) }
        }
        if !late.isEmpty {
            return CaptainSelfTestCheck(title: title,
                                        status: .fail,
                                        detail: "Preflight appears after: \(late.joined(separator: ", ")).",
                                        fix: fix,
                                        evidence: ["Sources/Kist/KistRunner.swift"])
        }
        if !missing.isEmpty {
            return CaptainSelfTestCheck(title: title,
                                        status: .fail,
                                        detail: "Could not find expected downstream marker(s): \(missing.joined(separator: ", ")).",
                                        fix: "Restore the audited runner anchors or update this self-test with a replacement hard gate.",
                                        evidence: ["Sources/Kist/KistRunner.swift"])
        }
        return CaptainSelfTestCheck(title: title,
                                    status: .pass,
                                    detail: "Preflight is before all audited side-effect markers.",
                                    fix: "No action needed.",
                                    evidence: ["Sources/Kist/KistRunner.swift"])
    }

    private func testCoverageChecks() -> [CaptainSelfTestCheck] {
        guard let tests = read("Tests/KistTests/KistRunnerSafetyTests.swift") else {
            return [CaptainSelfTestCheck(title: "Self-test regression coverage",
                                         status: .fail,
                                         detail: "Could not read safety tests.",
                                         fix: "Restore KistRunnerSafetyTests and add self-test coverage.",
                                         evidence: ["Tests/KistTests/KistRunnerSafetyTests.swift"])]
        }
        let required = [
            "testRunnerKeepsFleetDomainLearningPreflightBeforeSideEffects",
            "testRunnerKeepsPlanExecuteDomainLearningPreflightBeforeSideEffects",
            "testRegulatedDomainLearningGateBlocksExecutionUntilUnderstandingClears",
            "testRedactedDomainLearningModeDoesNotPersistRawSensitiveObjective",
            "testRunnerKeepsFleetSimulationPreflightBeforeSideEffects",
            "testRunnerKeepsPlanExecuteSimulationPreflightBeforeSideEffects",
            "testRedactedEvidenceModeDoesNotPersistRawSensitiveObjective",
            "testRiskSignalsUseTokenBoundariesAndDoNotMatchSubstrings",
            "testRiskSignalsCatchDestructiveAuthAndPaymentTerms"
        ]
        var missing: [String] = []
        var weak: [String] = []
        for name in required {
            guard let body = functionBody(named: name, in: tests) else {
                missing.append(name)
                continue
            }
            if !hasExecutableAssertion(body) {
                weak.append(name)
            }
        }
        let issues = missing.map { "missing \($0)" } + weak.map { "weak \($0)" }
        return [CaptainSelfTestCheck(title: "Simulation gate regression coverage",
                                     status: issues.isEmpty ? .pass : .fail,
                                     detail: issues.isEmpty
                                        ? "Safety tests cover order, redaction, and high-risk signal regressions."
                                        : "Coverage issue(s): \(issues.joined(separator: ", ")).",
                                     fix: issues.isEmpty
                                        ? "No action needed."
                                        : "Add executable assertions to the missing or placeholder safety tests before changing autonomy gates.",
                                     evidence: ["Tests/KistTests/KistRunnerSafetyTests.swift"])]
    }

    private func documentExportChecks() -> [CaptainSelfTestCheck] {
        guard let exportSource = read("Sources/Kist/DocumentExport.swift"),
              let replSource = read("Sources/Kist/KistREPL.swift"),
              let tests = read("Tests/KistTests/DocumentExportTests.swift") else {
            return [CaptainSelfTestCheck(title: "Document export regression coverage",
                                         status: .fail,
                                         detail: "Could not read document export source, REPL source, or tests.",
                                         fix: "Restore DocumentExport, KistREPL export routing, and DocumentExportTests before trusting local PDF/doc export.",
                                         evidence: ["Sources/Kist/DocumentExport.swift",
                                                    "Sources/Kist/KistREPL.swift",
                                                    "Tests/KistTests/DocumentExportTests.swift"])]
        }
        let exportCode = codeOnly(exportSource)
        let replCode = codeOnly(replSource)
        let sourceMarkers = [
            "struct DocumentExport",
            "static func parseIntent",
            "let repairWords",
            "guard !repairWords.contains",
            "static func latestAssistantText",
            "static func writeLatestAssistantDocument",
            "case .pdf",
            "case .rtf",
            "writePDF(text: text"
        ]
        var issues = sourceMarkers
            .filter { !markerSatisfied($0, in: exportCode) }
            .map { "missing source marker \($0)" }
        let replMarkers = [
            "static func handleDocumentExportRequest",
            "DocumentExport.writeLatestAssistantDocument",
            "openFailureAnalysis"
        ]
        issues += replMarkers
            .filter { !markerSatisfied($0, in: replCode) }
            .map { "missing REPL marker \($0)" }
        if let exportCall = replCode.range(of: "handleDocumentExportRequest(messageBody") {
            let normalTurnTail = String(replCode[exportCall.lowerBound...])
            let missingDownstreamMarkers = ["proofStore?.startTurn", "MediaResolver.resolve", "runTurnInterruptible"]
                .filter { !markerSatisfied($0, in: normalTurnTail) }
            if !missingDownstreamMarkers.isEmpty {
                issues.append("document export route is not before normal-turn model/media marker(s): \(missingDownstreamMarkers.joined(separator: ", "))")
            }
        } else {
            issues.append("missing REPL document export pre-route call")
        }

        let testExpectations: [(name: String, markers: [String])] = [
            ("testParsesPriorAnswerPDFRequest",
             ["hreay cna i have this as a pdf", "turn this into a document"]),
            ("testDoesNotStealSelfHealPDFDebugRequest",
             ["fix the code malformed issue"]),
            ("testLatestAssistantTextUsesMostRecentAssistantAnswer",
             ["new"]),
            ("testWritesPDFDocumentFromLatestAssistantAnswer",
             ["exported PDF", "%PDF"]),
            ("testREPLHandlesPDFExportBeforeNormalModelTurn",
             ["handleDocumentExportRequest", "exported PDF"]),
            ("testREPLDocumentExportDoesNotStealDebugRequest",
             [".notDocumentExport"]),
            ("testREPLDocumentExportReportsNoPriorAssistantText",
             ["No prior assistant answer"])
        ]
        for expectation in testExpectations {
            guard let body = rawFunctionBody(named: expectation.name, in: tests) else {
                issues.append("missing test \(expectation.name)")
                continue
            }
            if !hasExecutableAssertion(body) {
                issues.append("weak test \(expectation.name)")
            }
            let bodyWithoutComments = commentsOnlyRemoved(body)
            for marker in expectation.markers where !markerSatisfied(marker, in: bodyWithoutComments) {
                issues.append("test \(expectation.name) missing assertion marker \(marker)")
            }
        }
        return [CaptainSelfTestCheck(title: "Document export regression coverage",
                                     status: issues.isEmpty ? .pass : .fail,
                                     detail: issues.isEmpty
                                        ? "Local PDF/RTF export is source-pinned, routed before model/media calls, and covered for typo, no-prior-answer, and debug/self-heal requests."
                                        : "Coverage issue(s): \(issues.joined(separator: ", ")).",
                                     fix: issues.isEmpty
                                        ? "No action needed."
                                        : "Restore local document export routing and executable DocumentExportTests before allowing PDF/doc requests to reach provider calls.",
                                     evidence: ["Sources/Kist/DocumentExport.swift",
                                                "Sources/Kist/KistREPL.swift",
                                                "Tests/KistTests/DocumentExportTests.swift"])]
    }

    private func modelSubstitutionChecks() -> [CaptainSelfTestCheck] {
        guard let source = read("Sources/Kist/KistREPL+ModelSubstitution.swift") else {
            return [CaptainSelfTestCheck(title: "Model substitution regression coverage",
                                         status: .fail,
                                         detail: "Could not read model substitution source.",
                                         fix: "Restore model substitution source before trusting automatic model replacement.",
                                         evidence: ["Sources/Kist/KistREPL+ModelSubstitution.swift",
                                                    "Tests/KistTests/KistREPLTests.swift"])]
        }
        let testPaths = [
            "Tests/KistTests/ModelSubstitutionTests.swift",
            "Tests/KistTests/KistREPLTests.swift"
        ]
        let readableTests = testPaths.compactMap { path -> (path: String, text: String)? in
            guard let text = read(path) else { return nil }
            return (path, text)
        }
        guard !readableTests.isEmpty else {
            return [CaptainSelfTestCheck(title: "Model substitution regression coverage",
                                         status: .fail,
                                         detail: "Could not read model substitution regression tests.",
                                         fix: "Restore ModelSubstitutionTests or KistREPL coverage before trusting automatic model replacement.",
                                         evidence: ["Sources/Kist/KistREPL+ModelSubstitution.swift"] + testPaths)]
        }
        let tests = readableTests.map { $0.text }.joined(separator: "\n")
        let sourceCode = codeOnly(source)
        let sourceMarkers = [
            "modelSubstitutionDecision",
            "trajectorySafeToReplayForModelSubstitution",
            "modelSubstitutionReplacement",
            "looksLikeRefusalOrPermissionStop",
            "providerModels[candidate.providerId.lowercased()] == nil"
        ]
        let sourceTextMarkers = [
            "rate limit",
            "server error",
            "provider/transient failure",
            "timed out",
            "provider/connectivity failure"
        ]
        let missingSource = sourceMarkers.filter { !markerSatisfied($0, in: sourceCode) }
            + sourceTextMarkers.filter { !markerSatisfied($0, in: source) }
        let testExpectations: [(name: String, markers: [String])] = [
            ("testModelSubstitutionChoosesReadyRoleBackupForMalformedFailure",
             ["deepseek-v4-pro", "provider/protocol failure"]),
            ("testModelSubstitutionFallsBackToPriorityProviderWhenRolesDoNotHelp",
             ["gemini", "provider/protocol failure"]),
            ("testRefusalAndPermissionStopsDoNotSubstituteAcrossTextOneShotOrVisionLanes",
             ["permission denied", "oneShotSubstitution", "mediaSubstitutionDecision", "XCTAssertNil"]),
            ("testModelSubstitutionFallsBackOnTransientProviderFailure",
             ["rate-limited", "provider/transient failure"]),
            ("testModelSubstitutionFallsBackOnProviderConnectivityFailure",
             ["timed out", "provider/connectivity failure"]),
            ("testModelSubstitutionDoesNotReplayAfterMutatingWork",
             ["write_file", "XCTAssertNil"]),
            ("testModelSubstitutionDoesNotChooseProviderMissingFromKnownCatalog",
             ["providerModels", "XCTAssertNil"]),
            ("testModelSubstitutionDoesNotShopAroundHardSafetyStop",
             ["malware", "steal credentials", "XCTAssertNil"])
        ]
        let fileWithoutComments = commentsOnlyRemoved(tests)
        var testIssues: [String] = []
        for expectation in testExpectations {
            guard let body = rawFunctionBody(named: expectation.name, in: tests) else {
                testIssues.append("missing test \(expectation.name)")
                continue
            }
            if !hasExecutableAssertion(body) {
                testIssues.append("weak test \(expectation.name)")
            }
            let bodyWithoutComments = commentsOnlyRemoved(body)
            for marker in expectation.markers where !testMarkerSatisfied(marker,
                                                                         inBody: bodyWithoutComments,
                                                                         inFile: fileWithoutComments) {
                testIssues.append("test \(expectation.name) missing assertion marker \(marker)")
            }
        }
        let issues = missingSource.map { "missing source marker \($0)" } + testIssues
        return [CaptainSelfTestCheck(title: "Model substitution regression coverage",
                                     status: issues.isEmpty ? .pass : .fail,
                                     detail: issues.isEmpty
                                        ? "Model substitution failover is source-pinned and covered for malformed failures, refusal and permission stops, replay safety, and catalog readiness."
                                        : "Coverage issue(s): \(issues.joined(separator: ", ")).",
                                     fix: issues.isEmpty
                                        ? "No action needed."
                                        : "Restore model substitution policy markers and executable regression tests before trusting automatic model replacement.",
                                     evidence: ["Sources/Kist/KistREPL+ModelSubstitution.swift"]
                                                + readableTests.map { $0.path })]
    }

    private func continuousSupervisorChecks() -> [CaptainSelfTestCheck] {
        guard let source = read("Sources/AgentCore/FleetSupervisor.swift"),
              let tests = read("Tests/AgentCoreTests/FleetSupervisorTests.swift") else {
            return [CaptainSelfTestCheck(title: "Continuous supervisor regression coverage",
                                         status: .fail,
                                         detail: "Could not read FleetSupervisor source or tests.",
                                         fix: "Restore FleetSupervisor and its regression tests before changing autonomous worker supervision.",
                                         evidence: ["Sources/AgentCore/FleetSupervisor.swift",
                                                    "Tests/AgentCoreTests/FleetSupervisorTests.swift"])]
        }
        let sourceMarkers = [
            "public struct FleetSupervisorPolicy",
            "public struct FleetSupervisorIntervention",
            "public struct FleetSupervisorEscalation",
            "supervisorInterventions.append",
            "supervisorEscalations.append",
            "delivered:",
            "deliveryFailures",
            "archiveRejectedDone",
            "surrenderKey",
            "continuousIntervention",
            "continuousEscalation",
            "applyIntervention",
            "applyEscalation",
            "latestSupervisorInterventionEpoch",
            "FleetScopeValidator.normalize",
            "private func makeIntervention"
        ]
        let testExpectations: [(name: String, markers: [String])] = [
            ("testStaleAgentGetsSupervisorRepairDirectiveBeforeTimeout",
             ["SUPERVISOR STALE", "supervisorInterventions"]),
            ("testFailedSupervisorDirectiveDeliveryIsRecordedButNotCountedAsDelivered",
             ["delivery FAILED", "delivered, false"]),
            ("testFutureProgressTimestampDoesNotBecomeFutureHeartbeat",
             ["future-dated progress", "lastHeartbeatEpoch"]),
            ("testOutOfLeaseProgressIsBlockedAsDriftAndInjectedIntoWorkerContext",
             []),
            ("testProgressPathWithDotDotIsBlockedAsNonCanonicalDrift",
             []),
            ("testRejectedDoneMarkerIsConsumedAndNotReprocessedWithoutNewCommit",
             ["same rejected .fleet-done", "rejectCount"]),
            ("testWorkerReportedBlockedGetsSupervisorIntervention",
             ["needs API contract", ".blocked"]),
            ("testSupervisorCreatedBlockedStateDoesNotTriggerSecondInterventionByDefault",
             ["maxInterventionsPerAgent: 2", "interventions, 1"]),
            ("testUnresolvedSupervisorBlockEscalatesToRescueAssignment",
             ["SUPERVISOR ESCALATION BLOCKED", "supervisorEscalations.count"]),
            ("testFailedRescueEscalationDeliveryIsAuditedButNotCounted",
             ["rescue assignment delivery FAILED", "escalations, 0"]),
            ("testWorkerCannotSpoofSupervisorInterventionBudget",
             ["SUPERVISOR INTERVENTION", "supervisorInterventions.count"]),
            ("testProgressPathIsNormalizedBeforeDriftCheck",
             [])
        ]
        let supervisorCode = codeOnly(source)
        let missingSource = sourceMarkers.filter { !markerSatisfied($0, in: supervisorCode) }
        var testIssues: [String] = []
        for expectation in testExpectations {
            guard let body = rawFunctionBody(named: expectation.name, in: tests) else {
                testIssues.append("missing test \(expectation.name)")
                continue
            }
            if !hasExecutableAssertion(body) {
                testIssues.append("weak test \(expectation.name)")
            }
            let bodyWithoutComments = commentsOnlyRemoved(body)
            let fileWithoutComments = commentsOnlyRemoved(tests)
            for marker in expectation.markers where !testMarkerSatisfied(marker,
                                                                         inBody: bodyWithoutComments,
                                                                         inFile: fileWithoutComments) {
                testIssues.append("test \(expectation.name) missing assertion marker \(marker)")
            }
        }
        let issues = missingSource.map { "missing source marker \($0)" } + testIssues
        return [CaptainSelfTestCheck(title: "Continuous supervisor regression coverage",
                                     status: issues.isEmpty ? .pass : .fail,
                                     detail: issues.isEmpty
                                        ? "Supervisor detects stale, blocked, and drifted workers before terminal failure."
                                        : "Coverage issue(s): \(issues.joined(separator: ", ")).",
                                     fix: issues.isEmpty
                                        ? "No action needed."
                                        : "Restore continuous supervision source markers and regression tests.",
                                     evidence: ["Sources/AgentCore/FleetSupervisor.swift",
                                                "Tests/AgentCoreTests/FleetSupervisorTests.swift"])]
    }

    private func supervisorRecoveryAndBoardHardeningChecks() -> [CaptainSelfTestCheck] {
        guard let blackboard = read("Sources/AgentCore/FleetBlackboard.swift"),
              let store = read("Sources/AgentCore/FleetBlackboardStore.swift"),
              let supervisor = read("Sources/AgentCore/FleetSupervisor.swift"),
              let blackboardTests = read("Tests/AgentCoreTests/FleetBlackboardTests.swift"),
              let storeTests = read("Tests/AgentCoreTests/FleetBlackboardStoreTests.swift"),
              let supervisorTests = read("Tests/AgentCoreTests/FleetSupervisorTests.swift") else {
            return [CaptainSelfTestCheck(title: "Supervisor recovery and board hardening regression coverage",
                                         status: .fail,
                                         detail: "Could not read supervisor/blackboard hardening source or tests.",
                                         fix: "Restore FleetBlackboard, FleetBlackboardStore, FleetSupervisor, and their hardening regression tests.",
                                         evidence: ["Sources/AgentCore/FleetBlackboard.swift",
                                                    "Sources/AgentCore/FleetBlackboardStore.swift",
                                                    "Sources/AgentCore/FleetSupervisor.swift",
                                                    "Tests/AgentCoreTests/FleetBlackboardTests.swift",
                                                    "Tests/AgentCoreTests/FleetBlackboardStoreTests.swift",
                                                    "Tests/AgentCoreTests/FleetSupervisorTests.swift"])]
        }
        let code = codeOnly([blackboard, store, supervisor].joined(separator: "\n"))
        let sourceMarkers = [
            "currentSchemaVersion",
            "schemaVersion",
            "decodeIfPresent(Bool.self, forKey: .delivered) ?? false",
            "_lastLoadError",
            "lastLoadError()",
            "normalizeForPersistence",
            "maxNotesPerCell",
            "maxSupervisorRecordsPerCell",
            "reconcilePendingDeliveries",
            "!cell.supervisorInterventions[recordIndex].delivered",
            "!cell.supervisorEscalations[recordIndex].delivered",
            "writeIntervention(cell.worktreePath, intervention)",
            "writeEscalation(cell.worktreePath, escalation)",
            "let rejectedKey = rejectedHead.isEmpty ? nil",
            "guard !head.isEmpty else { return false }"
        ]
        let missingSource = sourceMarkers.filter { !markerSatisfied($0, in: code) }
        let testExpectations: [(name: String, source: String, markers: [String])] = [
            ("testSupervisorDeliveryRecordsDecodeMissingDeliveredAsUndelivered", blackboardTests,
             ["XCTAssertFalse(intervention.delivered)", "XCTAssertFalse(escalation.delivered)"]),
            ("testCorruptBoardLoadIsReported", storeTests,
             ["lastLoadError", "Couldn't load fleet blackboard"]),
            ("testSeedCapsUnboundedAppendOnlyLedgers", storeTests,
             ["keyDecisions.count, 200", "supervisorEscalations.count, 50"]),
            ("testEmptyHeadDoesNotPoisonRejectedSurrenderTracking", supervisorTests,
             ["unknown HEAD", "rejectedDoneHeadSHAs, []"]),
            ("testPendingSupervisorDirectiveDeliveryIsRecoveredOnNextSweep", supervisorTests,
             ["INTERVENTION RECOVERY", "delivered, true"]),
            ("testPendingRescueEscalationDeliveryIsRecoveredOnNextSweep", supervisorTests,
             ["ESCALATION RECOVERY", "delivered, true"])
        ]
        var testIssues: [String] = []
        for expectation in testExpectations {
            guard let body = rawFunctionBody(named: expectation.name, in: expectation.source) else {
                testIssues.append("missing test \(expectation.name)")
                continue
            }
            if !hasExecutableAssertion(body) {
                testIssues.append("weak test \(expectation.name)")
            }
            let bodyWithoutComments = commentsOnlyRemoved(body)
            let fileWithoutComments = commentsOnlyRemoved(expectation.source)
            for marker in expectation.markers where !testMarkerSatisfied(marker,
                                                                         inBody: bodyWithoutComments,
                                                                         inFile: fileWithoutComments) {
                testIssues.append("test \(expectation.name) missing assertion marker \(marker)")
            }
        }
        let issues = missingSource.map { "missing source marker \($0)" } + testIssues
        return [CaptainSelfTestCheck(title: "Supervisor recovery and board hardening regression coverage",
                                     status: issues.isEmpty ? .pass : .fail,
                                     detail: issues.isEmpty
                                        ? "Supervisor delivery recovery, unknown-HEAD handling, board schema/load errors, and bounded ledgers are covered."
                                        : "Coverage issue(s): \(issues.joined(separator: ", ")).",
                                     fix: issues.isEmpty
                                        ? "No action needed."
                                        : "Restore DeepSeek hardening markers and regression tests before changing supervisor recovery or fleet board persistence.",
                                     evidence: ["Sources/AgentCore/FleetBlackboard.swift",
                                                "Sources/AgentCore/FleetBlackboardStore.swift",
                                                "Sources/AgentCore/FleetSupervisor.swift",
                                                "Tests/AgentCoreTests/FleetBlackboardTests.swift",
                                                "Tests/AgentCoreTests/FleetBlackboardStoreTests.swift",
                                                "Tests/AgentCoreTests/FleetSupervisorTests.swift"])]
    }

    private func immuneSystemChecks() -> [CaptainSelfTestCheck] {
        var checks: [CaptainSelfTestCheck] = []

        let sandboxSource = read("Sources/AgentCore/Tools/SandboxedProcessRunner.swift")
        let sandboxMarkers = [
            "public enum SandboxedProcessRunner",
            "runRequired",
            "SeatbeltSandbox.wrap",
            "OS sandbox required",
            "canApplyRequiredSandbox"
        ]
        checks.append(markerCheck(title: "Required OS sandbox runner contract",
                                  source: sandboxSource,
                                  requiredMarkers: sandboxMarkers,
                                  passDetail: "SandboxedProcessRunner exposes only required-sandbox execution and fails closed when unavailable.",
                                  failFix: "Restore SandboxedProcessRunner.runRequired so executable trials cannot fall back to unsandboxed Process.",
                                  evidence: ["Sources/AgentCore/Tools/SandboxedProcessRunner.swift"]))

        let customTool = read("Sources/AgentCore/Tools/CustomTool.swift")
        let customToolMarkers = [
            "SandboxedProcessRunner.runRequired",
            "RunCommandTool.scrubbedEnvironment",
            "\"sandboxed\"",
            "\"sandbox\""
        ]
        checks.append(markerCheck(title: "Custom tool required OS sandbox",
                                  source: customTool,
                                  requiredMarkers: customToolMarkers,
                                  forbiddenMarkers: ["context.sandbox.enabled", "binaryRefusalReason"],
                                  passDetail: "custom_tool.run uses the required sandbox runner and reports sandbox metadata.",
                                  failFix: "Route custom_tool.run through SandboxedProcessRunner.runRequired and remove outer-context sandbox gating.",
                                  evidence: ["Sources/AgentCore/Tools/CustomTool.swift"]))

        let learningStore = read("Sources/Kist/UX/OrganizationalLearningStore.swift")
        let simulationLab = read("Sources/Kist/UX/CaptainSimulationLab.swift")
        let enforcer = read("Sources/Kist/UX/CaptainSimulationEnforcer.swift")
        let combined = [learningStore, simulationLab, enforcer].compactMap { $0 }.joined(separator: "\n")
        let persistenceMarkers = [
            "writeSucceeded",
            "writeError",
            "simulation evidence report could not be persisted",
            "writeSucceeded && run.passesGate",
            "var passesGate: Bool",
            "writeSucceeded && estimatedSuccess",
            "simulation evidence report was not persisted"
        ]
        checks.append(markerCheck(title: "Simulation evidence persistence gate",
                                  source: combined.isEmpty ? nil : combined,
                                  requiredMarkers: persistenceMarkers,
                                  passDetail: "Simulation reports fail closed when the evidence artifact cannot be persisted.",
                                  failFix: "Make CaptainSimulationGateReport carry write status and require persisted evidence before passesGate can be true.",
                                  evidence: ["Sources/Kist/UX/OrganizationalLearningStore.swift",
                                             "Sources/Kist/UX/CaptainSimulationLab.swift",
                                             "Sources/Kist/UX/CaptainSimulationEnforcer.swift"]))

        let customToolTests = read("Tests/AgentCoreTests/CustomToolTests.swift")
        let learningTests = read("Tests/KistTests/OrganizationalLearningStoreTests.swift")
        let testSource = [customToolTests, learningTests].compactMap { $0 }.joined(separator: "\n")
        let testMarkers = [
            "testRunUsesRequiredOSSandboxEvenWhenContextSandboxDisabled",
            "testRunCustomToolCannotWriteOutsideRootWithoutOuterSandboxFlag",
            "testSimulationGateWriteFailureBlocksExecution"
        ]
        checks.append(markerCheck(title: "Immune-system regression coverage",
                                  source: testSource.isEmpty ? nil : testSource,
                                  requiredMarkers: testMarkers,
                                  passDetail: "Regression tests cover generated-tool sandboxing and simulation evidence persistence failure.",
                                  failFix: "Add regression tests for required sandbox execution and fail-closed simulation report writes.",
                                  evidence: ["Tests/AgentCoreTests/CustomToolTests.swift",
                                             "Tests/KistTests/OrganizationalLearningStoreTests.swift"]))

        return checks
    }

    private func liveImmuneSystemChecks() -> [CaptainSelfTestCheck] {
        var checks: [CaptainSelfTestCheck] = []

        checks.append(sandboxDenialLiveProbe())
        checks.append(customToolSandboxLiveProbe())

        checks.append(simulationPersistenceLiveProbe())
        return checks
    }

    private func sandboxDenialLiveProbe() -> CaptainSelfTestCheck {
        let tempRoot = NSTemporaryDirectory() + "kist_self_test_sandbox_\(UUID().uuidString)"
        let externalRoot = NSHomeDirectory() + "/.kist-self-test-sandbox-escape-\(UUID().uuidString)"
        let externalTarget = externalRoot + "/escaped.txt"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        defer { try? FileManager.default.removeItem(atPath: externalRoot) }

        do {
            try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: externalRoot, withIntermediateDirectories: true)
        } catch {
            return CaptainSelfTestCheck(title: "Required OS sandbox live probe",
                                        status: .warn,
                                        detail: "Could not prepare temp-root sandbox probe: \(String(describing: error)).",
                                        fix: "Check temp and home-directory write permissions, then rerun /self-test.",
                                        evidence: [tempRoot, externalTarget])
        }

        let outcome = SandboxedProcessRunner.runRequired(
            launchPath: "/bin/sh",
            launchArgs: ["-c", "if echo escaped > '\(externalTarget)'; then echo escaped; exit 42; fi; echo sandbox-blocked; exit 0"],
            root: tempRoot,
            cwd: tempRoot,
            env: ["PATH": "/usr/bin:/bin", "HOME": tempRoot, "TMPDIR": tempRoot],
            timeoutSeconds: 5,
            capPerStream: 2_000)

        if Self.sandboxApplyUnavailable(outcome.combined) {
            return CaptainSelfTestCheck(title: "Required OS sandbox live probe",
                                        status: .warn,
                                        detail: "Host denied applying the required OS sandbox: \(Self.singleLine(outcome.combined, limit: 180)).",
                                        fix: "Run executable simulations on a host/session where macOS Seatbelt can be applied; keep execution held when the sandbox cannot be proven.",
                                        evidence: ["SandboxedProcessRunner.runRequired"])
        }

        if !outcome.sandboxed {
            return CaptainSelfTestCheck(title: "Required OS sandbox live probe",
                                        status: .warn,
                                        detail: "Required OS sandbox probe could not run: \(Self.singleLine(outcome.combined, limit: 180)).",
                                        fix: "Start Kist on a host where the required OS sandbox is available before running executable simulations or generated tools.",
                                        evidence: ["SandboxedProcessRunner.runRequired"])
        }

        let denied = outcome.exitCode == 0
            && outcome.combined.contains("sandbox-blocked")
            && !FileManager.default.fileExists(atPath: externalTarget)
        return CaptainSelfTestCheck(title: "Required OS sandbox live probe",
                                    status: denied ? .pass : .fail,
                                    detail: denied
                                        ? "Required-sandbox probe blocked an attempted write outside the project root."
                                        : "Sandbox probe did not prove out-of-root write denial. exit=\(outcome.exitCode), output=\(Self.singleLine(outcome.combined, limit: 180)).",
                                    fix: denied
                                        ? "No action needed."
                                        : "Tighten the required OS sandbox profile before trusting executable simulations or generated tools.",
                                    evidence: ["SandboxedProcessRunner.runRequired", externalTarget])
    }

    private func customToolSandboxLiveProbe() -> CaptainSelfTestCheck {
        let tempRoot = NSTemporaryDirectory() + "kist_self_test_custom_tool_\(UUID().uuidString)"
        let externalRoot = NSHomeDirectory() + "/.kist-self-test-custom-tool-escape-\(UUID().uuidString)"
        let externalTarget = externalRoot + "/escaped.txt"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        defer { try? FileManager.default.removeItem(atPath: externalRoot) }

        do {
            try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: externalRoot, withIntermediateDirectories: true)
        } catch {
            return CaptainSelfTestCheck(title: "Custom tool sandbox live probe",
                                        status: .warn,
                                        detail: "Could not prepare temp-root custom_tool probe: \(String(describing: error)).",
                                        fix: "Check temp and home-directory write permissions, then rerun /self-test.",
                                        evidence: [tempRoot, externalTarget])
        }

        let registry = ToolRegistry([CustomTool()])
        let context = ToolContext(projectRoot: tempRoot)
        let created = runToolSynchronously {
            await registry.execute(name: "custom_tool", arguments: [
                "action": "create",
                "name": "sandbox_escape_probe",
                "code": """
                import pathlib
                target = pathlib.Path('\(externalTarget)')
                try:
                    target.write_text('escaped')
                    print('escaped')
                    raise SystemExit(42)
                except OSError:
                    print('sandbox-blocked')
                """,
            ], context: context)
        }
        guard created.success else {
            return CaptainSelfTestCheck(title: "Custom tool sandbox live probe",
                                        status: .fail,
                                        detail: "Could not create generated custom tool: \(Self.singleLine(created.error ?? created.output, limit: 180)).",
                                        fix: "Restore custom_tool.create before trusting generated tool self-tests.",
                                        evidence: ["custom_tool.create"])
        }

        let run = runToolSynchronously(timeoutSeconds: 20) {
            await registry.execute(name: "custom_tool", arguments: [
                "action": "run",
                "name": "sandbox_escape_probe",
                "timeout": 5,
            ], context: context)
        }
        let runDiagnostic = [run.output, run.error ?? ""].joined(separator: " ")
        if Self.sandboxApplyUnavailable(runDiagnostic) {
            return CaptainSelfTestCheck(title: "Custom tool sandbox live probe",
                                        status: .warn,
                                        detail: "Host denied applying the custom_tool OS sandbox: \(Self.singleLine(runDiagnostic, limit: 180)).",
                                        fix: "Run generated custom tools only on a host/session where macOS Seatbelt can be applied; keep custom_tool execution held when the sandbox cannot be proven.",
                                        evidence: ["custom_tool.create", "custom_tool.run"])
        }
        let passed = run.success
            && run.output.contains("sandbox-blocked")
            && run.metadata["sandboxed"] == "true"
            && !FileManager.default.fileExists(atPath: externalTarget)
        return CaptainSelfTestCheck(title: "Custom tool sandbox live probe",
                                    status: passed ? .pass : .fail,
                                    detail: passed
                                        ? "custom_tool.run blocked an attempted generated-tool write outside the project root."
                                        : "custom_tool.run did not prove out-of-root write denial. success=\(run.success), output=\(Self.singleLine(run.output, limit: 180)), error=\(Self.singleLine(run.error ?? "", limit: 120)).",
                                    fix: passed
                                        ? "No action needed."
                                        : "Route custom_tool.run through SandboxedProcessRunner.runRequired before trusting generated helper tools.",
                                    evidence: ["custom_tool.create", "custom_tool.run", externalTarget])
    }

    private func runToolSynchronously(timeoutSeconds: Int = 20,
                                      _ operation: @escaping @Sendable () async -> ToolResult) -> ToolResult {
        final class ResultBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: ToolResult?

            func set(_ value: ToolResult) {
                lock.lock()
                stored = value
                lock.unlock()
            }

            func get() -> ToolResult? {
                lock.lock()
                let value = stored
                lock.unlock()
                return value
            }
        }

        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let result = await operation()
            box.set(result)
            semaphore.signal()
        }
        let waitResult = semaphore.wait(timeout: .now() + .seconds(max(1, timeoutSeconds)))
        guard waitResult == .success, let result = box.get() else {
            return .failure("custom_tool live probe timed out after \(timeoutSeconds)s")
        }
        return result
    }

    private func simulationPersistenceLiveProbe() -> CaptainSelfTestCheck {
        let tempRoot = NSTemporaryDirectory() + "kist_self_test_sim_persist_\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        do {
            try FileManager.default.createDirectory(atPath: tempRoot + "/.kist", withIntermediateDirectories: true)
            try """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "SelfTestProbe")
            """.write(toFile: tempRoot + "/Package.swift", atomically: true, encoding: .utf8)
            try "not a directory".write(toFile: tempRoot + "/.kist/learning", atomically: true, encoding: .utf8)
        } catch {
            return CaptainSelfTestCheck(title: "Simulation report persistence live probe",
                                        status: .warn,
                                        detail: "Could not prepare temp-root persistence probe: \(String(describing: error)).",
                                        fix: "Check temp directory write permissions, then rerun /self-test.",
                                        evidence: [tempRoot])
        }

        let plan = Plan(title: "Self-test simulation persistence probe",
                        tasks: [PlanTask(id: 1,
                                         title: "ACTION: simulate risky software refactor",
                                         detail: "probe fail-closed simulation report persistence",
                                         kind: .action)])
        let report = OrganizationalLearningStore(projectRoot: tempRoot,
                                                 specialistRegistry: {
                                                     SpecialistRegistry(projectRoot: $0, userDir: nil,
                                                                        claudeUserDir: nil)
                                                 })
            .runSimulationGate(plan: plan,
                               trajectory: [],
                               objective: "simulate software refactor",
                               measuredTrialMode: .interactive)
        let passed = !report.writeSucceeded
            && !report.passesGate
            && report.decision.contains("could not be persisted")
            && !report.text.contains("Decision: PROCEED")
            && report.benchmarkRecords == 0
        return CaptainSelfTestCheck(title: "Simulation report persistence live probe",
                                    status: passed ? .pass : .fail,
                                    detail: passed
                                        ? "A forced report-write failure blocked execution and did not promote benchmark memory."
                                        : "Forced report-write failure did not fail closed. writeSucceeded=\(report.writeSucceeded), passesGate=\(report.passesGate), benchmarkRecords=\(report.benchmarkRecords).",
                                    fix: passed
                                        ? "No action needed."
                                        : "Make simulation report persistence mandatory before execution or benchmark promotion.",
                                    evidence: ["OrganizationalLearningStore.runSimulationGate"])
    }

    private func markerCheck(title: String,
                             source: String?,
                             requiredMarkers: [String],
                             forbiddenMarkers: [String] = [],
                             passDetail: String,
                             failFix: String,
                             evidence: [String]) -> CaptainSelfTestCheck {
        guard let source else {
            return CaptainSelfTestCheck(title: title,
                                        status: .fail,
                                        detail: "Could not read audited source.",
                                        fix: failFix,
                                        evidence: evidence)
        }
        let missing = requiredMarkers.filter { !source.contains($0) }
        let forbidden = forbiddenMarkers.filter { source.contains($0) }
        let issues = missing.map { "missing \($0)" } + forbidden.map { "forbidden \($0)" }
        return CaptainSelfTestCheck(title: title,
                                    status: issues.isEmpty ? .pass : .fail,
                                    detail: issues.isEmpty ? passDetail : "Contract issue(s): \(issues.joined(separator: ", ")).",
                                    fix: issues.isEmpty ? "No action needed." : failFix,
                                    evidence: evidence)
    }

    private func blackboardDurabilityChecks() -> [CaptainSelfTestCheck] {
        guard let store = read("Sources/AgentCore/FleetBlackboardStore.swift"),
              let inbox = read("Sources/AgentCore/FleetUpdateInbox.swift"),
              let orchestrator = read("Sources/AgentCore/CaptainOrchestrator.swift"),
              let storeTests = read("Tests/AgentCoreTests/FleetBlackboardStoreTests.swift"),
              let inboxTests = read("Tests/AgentCoreTests/FleetUpdateInboxTests.swift"),
              let supervisorTests = read("Tests/AgentCoreTests/FleetSupervisorTests.swift"),
              let orchestratorTests = read("Tests/AgentCoreTests/CaptainOrchestratorTests.swift") else {
            return [CaptainSelfTestCheck(title: "Blackboard durability regression coverage",
                                         status: .fail,
                                         detail: "Could not read blackboard/inbox/orchestrator source or tests.",
                                         fix: "Restore FleetBlackboardStore, FleetUpdateInbox, CaptainOrchestrator, and durability regression tests.",
                                         evidence: ["Sources/AgentCore/FleetBlackboardStore.swift",
                                                    "Sources/AgentCore/FleetUpdateInbox.swift",
                                                    "Sources/AgentCore/CaptainOrchestrator.swift",
                                                    "Tests/AgentCoreTests/FleetBlackboardStoreTests.swift",
                                                    "Tests/AgentCoreTests/FleetUpdateInboxTests.swift",
                                                    "Tests/AgentCoreTests/FleetSupervisorTests.swift",
                                                    "Tests/AgentCoreTests/CaptainOrchestratorTests.swift"])]
        }
        let sourceMarkers = [
            "persistLocked",
            "guard persistLocked(initial)",
            "guard persistLocked(current)",
            "guard var current = _board else",
            "readPending()",
            "acknowledge(_ pending: PendingUpdate) -> Bool",
            "guard boardStore.seed(board) else",
            "GitIsolation.discard",
            "guard batonStore.save(heldBaton) else",
            "public let supervisionReady"
        ]
        let source = store + "\n" + inbox + "\n" + orchestrator
        let sourceCode = codeOnly(source)
        let missingSource = sourceMarkers.filter { !markerSatisfied($0, in: sourceCode) }
        let testMarkers = [
            "testSeedFailureDoesNotPublishInMemoryBoard": storeTests,
            "testFoldUpdateWithoutLoadedBoardFailsSoInboxCanRetry": storeTests,
            "testFoldProgressWithoutLoadedBoardFails": storeTests,
            "testFoldUpdateFailureDoesNotPublishInMemoryOnlyMutation": storeTests,
            "testReadPendingKeepsValidDropUntilAcknowledged": inboxTests,
            "testValidDropIsNotAcknowledgedWhenBlackboardHasNoLoadedBoard": inboxTests,
            "testBlackboardPersistenceFailurePreventsAllSignedClaim": supervisorTests,
            "testRejectionPersistenceFailureDoesNotArchiveDoneOrAdvanceBaton": supervisorTests,
            "testTimeoutPersistenceFailureDoesNotAdvanceBaton": supervisorTests,
            "testRejectedDoneHeadPersistsSoRestartDoesNotReinspectSameCommit": supervisorTests,
            "testBlackboardIsSeededBeforeFirstSpawn": orchestratorTests,
            "testBlackboardSeedFailurePreventsSpawnsAndBatons": orchestratorTests,
            "testSpawnFailureMarksAgentFailed": orchestratorTests,
            "testBatonSaveFailureDoesNotPublishInMemoryBaton": read("Tests/AgentCoreTests/FleetBatonStoreTests.swift") ?? ""
        ]
        let missingTests = testMarkers.compactMap { name, body in
            guard let testBody = rawFunctionBody(named: name, in: body),
                  hasExecutableAssertion(testBody) else { return "missing or weak \(name)" }
            return nil
        }
        let issues = missingSource.map { "missing source marker \($0)" } + missingTests
        return [CaptainSelfTestCheck(title: "Blackboard durability regression coverage",
                                     status: issues.isEmpty ? .pass : .fail,
                                     detail: issues.isEmpty
                                        ? "Blackboard writes publish after persistence and inbox updates are acknowledged after durable fold."
                                        : "Coverage issue(s): \(issues.joined(separator: ", ")).",
                                     fix: issues.isEmpty
                                        ? "No action needed."
                                        : "Restore fail-closed blackboard persistence and inbox acknowledge tests.",
                                     evidence: ["Sources/AgentCore/FleetBlackboardStore.swift",
                                                "Sources/AgentCore/FleetUpdateInbox.swift",
                                                "Sources/AgentCore/CaptainOrchestrator.swift",
                                                "Tests/AgentCoreTests/FleetBlackboardStoreTests.swift",
                                                "Tests/AgentCoreTests/FleetUpdateInboxTests.swift",
                                                "Tests/AgentCoreTests/FleetSupervisorTests.swift",
                                                "Tests/AgentCoreTests/CaptainOrchestratorTests.swift"])]
    }

    private func selfHealChecks() -> [CaptainSelfTestCheck] {
        guard let source = read("Sources/Kist/UX/OrganizationalLearningStore.swift") else {
            return [CaptainSelfTestCheck(title: "Self-heal mission source",
                                         status: .warn,
                                         detail: "Could not read OrganizationalLearningStore.swift.",
                                         fix: "Restore the organizational learning store or split self-heal checks into their new source file.",
                                         evidence: ["Sources/Kist/UX/OrganizationalLearningStore.swift"])]
        }
        let required = ["self-heal-researcher", "self-heal-builder", "self-heal-critic", "self-heal-captain-gate"]
        let missing = required.filter { !source.contains($0) }
        let organization = CaptainSelfTestCheck(
            title: "Self-heal specialist organization",
            status: missing.isEmpty ? .pass : .warn,
            detail: missing.isEmpty
                ? "Research, build, review, and gate specialists are defined."
                : "Missing specialist definition(s): \(missing.joined(separator: ", ")).",
            fix: missing.isEmpty
                ? "No action needed."
                : "Restore the missing self-heal specialist roles before building continuous supervision.",
            evidence: ["Sources/Kist/UX/OrganizationalLearningStore.swift"])

        let learningTests = read("Tests/KistTests/OrganizationalLearningStoreTests.swift") ?? ""
        let combined = source + "\n" + learningTests
        let ledgerMarkers = [
            "struct LearningEvidenceRecord",
            "evidenceLedgerPath",
            "recordSpecialistEvidenceLedger",
            "updatedTaskIDs",
            "evidenceLedgerRecorded",
            "evidence-ledger.jsonl",
            "LearningEvidenceRecord.self"
        ]
        let missingLedger = ledgerMarkers.filter { !combined.contains($0) }
        let ledger = CaptainSelfTestCheck(
            title: "Specialist evidence ledger persistence",
            status: missingLedger.isEmpty ? .pass : .fail,
            detail: missingLedger.isEmpty
                ? "Specialist outputs write a durable evidence ledger and tests assert artifact, memory, and task linkage."
                : "Missing ledger marker(s): \(missingLedger.joined(separator: ", ")).",
            fix: missingLedger.isEmpty
                ? "No action needed."
                : "Restore the evidence ledger record, writer, task-ID linkage, and regression assertions for specialist output artifacts.",
            evidence: ["Sources/Kist/UX/OrganizationalLearningStore.swift",
                       "Tests/KistTests/OrganizationalLearningStoreTests.swift"])

        return [organization, ledger]
    }

    private func markerSatisfied(_ marker: String, in text: String) -> Bool {
        if text.contains(marker) { return true }
        return Self.markerAlternatives[marker]?.contains { text.contains($0) } ?? false
    }

    private func testMarkerSatisfied(_ marker: String, inBody body: String, inFile file: String) -> Bool {
        markerSatisfied(marker, in: body) || markerSatisfied(marker, in: file)
    }

    private static let markerAlternatives: [String: [String]] = [
        "SUPERVISOR DRIFT": ["directive?.kind, .drift", "directive?.kind", ".drift"],
        "Other/B.swift": ["directive?.summary.contains", "directive?.evidence.first"],
        "Core/../Other.swift": ["directive?.kind, .drift", "directive?.evidence.first"],
        "non-canonical": ["directive?.summary.contains", "directive?.kind, .drift"],
        "./Core/Foo.swift": ["cell.status, .working", "result.interventions, 0"],
        "interventions, 0": ["result.interventions, 0"],
        "guard persistLocked(initial)": ["guard persistLocked(normalized) else { return false }"],
        "guard persistLocked(current)": ["guard persistLocked(normalized) else { return false }"]
    ]

    private static func sandboxApplyUnavailable(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("sandbox_apply")
            && (lower.contains("operation not permitted") || lower.contains("not permitted"))
    }

    private func boardHealthChecks() -> [CaptainSelfTestCheck] {
        let plan = PlanStore(projectRoot: projectRoot).load()
        let blocked = plan.tasks.filter { $0.status == .blocked }
        let missingContracts = plan.tasks.filter {
            $0.status != .done && ($0.acceptance.isEmpty || $0.verification.isEmpty)
        }
        let ledger = OrganizationalLearningStore(projectRoot: projectRoot).evidenceLedger(limit: 10_000)
        let ledgerTaskIDs = Set(ledger.flatMap(\.taskIDs))
        let ledgerArtifacts = Set(ledger.map(\.artifactPath))
        var proofIssues: [String] = []
        for task in plan.tasks {
            let needsProofNow = task.status == .inProgress || task.status == .done
            if needsProofNow && task.evidence.isEmpty && !ledgerTaskIDs.contains(task.id) {
                proofIssues.append("[\(task.id)] \(task.boardTitle) has no attached evidence")
            }
            let unledgered = task.evidence.filter {
                isSpecialistEvidencePath($0) && !ledgerArtifacts.contains($0)
            }
            if let first = unledgered.first {
                proofIssues.append("[\(task.id)] \(task.boardTitle) has specialist evidence without ledger: \(first)")
            }
        }
        var checks: [CaptainSelfTestCheck] = [
            CaptainSelfTestCheck(title: "Task board blocked work",
                                 status: blocked.isEmpty ? .pass : .warn,
                                 detail: blocked.isEmpty
                                    ? "No blocked tasks on the current board."
                                    : "\(blocked.count) blocked task(s): " + blocked.prefix(5).map(\.boardTitle).joined(separator: "; "),
                                 fix: blocked.isEmpty
                                    ? "No action needed."
                                    : "Resolve or explicitly replan blocked task-board items before adding more autonomous layers.",
                                 evidence: [".kist/plan.json"]),
            CaptainSelfTestCheck(title: "Task board contract quality",
                                 status: missingContracts.isEmpty ? .pass : .warn,
                                 detail: missingContracts.isEmpty
                                    ? "Open tasks have acceptance and verification contracts."
                                    : "\(missingContracts.count) open task(s) lack acceptance or verification.",
                                 fix: missingContracts.isEmpty
                                    ? "No action needed."
                                    : "Add acceptance and verification fields to open tasks so Captain can know what done means.",
                                 evidence: [".kist/plan.json"]),
            CaptainSelfTestCheck(title: "Task board evidence ledger health",
                                 status: proofIssues.isEmpty ? .pass : .warn,
                                 detail: proofIssues.isEmpty
                                    ? "Active/done tasks have evidence or ledger linkage, and specialist artifact evidence is durably ledgered."
                                    : "\(proofIssues.count) proof issue(s): " + proofIssues.prefix(5).joined(separator: "; "),
                                 fix: proofIssues.isEmpty
                                    ? "No action needed."
                                    : "Capture specialist output through the evidence ledger, or attach verified evidence before considering active/done work proven.",
                                 evidence: [".kist/plan.json", ".kist/learning/evidence-ledger.jsonl"])
        ]
        if !FileManager.default.fileExists(atPath: projectRoot + "/Package.swift") {
            checks.append(CaptainSelfTestCheck(title: "Live test command discovery",
                                               status: .warn,
                                               detail: "No Package.swift found; self-test cannot infer `swift test` as the project-wide command.",
                                               fix: "Add a project test command to a future configurable self-test profile.",
                                               evidence: ["Package.swift"]))
        }
        return checks
    }

    private func isSpecialistEvidencePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains(".kist/learning/self-heal/specialists/")
            || lower.contains(".kist/learning/research-archive/domain-learning/specialists/")
    }

    private func seedTasks(for checks: [CaptainSelfTestCheck], reportPath: String) -> Int {
        let store = PlanStore(projectRoot: projectRoot)
        var count = 0
        for check in checks where check.status != .pass {
            let title = "\(check.status == .fail ? "ACTION" : "REVIEW"): Self-test finding -- \(check.title)"
            guard !taskExists(title: title) else { continue }
            let task = store.add(title: title,
                                 detail: "\(check.detail)\nFix: \(check.fix)",
                                 owner: "captain-self-test",
                                 kind: check.status == .fail ? .action : .review,
                                 acceptance: "The self-test finding is resolved or explicitly accepted with evidence.",
                                 verification: "/self-test shows this check as PASS, or a decision task records why WARN is acceptable.",
                                 evidence: [reportPath] + check.evidence)
            if store.load().tasks.contains(where: { $0.id == task.id }) {
                count += 1
            }
        }
        return count
    }

    private func taskExists(title: String) -> Bool {
        let wanted = boardTitle(title).lowercased()
        return PlanStore(projectRoot: projectRoot).load().tasks.contains {
            $0.status != .done && boardTitle($0.title).lowercased() == wanted
        }
    }

    private func render(checks: [CaptainSelfTestCheck],
                        reportPath: String,
                        seededTasks: Int,
                        seedFindings: Bool,
                        recommendedCommands: [String]) -> String {
        let failures = checks.filter { $0.status == .fail }
        let warnings = checks.filter { $0.status == .warn }
        let passed = checks.filter { $0.status == .pass }
        let outcome = failures.isEmpty ? (warnings.isEmpty ? "PASS" : "WARN") : "FAIL"
        var lines = [
            "# Static Kist Self-Check",
            "",
            "Static outcome: STATIC \(outcome)",
            "Checks: \(passed.count) pass / \(warnings.count) warn / \(failures.count) fail",
            "Report: \(reportPath)",
            "Mode: \(seedFindings ? "seeded repair queue" : "check-only, report written")",
            "This is a static architecture audit. Run the recommended commands below for executable proof.",
        ]
        if !failures.isEmpty {
            lines += ["", "## What Needs Fixing"]
            for check in failures {
                lines += [
                    "- [\(check.status.rawValue)] \(check.title)",
                    "  Issue: \(check.detail)",
                    "  Fix: \(check.fix)",
                ]
            }
        }
        if !warnings.isEmpty {
            lines += ["", "## What Needs Attention"]
            for check in warnings {
                lines += [
                    "- [\(check.status.rawValue)] \(check.title)",
                    "  Watch: \(check.detail)",
                    "  Next: \(check.fix)",
                ]
            }
        }
        if failures.isEmpty && warnings.isEmpty {
            lines += [
                "",
                "## What Needs Attention",
                "- Nothing detected by deterministic self-test."
            ]
        }
        lines += ["", "## Checks"]
        for check in checks {
            lines += [
                "- [\(check.status.rawValue)] \(check.title)",
                "  \(check.detail)",
            ]
            if !check.evidence.isEmpty {
                lines.append("  Evidence: \(check.evidence.joined(separator: "; "))")
            }
        }
        lines += [
            "",
            "## Recommended Next Test Commands",
        ]
        lines += recommendedCommands.map { "- \($0)" }
        lines += [
            "",
            "## Captain Action",
            "Seeded tasks: \(seededTasks)",
            seedFindings
                ? "Use `/tasks` to inspect the generated repair/review queue."
                : "No tasks were created. Run `/self-test run` or `/self-test --seed` to seed repair/review tasks."
        ]
        return lines.joined(separator: "\n")
    }

    private func recommendedCommands() -> [String] {
        var commands = ["swift test --filter KistRunnerSafetyTests", "swift test", "git diff --check", "kist --health"]
        if FileManager.default.fileExists(atPath: projectRoot + "/Package.swift") == false {
            commands = ["Define project test command", "git diff --check", "kist --health"]
        }
        return commands
    }

}
