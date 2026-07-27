import Foundation

/// Treats repo/dependency content (and agent diffs) as UNTRUSTED — ported from TinkySDR's Captain
/// (C1). Prompt injection via README/comments/dependency metadata is OWASP's #1 AI threat for 2026
/// (CurXecute CVE-2025-54135 was a README-driven RCE). A heuristic regex scanner surfacing SUSPECT
/// injection/exfiltration patterns so a human can look. Advisory, never autonomously blocking; the
/// typed `ScanOutcome` makes "no pattern matched" un-conflatable with "safe". PURE + deterministic.
public struct InjectionFinding: Equatable, Sendable {
    public let kind: String        // category id (e.g. "instruction_override")
    public let source: String      // where it was found
    public let snippet: String     // bounded excerpt
    public init(kind: String, source: String, snippet: String) { self.kind = kind; self.source = source; self.snippet = snippet }
}

/// Typed result so a caller can never read "no pattern matched" as a safety clearance.
public enum ScanOutcome: Equatable, Sendable {
    case noPatternMatched
    case advisory([InjectionFinding])
    public var findings: [InjectionFinding] { if case let .advisory(f) = self { return f }; return [] }
    public var hasSignatures: Bool { if case .advisory = self { return true }; return false }
}

public enum UntrustedContentScanner {
    // (kind, ICU regex). Internal so a test can assert every pattern compiles.
    static let patterns: [(kind: String, regex: String)] = [
        ("instruction_override", #"(?i)\b(ignore|disregard|forget)\b[^.\n]{0,40}\b(all\s+)?(previous|prior|above|earlier|system)\b[^.\n]{0,20}\b(instruction|instructions|prompt|prompts|rule|rules|context)\b"#),
        ("role_assumption",      #"(?i)\byou\s+are\s+now\b"#),
        ("role_assumption",      #"(?im)^\s*(system|assistant|developer)\s*:"#),
        ("agent_directive",      #"(?i)\b(AI|agent|assistant|claude|copilot|cursor|model)\b[^.\n]{0,30}\b(must|should|please)\b[^.\n]{0,30}\b(run|execute|delete|exfiltrate|send|curl|wget|push|commit)\b"#),
        ("command_exec",         #"(?i)\bcurl\b[^\n]{0,80}\|\s*(?:sh|bash)\b"#),
        ("command_exec",         #"(?i)\brm\s+-rf\b"#),
        ("command_exec",         #"(?i)\bbase64\s+-d\b"#),
        ("command_exec",         #"(?i)\beval\s*\("#),
        ("command_exec",         #"(?i)\bchmod\s+\+x\b"#),
        ("exfiltration",         #"(?i)\b(POST|GET)\s+https?://"#),
        ("exfiltration",         #"(?i)\b(send|upload|exfiltrate|leak)\b[^\n]{0,40}\b(token|secret|key|credential|env)\b"#),
        ("secret_read",          #"(?i)\b(cat|print|echo|read)\b[^.\n]{0,20}(\.env|id_rsa|\.aws/credentials|\.ssh/|secrets?)\b"#),
        ("hidden_unicode",       #"[\x{200B}\x{200C}\x{200D}\x{2060}\x{FEFF}\x{202E}]"#),
    ]

    public static let defaultMaxBytes = 200_000

    /// Typed primary API: `.noPatternMatched` (found nothing — NOT a clearance) vs `.advisory`.
    public static func evaluate(_ text: String, source: String, maxBytes: Int = defaultMaxBytes) -> ScanOutcome {
        let f = scan(text, source: source, maxBytes: maxBytes)
        return f.isEmpty ? .noPatternMatched : .advisory(f)
    }

    private static func scan(_ text: String, source: String, maxBytes: Int = defaultMaxBytes) -> [InjectionFinding] {
        let cap = maxBytes > 0 ? maxBytes : defaultMaxBytes
        let scoped = text.count > cap ? String(text.prefix(cap)) : text
        var findings: [InjectionFinding] = []
        var seen = Set<String>()
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p.regex) else { continue }
            let range = NSRange(scoped.startIndex..<scoped.endIndex, in: scoped)
            re.enumerateMatches(in: scoped, range: range) { match, _, stop in
                guard let m = match else { return }
                let capped = NSRange(location: m.range.location, length: min(m.range.length, 240))
                guard let r = Range(capped, in: scoped) else { return }
                let snippet = bounded(String(scoped[r]))
                if seen.insert(p.kind + "|" + snippet).inserted {
                    findings.append(InjectionFinding(kind: p.kind, source: source, snippet: snippet))
                }
                if findings.count >= 50 { stop.pointee = true }
            }
        }
        return findings
    }

    private static func bounded(_ s: String, max: Int = 120) -> String {
        let oneLine = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return oneLine.count <= max ? oneLine : String(oneLine.prefix(max)) + "…"
    }
}
