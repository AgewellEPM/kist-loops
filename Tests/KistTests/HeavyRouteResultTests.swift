import XCTest
import AgentCore
@testable import Kist

final class HeavyRouteResultTests: XCTestCase {
    func testInterruptionOverridesZeroExitCode() {
        let result = HeavyRouteResult(
            exitCode: 0,
            interruption: .interject,
            review: .notApplicable("no external review was requested"),
            verification: .unavailable("execution was interrupted"))

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.finalText, "interrupted — heavy route stopped before completion")
        XCTAssertNil(result.verification.proofSuccess)
    }

    func testVerifiedFailureStaysDistinctFromUnavailableVerification() {
        let failed = HeavyRouteResult(
            exitCode: 1,
            interruption: nil,
            review: .handledInternally("the route owns its critic stage"),
            verification: .failed("the route's deterministic gate did not pass"))
        let advisory = HeavyRouteResult(
            exitCode: 0,
            interruption: nil,
            review: .handledInternally("the council synthesized its own review"),
            verification: .unavailable("this advisory route has no deterministic oracle"))

        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(failed.verification.proofSuccess, false)
        XCTAssertTrue(advisory.succeeded)
        XCTAssertNil(advisory.verification.proofSuccess)
        XCTAssertTrue(advisory.verification.proofText.hasPrefix("unavailable"))
    }

    func testHeavyRouteProofHasOneTypedDecisionAndOneCanonicalFinal() {
        let result = HeavyRouteResult(
            exitCode: 0,
            interruption: nil,
            review: .handledInternally("the council owns critique"),
            verification: .unavailable("advisory route has no deterministic oracle"))

        let entries = [HeavyRouteProof.routeEntry(intent: .review, mode: .inline,
                                                  execution: "council")]
            + HeavyRouteProof.completionEntries(result: result, intent: .review,
                                                mode: .inline, execution: "council")

        XCTAssertEqual(entries.map(\.kind), [.routeSelected, .reviewAssessment,
                                              .verificationAssessment, .turnFinalized])
        XCTAssertEqual(entries.filter { $0.kind == .routeSelected }.count, 1)
        XCTAssertEqual(entries.filter { $0.kind == .turnFinalized }.count, 1)
        XCTAssertNil(entries[2].success, "unavailable verification must never be recorded as passing")
        XCTAssertEqual(entries[3].success, true, "the route itself completed even though no oracle exists")
    }

    func testHeavyRouteProofFinalizesInterruptedRunAsFailure() {
        let result = HeavyRouteResult(
            exitCode: 0,
            interruption: .cancel,
            review: .notApplicable("the route was cancelled"),
            verification: .unavailable("the route was cancelled"))

        let entries = HeavyRouteProof.completionEntries(result: result, intent: .fleet,
                                                        mode: .fleet, execution: "fleet(3)")

        XCTAssertEqual(entries.last?.kind, .turnFinalized)
        XCTAssertEqual(entries.last?.success, false)
        XCTAssertTrue(entries.last?.text.contains("cancelled") == true)
    }

    func testMutationRouteCannotFinalizeSuccessWhenVerificationIsUnavailable() {
        let result = HeavyRouteResult(
            exitCode: 0,
            interruption: nil,
            review: .handledInternally("review finished"),
            verification: .unavailable("no deterministic oracle ran"))

        let entries = HeavyRouteProof.completionEntries(result: result, intent: .build,
                                                        mode: .planExecute, execution: "plan-execute")
        XCTAssertFalse(result.satisfiesExpectedOutcome(intent: .build, mode: .planExecute))
        XCTAssertTrue(result.satisfiesExpectedOutcome(intent: .research, mode: .inline),
                      "advisory routes may succeed without an execution oracle")
        XCTAssertEqual(entries.last?.kind, .turnFinalized)
        XCTAssertEqual(entries.last?.success, false)
        XCTAssertTrue(entries.last?.text.contains("result=failed") == true)
        XCTAssertTrue(entries.last?.text.contains("route_status=completed") == true,
                      "typed failure and raw route exit must remain distinct and truthful")
    }

    func testHeavyResultCarriesBoundedSubstanceAndOnlyVerifiedProjectArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-heavy-context-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let report = root.appendingPathComponent("report.md")
        try "grounded report".write(to: report, atomically: true, encoding: .utf8)
        let directory = root.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let symlink = root.appendingPathComponent("report-link.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: report)

        let references = HeavyRouteResult.verifiedArtifactReferences(
            ["report.md", "directory", "report-link.md", "/etc/passwd", "missing.md"],
            projectRoot: root.path)
        let canonicalReport = try XCTUnwrap(ToolContext.canonicalize(report.path))
        XCTAssertEqual(references.count, 1)
        XCTAssertTrue(references[0].hasPrefix(canonicalReport + " [sha256:"))

        let result = HeavyRouteResult(
            exitCode: 0, interruption: nil,
            review: .handledInternally("council critique"),
            verification: .unavailable("advisory route"),
            substantiveSummary: String(repeating: "x", count: 5_000),
            artifactReferences: references)
        XCTAssertEqual(result.substantiveSummary?.count, 4_000)
        XCTAssertTrue(result.transcriptSummary.contains("Substantive result (advisory)"))
        XCTAssertTrue(result.transcriptSummary.contains(report.path))

        try "replaced report".write(to: report, atomically: true, encoding: .utf8)
        XCTAssertTrue(HeavyRouteResult.revalidatedArtifactReferences(
            references, projectRoot: root.path).isEmpty,
            "a digest receipt must be rejected after the artifact changes")
    }

    func testCouncilContextRequiresTheExactCapturedRegularFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-council-context-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let artifact = root.appendingPathComponent("council.md")
        let markdown = "# Council\n\nVerified board\n"
        try markdown.write(to: artifact, atomically: true, encoding: .utf8)
        let result = CouncilRunResult(
            goal: "fix parser", minds: [], finalPlan: "Implement and test parser",
            markdown: markdown, builderBrief: "advisory builder brief")
        let capture = KistRunner.CouncilPipelineCapture(
            result: result, artifactPath: artifact.path)

        let verified = try XCTUnwrap(HeavyRouteResult.verifiedCouncilContext(
            capture, projectRoot: root.path))
        XCTAssertEqual(verified.substantiveSummary, "Implement and test parser")
        XCTAssertEqual(verified.artifactReferences.count, 1)

        try "tampered".write(to: artifact, atomically: true, encoding: .utf8)
        XCTAssertNil(HeavyRouteResult.verifiedCouncilContext(capture, projectRoot: root.path))

        let target = root.appendingPathComponent("target.md")
        try markdown.write(to: target, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNil(HeavyRouteResult.verifiedCouncilContext(
            .init(result: result, artifactPath: link.path), projectRoot: root.path))
    }

    func testResearchContextRequiresExactRunManifestAndReportDigest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-research-context-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runID = "run_fixture"
        let base = root.appendingPathComponent(".kist/research-runs/\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let report = "# Research Dossier\n\nGrounded finding.\n"
        try report.write(to: base.appendingPathComponent("report.md"),
                         atomically: true, encoding: .utf8)
        let evidence = #"{"sequence":1,"id":"E001","kind":"web_search","title":"Fixture evidence","text":"Grounded finding.","metadata":{},"at":1}"# + "\n"
        let evidenceURL = base.appendingPathComponent("evidence.jsonl")
        try evidence.write(to: evidenceURL, atomically: true, encoding: .utf8)
        let canonicalRoot = try XCTUnwrap(ToolContext.canonicalize(root.path))
        func manifestData(status: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "runID": runID,
                "goal": "inspect parser",
                "projectRoot": canonicalRoot,
                "status": status,
                "createdAt": 1.0,
                "updatedAt": 2.0,
                "reportPath": ".kist/research-runs/\(runID)/report.md",
            ], options: [.sortedKeys])
        }
        try manifestData(status: "synthesized").write(
            to: base.appendingPathComponent("manifest.json"), options: .atomic)
        let capture = KistRunner.ResearchPipelineCapture(
            runID: runID,
            manifestPath: ".kist/research-runs/\(runID)/manifest.json",
            evidencePath: ".kist/research-runs/\(runID)/evidence.jsonl",
            reportPath: ".kist/research-runs/\(runID)/report.md",
            dossier: report,
            dossierDigest: PEELEvidenceReceipt.contentDigest(report),
            evidenceDigest: KistRunner.ResearchPipelineCapture.sha256Hex(Data(evidence.utf8)),
            peelReceipt: .init(researchRunID: runID, status: .skippedUnavailable,
                               summary: "optional gate unavailable"))

        let verified = try XCTUnwrap(HeavyRouteResult.verifiedResearchContext(
            capture, projectRoot: root.path))
        XCTAssertEqual(verified.substantiveSummary, report.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(verified.artifactReferences.count, 3)

        try manifestData(status: "council").write(
            to: base.appendingPathComponent("manifest.json"), options: .atomic)
        XCTAssertNotNil(HeavyRouteResult.verifiedResearchContext(
            capture, projectRoot: root.path),
            "nested council progress must retain an already synthesized report lineage")

        let replacedEvidence = #"{"sequence":1,"id":"E001","kind":"web_search","title":"Replaced evidence","text":"Different bytes.","metadata":{},"at":1}"# + "\n"
        try replacedEvidence.write(to: evidenceURL, atomically: true, encoding: .utf8)
        XCTAssertNil(HeavyRouteResult.verifiedResearchContext(capture, projectRoot: root.path),
                     "nonempty replacement evidence must not inherit the captured lineage")
        try evidence.write(to: evidenceURL, atomically: true, encoding: .utf8)
        XCTAssertNotNil(HeavyRouteResult.verifiedResearchContext(capture, projectRoot: root.path))

        try "replaced dossier".write(to: base.appendingPathComponent("report.md"),
                                      atomically: true, encoding: .utf8)
        XCTAssertNil(HeavyRouteResult.verifiedResearchContext(capture, projectRoot: root.path))
    }

    func testExistingREPLHeavyRoutesReturnAndRecordTheirActualResults() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repl = kistREPLFamilySource()
        let runner = try String(contentsOf: root.appendingPathComponent("Sources/Kist/KistRunner.swift"),
                                encoding: .utf8)

        XCTAssertTrue(repl.contains("async -> HeavyRouteResult"),
                      "heavy routes must return evidence instead of Void")
        XCTAssertTrue(repl.contains("HeavyRouteProof.routeEntry"))
        XCTAssertTrue(repl.contains("HeavyRouteProof.completionEntries"))
        XCTAssertTrue(repl.contains("rememberInConversation || intent.expectsMutation || intent == .desktop"),
                      "mutation routes must remain available to pragmatic follow-up turns")
        XCTAssertTrue(repl.contains("assistantSummary: result.transcriptSummary"))
        XCTAssertFalse(repl.contains("handed off to \\(execution)"),
                       "accepted auto-routing must not synthesize an unknown handoff result")
        XCTAssertTrue(runner.contains("let exitCode = await InterruptibleTurn.run"),
                      "the runner must carry its existing exit code back to the REPL")
        XCTAssertTrue(runner.contains("interrupted.value = reason"),
                      "ESC must be distinguished from an ordinary route failure")
    }
}
