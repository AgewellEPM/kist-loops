import Foundation

/// One security finding. The whole point of our audit is TRUST: every finding carries concrete
/// evidence (file + line + the matched snippet), so it is grounded-by-construction — a deterministic
/// scanner found it, an LLM did not invent it. This is the antidote to the frontier's fake-exploit
/// problem. A finding with no `file`/`evidence` is not allowed.
public struct SecurityFinding: Sendable, Codable, Equatable {
    public enum Severity: String, Sendable, Codable, CaseIterable, Comparable {
        case info, low, medium, high, critical
        private var rank: Int { Self.allCases.firstIndex(of: self)! }
        public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }

    public enum Category: String, Sendable, Codable {
        case secret          // a credential committed in source
        case dependency      // a risky/unpinned/outdated dependency
        case codeInjection   // shell/SQL/eval injection surface
        case crypto          // weak/misused cryptography
        case config          // insecure config (TLS off, debug on, perms)
    }

    public let id: String            // stable per (category, file, line, rule)
    public let severity: Severity
    public let category: Category
    public let rule: String          // the detector that fired, e.g. "aws-access-key"
    public let title: String
    public let file: String          // project-relative
    public let line: Int             // 1-based
    public let evidence: String      // the matched snippet (secrets redacted)
    public let recommendation: String
    public let owasp: String?        // OWASP mapping when known, e.g. "A07:2021 / LLM06"

    public init(severity: Severity, category: Category, rule: String, title: String,
                file: String, line: Int, evidence: String, recommendation: String, owasp: String? = nil) {
        self.severity = severity; self.category = category; self.rule = rule; self.title = title
        self.file = file; self.line = line
        // CENTRAL chokepoint: every finding's evidence is run through secret redaction, so a token on a
        // dependency/SAST line can't leak even though only the secret scanner pre-redacts its own hits.
        self.evidence = SecretScanner.redactSecrets(in: evidence)
        self.recommendation = recommendation; self.owasp = owasp
        self.id = "\(category.rawValue):\(rule):\(file):\(line)"
    }
}

/// The aggregated, deterministic audit result. Trustworthy by construction — there's no LLM in the
/// finding path, so there are no hallucinated vulnerabilities.
public struct AuditReport: Sendable, Codable, Equatable {
    public let findings: [SecurityFinding]
    public let filesScanned: Int
    public let root: String

    public init(findings: [SecurityFinding], filesScanned: Int, root: String) {
        // Highest severity first, then by file/line for stable output.
        self.findings = findings.sorted {
            $0.severity != $1.severity ? $0.severity > $1.severity
                : ($0.file != $1.file ? $0.file < $1.file : $0.line < $1.line)
        }
        self.filesScanned = filesScanned
        self.root = root
    }

    public var counts: [SecurityFinding.Severity: Int] {
        Dictionary(grouping: findings, by: \.severity).mapValues(\.count)
    }

    /// A human-readable report. Deterministic ordering; secrets already redacted in `evidence`.
    public func render() -> String {
        guard !findings.isEmpty else { return "Security audit: \(filesScanned) files scanned · no findings." }
        let c = counts
        let header = SecurityFinding.Severity.allCases.reversed()
            .compactMap { s in c[s].map { "\($0) \(s.rawValue)" } }.joined(separator: " · ")
        var out = "Security audit · \(filesScanned) files · \(findings.count) findings (\(header))\n"
        for f in findings {
            out += "\n[\(f.severity.rawValue.uppercased())] \(f.title)  (\(f.rule))\n"
            out += "  \(f.file):\(f.line)\n"
            out += "  evidence: \(f.evidence)\n"
            if let owasp = f.owasp { out += "  owasp: \(owasp)\n" }
            out += "  fix: \(f.recommendation)\n"
        }
        return out
    }
}
