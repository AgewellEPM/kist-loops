import XCTest
@testable import AgentCore

/// The academia-bounded source list: membership, subdomain matching, citation classes, the
/// bounded pull over verified evidence, and the ranking boost that puts scholarly/medical hosts
/// ahead of the open web.
final class AcademicSourceRegistryTests: XCTestCase {
    func testCoreScholarlyMedicalAndEncyclopedicHostsAreMembers() {
        for host in ["scholar.google.com", "pubmed.ncbi.nlm.nih.gov", "en.wikipedia.org",
                     "arxiv.org", "nejm.org", "thelancet.com", "jamanetwork.com", "bmj.com",
                     "cochranelibrary.com", "clinicaltrials.gov", "www.nature.com",
                     "pmc.ncbi.nlm.nih.gov", "link.springer.com", "medrxiv.org"] {
            XCTAssertTrue(AcademicSourceRegistry.isAcademicHost(host), "\(host) must be in the bounded list")
        }
    }

    func testNonAcademicAndLookalikeHostsAreExcluded() {
        for host in ["medium.com", "reddit.com", "healthline.com", "webmd.com",
                     "notnature.com", "fakearxiv.org", "wikipedia.org.evil.com"] {
            XCTAssertFalse(AcademicSourceRegistry.isAcademicHost(host),
                           "\(host) must not pass the bounded list")
        }
    }

    func testCitationClassesDistinguishPeerReviewPreprintAndEncyclopedic() {
        XCTAssertEqual(AcademicSourceRegistry.citationClass(url: "https://pubmed.ncbi.nlm.nih.gov/12345/"),
                       "academic")
        XCTAssertTrue(AcademicSourceRegistry.citationClass(url: "https://www.medrxiv.org/content/x")
            .contains("preprint"))
        XCTAssertTrue(AcademicSourceRegistry.citationClass(url: "https://en.wikipedia.org/wiki/Aspirin")
            .contains("encyclopedic"))
        XCTAssertEqual(AcademicSourceRegistry.citationClass(url: "https://medium.com/post"),
                       "non-academic")
    }

    func testAcademicPullFiltersVerifiedSourcesByRegistryOnly() {
        func source(_ url: String) -> VerifiedResearchPrimarySource {
            VerifiedResearchPrimarySource(evidenceID: url, title: "t", url: url, httpStatus: 200,
                                          contentSHA256: String(repeating: "a", count: 64),
                                          text: "content")
        }
        let mixed = [source("https://pubmed.ncbi.nlm.nih.gov/1/"),
                     source("https://medium.com/post"),
                     source("https://en.wikipedia.org/wiki/X")]
        let academic = AcademicSourceRegistry.academicSources(in: mixed)
        XCTAssertEqual(academic.map(\.url),
                       ["https://pubmed.ncbi.nlm.nih.gov/1/", "https://en.wikipedia.org/wiki/X"])
    }

    func testRankingBoostsAcademicHostsAboveGenericWebAndDoesNotPenalizeTheirPDFs() {
        let search = """
        URL: https://randomblog.example.com/health-post
        URL: https://pubmed.ncbi.nlm.nih.gov/98765/
        URL: https://www.ncbi.nlm.nih.gov/pmc/articles/PMC1/paper.pdf
        """
        let ranked = ResearchEvidencePolicy.rankedPrimarySourceURLs(
            searchOutput: search, goal: "statin myopathy evidence", limit: 3)
        XCTAssertEqual(ranked.first, "https://pubmed.ncbi.nlm.nih.gov/98765/")
        XCTAssertTrue(ranked.dropFirst().first?.contains("ncbi.nlm.nih.gov") == true,
                      "an academic PDF must not be penalized below the generic blog")
        XCTAssertEqual(ranked.last, "https://randomblog.example.com/health-post")
    }

    func testVerifiedAcademicSourcesComposesVerificationThenBoundary() {
        let text = "peer reviewed finding"
        let digest = BuilderEvidenceDigest.sha256(text)
        func evidence(_ id: String, url: String, digestValue: String) -> ResearchEvidence {
            ResearchEvidence(sequence: 1, id: id, kind: "fetch_url", title: "t", url: url,
                             path: nil, text: text,
                             metadata: ["status": "200", "content_sha256": digestValue,
                                        "fetch_status": "complete"],
                             at: Date().timeIntervalSince1970)
        }
        let sources = ResearchEvidencePolicy.verifiedAcademicSources(in: [
            evidence("good", url: "https://pubmed.ncbi.nlm.nih.gov/1/", digestValue: digest),
            evidence("tampered", url: "https://pubmed.ncbi.nlm.nih.gov/2/",
                     digestValue: String(repeating: "b", count: 64)),
            evidence("nonacademic", url: "https://healthline.com/x", digestValue: digest),
        ])
        XCTAssertEqual(sources.map(\.evidenceID), ["good"],
                       "boundary must narrow verified sources, never re-admit tampered or non-academic ones")
    }
}
