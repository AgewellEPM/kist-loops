import Foundation

/// PROOF-CARRYING PATCHES (docs/kist/LEAPFROG_ROADMAP_2026.md WS1). A change can ship a set of machine-checkable
/// CLAIMS about itself — "I added function X", "I added a test file", "I introduced no force-unwraps", "I changed
/// ≤ N lines", "I only touched files under src/". kist evaluates each claim DETERMINISTICALLY against the actual
/// staged diff (no LLM in the verify loop) and folds the results into the receipt's checks. A claim that doesn't
/// hold FAILS the receipt → the change can't merge. This turns an agent's self-description into an enforceable
/// contract: a lying "I added tests" patch is caught by the gate, not trusted.
///
/// The claims are intentionally a small, TOTAL, deterministic language over (added lines, changed files) — the
/// same inputs the built-in scans use. Richer proofs (AST/semantic) build on this same fold-into-receipt seam.

public struct ProofClaim: Codable, Equatable, Sendable {
    public let kind: String       // see ProofKind
    public let value: String      // regex / path / integer / ';'-separated prefixes, depending on kind
    public let required: Bool
    public let note: String

    public init(kind: String, value: String, required: Bool = true, note: String = "") {
        self.kind = kind; self.value = value; self.required = required; self.note = note
    }
}

public struct ProofSet: Codable, Equatable, Sendable {
    public let diffDigest: String     // binds the proof set to the exact change it describes
    public let claims: [ProofClaim]
    public init(diffDigest: String, claims: [ProofClaim]) { self.diffDigest = diffDigest; self.claims = claims }
}

public enum ProofChecker {
    /// The supported deterministic claim kinds. Unknown kinds fail closed (an unrecognized claim is NOT silently
    /// passed — a policy that references a kind this kist can't evaluate must not appear satisfied).
    public enum ProofKind: String {
        case addedMatches    = "added-matches"     // ≥1 added line matches the regex `value`
        case addedAbsent     = "added-absent"      // NO added line matches the regex `value` (e.g. no force-unwrap)
        case fileTouched     = "file-touched"      // `value` is among the changed files
        case fileAbsent      = "file-absent"       // `value` is NOT among the changed files
        case maxAddedLines   = "max-added-lines"   // count(added lines) ≤ Int(value)
        case scope           = "scope"             // every changed file starts with one of `value` (';'-separated)
    }

    /// Bounds on `--proofs` input (a verify-time input, but cap it anyway so a pathological proof file can't hang
    /// or blow up verify — availability hygiene, Codex gate9 LOW).
    public static let maxClaims = 256
    public static let maxPatternLength = 512

    /// Evaluate every claim against the change. Returns one ReceiptCheck per claim (name `proof:<kind>`), ready to
    /// fold into the receipt. Deterministic and total; a malformed/unknown/over-cap claim yields a FAILED check.
    public static func evaluate(diff: String, changedFiles: [String], claims: [ProofClaim]) -> [ReceiptCheck] {
        let added = ReceiptChecks.parseAddedLines(diff)
        if claims.count > maxClaims {
            return [ReceiptCheck(name: "proof:limit", kind: .deterministic, passed: false,
                                 detail: "too many claims (\(claims.count) > \(maxClaims)) — fail-closed")]
        }
        return claims.map { claim in
            let (ok, detail) = evaluateOne(claim, added: added, changedFiles: changedFiles)
            return ReceiptCheck(name: "proof:\(claim.kind)", kind: .deterministic, passed: ok,
                                required: claim.required,
                                detail: detail + (claim.note.isEmpty ? "" : " — \(claim.note)"))
        }
    }

    /// Compile + match a regex, failing CLOSED on an INVALID pattern — Foundation's `range(of:.regularExpression)`
    /// returns nil (no match) for a malformed pattern, which would silently pass an `added-absent` claim (Codex
    /// gate9 LOW). Returns nil to signal "the pattern itself is invalid" so callers can fail the check.
    private static func anyLineMatches(_ pattern: String, in lines: [String]) -> Bool? {
        guard pattern.count <= maxPatternLength,
              let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        return lines.contains { line in
            re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
    }

    private static func evaluateOne(_ c: ProofClaim, added: [String], changedFiles: [String]) -> (Bool, String) {
        guard let kind = ProofKind(rawValue: c.kind) else {
            return (false, "unknown proof kind '\(c.kind)' (fail-closed)")
        }
        switch kind {
        case .addedMatches:
            guard let hit = anyLineMatches(c.value, in: added) else {
                return (false, "invalid/oversized regex /\(c.value)/ — fail-closed")
            }
            return (hit, hit ? "an added line matches /\(c.value)/" : "no added line matches /\(c.value)/")
        case .addedAbsent:
            guard let hit = anyLineMatches(c.value, in: added) else {
                return (false, "invalid/oversized regex /\(c.value)/ — fail-closed (an absence claim can't be certified)")
            }
            return (!hit, hit ? "an added line matches the forbidden /\(c.value)/" : "no added line matches /\(c.value)/")
        case .fileTouched:
            let ok = changedFiles.contains(c.value)
            return (ok, ok ? "changed \(c.value)" : "did NOT change \(c.value)")
        case .fileAbsent:
            let ok = !changedFiles.contains(c.value)
            return (ok, ok ? "did not change \(c.value)" : "changed the forbidden \(c.value)")
        case .maxAddedLines:
            guard let n = Int(c.value) else { return (false, "max-added-lines value '\(c.value)' is not an integer") }
            let ok = added.count <= n
            return (ok, "\(added.count) added line(s) ≤ \(n)? \(ok)")
        case .scope:
            // PATH-COMPONENT prefix, not a raw string prefix — else `scope=src` would falsely match `src2/evil`
            // (a sibling dir), letting an out-of-scope change claim it stayed in scope (self-review finding).
            let prefixes = c.value.split(separator: ";").map(String.init).filter { !$0.isEmpty }
            func inScope(_ f: String) -> Bool {
                prefixes.contains { p in
                    let dir = p.hasSuffix("/") ? p : p + "/"
                    return f == p || f.hasPrefix(dir)
                }
            }
            let outside = changedFiles.filter { !inScope($0) }
            return (outside.isEmpty, outside.isEmpty ? "all changes within scope [\(c.value)]"
                                                     : "changed files outside scope: \(outside.joined(separator: ", "))")
        }
    }
}
