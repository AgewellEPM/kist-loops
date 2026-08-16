import XCTest
@testable import AgentCore

final class ResearchEvidencePolicyTests: XCTestCase {
    func testPEELReceiptDigestUsesCanonicalSHA256Format() {
        let text = "exact symbolic evidence bytes\n"
        let digest = PEELEvidenceReceipt.contentDigest(text)

        XCTAssertEqual(digest, BuilderEvidenceDigest.sha256(text))
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(digest.allSatisfy(\.isHexDigit))
    }

    func testContextChunkIDsAcceptOnlyCanonicalDeduplicatedSearchRows() {
        let output = """
        Context search: goal
        Matches: 4

        - test.sh:L1-L9 · 240 chars
          preview
        - Sources/A.swift:L10-L30 · 900 chars
        - test.sh:L1-L9 · 240 chars
        - ../../escape · 12 chars
        """

        XCTAssertEqual(ResearchEvidencePolicy.contextChunkIDs(searchOutput: output), [
            "test.sh:L1-L9", "Sources/A.swift:L10-L30",
        ])
        XCTAssertEqual(ResearchEvidencePolicy.contextChunkIDs(searchOutput: output, limit: 1), [
            "test.sh:L1-L9",
        ])
    }

    func testPrimarySelectionPrefersRelevantOfficialHTMLAndRejectsPrivateCandidates() {
        let search = """
        1. Sample
           URL: https://github.com/example/gnucobol-sample
        2. Internal trap
           URL: http://127.0.0.1/manual
        3. Official PDF
           URL: https://gnucobol.sourceforge.io/doc/gnucobol.pdf
        4. Official Programmer Guide
           URL: https://gnucobol.sourceforge.io/HTML/gnucobpg.html
        """

        let selected = ResearchEvidencePolicy.rankedPrimarySourceURLs(
            searchOutput: search, goal: "Create a GnuCOBOL program", limit: 3)

        XCTAssertEqual(selected.first,
                       "https://gnucobol.sourceforge.io/HTML/gnucobpg.html")
        XCTAssertFalse(selected.contains(where: { $0.contains("127.0.0.1") }))
        XCTAssertLessThanOrEqual(selected.count, 3)
    }

    func testSearchSnippetAndTamperedFetchCannotSatisfyPrimaryPolicy() {
        let snippet = ResearchEvidence(
            sequence: 1, id: "E001", kind: "web_search", title: "search",
            url: nil, path: nil, text: "URL: https://docs.example/manual",
            metadata: ["status": "200"], at: 0)
        let tampered = ResearchEvidence(
            sequence: 2, id: "E002", kind: "fetch_url", title: "manual",
            url: "https://docs.example/manual", path: nil, text: "actual bytes",
            metadata: [
                "status": "200", "fetch_status": "complete",
                "content_sha256": BuilderEvidenceDigest.sha256("different bytes"),
            ], at: 0)

        XCTAssertTrue(ResearchEvidencePolicy.verifiedPrimarySources(
            in: [snippet, tampered]).isEmpty)
    }

    func testVerifiedPrimaryAcceptsBounded200PrefixOnlyWithTruncationProof() {
        let text = "bounded documentation prefix"
        let base = ResearchEvidence(
            sequence: 1, id: "E003", kind: "fetch_url", title: "manual",
            url: "https://docs.example/manual", path: nil, text: text,
            metadata: [
                "status": "200", "fetch_status": "partial",
                "content_sha256": BuilderEvidenceDigest.sha256(text),
            ], at: 0)
        let proven = ResearchEvidence(
            sequence: base.sequence, id: base.id, kind: base.kind, title: base.title,
            url: base.url, path: base.path, text: base.text,
            metadata: base.metadata.merging(["truncated": "true"]) { _, new in new }, at: base.at)

        XCTAssertTrue(ResearchEvidencePolicy.verifiedPrimarySources(in: [base]).isEmpty)
        XCTAssertEqual(ResearchEvidencePolicy.verifiedPrimarySources(in: [proven]).map(\.evidenceID), ["E003"])
    }

    func testPEELRelevanceRejectsUnrelatedTilesAndBindsAcceptedCitation() {
        let text = "The GnuCOBOL DISPLAY statement writes a literal followed by a line terminator."
        let primary = VerifiedResearchPrimarySource(
            evidenceID: "E003", title: "GnuCOBOL Programmer Guide",
            url: "https://gnucobol.sourceforge.io/HTML/gnucobpg.html",
            httpStatus: 206, contentSHA256: BuilderEvidenceDigest.sha256(text), text: text)
        let goal = "Create GnuCOBOL DISPLAY output containing COBOLO_OK"

        XCTAssertFalse(ResearchEvidencePolicy.peelIsRelevant(
            goal: goal,
            output: "Japan has coastal population centers and unrelated demographic facts.",
            primary: primary))
        let relevant = "GnuCOBOL can use DISPLAY for the requested COBOLO output, as supported by [E003]. SHA-256 \(primary.contentSHA256)"
        XCTAssertTrue(ResearchEvidencePolicy.peelIsRelevant(
            goal: goal, output: relevant, primary: primary))
        XCTAssertTrue(ResearchEvidencePolicy.peelQuery(goal: goal, primary: primary)
            .contains("Required citation: [E003]"))
        let bound = ResearchEvidencePolicy.bindPEELOutput(relevant, primary: primary)
        XCTAssertTrue(bound.contains("[PRIMARY EVIDENCE E003]"))
        XCTAssertTrue(bound.contains(primary.contentSHA256))
    }

