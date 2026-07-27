import Foundation

/// Scans source text for committed credentials. High-precision patterns (provider-specific token
/// shapes + tightly-scoped generic assignments) so we don't cry wolf — a noisy security tool is a
/// distrusted one. Every hit becomes a grounded finding with the secret REDACTED in the evidence.
public enum SecretScanner {
    struct Rule { let id: String; let title: String; let severity: SecurityFinding.Severity; let regex: NSRegularExpression }

    private static func re(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    static let rules: [Rule] = [
        .init(id: "private-key", title: "Private key committed in source", severity: .critical,
              regex: re(#"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----"#)),
        .init(id: "aws-access-key", title: "AWS access key id", severity: .critical, regex: re(#"\bAKIA[0-9A-Z]{16}\b"#)),
        .init(id: "github-token", title: "GitHub token", severity: .critical, regex: re(#"\b(?:ghp|gho|ghs|ghu|ghr)_[0-9A-Za-z]{36}\b"#)),
        .init(id: "github-pat", title: "GitHub fine-grained PAT", severity: .critical, regex: re(#"\bgithub_pat_[0-9A-Za-z_]{22,}\b"#)),
        .init(id: "slack-token", title: "Slack token", severity: .high, regex: re(#"\bxox[baprs]-[0-9A-Za-z-]{10,}\b"#)),
        .init(id: "google-api-key", title: "Google API key", severity: .high, regex: re(#"\bAIza[0-9A-Za-z_\-]{35}\b"#)),
        .init(id: "stripe-secret", title: "Stripe secret key", severity: .critical, regex: re(#"\bsk_live_[0-9A-Za-z]{24,}\b"#)),
        .init(id: "openai-key", title: "OpenAI/Anthropic-style API key", severity: .high, regex: re(#"\bsk-(?:ant-)?[A-Za-z0-9_\-]{32,}\b"#)),
        .init(id: "jwt", title: "JSON Web Token", severity: .medium, regex: re(#"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#)),
        // Tightly-scoped generic assignment: a secret-ish name set to a 16+ char quoted literal.
        .init(id: "generic-secret-assignment", title: "Hardcoded secret in assignment", severity: .high,
              regex: re(#"(?:api[_-]?key|secret|token|passwd|password|access[_-]?key)\s*[:=]\s*["'][0-9A-Za-z/+_\-]{16,}["']"#)),
    ]

    /// Names whose value matching the generic rule is almost always a placeholder, not a real leak.
    private static let placeholders = ["example", "changeme", "your_", "xxx", "placeholder", "dummy", "redacted", "test", "<", "${", "env."]

    public static func scan(text: String, file: String) -> [SecurityFinding] {
        var findings: [SecurityFinding] = []
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if line.count > 4000 { continue }                          // skip minified blobs
            let ns = line as NSString
            for rule in rules {
                guard let m = rule.regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
                let matched = ns.substring(with: m.range)
                // Placeholder check operates on the MATCH, not the whole line — so a real secret on a
                // line that merely contains "test"/"example" elsewhere (e.g. a comment) isn't suppressed.
                if rule.id == "generic-secret-assignment",
                   placeholders.contains(where: { matched.lowercased().contains($0) }) { continue }
                findings.append(SecurityFinding(
                    severity: rule.severity, category: .secret, rule: rule.id, title: rule.title,
                    file: file, line: i + 1, evidence: redact(matched),
                    recommendation: "Remove the secret, rotate it immediately, and load it from a secret store / env var.",
                    owasp: "A07:2021 Identification & Auth Failures"))
            }
        }
        return findings
    }

    /// Redact every secret-shaped substring in ARBITRARY text. The other scanners (deps, SAST) store
    /// raw source lines as evidence; routing all evidence through here guarantees no scanner can leak a
    /// real token regardless of which rule produced the finding. Idempotent (redacted output is inert).
    public static func redactSecrets(in text: String) -> String {
        var out = text
        for rule in rules {
            while let m = rule.regex.firstMatch(in: out, range: NSRange(location: 0, length: (out as NSString).length)) {
                let ns = out as NSString
                let matched = ns.substring(with: m.range)
                let masked = redact(matched)
                if masked == matched { break }            // already inert → avoid infinite loop
                out = ns.replacingCharacters(in: m.range, with: masked)
            }
        }
        return out
    }

    /// Show enough to locate it, never enough to use it: first 4 + last 2, middle masked.
    static func redact(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count > 10 else { return String(repeating: "•", count: t.count) }
        let head = t.prefix(4), tail = t.suffix(2)
        return "\(head)\(String(repeating: "•", count: min(t.count - 6, 20)))\(tail)"
    }
}
