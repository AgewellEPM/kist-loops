import XCTest
import AgentCore
@testable import Kist

final class LegalResearchWorkflowTests: XCTestCase {
    func testProgrammingVocabularyDoesNotStartLegalResearch() {
        for request in ["Review the rule card; false is not legal, the vocabulary accepts yes or no.",
                        "Analyze the release build and verify the API contract.",
                        "Review this test case and its lawful state transitions.",
                        "Help diagnose GoldenEye: invalid rule parameters fail to create a card."] {
            XCTAssertFalse(LegalResearchWorkflow.isLegalResearchIntent(request), request)
        }
        for request in ["Review this lease and explain the eviction deadlines", "Help analyze the court notice",
                        "I need legal research on this contract"] {
            XCTAssertTrue(LegalResearchWorkflow.isLegalResearchIntent(request), request)
        }
    }
    private func tempRoot() -> String {
        let root = NSTemporaryDirectory() + "kist_legal_research_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testLegalResearchIntentCatchesFullResearchAndAvoidsRepairPrompts() {
        XCTAssertTrue(LegalResearchWorkflow.isLegalResearchIntent(
            "I need full legal research on this Connecticut HELOC hardship letter"))
        XCTAssertTrue(LegalResearchWorkflow.isLegalResearchIntent(
            "analyze this contract legally and make a legal memo"))
        XCTAssertFalse(LegalResearchWorkflow.isLegalResearchIntent(
            "fix the code malformed issue from the pdf legal research bug"))
    }

    func testLegalResearchReportExtractsTextSeedsTasksAndSpecialists() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let letter = root + "/hardship letter.txt"
        try write("""
        Lauren Boyett
        South Windsor, Connecticut
        Requesting HELOC hardship assistance, loan modification, mediation, and foreclosure prevention.
        """, to: letter)

        let report = LegalResearchWorkflow(projectRoot: root,
                                           now: { Date(timeIntervalSince1970: 1_783_000_000) })
            .run(input: "full legal research jurisdiction: Connecticut on HELOC hardship '\(letter)'")

        XCTAssertTrue(report.writeSucceeded)
        XCTAssertTrue(report.readyForResearch)
        XCTAssertEqual(report.jurisdiction, "Connecticut")
        XCTAssertEqual(report.sourceCount, 1)
        XCTAssertEqual(report.extractedSourceCount, 1)
        XCTAssertGreaterThanOrEqual(report.createdSpecialists, 3)
        XCTAssertTrue(report.researchGoal.contains("FULL LEGAL RESEARCH REQUEST"))
        XCTAssertTrue(report.researchGoal.contains("Official statutes"))
        XCTAssertTrue(report.researchGoal.contains("HELOC hardship assistance"))
        XCTAssertTrue(report.text.contains("Questions for Attorney"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + report.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.kist/agents/legal-research-lead.md"))

        let plan = PlanStore(projectRoot: root).load()
        XCTAssertTrue(plan.tasks.contains { $0.title.hasPrefix("RESEARCH: Official-source legal research") })
        XCTAssertTrue(plan.tasks.contains { $0.owner == "legal-citation-critic" && $0.kind == .review })
    }

    func testLegalResearchMissingJurisdictionHoldsBeforeResearchHandoff() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let report = LegalResearchWorkflow(projectRoot: root,
                                           now: { Date(timeIntervalSince1970: 1_783_000_100) })
            .run(input: "full legal research on this eviction dispute")

        XCTAssertTrue(report.writeSucceeded)
        XCTAssertFalse(report.readyForResearch)
        XCTAssertTrue(report.blockers.contains { $0.contains("missing jurisdiction") })
        XCTAssertTrue(report.text.contains("UNKNOWN - ask user"))
        XCTAssertTrue(PlanStore(projectRoot: root).load().tasks.contains {
            $0.title.hasPrefix("DECISION: Confirm legal jurisdiction")
        })
    }

    func testJurisdictionDetectionDoesNotTreatCommonAbbreviationsAsStates() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let report = LegalResearchWorkflow(projectRoot: root,
                                           now: { Date(timeIntervalSince1970: 1_783_000_101) })
            .run(input: "full legal research on whether I am OK to sign or if it puts me in breach")

