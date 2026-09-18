import Foundation

/// The curated academia-bounded source list: the registry research pulls from when the caller
/// wants REAL academic/medical evidence rather than the open web. Membership is a curated,
/// reviewable allowlist — never inferred from page content, never extended at runtime — so the
/// boundary itself is auditable. Fetch-level verification (content SHA-256 binding, status
/// checks) still applies through ResearchEvidencePolicy; this registry only decides which hosts
/// count as academic.
public enum AcademicSourceRegistry {
    /// Scholarly discovery and aggregation.
    static let scholarlyDomains: [String] = [
        "scholar.google.com", "semanticscholar.org", "arxiv.org", "openalex.org",
        "crossref.org", "doaj.org", "core.ac.uk", "jstor.org", "academic.oup.com",
    ]

    /// Encyclopedic grounding. Wikipedia is admissible background, and its provenance class is
    /// still curated-web, not peer review — writers must cite the underlying papers for claims.
    static let encyclopedicDomains: [String] = [
        "wikipedia.org", "wikidata.org",
    ]

    /// Medical literature, trials, and public-health authorities — the core of the medical
    /// research lane.
    static let medicalDomains: [String] = [
        "pubmed.ncbi.nlm.nih.gov", "ncbi.nlm.nih.gov", "nih.gov", "clinicaltrials.gov",
        "cochranelibrary.com", "who.int", "cdc.gov", "medlineplus.gov", "ema.europa.eu",
        "biorxiv.org", "medrxiv.org",
        "nejm.org", "thelancet.com", "jamanetwork.com", "bmj.com", "nature.com",
        "science.org", "cell.com", "plos.org", "frontiersin.org", "mdpi.com",
        "link.springer.com", "springer.com", "sciencedirect.com",
        "onlinelibrary.wiley.com", "wiley.com", "tandfonline.com", "karger.com",
    ]

    /// The full bounded list, deduplicated and sorted for stable display and audit.
    public static let domains: [String] = Array(
        Set(scholarlyDomains + encyclopedicDomains + medicalDomains)).sorted()

    /// Preprint servers are real research but not peer-reviewed; writers must label them.
    public static let preprintDomains: Set<String> = ["arxiv.org", "biorxiv.org", "medrxiv.org"]

    private static let domainSet = Set(domains)

    /// Exact host or subdomain membership (pmc.ncbi.nlm.nih.gov matches ncbi.nlm.nih.gov;
    /// en.wikipedia.org matches wikipedia.org). Never substring matching — "notnature.com"
    /// must not pass.
    public static func isAcademicHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        if domainSet.contains(normalized) { return true }
        return domainSet.contains { normalized.hasSuffix("." + $0) }
    }

    public static func isPreprintHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        if preprintDomains.contains(normalized) { return true }
        return preprintDomains.contains { normalized.hasSuffix("." + $0) }
    }

    /// The academia-bounded pull: keep only content-verified sources whose host is in the
    /// registry. Input must already have passed ResearchEvidencePolicy.verifiedPrimarySources —
    /// this narrows the boundary, it never widens or re-verifies.
    public static func academicSources(
        in verified: [VerifiedResearchPrimarySource]
    ) -> [VerifiedResearchPrimarySource] {
        verified.filter { source in
            guard let host = URLComponents(string: source.url)?.host else { return false }
            return isAcademicHost(host)
        }
    }

    /// One-line evidence label for writer/review agents: how this source may be cited.
    public static func citationClass(url: String) -> String {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return "non-academic" }
        if isPreprintHost(host) { return "academic-preprint (not peer-reviewed; label it)" }
        if isAcademicHost(host) {
            return encyclopedicDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) })
                ? "encyclopedic-background (cite the underlying papers for claims)"
                : "academic"
        }
        return "non-academic"
    }
}
