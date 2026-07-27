import Foundation

/// The "don't trust a review finding until it's grounded in the actual code" discipline, made mechanical.
///
/// When a multi-model council (or any LLM) reviews code, high-recall models surface CONFIDENT findings
/// that are FALSE — they cite a `public init` "bypass" on a type that is a `struct`, or quote a do/catch
/// nesting that doesn't exist. A human reviewer catches these by READING THE SOURCE at the cited spot and
/// checking the claim matches. This module does exactly that, before a finding is allowed to count:
///
///   1. SOURCE-GROUND (the novel piece): the finding must QUOTE real code that actually appears at (or
///      near) the file:line it cites. A finding whose quoted code is not in the file is `.refutedFabricated`
///      — dropped as a likely hallucination/misquote. kist already checks a cited FILE exists
///      (`GroundedReviewValidator`); this checks the cited CODE exists, which is what catches the false
///      positives a filename check can't.
///   2. ADVERSARIALLY REFUTE (reuses the bug-bounty `FindingVerifier` shape): each GROUNDED finding faces
///      a panel of skeptics whose only job is to refute it; it is `.confirmed` only if a strict minority
///      refute. An LLM here can DOWN-RANK a grounded finding but can never MINT one — the antidote to the
///      fake-finding problem. No panel ⇒ `.unverified` (grounded but held, not auto-trusted).
///
/// Net: a finding is trustworthy only when its code is real AND it survives skeptics — the same bar a
/// careful human applies. Pure + deterministic (the grounder); the panel is injectable (LLM or stub).
public enum ReviewVerdict: String, Sendable, Codable, Equatable {
    case confirmed          // grounded in real code AND survived the refute panel → trustworthy
    case refutedFabricated  // cited file/line/code not found → likely hallucinated/misquoted, dropped
    case refutedPanel       // grounded, but the refute panel's majority refuted it → dropped
    case unverified         // grounded in real code, but no panel ran → held, NOT auto-trusted
}

/// One review finding as emitted by a reviewing model. `codeQuote` is the load-bearing field: the EXACT
/// code the finding claims to be about. Grounding checks that quote against the real file — so the model
/// can only get a finding counted by quoting code that genuinely exists.
public struct GroundedReviewFinding: Sendable, Codable, Equatable {
    public let severity: String     // CRITICAL / HIGH / MED / LOW (free text; normalized for display only)
    public let file: String         // project-relative path the finding cites
    public let line: Int?           // 1-based line, optional (grounding uses a window around it when present)
    public let codeQuote: String    // the exact code snippet the finding is about (grounded against source)
    public let claim: String        // the asserted problem

    public init(severity: String, file: String, line: Int?, codeQuote: String, claim: String) {
        self.severity = severity; self.file = file; self.line = line
        self.codeQuote = codeQuote; self.claim = claim
    }
}

/// One skeptic's attempt to refute a GROUNDED review finding. `refuted == true` = "not a real, in-context
/// problem." Default toward refuted when uncertain (a skeptic, not a cheerleader). Cannot create findings.
public struct ReviewRefuteVote: Sendable, Codable, Equatable {
    public let refuted: Bool
    public let reason: String
    public init(refuted: Bool, reason: String) { self.refuted = refuted; self.reason = reason }
}

public protocol ReviewFindingRefuter: Sendable {
    func refute(_ finding: GroundedReviewFinding) async -> ReviewRefuteVote
}

public struct VerifiedReviewFinding: Sendable, Codable, Equatable {
    public let finding: GroundedReviewFinding
    public let verdict: ReviewVerdict
    public let refuteCount: Int
    public let panelSize: Int
    public let rationale: String

    public init(finding: GroundedReviewFinding, verdict: ReviewVerdict, refuteCount: Int, panelSize: Int, rationale: String) {
        self.finding = finding; self.verdict = verdict
        self.refuteCount = refuteCount; self.panelSize = panelSize; self.rationale = rationale
    }

    /// Only a confirmed finding is trustworthy enough to surface as real.
    public var isTrustworthy: Bool { verdict == .confirmed }
}

public enum ReviewFindingVerifier {

    /// How many lines around a cited `line` the quoted code may appear within and still count as grounded
    /// (models often cite an approximate line). The quote must appear SOMEWHERE in this window.
    public static let defaultLineWindow = 12

    public struct Grounding: Sendable, Equatable {
        public let grounded: Bool
        public let reason: String
    }