        XCTAssertTrue(report.writeSucceeded)
        XCTAssertNil(report.jurisdiction)
        XCTAssertEqual(report.jurisdictionConfidence, 0)
        XCTAssertTrue(report.blockers.contains { $0.contains("missing jurisdiction") })
    }

    func testExplicitJurisdictionAbbreviationIsAcceptedWithHighConfidence() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let report = LegalResearchWorkflow(projectRoot: root,
                                           now: { Date(timeIntervalSince1970: 1_783_000_102) })
            .run(input: "full legal research jurisdiction: OR on contract notice deadlines")

        XCTAssertTrue(report.writeSucceeded)
        XCTAssertEqual(report.jurisdiction, "Oregon")
        XCTAssertGreaterThanOrEqual(report.jurisdictionConfidence, 90)
        XCTAssertTrue(report.jurisdictionEvidence.contains("explicit"))
    }

    func testContextualStateNameBeatsRandomStateLikeWords() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let memo = root + "/case facts.md"
        try write("Property address: South Windsor, Connecticut 06074\nHELOC issue.", to: memo)

        let report = LegalResearchWorkflow(projectRoot: root,
                                           now: { Date(timeIntervalSince1970: 1_783_000_103) })
            .run(input: "full legal research Washington said this may be urgent '\(memo)'")

        XCTAssertTrue(report.writeSucceeded)
        XCTAssertEqual(report.jurisdiction, "Connecticut")
        XCTAssertGreaterThanOrEqual(report.jurisdictionConfidence, 75)
        XCTAssertFalse(report.blockers.contains { $0.contains("low-confidence jurisdiction") })
    }

    func testExternalConsentMarkersAreStrippedFromObjective() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let report = LegalResearchWorkflow(projectRoot: root,
                                           now: { Date(timeIntervalSince1970: 1_783_000_104) })
            .run(input: "full legal research jurisdiction: CT --send-docs on HELOC hardship")

        XCTAssertTrue(report.writeSucceeded)
        XCTAssertEqual(report.jurisdiction, "Connecticut")
        XCTAssertFalse(report.objective.contains("--send-docs"))
        XCTAssertFalse(report.researchGoal.contains("--send-docs"))
    }

    func testLegalDocumentPathRejectsAbsolutePathOutsideProject() throws {
        let root = tempRoot()
        let outside = NSTemporaryDirectory() + "outside_legal_doc_\(UUID().uuidString).txt"
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outside)
        }
        try write("Property address: South Windsor, Connecticut\nHELOC issue.", to: outside)

        let report = LegalResearchWorkflow(projectRoot: root,
                                           now: { Date(timeIntervalSince1970: 1_783_000_105) })
            .run(input: "full legal research jurisdiction: CT '\(outside)'")

        XCTAssertTrue(report.writeSucceeded)
        XCTAssertEqual(report.sourceCount, 0)
        XCTAssertEqual(report.extractedSourceCount, 0)
        XCTAssertTrue(report.text.contains("No document file was attached"))
    }

    func testLegalDocumentPathRejectsSymlinkEscape() throws {
        let root = tempRoot()
        let outside = NSTemporaryDirectory() + "outside_legal_target_\(UUID().uuidString).txt"
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outside)
        }
        try write("Property address: South Windsor, Connecticut\nHELOC issue.", to: outside)
        let link = root + "/escape.txt"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)

        let report = LegalResearchWorkflow(projectRoot: root,
                                           now: { Date(timeIntervalSince1970: 1_783_000_106) })
            .run(input: "full legal research jurisdiction: CT '\(link)'")

        XCTAssertTrue(report.writeSucceeded)
        XCTAssertEqual(report.sourceCount, 0)
        XCTAssertEqual(report.extractedSourceCount, 0)
        XCTAssertFalse(report.text.contains("outside_legal_target"))
    }

    func testTextExtractionNotesWhenDocumentIsTruncated() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let memo = root + "/long hardship memo.txt"
        try write("South Windsor, Connecticut\n" + String(repeating: "HELOC hardship facts. ", count: 900),
                  to: memo)

        let report = LegalResearchWorkflow(projectRoot: root,
                                           now: { Date(timeIntervalSince1970: 1_783_000_107) })
            .run(input: "full legal research jurisdiction: CT '\(memo)'")

        XCTAssertTrue(report.writeSucceeded)
        XCTAssertEqual(report.sourceCount, 1)
        XCTAssertEqual(report.extractedSourceCount, 1)
        XCTAssertTrue(report.text.contains("truncated to 12000 characters"))
        XCTAssertTrue(report.researchGoal.contains("truncated to 12000 characters"))
        XCTAssertTrue(report.researchGoal.contains("[truncated]"))
    }

    func testPDFExtractionFailureRequestsOCRBeforeDocumentSpecificConclusions() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let pdf = root + "/scanned-hardship.pdf"
        try Data("%PDF".utf8).write(to: URL(fileURLWithPath: pdf))

        let report = LegalResearchWorkflow(projectRoot: root,
                                           now: { Date(timeIntervalSince1970: 1_783_000_108) })
            .run(input: "full legal research jurisdiction: CT '\(pdf)'")

        XCTAssertTrue(report.writeSucceeded)
        XCTAssertEqual(report.sourceCount, 1)
        XCTAssertEqual(report.extractedSourceCount, 0)
        XCTAssertFalse(report.readyForResearch)
        XCTAssertTrue(report.text.contains("OCR/vision needed"))
        XCTAssertTrue(report.blockers.contains { $0.contains("OCR/searchable text") })
    }

    func testKistREPLLegalResearchHelpersExposeWorkflow() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let memo = root + "/DC case facts.md"
        try write("Jurisdiction: Connecticut\nCourt deadline question.", to: memo)

        XCTAssertTrue(KistREPL.isLegalResearchIntent("legal research this case \(memo)"))
        let report = KistREPL.handleLegalResearchCommand("legal research this case '\(memo)'",
                                                         projectRoot: root)
        XCTAssertTrue(report.writeSucceeded)
        XCTAssertEqual(report.jurisdiction, "Connecticut")
        XCTAssertTrue(report.researchGoal.contains("Court deadline question"))
    }

    func testLegalResearchMemoryAppendSurvivesConcurrentWriters() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let queue = DispatchQueue(label: "legal-memory-concurrent", attributes: .concurrent)
        let group = DispatchGroup()

        for idx in 0..<20 {
            group.enter()
            queue.async {
                _ = LegalResearchWorkflow(projectRoot: root,
                                          now: { Date(timeIntervalSince1970: Double(1_783_001_000 + idx)) })
                    .run(input: "full legal research jurisdiction: Connecticut on issue \(idx)")
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)

        let path = root + "/.kist/learning/knowledge-index.jsonl"
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 20)
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
    }
}
