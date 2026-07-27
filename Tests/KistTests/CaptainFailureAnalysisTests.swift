import XCTest
import AgentCore
@testable import Kist

final class CaptainFailureAnalysisTests: XCTestCase {
    func testMalformedImageURLFailureCreatesDiagnosisCapsuleAndTasks() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let summary = """
        provider 'mimo' error: http(status: 400, body: messages[1]: unknown variant `image_url`, expected `text`)
        """
        let analyzer = CaptainFailureAnalysis(projectRoot: root,
                                              now: { Date(timeIntervalSince1970: 1_783_060_000) })

        let report = analyzer.analyze(goal: "can i have this as a pdf",
                                      summary: summary,
                                      trajectory: [],
                                      proofEntries: [
                                        .init(kind: .failed, tool: nil, success: false, text: summary)
                                      ])

        XCTAssertTrue(report.writeSucceeded, report.writeError ?? "missing write error")
        XCTAssertEqual(report.capsule.likelyLayer, .mediaAttachmentSerialization)
        XCTAssertEqual(report.capsule.confidence, 92)
        XCTAssertTrue(report.capsule.observed.contains("image payload"))
        XCTAssertEqual(report.seededTasks, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + report.path))

        let text = try String(contentsOfFile: root + "/" + report.path)
        XCTAssertTrue(text.contains("Captain Failure Analysis"))
        XCTAssertTrue(text.contains("Stale media attachment leaked"))
        XCTAssertTrue(text.contains("Do not retry blindly"))

        let latest = try XCTUnwrap(CaptainFailureAnalysis.latest(projectRoot: root))
        XCTAssertEqual(latest.id, report.capsule.id)
        XCTAssertEqual(latest.likelyLayer, .mediaAttachmentSerialization)
        let rendered = CaptainFailureAnalysis.renderLatest(projectRoot: root)
        XCTAssertTrue(rendered.contains("Captain Failure Analysis"))
        XCTAssertTrue(rendered.contains(report.capsule.id))
        XCTAssertTrue(rendered.contains("media-attachment-serialization"))

        let plan = PlanStore(projectRoot: root).load()
        XCTAssertEqual(plan.tasks.count, 5)
        XCTAssertTrue(plan.tasks.contains { $0.title.contains("Diagnose failure") && $0.status == .inProgress })
        XCTAssertTrue(plan.tasks.contains { $0.title.contains("Teach Captain failure lesson") })
    }

    func testSelfHealMissionUsesLatestFailureCapsule() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        _ = CaptainFailureAnalysis(projectRoot: root,
                                   now: { Date(timeIntervalSince1970: 1_783_060_100) })
            .analyze(goal: "fix the malformed pdf request",
                     summary: "provider error: bad request malformed image_url expected text",
                     trajectory: [],
                     seedTasks: false)

        let report = OrganizationalLearningStore(projectRoot: root,
                                                 now: { Date(timeIntervalSince1970: 1_783_060_101) })
            .runSelfHealMission(plan: Plan(), trajectory: [], objective: "fix the last failure")

        XCTAssertTrue(report.writeSucceeded, report.writeError ?? "missing write error")
        XCTAssertTrue(report.text.contains("Failure analysis: Provider rejected image payload"))
        XCTAssertTrue(report.text.contains("latest failure capsule"))
        XCTAssertTrue(report.text.contains("media-attachment-serialization"))
        XCTAssertTrue(report.text.contains("must trigger media-history serialization diagnosis"))
    }

    func testDocumentExportFailureCreatesFirstClassDiagnosis() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let analyzer = CaptainFailureAnalysis(projectRoot: root,
                                              now: { Date(timeIntervalSince1970: 1_783_060_200) })

        let report = analyzer.analyze(goal: "can i have this as a pdf",
                                      summary: "document export failed: could not create PDF writer",
                                      trajectory: [],
                                      seedTasks: true)

        XCTAssertTrue(report.writeSucceeded, report.writeError ?? "missing write error")
        XCTAssertEqual(report.capsule.likelyLayer, .documentExport)
        XCTAssertEqual(report.capsule.confidence, 88)
        XCTAssertTrue(report.capsule.observed.contains("Document export failed"))
        XCTAssertTrue(report.capsule.verificationPlan.contains("swift test --filter DocumentExportTests"))
        XCTAssertTrue(report.capsule.teachCandidate.contains("Document export failures are first-class"))
        XCTAssertEqual(report.seededTasks, 5)

        let text = try String(contentsOfFile: root + "/" + report.path)
        XCTAssertTrue(text.contains("document-export"))
        XCTAssertTrue(text.contains("Document export writer failed"))

        let mission = OrganizationalLearningStore(projectRoot: root,
                                                  now: { Date(timeIntervalSince1970: 1_783_060_201) })
            .runSelfHealMission(plan: Plan(), trajectory: [], objective: "fix document export")

        XCTAssertTrue(mission.writeSucceeded, mission.writeError ?? "missing write error")
        XCTAssertTrue(mission.text.contains("latest failure capsule"))
        XCTAssertTrue(mission.text.contains("document-export"))
        XCTAssertTrue(mission.text.contains("Document export failures are first-class"))
    }

    func testFailureCapsuleLedgerSurvivesConcurrentWriters() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let queue = DispatchQueue(label: "failure-capsules-concurrent", attributes: .concurrent)
        let group = DispatchGroup()

        for idx in 0..<20 {
            group.enter()
            queue.async {
                _ = CaptainFailureAnalysis(projectRoot: root)
                    .analyze(goal: "failure \(idx)",
                             summary: "document export failed: could not create PDF writer \(idx)",
                             trajectory: [],
                             seedTasks: false)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)

        let path = root + "/.kist/learning/failure-capsules.jsonl"
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 20)
        for line in lines {
            XCTAssertNoThrow(try JSONDecoder().decode(CaptainFailureCapsule.self, from: Data(line.utf8)))
        }
    }

    func testAutoSupervisionGuardSkipsRecursiveSystemCommands() {
        XCTAssertTrue(KistREPL.shouldAutoSuperviseFailure(goal: "make this a pdf"))
        XCTAssertTrue(KistREPL.shouldAutoSuperviseFailure(goal: "fix the provider malformed request"))
        XCTAssertFalse(KistREPL.shouldAutoSuperviseFailure(goal: "/self-heal run"))
        XCTAssertFalse(KistREPL.shouldAutoSuperviseFailure(goal: "self-heal run last failure"))
        XCTAssertFalse(KistREPL.shouldAutoSuperviseFailure(goal: "immune check"))
        XCTAssertFalse(KistREPL.shouldAutoSuperviseFailure(goal: "simulate risky plan"))
    }

    func testLegalResearchExternalDocumentConsentMarkers() {
        XCTAssertFalse(KistREPL.legalResearchHasExternalDocumentConsent("full legal research jurisdiction: CT on file.pdf"))
        XCTAssertTrue(KistREPL.legalResearchHasExternalDocumentConsent("full legal research --send-docs jurisdiction: CT on file.pdf"))
        XCTAssertTrue(KistREPL.legalResearchHasExternalDocumentConsent("I consent to send this document to model for research"))
    }

    func testSupervisorRepairObjectiveNamesFailureLayer() throws {
        let capsule = CaptainFailureCapsule(
            id: "failure-1",
            objective: "make pdf",
            observed: "Provider rejected image payload in a text-only request history.",
            likelyLayer: .mediaAttachmentSerialization,
            confidence: 92,
            evidence: [],
            hypotheses: [],
            researchTasks: [],
            repairPlan: [],
            verificationPlan: [],
            teachCandidate: "teach",
            reportPath: ".kist/learning/failures/failure-1.md",
            createdAt: 1)

        let objective = KistREPL.supervisorRepairObjective(for: capsule)
        XCTAssertTrue(objective.contains("failure-1"))
        XCTAssertTrue(objective.contains("media-attachment-serialization"))
        XCTAssertTrue(objective.contains("Provider rejected image payload"))
    }

    func testRepairVerificationStaysIncompleteUntilAllPlannedChecksHaveEvidence() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let report = CaptainFailureAnalysis(projectRoot: root,
                                            now: { Date(timeIntervalSince1970: 1_783_060_300) })
            .analyze(goal: "can i have this as a pdf",
                     summary: "document export failed: could not create PDF writer",
                     trajectory: [],
                     seedTasks: false)

        let verification = try CaptainFailureAnalysis(projectRoot: root,
                                                      now: { Date(timeIntervalSince1970: 1_783_060_301) })
            .recordRepairVerification(capsuleID: report.capsule.id,
                                      evidenceText: "swift test --filter DocumentExportTests passed")

        XCTAssertEqual(verification.status, .incomplete)
        XCTAssertTrue(verification.missingVerification.contains("swift test --filter CaptainFailureAnalysisTests"))
        XCTAssertTrue(verification.missingVerification.contains("swift test --filter KistREPLTests"))
        let rendered = CaptainFailureAnalysis.renderLatest(projectRoot: root)
        XCTAssertTrue(rendered.contains("Repair status: incomplete"))
        XCTAssertTrue(rendered.contains("Missing verification"))
    }

    func testFailureCommandRecordsVerifiedRepairWhenEvidenceMatchesPlan() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        _ = CaptainFailureAnalysis(projectRoot: root,
                                   now: { Date(timeIntervalSince1970: 1_783_060_400) })
            .analyze(goal: "can i have this as a pdf",
                     summary: "document export failed: could not create PDF writer",
                     trajectory: [],
                     seedTasks: false)

        let output = CaptainFailureAnalysis.handleCommand("""
        verify swift test --filter DocumentExportTests passed;
        swift test --filter CaptainFailureAnalysisTests passed;
        swift test --filter KistREPLTests passed
        """, projectRoot: root)

        XCTAssertTrue(output.contains("Captain Repair Verification"))
        XCTAssertTrue(output.contains("Status: verified"))
        let latest = try XCTUnwrap(CaptainFailureAnalysis.latest(projectRoot: root))
        let verification = try XCTUnwrap(CaptainFailureAnalysis.latestRepairVerification(projectRoot: root,
                                                                                        capsuleID: latest.id))
        XCTAssertEqual(verification.status, .verified)
        XCTAssertTrue(verification.missingVerification.isEmpty)
        XCTAssertTrue(CaptainFailureAnalysis.renderLatest(projectRoot: root).contains("Repair status: verified"))
    }

    func testFocusedSwiftTestsDoNotSatisfyGenericFullSuiteVerification() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let report = CaptainFailureAnalysis(projectRoot: root,
                                            now: { Date(timeIntervalSince1970: 1_783_060_500) })
            .analyze(goal: "make this a pdf",
                     summary: "provider bad request: unknown variant image_url expected text",
                     trajectory: [],
                     seedTasks: false)
        XCTAssertTrue(report.capsule.verificationPlan.contains("swift test"))

        let incomplete = try CaptainFailureAnalysis(projectRoot: root,
                                                   now: { Date(timeIntervalSince1970: 1_783_060_501) })
            .recordRepairVerification(capsuleID: report.capsule.id,
                                      evidenceText: """
                                      swift test --filter ProviderVisionEncodingTests passed
                                      swift test --filter DocumentExportTests passed
                                      """)

        XCTAssertEqual(incomplete.status, .incomplete)
        XCTAssertTrue(incomplete.missingVerification.contains("swift test"))

        let verified = try CaptainFailureAnalysis(projectRoot: root,
                                                 now: { Date(timeIntervalSince1970: 1_783_060_502) })
            .recordRepairVerification(capsuleID: report.capsule.id,
                                      evidenceText: """
                                      swift test --filter ProviderVisionEncodingTests passed
                                      swift test --filter DocumentExportTests passed
                                      full suite: Executed 2151 tests, with 4 tests skipped and 0 failures
                                      """)

        XCTAssertEqual(verified.status, .verified)
        XCTAssertTrue(verified.missingVerification.isEmpty)
    }

    func testAutomaticRepairVerificationSkipsDuplicateEvidenceAndRecordsProgress() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let report = CaptainFailureAnalysis(projectRoot: root,
                                            now: { Date(timeIntervalSince1970: 1_783_060_600) })
            .analyze(goal: "can i have this as a pdf",
                     summary: "document export failed: could not create PDF writer",
                     trajectory: [],
                     seedTasks: false)
        let analyzer = CaptainFailureAnalysis(projectRoot: root,
                                              now: { Date(timeIntervalSince1970: 1_783_060_601) })

        let first = try analyzer.recordRepairVerificationIfChanged(
            capsuleID: report.capsule.id,
            evidenceText: "self-heal-critic: swift test --filter DocumentExportTests passed")
        XCTAssertEqual(first?.status, .incomplete)

        let duplicate = try analyzer.recordRepairVerificationIfChanged(
            capsuleID: report.capsule.id,
            evidenceText: "self-heal-critic: swift test --filter DocumentExportTests passed")
        XCTAssertNil(duplicate)

        let verified = try analyzer.recordRepairVerificationIfChanged(
            capsuleID: report.capsule.id,
            evidenceText: """
            self-heal-critic: swift test --filter DocumentExportTests passed
            self-heal-captain-gate: swift test --filter CaptainFailureAnalysisTests passed
            self-heal-captain-gate: swift test --filter KistREPLTests passed
            """)
        XCTAssertEqual(verified?.status, .verified)

        let ledger = try String(contentsOfFile: root + "/.kist/learning/failure-repair-verifications.jsonl",
                                encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? JSONDecoder().decode(CaptainFailureRepairVerification.self, from: Data($0.utf8)) }
        XCTAssertEqual(ledger.count, 2)
        XCTAssertEqual(ledger.map(\.status), [.incomplete, .verified])
    }

    func testRepairVerificationRejectsCommandMentionsWithoutPassingEvidence() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let report = CaptainFailureAnalysis(projectRoot: root,
                                            now: { Date(timeIntervalSince1970: 1_783_060_700) })
            .analyze(goal: "can i have this as a pdf",
                     summary: "document export failed: could not create PDF writer",
                     trajectory: [],
                     seedTasks: false)

        let mentionedOnly = try CaptainFailureAnalysis(projectRoot: root,
                                                      now: { Date(timeIntervalSince1970: 1_783_060_701) })
            .recordRepairVerification(capsuleID: report.capsule.id,
                                      evidenceText: """
                                      self-heal-critic: did not run swift test --filter DocumentExportTests
                                      self-heal-gate: swift test --filter CaptainFailureAnalysisTests is the right command
                                      self-heal-gate: swift test --filter KistREPLTests failed
                                      """)

        XCTAssertEqual(mentionedOnly.status, .incomplete)
        XCTAssertTrue(mentionedOnly.missingVerification.contains("swift test --filter DocumentExportTests"))
        XCTAssertTrue(mentionedOnly.missingVerification.contains("swift test --filter CaptainFailureAnalysisTests"))
        XCTAssertTrue(mentionedOnly.missingVerification.contains("swift test --filter KistREPLTests"))
    }

    func testVerificationEvidenceExtractorIgnoresNarrativeAndKeepsProofLines() {
        let extracted = CaptainFailureAnalysis.extractVerificationEvidence(from: """
        I would run swift test --filter DocumentExportTests next.
        This should not count as proof.
        VERIFY: swift test --filter DocumentExportTests => PASS: executed 5 tests with 0 failures
        swift test --filter CaptainFailureAnalysisTests failed with 1 failure
        full suite: Executed 2157 tests, with 4 tests skipped and 0 failures
        git diff --check is a good idea.
        git diff --check clean
        """)

        XCTAssertFalse(extracted.contains("I would run"))
        XCTAssertFalse(extracted.contains("good idea"))
        XCTAssertTrue(extracted.contains("VERIFY: swift test --filter DocumentExportTests"))
        XCTAssertTrue(extracted.contains("swift test --filter CaptainFailureAnalysisTests failed"))
        XCTAssertTrue(extracted.contains("full suite: Executed 2157 tests"))
        XCTAssertTrue(extracted.contains("git diff --check clean"))
    }

    func testStructuredVerificationEvidenceExtractsOutcomeAndCommand() {
        let timestamp = Date(timeIntervalSince1970: 1_783_061_000)
        let extracted = CaptainFailureAnalysis.extractStructuredEvidence(from: """
        I would run swift test --filter DocumentExportTests next.
        VERIFY: swift test --filter DocumentExportTests => PASS: executed 5 tests with 0 failures
        full suite: Executed 2157 tests, with 4 tests skipped and 0 failures
        git diff --check clean
        swift test --filter CaptainFailureAnalysisTests failed with 1 failure
        """, timestamp: timestamp)

        XCTAssertEqual(extracted.map(\.command), [
            "swift test --filter DocumentExportTests",
            "swift test",
            "git diff --check",
            "swift test --filter CaptainFailureAnalysisTests"
        ])
        XCTAssertEqual(extracted.map(\.outcome), [.pass, .pass, .pass, .fail])
        XCTAssertEqual(extracted.first?.rawLine,
                       "VERIFY: swift test --filter DocumentExportTests => PASS: executed 5 tests with 0 failures")
        XCTAssertEqual(extracted.first?.timestamp, timestamp)
    }

    func testVerificationEvidenceSummaryRendersCommandOutcomes() {
        let summary = CaptainFailureAnalysis.renderVerificationEvidenceSummary([
            .init(command: "swift test --filter DocumentExportTests",
                  outcome: .pass,
                  rawLine: "VERIFY: swift test --filter DocumentExportTests => PASS",
                  timestamp: nil),
            .init(command: "git diff --check",
                  outcome: .fail,
                  rawLine: "VERIFY: git diff --check => FAIL",
                  timestamp: nil),
            .init(command: "",
                  outcome: .unknown,
                  rawLine: "VERIFY: manual review pending",
                  timestamp: nil)
        ])

        XCTAssertTrue(summary.contains("pass: swift test --filter DocumentExportTests"))
        XCTAssertTrue(summary.contains("fail: git diff --check"))
        XCTAssertTrue(summary.contains("unknown: VERIFY: manual review pending"))
    }

    func testStructuredEvidenceExtractorRejectsNarrativeCommandMentions() {
        let extracted = CaptainFailureAnalysis.extractStructuredEvidence(from: """
        The next command should be swift test --filter DocumentExportTests.
        git diff --check is a good idea.
        We should run the full suite before merging.
        """)

        XCTAssertTrue(extracted.isEmpty)
    }

    func testStructuredRepairVerificationRecordsStructuredLedgerEvidence() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let report = CaptainFailureAnalysis(projectRoot: root,
                                            now: { Date(timeIntervalSince1970: 1_783_061_100) })
            .analyze(goal: "can i have this as a pdf",
                     summary: "document export failed: could not create PDF writer",
                     trajectory: [],
                     seedTasks: false)
        let evidence: [VerificationEvidence] = [
            .init(command: "swift test --filter DocumentExportTests",
                  outcome: .pass,
                  rawLine: "VERIFY: swift test --filter DocumentExportTests => PASS: executed 5 tests with 0 failures",
                  timestamp: Date(timeIntervalSince1970: 1_783_061_101)),
            .init(command: "swift test --filter CaptainFailureAnalysisTests",
                  outcome: .pass,
                  rawLine: "VERIFY: swift test --filter CaptainFailureAnalysisTests => PASS: executed 18 tests with 0 failures",
                  timestamp: Date(timeIntervalSince1970: 1_783_061_102)),
            .init(command: "swift test --filter KistREPLTests",
                  outcome: .pass,
                  rawLine: "VERIFY: swift test --filter KistREPLTests => PASS: executed 32 tests with 0 failures",
                  timestamp: Date(timeIntervalSince1970: 1_783_061_103))
        ]

        let verification = try CaptainFailureAnalysis(projectRoot: root,
                                                      now: { Date(timeIntervalSince1970: 1_783_061_104) })
            .recordRepairVerification(capsuleID: report.capsule.id,
                                      evidence: evidence)

        XCTAssertEqual(verification.status, .verified)
        XCTAssertEqual(verification.structuredEvidence, evidence)

        let ledger = try String(contentsOfFile: root + "/.kist/learning/failure-repair-verifications.jsonl",
                                encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? JSONDecoder().decode(CaptainFailureRepairVerification.self, from: Data($0.utf8)) }
        XCTAssertEqual(ledger.first?.structuredEvidence, evidence)
    }

    func testStructuredRepairVerificationUsesLatestOutcomeForRepeatedCommand() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let report = CaptainFailureAnalysis(projectRoot: root,
                                            now: { Date(timeIntervalSince1970: 1_783_061_200) })
            .analyze(goal: "can i have this as a pdf",
                     summary: "document export failed: could not create PDF writer",
                     trajectory: [],
                     seedTasks: false)
        let evidence: [VerificationEvidence] = [
            .init(command: "swift test --filter DocumentExportTests",
                  outcome: .fail,
                  rawLine: "VERIFY: swift test --filter DocumentExportTests => FAIL: 1 failure",
                  timestamp: nil),
            .init(command: "swift test --filter DocumentExportTests",
                  outcome: .pass,
                  rawLine: "VERIFY: swift test --filter DocumentExportTests => PASS: executed 5 tests with 0 failures",
                  timestamp: nil),
            .init(command: "swift test --filter CaptainFailureAnalysisTests",
                  outcome: .pass,
                  rawLine: "VERIFY: swift test --filter CaptainFailureAnalysisTests => PASS: executed 18 tests with 0 failures",
                  timestamp: nil),
            .init(command: "swift test --filter KistREPLTests",
                  outcome: .pass,
                  rawLine: "VERIFY: swift test --filter KistREPLTests => PASS: executed 32 tests with 0 failures",
                  timestamp: nil)
        ]

        let verification = try CaptainFailureAnalysis(projectRoot: root)
            .recordRepairVerification(capsuleID: report.capsule.id,
                                      evidence: evidence)

        XCTAssertEqual(verification.status, .verified)
        XCTAssertTrue(verification.missingVerification.isEmpty)
    }

    func testStructuredRepairVerificationPreservesSemicolonInRawEvidenceLine() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let report = CaptainFailureAnalysis(projectRoot: root,
                                            now: { Date(timeIntervalSince1970: 1_783_061_300) })
            .analyze(goal: "can i have this as a pdf",
                     summary: "document export failed: could not create PDF writer",
                     trajectory: [],
                     seedTasks: false)
        let firstLine = "VERIFY: swift test --filter DocumentExportTests => PASS: output kept warning; executed 5 tests with 0 failures"
        let evidence: [VerificationEvidence] = [
            .init(command: "swift test --filter DocumentExportTests",
                  outcome: .pass,
                  rawLine: firstLine,
                  timestamp: nil),
            .init(command: "swift test --filter CaptainFailureAnalysisTests",
                  outcome: .pass,
                  rawLine: "VERIFY: swift test --filter CaptainFailureAnalysisTests => PASS: executed 18 tests with 0 failures",
                  timestamp: nil),
            .init(command: "swift test --filter KistREPLTests",
                  outcome: .pass,
                  rawLine: "VERIFY: swift test --filter KistREPLTests => PASS: executed 32 tests with 0 failures",
                  timestamp: nil)
        ]

        let verification = try CaptainFailureAnalysis(projectRoot: root)
            .recordRepairVerification(capsuleID: report.capsule.id,
                                      evidence: evidence)

        XCTAssertEqual(verification.status, .verified)
        XCTAssertEqual(verification.evidence.count, 3)
        XCTAssertEqual(verification.evidence.first, firstLine)
    }

    func testRepairVerificationRequiresCleanDiffCheckEvidence() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let analyzer = CaptainFailureAnalysis(projectRoot: root,
                                              now: { Date(timeIntervalSince1970: 1_783_060_800) })
        let report = analyzer.analyze(goal: "tool failed",
                                      summary: "tool execution failed",
                                      trajectory: [
                                        ActionRecord(tool: "write_file",
                                                     argsFingerprint: "path",
                                                     success: false)
                                      ],
                                      seedTasks: false)
        XCTAssertTrue(report.capsule.verificationPlan.contains("git diff --check"))

        let dirty = try analyzer.recordRepairVerification(capsuleID: report.capsule.id,
                                                         evidenceText: """
                                                         Run the focused test for write_file passed
                                                         git diff --check had whitespace errors
                                                         """)
        XCTAssertEqual(dirty.status, .incomplete)
        XCTAssertTrue(dirty.missingVerification.contains("git diff --check"))

        let clean = try analyzer.recordRepairVerification(capsuleID: report.capsule.id,
                                                         evidenceText: """
                                                         Run the focused test for write_file passed
                                                         git diff --check clean
                                                         """)
        XCTAssertEqual(clean.status, .verified)
    }

    private func tempRoot() -> String {
        let root = NSTemporaryDirectory() + "captain_failure_analysis_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }
}