    /// The minimum normalized quote length that can ground. A handful of characters ("let", "return",
    /// "}", "try") appear all over a file, so a too-short quote would "ground" on a ubiquitous token and
    /// give false confidence. Requiring a substantial, multi-token-ish quote means the model has to point
    /// at the SPECIFIC code its finding is about. (Grounding proves that code EXISTS — not that the bug is
    /// real; the refute panel is the second gate for realness. See verify()'s contract.)
    public static let minQuoteChars = 12

    /// Ground a finding against the real source: the cited file must exist within the project, and the
    /// `codeQuote` (whitespace-normalized, ≥ minQuoteChars) must actually appear in it — within a window
    /// around `line` when a line is cited. A trivial/absent quote can't be grounded. IMPORTANT: a `true`
    /// here means only that the cited code is PRESENT in the repo — it is NOT a judgement that the finding
    /// is a real bug. Pure + deterministic.
    public static func ground(_ finding: GroundedReviewFinding, projectRoot: String,
                              lineWindow: Int = defaultLineWindow) -> Grounding {
        let quote = normalize(finding.codeQuote)
        guard quote.count >= minQuoteChars else {
            return Grounding(grounded: false, reason: "quote too short (<\(minQuoteChars) chars) to verify — quote the SPECIFIC code the finding is about, not a ubiquitous token")
        }
        guard let full = resolvedPath(finding.file, projectRoot: projectRoot) else {
            return Grounding(grounded: false, reason: "cited file '\(finding.file)' is not in the project — likely fabricated")
        }
        guard let source = try? String(contentsOfFile: full, encoding: .utf8) else {
            return Grounding(grounded: false, reason: "cited file '\(finding.file)' could not be read")
        }
        let lines = source.components(separatedBy: "\n")
        // CLAMP both the cited line AND the window BEFORE any arithmetic — a malformed `line: Int.max` OR a
        // caller passing `lineWindow: Int.max` would otherwise overflow Int and TRAP. Fail soft, never crash.
        let win = max(0, min(lineWindow, lines.count + 1))
        // When a line is cited, ground within a window around it; else search the whole file.
        if let rawLine = finding.line, rawLine >= 1 {
            let line = min(rawLine, lines.count + 1)
            // Prefer a match in the window around the (clamped) cited line (strong grounding).
            let lo = max(0, line - 1 - win)
            let hi = min(lines.count, line - 1 + win + 1)
            if lo < hi, normalize(lines[lo..<hi].joined(separator: "\n")).contains(quote) {
                return Grounding(grounded: true, reason: "quoted code found near \(finding.file):\(rawLine)")
            }
            // Whole-file fallback so a wrong/approximate line (even far off, or past EOF) doesn't FALSELY
            // drop a finding whose code genuinely exists — but flag it as off-line (weaker grounding).
            if normalize(source).contains(quote) {
                return Grounding(grounded: true, reason: "quoted code found in \(finding.file) (not near cited line \(rawLine))")
            }
            return Grounding(grounded: false, reason: "quoted code not found at \(finding.file):\(rawLine) — likely fabricated or misquoted")
        }
        if normalize(source).contains(quote) {
            return Grounding(grounded: true, reason: "quoted code found in \(finding.file)")
        }
        return Grounding(grounded: false, reason: "quoted code not found in \(finding.file) — likely fabricated or misquoted")
    }

    /// Ground every finding, then adversarially refute the grounded ones. Ungrounded ⇒ `.refutedFabricated`
    /// WITHOUT a panel (a fabrication is dispositive — no skeptic vote can rescue code that isn't there).
    /// Grounded + empty panel ⇒ `.unverified` (held). Grounded + panel ⇒ `.confirmed` iff a strict minority
    /// refute (refuteCount * 2 < panelSize), else `.refutedPanel`.
    public static func verify(findings: [GroundedReviewFinding], projectRoot: String,
                              panel: [ReviewFindingRefuter] = [],
                              lineWindow: Int = defaultLineWindow) async -> [VerifiedReviewFinding] {
        var out: [VerifiedReviewFinding] = []
        for f in findings {
            let g = ground(f, projectRoot: projectRoot, lineWindow: lineWindow)
            guard g.grounded else {
                out.append(VerifiedReviewFinding(finding: f, verdict: .refutedFabricated,
                                                 refuteCount: 0, panelSize: 0, rationale: g.reason))
                continue
            }
            if panel.isEmpty {
                out.append(VerifiedReviewFinding(finding: f, verdict: .unverified, refuteCount: 0, panelSize: 0,
                                                 rationale: g.reason + "; no refute panel ran — held, not auto-trusted"))
                continue
            }
            var refutes = 0
            var reasons: [String] = []
            for skeptic in panel {
                let v = await skeptic.refute(f)
                if v.refuted { refutes += 1; reasons.append(v.reason) }
            }
            let confirmed = refutes * 2 < panel.count   // strict minority refuted → survives
            let tally = "refuted \(refutes)/\(panel.count)"
            if confirmed {
                out.append(VerifiedReviewFinding(finding: f, verdict: .confirmed, refuteCount: refutes,
                                                 panelSize: panel.count, rationale: g.reason + "; survived panel (\(tally))"))
            } else {
                let why = "grounded but refuted by panel (\(tally))" + (reasons.isEmpty ? "" : ": \(reasons.prefix(2).joined(separator: "; "))")
                out.append(VerifiedReviewFinding(finding: f, verdict: .refutedPanel, refuteCount: refutes,
                                                 panelSize: panel.count, rationale: why))
            }
        }
        return out
    }

