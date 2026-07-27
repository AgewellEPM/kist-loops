import Foundation

/// THE AUTHORIZATION SPINE of the bug-bounty assistant. `AuthorizationScopeEngine` decides *what kind* of
/// work a request is and gates tools by kind — but it trusts prompt-text claims of authorization ("the
/// request says it's authorized"). A real engagement cannot run on a sentence in a prompt. A
/// `SecurityEngagement` is the DURABLE, ATTESTED scope: the explicit list of targets the operator has
/// confirmed they are permitted to test, plus the program rules and testing limits.
///
/// The core invariant is FAIL-CLOSED: `inScope(host:)` returns `.outOfScope` for ANYTHING not explicitly
/// covered by an attested target. Empty scope ⇒ nothing is in scope. A typo, a redirect to a third-party
/// host, a look-alike domain — all refused. This is the structural guardrail the security constraints
/// require: it is not a prompt the model can talk its way past; it's a set-membership test on a host.
public struct SecurityTarget: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, Equatable {
        case domain     // apex + all subdomains (example.com ⇒ example.com, api.example.com, …)
        case host       // ONE exact host (api.example.com and nothing else)
        case wildcard   // subdomains only (*.example.com ⇒ api.example.com, NOT example.com itself)
        case cidr       // an IPv4 range, e.g. 10.0.0.0/8
        case repo       // a source repo, exact "owner/name"
    }
    public let kind: Kind
    public let value: String   // canonicalized at init

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = SecurityTarget.canonical(kind: kind, value: value)
    }

    // Codex LOW: synthesized Codable would bypass canonical(), so a stored "EXAMPLE.COM" would decode
    // uppercase and never match the lowercased host at runtime (a silently-invisible target). Route the
    // decode through the canonical init so on-disk values are always re-canonicalized.
    enum CodingKeys: String, CodingKey { case kind, value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(Kind.self, forKey: .kind), value: try c.decode(String.self, forKey: .value))
    }

    static func canonical(kind: Kind, value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .domain, .host:
            return SecurityEngagement.canonicalHost(v) ?? v.lowercased()
        case .wildcard:
            // Review (Grok): accept the natural "*.example.com" spelling — strip the leading "*." so the
            // stored value is the parent the suffix-match expects. WITHOUT this the '*' fails the host
            // charset and the wildcard canonicalizes to a DEAD target that silently matches nothing (the
            // operator's intended scope vanishes). Fail-closed, but a footgun — normalize it.
            var w = v
            if w.hasPrefix("*.") { w.removeFirst(2) }
            return SecurityEngagement.canonicalHost(w) ?? w.lowercased()
        case .cidr:
            // Review (DeepSeek+Grok, CRITICAL): validate AND refuse absurdly-broad ranges here, so a
            // malformed or "/0" CIDR canonicalizes to "" (excluded from auth + matching) rather than
            // silently authorizing a huge swath of the internet. cidrV4 enforces the /8 floor.
            return SecurityEngagement.cidrV4(v) != nil ? v : ""
        case .repo:
            return v.lowercased()
        }
    }
}

public enum ScopeMatch: Sendable, Equatable {
    case inScope(matchedBy: SecurityTarget)
    case outOfScope(reason: String)

    public var isInScope: Bool { if case .inScope = self { return true }; return false }
}

public struct SecurityEngagement: Sendable, Codable, Equatable {
    public let id: String
    public let program: String          // "HackerOne: Acme", "Private: my-app", …
    public let attestedBy: String       // who confirmed authorization (an operator identity, not the model)
    public let attestedAtISO: String    // when (ISO-8601 string; passed in, never wall-clock-read here)
    public let targets: [SecurityTarget]
    public let safeHarbor: Bool         // does the program offer safe-harbor / authorization-to-test?
    public let rulesURL: String?
    public let testingLimits: [String]  // "no destructive payloads", "<=10 req/s", "prod read-only", …

    public init(id: String, program: String, attestedBy: String, attestedAtISO: String,
                targets: [SecurityTarget], safeHarbor: Bool, rulesURL: String?, testingLimits: [String]) {
        self.id = id
        self.program = program
        self.attestedBy = attestedBy
        self.attestedAtISO = attestedAtISO
        self.targets = targets
        self.safeHarbor = safeHarbor
        self.rulesURL = rulesURL
        self.testingLimits = testingLimits
    }

    /// Is this engagement valid enough to authorize ANY active work? Fail-closed prerequisites.
    /// Codex CRITICAL: trim ALL whitespace incl newlines (an attestedBy of "\n" must not authorize).
    /// Codex HIGH: require at least one target with a NON-EMPTY canonical value (a blank target ⇒ none).
    public var isAuthorized: Bool {
        !attestedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && targets.contains { !$0.value.isEmpty }
    }

    // MARK: - the gate

