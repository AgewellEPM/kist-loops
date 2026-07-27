import Foundation

/// SAST-lite: high-precision pattern detectors for the dangerous shapes that actually cause incidents
/// — injection surfaces, disabled TLS verification, weak crypto, eval/exec. Curated to keep
/// false-positives near zero (trust > coverage). Each hit is grounded at file:line with the snippet.
public enum StaticAnalyzer {
    struct Rule {
        let id: String; let title: String; let severity: SecurityFinding.Severity
        let category: SecurityFinding.Category; let regex: NSRegularExpression
        let fix: String; let owasp: String?
    }

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    static let rules: [Rule] = [
        .init(id: "tls-verify-disabled-py", title: "TLS verification disabled (requests)", severity: .high, category: .config,
              regex: re(#"verify\s*=\s*False"#), fix: "Never disable TLS verification; fix the cert chain instead.", owasp: "A02:2021 Cryptographic Failures"),
        .init(id: "tls-verify-disabled-node", title: "TLS verification disabled (Node)", severity: .high, category: .config,
              regex: re(#"rejectUnauthorized\s*:\s*false"#), fix: "Remove rejectUnauthorized:false; trust a proper CA.", owasp: "A02:2021 Cryptographic Failures"),
        .init(id: "tls-verify-disabled-go", title: "TLS verification disabled (Go)", severity: .high, category: .config,
              regex: re(#"InsecureSkipVerify\s*:\s*true"#), fix: "Remove InsecureSkipVerify; verify certificates.", owasp: "A02:2021 Cryptographic Failures"),
        .init(id: "ats-arbitrary-loads", title: "App Transport Security disabled", severity: .medium, category: .config,
              regex: re(#"NSAllowsArbitraryLoads"#), fix: "Scope ATS exceptions; don't allow arbitrary loads globally.", owasp: "A02:2021 Cryptographic Failures"),
        .init(id: "shell-true-py", title: "subprocess with shell=True", severity: .high, category: .codeInjection,
              regex: re(#"subprocess\.[A-Za-z_]+\([^)]*shell\s*=\s*True"#), fix: "Pass an argv list, not shell=True, to avoid shell injection.", owasp: "A03:2021 Injection"),
        .init(id: "os-system", title: "os.system with dynamic input", severity: .medium, category: .codeInjection,
              regex: re(#"os\.system\([^)]*(?:\+|%|f["']|format\()"#), fix: "Use subprocess with an argv list; never build shell strings.", owasp: "A03:2021 Injection"),
        .init(id: "js-exec-concat", title: "child_process.exec with concatenation", severity: .high, category: .codeInjection,
              regex: re(#"\.exec\(\s*[`"'][^`"']*\$\{|\.exec\([^)]*\+"#), fix: "Use execFile/spawn with an args array.", owasp: "A03:2021 Injection"),
        .init(id: "eval-use", title: "eval() on dynamic input", severity: .high, category: .codeInjection,
              regex: re(#"\beval\s*\("#), fix: "Avoid eval; parse/validate input explicitly.", owasp: "A03:2021 Injection"),
        .init(id: "weak-hash-md5", title: "Weak hash (MD5)", severity: .low, category: .crypto,
              regex: re(#"(?i)\bMD5\b"#), fix: "Use SHA-256+; for passwords use bcrypt/scrypt/argon2.", owasp: "A02:2021 Cryptographic Failures"),
        .init(id: "weak-hash-sha1", title: "Weak hash (SHA-1)", severity: .low, category: .crypto,
              regex: re(#"(?i)\bSHA-?1\b"#), fix: "Use SHA-256+ for integrity; never for passwords.", owasp: "A02:2021 Cryptographic Failures"),
        .init(id: "cipher-ecb", title: "ECB cipher mode", severity: .medium, category: .crypto,
              regex: re(#"\bAES[-/ ]?ECB\b|MODE_ECB"#), fix: "Use an authenticated mode (GCM); never ECB.", owasp: "A02:2021 Cryptographic Failures"),
    ]

    /// Comment-prefix per common language extension, to skip obvious commented-out lines.
    private static let lineComment: [String: String] = [
        "py": "#", "rb": "#", "sh": "#", "yml": "#", "yaml": "#",
        "js": "//", "ts": "//", "tsx": "//", "jsx": "//", "go": "//", "swift": "//", "java": "//", "c": "//", "cpp": "//", "rs": "//"
    ]

    public static func scan(text: String, file: String) -> [SecurityFinding] {
        let ext = (file as NSString).pathExtension.lowercased()
        let comment = lineComment[ext]
        var findings: [SecurityFinding] = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw
            if line.count > 4000 { continue }
            if let comment, line.trimmingCharacters(in: .whitespaces).hasPrefix(comment) { continue }   // skip comments
            let ns = line as NSString
            for rule in rules {
                guard let m = rule.regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
                findings.append(SecurityFinding(
                    severity: rule.severity, category: rule.category, rule: rule.id, title: rule.title,
                    file: file, line: i + 1, evidence: String(ns.substring(with: m.range).prefix(200)),
                    recommendation: rule.fix, owasp: rule.owasp))
            }
        }
        return findings
    }
}
