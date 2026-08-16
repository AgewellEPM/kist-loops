import Foundation

/// Best-effort redaction for tool/model boundary text. This is not a DLP system; it is
/// a cheap, always-on guard that prevents common API keys and `KEY=value` secrets from
/// being reflected into transcripts, terminal output, hooks, or later model context.
public enum SecretMasker {
    public static let marker = "[REDACTED_SECRET]"

    private static let patterns: [NSRegularExpression] = [
        // PEM private-key blocks (RSA/EC/OpenSSH/PKCS8) — multiline OR single-line \n-escaped (GCP SA
        // JSON). Placed FIRST: a leaked private key is the highest-severity shape. Zero capture groups.
        regex(#"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----[\s\S]*?-----END (?:[A-Z0-9 ]+ )?PRIVATE KEY-----"#),
        // JSON Web Tokens: base64url header.payload.signature (header starts eyJ = {" ).
        regex(#"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#),
        // OpenAI/Anthropic/DeepSeek-style bearer keys and common hosted-token prefixes.
        regex(#"\b(?:sk|sk-ant|sk-proj)-[A-Za-z0-9_\-]{12,}\b"#),
        regex(#"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}\b"#),
        regex(#"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#),
        regex(#"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#),
        regex(#"\bAIza[A-Za-z0-9_\-]{20,}\b"#),
        // Google OAuth client secret.
        regex(#"\bGOCSPX-[A-Za-z0-9_\-]{16,}\b"#),
        // Slack tokens (bot/user/app/refresh/legacy) and Slack webhook path segments.
        regex(#"\bxox[baprse]-[A-Za-z0-9-]{10,}\b"#),
        // Stripe / Razorpay-style live+test secret/restricted keys (underscore form — distinct from sk-).
        regex(#"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}\b"#),
        // npm access token.
        regex(#"\bnpm_[A-Za-z0-9]{36}\b"#),
        // Slack incoming-webhook URL (the path IS the secret).
        regex(#"https://hooks\.slack\.com/services/[A-Za-z0-9/]{20,}"#),
        // Standard HTTP bearer authorization. Match the whole header so opaque OAuth tokens without a
        // provider-specific prefix are never reflected; tolerate header-name/scheme case and whitespace.
        regex(#"(?i)\bauthorization\s*:\s*bearer\s+[^\s\"',;]+"#),
        // Assignment/header style secrets. Keep the key name, redact only the value. NOTE: deliberately
        // NOT including client_secret/private_key here — those over-match ordinary source (e.g.
        // `let privateKey = SecKeyCreateRandomKey(...)`); the actual secret material is caught precisely
        // by the dedicated GOCSPX- and PEM-block shape patterns above.
        regex(#"(?i)\b(api[_-]?key|access[_-]?token|auth[_-]?token|bearer|password|secret)\b\s*[:=]\s*["']?([^\s"',;]{16,})"#),
    ]

    public static func mask(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        for pattern in patterns {
            let range = NSRange(out.startIndex..., in: out)
            if pattern.numberOfMatches(in: out, range: range) == 0 { continue }
            out = pattern.stringByReplacingMatches(in: out, range: range, withTemplate: replacement(for: pattern))
        }
        return out
    }

    public static func mask(_ result: ToolResult) -> ToolResult {
        ToolResult(success: result.success,
                   output: mask(result.output),
                   error: result.error.map(mask),
                   metadata: result.metadata.mapValues(mask),
                   trustedCommandReference: result.trustedCommandReference)
    }

    private static func replacement(for pattern: NSRegularExpression) -> String {
        // The assignment/header pattern has two captures: preserve the key name.
        pattern.numberOfCaptureGroups == 2 ? "$1=\(marker)" : marker
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}
