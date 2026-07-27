import Foundation

/// Deterministic checks that run over a change to produce ReceiptChecks — the cheap, model-independent backbone
/// of proof-carrying patches (docs/kist/LEAPFROG_ROADMAP_2026.md WS1). These run in milliseconds, locally, with
/// no LLM in the loop. `ReceiptChecks.parseAddedLines` turns a unified diff into the added-line content the
/// scans inspect; `runBuiltins` runs the security backbone; `CommandCheck` wraps compile/test as a check.
public enum ReceiptChecks {

    /// Added (`+`) content lines from a unified diff (excludes the `+++` file header). Trims the leading `+`.
    public static func parseAddedLines(_ diff: String) -> [String] {
        diff.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            guard line.hasPrefix("+"), !line.hasPrefix("+++") else { return nil }
            return String(line.dropFirst())
        }
    }

    /// The built-in deterministic security scans every change is checked against.
    public static func runBuiltins(diff: String) -> [ReceiptCheck] {
        let added = parseAddedLines(diff)
        return [secretScan(added), hostControlIntro(added)]
    }

    /// Fail if a change ADDS a hard-coded secret. This is a cheap deterministic BACKSTOP — a widened pattern set
    /// (private-key blocks, AWS/GitHub/Slack/OpenAI token shapes, JSON `"key": "value"` forms), NOT a complete DLP.
    /// Split/obfuscated secrets still evade it (see docs/kist/RECEIPT_THREAT_MODEL.md); the verification proof is
    /// the real gate. Codex gate broadened the shapes (the `"api_key": "..."` JSON form used to slip the `[=:]`).
    public static func secretScan(_ added: [String]) -> ReceiptCheck {
        let patterns: [(String, String)] = [
            ("private-key-block", "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"),
            ("aws-access-key", "(AKIA|ASIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA)[0-9A-Z]{16}"),
            ("github-token", "(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}"),
            ("slack-token", "xox[baprs]-[A-Za-z0-9-]{10,}"),
            ("openai-key", "sk-[A-Za-z0-9_-]{20,}"),
            ("google-key", "AIza[0-9A-Za-z_\\-]{30,}"),
            // key/secret/token = / : "value" — quote may sit before the separator (JSON) or after it (assignment).
            ("generic-api-key", "(?i)(api[_-]?key|secret|token|passwd|password)[\"']?\\s*[=:]\\s*[\"']?[A-Za-z0-9_\\-]{20,}"),
        ]
        var hits: [String] = []
        for line in added {
            for (label, pat) in patterns where line.range(of: pat, options: .regularExpression) != nil {
                hits.append(label)
            }
        }
        let ok = hits.isEmpty
        return ReceiptCheck(name: "no-secrets", kind: .deterministic, passed: ok,
                            detail: ok ? "no hard-coded secrets in added lines" : "possible secret(s): \(Set(hits).sorted().joined(separator: ", "))")
    }

    /// Fail if a change INTRODUCES host-control / UI-automation shell (osascript/screencapture/…) — the exact
    /// capability kist's own security denies by default. Reuses the canonical host-control token list.
    public static func hostControlIntro(_ added: [String]) -> ReceiptCheck {
        // BACKSTOP token list, not a boundary — same-line string-concat / Unicode-escape / wrapper-binary evasions
        // are a fundamental limit of pattern-scanning (docs/kist/RECEIPT_THREAT_MODEL.md). Widened per Codex gate.
        let tokens = ["osascript", "nsapplescript", "cliclick", "screencapture", "cgeventpost",
                      "cgeventcreate", "cgwindowlistcreateimage", "screencapturekit", "scstream",
                      "axuielement", "iohidpost", "iohidevent", "\"system events\""]
        var hits: [String] = []
        for line in added {
            let l = line.lowercased()
            for t in tokens where l.contains(t) { hits.append(t) }
        }
        let ok = hits.isEmpty
        return ReceiptCheck(name: "no-host-control-intro", kind: .deterministic, passed: ok,
                            detail: ok ? "no UI-automation/host-control introduced"
                                       : "introduces host-control: \(Set(hits).sorted().joined(separator: ", "))")
    }
}

/// A check backed by running a project command (compile/tests/lint) — the real deterministic backbone. The
/// runner is injected so the logic is unit-testable without spawning processes.
public struct CommandCheck: Sendable {
    public let name: String
    public let command: String
    public let required: Bool
    public init(name: String, command: String, required: Bool = true) {
        self.name = name; self.command = command; self.required = required
    }
    /// `run` returns (exitCode, output). exit 0 ⇒ passed.
    public func evaluate(_ run: (String) -> (exit: Int32, output: String)) -> ReceiptCheck {
        let r = run(command)
        return ReceiptCheck(name: name, kind: .deterministic, passed: r.exit == 0, required: required,
                            detail: r.exit == 0 ? "`\(command)` exited 0"
                                                : "`\(command)` exited \(r.exit): \(r.output.suffix(200))")
    }
}