    func testEvidenceBoundJeevesPEELUsesVerifiedSourceWithoutCallingLegacyBridge() async {
        let bridgeCalls = PEELBridgeProbe()
        let text = "GnuCOBOL documents the Extended DISPLAY statement for program output."
        let digest = BuilderEvidenceDigest.sha256(text)
        let tool = JeevesResearchTool(runner: { _ in
            await bridgeCalls.record()
            return .failure("legacy bridge must not run")
        })
        let result = await ToolRegistry([tool]).execute(
            name: "jeeves_research",
            arguments: [
                "query": "Use GnuCOBOL DISPLAY for COBOLO output",
                "research_goal": "Use GnuCOBOL DISPLAY for COBOLO output",
                "primary_evidence_id": "E003",
                "primary_url": "https://gnucobol.example/manual",
                "primary_status": 200,
                "primary_digest": digest,
                "primary_evidence_text": text,
            ],
            context: ToolContext(projectRoot: "/tmp"))

        let recordedBridgeCalls = await bridgeCalls.count()
        XCTAssertTrue(result.success, result.error ?? result.output)
        XCTAssertEqual(recordedBridgeCalls, 0)
        XCTAssertTrue(result.output.contains("SYMBOLIC PEEL: PASS"))
        XCTAssertTrue(result.output.contains("[E003]"))
        XCTAssertEqual(result.metadata["primary_content_sha256"], digest)
    }

    func testEvidenceBoundJeevesPEELRejectsTamperAndIrrelevance() async {
        let tool = JeevesResearchTool(runner: { _ in .failure("unused") })
        let registry = ToolRegistry([tool])
        let base: [String: Any] = [
            "query": "Use GnuCOBOL DISPLAY for output",
            "research_goal": "Use GnuCOBOL DISPLAY for output",
            "primary_evidence_id": "E003",
            "primary_url": "https://docs.example/manual",
            "primary_status": 200,
        ]
        var tampered = base
        tampered["primary_digest"] = BuilderEvidenceDigest.sha256("different")
        tampered["primary_evidence_text"] = "GnuCOBOL DISPLAY documentation."
        let tamperResult = await registry.execute(
            name: "jeeves_research", arguments: tampered,
            context: ToolContext(projectRoot: "/tmp"))

        var irrelevant = base
        let unrelated = "Coastal population statistics and unrelated judicial history."
        irrelevant["primary_digest"] = BuilderEvidenceDigest.sha256(unrelated)
        irrelevant["primary_evidence_text"] = unrelated
        let relevanceResult = await registry.execute(
            name: "jeeves_research", arguments: irrelevant,
            context: ToolContext(projectRoot: "/tmp"))

        XCTAssertFalse(tamperResult.success)
        XCTAssertFalse(relevanceResult.success)
    }

    func testSymbolicPEELUsesOriginalGoalAndSkipsWeakManualIndex() {
        let generic = "GnuCOBOL Manual. Authors and documentation index. Compiler options and module loader."
        let genericSource = VerifiedResearchPrimarySource(
            evidenceID: "E003", title: "GnuCOBOL Manual",
            url: "https://docs.example/gnucobol/manual", httpStatus: 200,
            contentSHA256: BuilderEvidenceDigest.sha256(generic), text: generic)
        let relevant = "GnuCOBOL program output uses the DISPLAY statement. A newline is emitted unless NO ADVANCING is specified."
        let relevantSource = VerifiedResearchPrimarySource(
            evidenceID: "E004", title: "GnuCOBOL Programmer Guide",
            url: "https://docs.example/gnucobol/programmer", httpStatus: 200,
            contentSHA256: BuilderEvidenceDigest.sha256(relevant), text: relevant)
        let goal = "Create a valid GnuCOBOL program printing a newline"

        XCTAssertNil(ResearchEvidencePolicy.symbolicPEEL(goal: goal, primary: genericSource))
        XCTAssertEqual(ResearchEvidencePolicy.firstRelevantPrimarySource(
            goal: goal, in: [genericSource, relevantSource])?.evidenceID, "E004")
        XCTAssertNotNil(ResearchEvidencePolicy.symbolicPEEL(goal: goal, primary: relevantSource))
    }

    func testEvidenceBoundPEELCannotLaunderEvidenceThroughRenderedQuery() async {
        let generic = "GnuCOBOL Manual. Authors, copyright, documentation, and compiler index."
        let primary = VerifiedResearchPrimarySource(
            evidenceID: "E003", title: "manual", url: "https://docs.example/manual",
            httpStatus: 200, contentSHA256: BuilderEvidenceDigest.sha256(generic), text: generic)
        let result = await ToolRegistry([JeevesResearchTool(runner: { _ in .failure("unused") })]).execute(
            name: "jeeves_research",
            arguments: [
                "query": ResearchEvidencePolicy.peelQuery(
                    goal: "Create a GnuCOBOL program printing a newline", primary: primary),
                "research_goal": "Create a GnuCOBOL program printing a newline",
                "primary_evidence_id": primary.evidenceID,
                "primary_url": primary.url,
                "primary_status": primary.httpStatus,
                "primary_digest": primary.contentSHA256,
                "primary_evidence_text": primary.text,
            ],
            context: ToolContext(projectRoot: "/tmp"))

        XCTAssertFalse(result.success)
    }
}

private actor PEELBridgeProbe {
    private var calls = 0
    func record() { calls += 1 }
    func count() -> Int { calls }
}