    // MARK: - Sanitizing for a downstream consumer (e.g. a planner)

    /// Remove the raw `<<<FINDING…FINDING>>>` blocks from `text`, keeping the surrounding prose. Fail-soft
    /// on an unterminated marker (drops the dangling tail). Used to scrub un-grounded findings out of text
    /// before a downstream planner reads it.
    public static func stripFindingBlocks(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let start = rest.range(of: "<<<FINDING") {
            out += rest[rest.startIndex..<start.lowerBound]
            if let end = rest.range(of: "FINDING>>>", range: start.upperBound..<rest.endIndex) {
                rest = rest[end.upperBound...]
            } else {
                rest = ""   // unterminated block — drop the rest
                break
            }
        }
        out += rest
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The reviewer's output rewritten for a downstream PLANNER: the raw finding blocks are removed and
    /// replaced by a VERIFIED summary listing only grounded findings, plus a note that the fabricated ones
    /// were dropped. So a planner can never base a decision on an un-grounded (likely fabricated) finding —
    /// the grounding must happen BEFORE the synthesis, not after it (Codex HIGH).
    public static func sanitizedForPlanner(_ reviewerOutput: String, verified: [VerifiedReviewFinding]) -> String {
        let prose = stripFindingBlocks(reviewerOutput)
        // KEEP what the planner may act on: .confirmed (grounded AND survived the skeptic panel) and
        // .unverified (grounded, no panel ran). DROP .refutedFabricated (code not in repo) AND
        // .refutedPanel (the skeptic panel judged it NOT a real bug) — neither should reach the plan.
        let confirmed = verified.filter { $0.verdict == .confirmed }
        let unverified = verified.filter { $0.verdict == .unverified }
        let grounded = confirmed + unverified
        let dropped = verified.filter { $0.verdict == .refutedFabricated || $0.verdict == .refutedPanel }
        let fabricated = dropped   // kept name below for the existing dropped-count note
        // PREFIX CAVEAT (Codex): the structured findings below are grounded, but a model can also write a
        // code-specific claim as PROSE to evade the block-grounder. Frame the prose for the planner so an
        // un-grounded code claim there can't be taken as verified. The caveat fires UNCONDITIONALLY — an
        // earlier heuristic ("only when a FINDING block was present") fired only on the COOPERATIVE case and
        // MISSED the exact adversarial path it exists to cover (a code claim purely in prose, no marker,
        // empty `verified`). Always-on is unevadable; on a council that discussed no code it's vacuously
        // true. The COMPLETE close — judging the REALNESS of every claim, prose included — is the refute
        // panel, the un-wired second gate.
        var s = "[GROUNDING ACTIVE — only the CODE-GROUNDED FINDINGS listed below (if any) were checked "
              + "against the source. Any code-specific claim in the prose that is NOT in that list was NOT "
              + "verified; do not treat it as confirmed or turn it into a task on its own.]\n\n"
        s += prose
        _ = grounded   // (confirmed + unverified are rendered separately below)
        if !confirmed.isEmpty {
            s += "\n\nCONFIRMED FINDINGS (grounded in real code AND survived a skeptic refute panel — safe to act on):"
            for v in confirmed {
                let loc = v.finding.line.map { "\(v.finding.file):\($0)" } ?? v.finding.file
                s += "\n- \(v.finding.severity) \(loc): \(v.finding.claim)"
            }
        }
        if !unverified.isEmpty {
            s += "\n\nCODE-GROUNDED FINDINGS (the cited code EXISTS in the repo — existence is confirmed, but the bug itself is NOT yet validated; no refute panel ran, so treat realness as unproven):"
            for v in unverified {
                let loc = v.finding.line.map { "\(v.finding.file):\($0)" } ?? v.finding.file
                s += "\n- \(v.finding.severity) \(loc): \(v.finding.claim)"
            }
        }
        if !fabricated.isEmpty {
            s += "\n\nNOTE: \(fabricated.count) finding(s) were REMOVED — either the quoted code is NOT in the repo (likely fabricated) or a skeptic panel judged them NOT a real bug. Do NOT base the plan on them."
        }
        return s
    }

    // MARK: - Parsing model output

    /// Parse structured findings a reviewing model emitted between `<<<FINDING` and `FINDING>>>` markers,
    /// each a small key/value block. Free-text prose around the blocks is ignored — so a model can explain
    /// AND emit machine-checkable findings. Lines:
    ///   severity: HIGH
    ///   file: Sources/.../Foo.swift
    ///   line: 42                  (optional)
    ///   claim: one-line problem
    ///   code: <multi-line until the closing marker; the EXACT code being flagged>
    /// `code:` is greedy to the end of the block so the quote can span lines.
    public static func parse(_ text: String) -> [GroundedReviewFinding] {
        var findings: [GroundedReviewFinding] = []
        let scanner = text.components(separatedBy: "<<<FINDING")
        for chunk in scanner.dropFirst() {
            guard let end = chunk.range(of: "FINDING>>>") else { continue }
            let block = String(chunk[chunk.startIndex..<end.lowerBound])
            var severity = "", file = "", claim = "", code = ""
            var line: Int? = nil
            var inCode = false
            var codeLines: [String] = []
            for raw in block.components(separatedBy: "\n") {
                if inCode { codeLines.append(raw); continue }
                let t = raw.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                if let v = value(of: "severity", in: t) { severity = v }
                else if let v = value(of: "file", in: t) { file = v }
                else if let v = value(of: "line", in: t) { line = Int(v.trimmingCharacters(in: .whitespaces)) }
                else if let v = value(of: "claim", in: t) { claim = v }
                else if let v = value(of: "code", in: t) {
                    inCode = true
                    if !v.isEmpty { codeLines.append(v) }
                }
            }
            code = codeLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let f = GroundedReviewFinding(severity: severity.isEmpty ? "UNSPECIFIED" : severity,
                                  file: file, line: line, codeQuote: code, claim: claim)
            // Skip an utterly empty block (no file and no claim) — it carries no finding.
            if !file.isEmpty || !claim.isEmpty { findings.append(f) }
        }
        return findings
    }

    private static func value(of key: String, in line: String) -> String? {
        let prefix = key + ":"
        guard line.lowercased().hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - helpers

    /// Collapse all runs of whitespace (incl. newlines) to a single space and trim, so the grounding match
    /// is robust to indentation/formatting differences between the model's quote and the source.
    static func normalize(_ s: String) -> String {
        let collapsed = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return collapsed
    }

    /// Resolve a project-relative ref to an absolute path WITHIN the project root (reject traversal/abs).
    /// SYMLINK-SAFE: resolves symlinks on BOTH the candidate and the root before the prefix check, so a
    /// planted `Sources/x -> /etc/passwd` symlink can't pass containment and get read (standardizedFileURL
    /// alone collapses `..` but does NOT resolve symlinks, which fileExists/contentsOfFile then follow).
    private static func resolvedPath(_ ref: String, projectRoot: String) -> String? {
        var r = ref
        while r.hasPrefix("./") { r.removeFirst(2) }
        if r.hasPrefix("/") || r.contains("://") || r.isEmpty { return nil }
        let candidate = URL(fileURLWithPath: projectRoot).appendingPathComponent(r).standardizedFileURL
        // Pre-check on the lexical path too (cheap reject of obvious escapes before touching the FS).
        let lexicalRoot = URL(fileURLWithPath: projectRoot).standardizedFileURL.path
        guard candidate.path == lexicalRoot || candidate.path.hasPrefix(lexicalRoot + "/") else { return nil }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        // Now resolve symlinks on both sides and re-verify containment — the real defense.
        let realFull = candidate.resolvingSymlinksInPath().path
        let realRoot = URL(fileURLWithPath: projectRoot).resolvingSymlinksInPath().path
        guard realFull == realRoot || realFull.hasPrefix(realRoot + "/") else { return nil }
        return candidate.path
    }
}
