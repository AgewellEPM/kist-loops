import Foundation
import XCTest
@testable import AgentCore
@testable import Kist

final class AutonomyMissionTests: XCTestCase {
    func testMissionIsAnAutopilotSandboxedMode() {
        unsetenv("KIST_ACTIVE")
        let options = KistOptions.parse(["--mission", "fix the captain loop"])

        XCTAssertTrue(options.mission)
        XCTAssertTrue(options.auto)
        XCTAssertTrue(options.yolo)
        XCTAssertTrue(options.allowShell)
        XCTAssertTrue(options.sandbox)
        XCTAssertEqual(options.goal, "fix the captain loop")
    }

    func testIndependentReviewRejectsSameProviderAndModel() {
        let deepseek = ProviderBinding(providerId: "deepseek", model: "reasoner")
        XCTAssertNil(KistRunner.independentReviewIdentities(builder: deepseek, reviewer: deepseek))

        let critic = ProviderBinding(providerId: "zhipu", model: "glm-5")
        let identities = KistRunner.independentReviewIdentities(builder: deepseek, reviewer: critic)
        XCTAssertEqual(identities?.builder, "deepseek:reasoner")
        XCTAssertEqual(identities?.reviewer, "zhipu:glm-5")
    }

    func testReceiptLineUsesTheRuntimeContract() throws {
        let line = try XCTUnwrap(KistRunner.autonomyReceiptLine(
            prefix: "KIST_OBJECTIVE_RECEIPT:",
            payload: [
                "receiptType": "kist.objective-stages",
                "schemaVersion": 1,
                "stages": [["name": "verify", "status": "passed"]],
            ]
        ))
        XCTAssertTrue(line.hasPrefix("KIST_OBJECTIVE_RECEIPT: "))
        let json = String(line.dropFirst("KIST_OBJECTIVE_RECEIPT: ".count))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["receiptType"] as? String, "kist.objective-stages")
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
    }

    func testAutonomyDossierRejectsEvidenceLedgerReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-autonomy-evidence-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = "run_fixture"
        let base = root.appendingPathComponent(".kist/research-runs/\(runID)",
                                               isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let report = "# Research Dossier\n\nBound finding.\n"
        try report.write(to: base.appendingPathComponent("report.md"),
                         atomically: true, encoding: .utf8)
        let peelDigest = PEELEvidenceReceipt.contentDigest("symbolic proof")
        func evidenceData(text: String) throws -> Data {
            var data = try JSONEncoder().encode(ResearchEvidence(
                sequence: 1, id: "E001", kind: "symbolic_peel",
                title: "Symbolic PEEL", url: nil,
                path: ".kist/research-runs/\(runID)/evidence.jsonl",
                text: text, metadata: ["digest": peelDigest], at: 1))
            data.append(0x0A)
            return data
        }
        let originalEvidence = try evidenceData(text: "symbolic proof")
        let evidenceURL = base.appendingPathComponent("evidence.jsonl")
        try originalEvidence.write(to: evidenceURL, options: .atomic)
        let canonicalRoot = try XCTUnwrap(ToolContext.canonicalize(root.path))
        let manifest = try JSONSerialization.data(withJSONObject: [
            "runID": runID,
            "goal": "inspect parser",
            "projectRoot": canonicalRoot,
            "status": "synthesized",
            "createdAt": 1.0,
            "updatedAt": 2.0,
            "reportPath": ".kist/research-runs/\(runID)/report.md",
        ], options: [.sortedKeys])
        try manifest.write(to: base.appendingPathComponent("manifest.json"), options: .atomic)
        let capture = KistRunner.ResearchPipelineCapture(
            runID: runID,
            manifestPath: ".kist/research-runs/\(runID)/manifest.json",
            evidencePath: ".kist/research-runs/\(runID)/evidence.jsonl",
            reportPath: ".kist/research-runs/\(runID)/report.md",
            dossier: report,
            dossierDigest: PEELEvidenceReceipt.contentDigest(report),
            evidenceDigest: KistRunner.ResearchPipelineCapture.sha256Hex(originalEvidence),
            peelReceipt: .init(
                researchRunID: runID, status: .passed, evidenceID: "E001",
                locator: ".kist/research-runs/\(runID)/evidence.jsonl",
                digest: peelDigest, summary: "fixture PEEL passed"))

        XCTAssertEqual(try KistRunner.autonomyDossier(capture: capture, root: root.path).text,
                       report)

        // Keep the same PEEL identity/digest metadata so only the exact ledger-byte binding can
        // distinguish this replacement from the captured evidence.
        try evidenceData(text: "replacement bytes").write(to: evidenceURL, options: .atomic)
        XCTAssertThrowsError(try KistRunner.autonomyDossier(capture: capture, root: root.path))
    }
}