    /// FAIL-CLOSED host membership. Accepts a bare host, a host:port, or a full URL — extracts and
    /// canonicalizes the host first, then tests it against every target. Anything unparseable or
    /// uncovered is `.outOfScope`. There is no "probably fine" branch.
    public func inScope(host raw: String) -> ScopeMatch {
        guard isAuthorized else { return .outOfScope(reason: "engagement is not authorized (no attestation or no targets)") }
        guard let host = SecurityEngagement.canonicalHost(raw), !host.isEmpty else {
            return .outOfScope(reason: "could not parse a host from '\(raw)'")
        }
        let ip = SecurityEngagement.ipv4(host)   // nil if not a dotted-quad
        for t in targets where !t.value.isEmpty {   // an empty-canonical target matches nothing
            switch t.kind {
            case .host:
                if host == t.value { return .inScope(matchedBy: t) }
            case .domain:
                // apex OR a subdomain — matched on a LABEL boundary so evil-example.com ≠ example.com
                // and example.com.attacker.com ≠ example.com.
                if host == t.value || host.hasSuffix("." + t.value) { return .inScope(matchedBy: t) }
            case .wildcard:
                // subdomains ONLY (not the apex itself)
                if host != t.value, host.hasSuffix("." + t.value) { return .inScope(matchedBy: t) }
            case .cidr:
                if let ip, let range = SecurityEngagement.cidrV4(t.value), range.contains(ip) {
                    return .inScope(matchedBy: t)
                }
            case .repo:
                break   // repos are matched by `inScope(repo:)`, not by host
            }
        }
        return .outOfScope(reason: "'\(host)' is not covered by any attested target in '\(program)'")
    }

    /// FAIL-CLOSED repo membership ("owner/name"), for source-level findings.
    public func inScope(repo raw: String) -> ScopeMatch {
        guard isAuthorized else { return .outOfScope(reason: "engagement is not authorized") }
        let repo = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !repo.isEmpty else { return .outOfScope(reason: "empty repo identifier") }   // Codex HIGH: blank ≠ blank target
        for t in targets where t.kind == .repo && !t.value.isEmpty && t.value == repo { return .inScope(matchedBy: t) }
        return .outOfScope(reason: "'\(repo)' is not an attested repo target in '\(program)'")
    }

    // MARK: - host / ip helpers

    /// Extract a canonical host (lowercased, no scheme/port/path/trailing dot) from a bare host or a URL.
    static func canonicalHost(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if s.contains("://"), let url = URL(string: s), let h = url.host { s = h }
        else {
            // strip a leading scheme-less "//", any path, query, fragment, then a :port
            if s.hasPrefix("//") { s.removeFirst(2) }
            if let slash = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<slash]) }
            if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }   // strip userinfo
            // strip :port only when it's a numeric port (don't butcher IPv6 — out of v1 scope, treat as-is)
            if let colon = s.lastIndex(of: ":"), s[s.index(after: colon)...].allSatisfy(\.isNumber),
               s.firstIndex(of: ":") == colon {
                s = String(s[..<colon])
            }
        }
        while s.hasSuffix(".") { s.removeLast() }
        // Codex HIGH: strict, fail-closed charset — ASCII letters/digits/'-'/'.' only. Rejects whitespace,
        // control chars (tab/newline), '@', '%', IPv6 brackets, and non-ASCII/IDN homoglyphs — any of which
        // could make the matched host differ from the real connect target. Out of v1 scope ⇒ refuse.
        // RUNBOOK (Codex INFO): this also refuses underscore SRV labels (_sip._tcp.…) and RAW Unicode IDNs.
        // Punycode (xn--…) IS accepted, so real registered IDN targets work — store those in punycode form.
        // If an engagement legitimately needs an underscore label, pre-canonicalize it to its base domain.
        guard !s.isEmpty,
              s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
        else { return nil }
        return s
    }

    /// Parse a dotted-quad IPv4 to a UInt32, or nil. (IPv6 intentionally out of v1 scope.)
    static func ipv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var acc: UInt32 = 0
        for p in parts {
            // Codex MEDIUM: reject empty, >3 digits, and octal-ambiguous leading zeros ("010" decimal-parses
            // to 10 here but a libc resolver may read it as octal 8) — so a CIDR can't mis-authorize.
            guard (1...3).contains(p.count), !(p.count > 1 && p.first == "0"), let n = UInt32(p), n <= 255 else { return nil }
            acc = (acc << 8) | n
        }
        return acc
    }

    /// The broadest CIDR an engagement may attest. A /8 is already 16M hosts; nothing legitimate in a
    /// bug-bounty scope is broader. Refusing </8 (incl. /0 = the entire internet) is a fail-closed footgun
    /// guard so a typo or over-broad target can't silently authorize a huge swath of address space.
    static let minCIDRPrefixBits: UInt32 = 8

    /// Parse "base/prefix" IPv4 CIDR into the inclusive UInt32 range it covers, or nil (malformed OR
    /// broader than the /8 floor). bits is constrained to 8...32 so the shift is always well-defined.
    static func cidrV4(_ s: String) -> ClosedRange<UInt32>? {
        let parts = s.split(separator: "/")
        guard parts.count == 2, let base = ipv4(String(parts[0])),
              let bits = UInt32(parts[1]), (minCIDRPrefixBits...32).contains(bits) else { return nil }
        let mask: UInt32 = ~UInt32(0) << (32 - bits)
        let network = base & mask
        let broadcast = network | ~mask
        return network...broadcast
    }
}
