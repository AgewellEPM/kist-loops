import Foundation
import AgentCore

/// CLI surface for the Verification Receipt system (docs/kist/LEAPFROG_ROADMAP_2026.md WS2 T2.2):
///   kist --verify [--verify-cmd "swift build && swift test"]   → run checks on the STAGED change, seal+store a receipt
///   kist --guard                                               → gate: the staged change needs a valid receipt (exit 0/1)
///   kist --install-guard                                       → install a pre-commit hook that runs `kist --guard`
/// The guard is UNBLOCKABLE by design: it wraps git, not an editor — any agent/editor/CLI that stages a change
/// must have produced a matching receipt or the commit is refused.
extension KistRunner {
    static func rcptStderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    /// Run git and return BOTH exit status and raw stdout bytes. The status matters: a git failure (launch error,
    /// nonzero exit) must NEVER be indistinguishable from "clean/empty output" — the guard fail-opens if it is
    /// (Codex CRITICAL). Launch failure ⇒ sentinel -1 (nonzero) so callers treat it as an error, not empty.
    static func gitRun(_ args: [String], cwd: String) -> (status: Int32, data: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return (-1, Data()) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    /// LOSSLESS byte→string: ISO-Latin-1 is a total, injective map (every byte 0–255 → a distinct code point), so
    /// a diff/blob with invalid UTF-8 never decodes to "" (which would corrupt the digest AND skip the secret
    /// scan — Codex CRITICAL/MED). Distinct byte sequences → distinct strings → distinct digests, deterministically
    /// and identically on every machine. This is the canonical decode for anything that feeds a digest or a scan.
    static func losslessString(_ data: Data) -> String { String(bytes: data, encoding: .isoLatin1) ?? "" }

    static func gitOut(_ args: [String], cwd: String) -> String { losslessString(gitRun(args, cwd: cwd).data) }

    private static func runShell(_ command: String, cwd: String) -> (exit: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return (127, "could not launch: \(error)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // STABLE diff flags so the digest is MACHINE-INDEPENDENT (git diff output varies by local config —
    // diff.algorithm/renames/quotePath/abbrev — which would make a receipt made on machine A false-reject on
    // machine B). Pin every relevant knob via `-c` overrides + explicit flags so verify and guard agree everywhere.
    //   --full-index : full 40-char blob SHAs (not abbreviated) → binary changes bind to a collision-resistant id,
    //                  and `core.abbrev` can't shift the digest (Codex HIGH: binary binding was weaker than "exact").
    //   --binary     : include the actual binary patch so binary CONTENT is bound, not just "Binary files differ".
    //   --no-textconv: never run a textconv filter that could rewrite the diff (determinism + can't be gamed).
    // Shared config prefix + diff flags (NO ref selector). `internal` (not private) so the CI range-guard in the
    // sibling file reproduces the SAME digest by appending positional refs instead of `--cached`.
    static let stableDiffFlags = [
        "-c", "core.quotePath=false", "-c", "diff.noprefix=false", "-c", "diff.mnemonicPrefix=false",
        "-c", "diff.algorithm=myers", "-c", "diff.renames=false", "-c", "diff.renameLimit=0",
        "-c", "diff.interHunkContext=0",   // pin it too (Codex round 2: -c diff.interHunkContext=10 shifted the digest)
        "diff", "--no-color", "--no-ext-diff", "--full-index", "--binary", "--no-textconv", "-U3",
    ]
    /// EXCLUDE the receipt store itself from every gated diff. A receipt is minted for the code change BEFORE the
    /// receipt file exists, then committed ALONGSIDE the code — so the commit's diff would otherwise include the
    /// receipt JSON and never match the sealed digest (circular). Excluding `.kist/receipts` on BOTH ends (verify
    /// AND gate) keeps the digest symmetric: the proof artifact is not part of the reviewed change. (Live-test C1.)
    static let receiptPathExclusion = ["--", ".", ":(exclude,top).kist/receipts"]

    /// Staged-index diff (verify + local guard): shared flags + `--cached` + the receipt-store exclusion.
    private static var stableDiff: [String] {
        var a = stableDiffFlags; a.insert("--cached", at: a.firstIndex(of: "diff")! + 1)
        a.append(contentsOf: receiptPathExclusion); return a
    }
    /// Range diff (CI guard): the shared flags; caller appends `<base> <head>` then the same exclusion.
    static var stableDiffRangeFlags: [String] { stableDiffFlags }

    /// Read the staged diff with its git EXIT STATUS. status != 0 ⇒ error (NOT "nothing staged"): callers must
    /// fail-closed, never admit blind. Diff bytes are decoded losslessly (never "" on invalid UTF-8).
    private static func stagedDiff(root: String) -> (status: Int32, diff: String) {
        let r = gitRun(stableDiff, cwd: root)
        return (r.status, losslessString(r.data))
    }

    /// Staged files with their change status, read with `-z` (NUL-delimited) so filenames containing newlines or
    /// quotes are NOT C-quoted/mis-split (Codex round 2: a quoted name broke `git show :<file>` → the content scan
    /// silently skipped it). renames are off (diff.renames=false) so entries are (status, path) pairs.
    private static func stagedNameStatus(root: String) -> (status: Int32, entries: [(status: String, path: String)]) {
        // --no-renames: keep entries as clean (status,path) PAIRS. With rename detection on (a common git default)
        // an R entry carries TWO paths (old,new) and would misalign the pair-parser → wrong changedFiles → a proof
        // `scope`/`file-touched` claim could evaluate against the wrong file list (Codex gate9 MED).
        let r = gitRun(["diff", "--cached", "--name-status", "-z", "--no-renames"], cwd: root)
        guard r.status == 0 else { return (r.status, []) }
        let toks = losslessString(r.data).split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)
        var entries: [(String, String)] = []
        var i = 0
        while i + 1 < toks.count { entries.append((toks[i], toks[i + 1])); i += 2 }
        return (0, entries)
    }

    private static func stagedFiles(root: String) -> [String] {
        stagedNameStatus(root: root).entries.map { $0.path }
    }

    /// Staged-index counterpart of the CI guard's receiptDirIntegrity: every STAGED file under `.kist/receipts/`
    /// must be a seal-valid receipt, else content is being smuggled into the diff-excluded receipts dir (dogfood
    /// HOLE B). Returns a failure reason, or nil if clean.
    static func stagedReceiptDirIntegrity(root: String, key: Data, verifier: ReceiptAttestationVerifier) -> String? {
        // `--raw -z` gives the staged NEW MODE so a gitlink/symlink/tree under receipts is rejected (not just
        // whole-file authenticated). `git show :<path>` reads the staged blob. Shares the CI guard's parser.
        let raw = gitOut(["diff", "--cached", "--raw", "-z", "--no-renames", "--", ":(top).kist/receipts"], cwd: root)
        return checkReceiptRaw(raw, showRef: { ":\($0)" }, root: root, key: key, verifier: verifier)
    }

    /// FULL-CONTENT secret scan of every staged blob — catches secrets the DIFF-based scan misses: a secret in
    /// a BINARY file (git diff shows no content) and a secret whose text isn't on a scanned `+` line. Reads the
    /// staged object (`git show :<file>`); binary bytes are scanned raw (lossy utf8, but the ASCII key/base64
    /// patterns still match). Pen-test-driven.
    private static func stagedContentSecretCheck(root: String) -> ReceiptCheck {
        let (status, entries) = stagedNameStatus(root: root)
        guard status == 0 else {
            // Couldn't even enumerate staged files → cannot certify "no secrets" → FAIL CLOSED (Codex round 2).
            return ReceiptCheck(name: "no-secrets-in-content", kind: .deterministic, passed: false,
                                detail: "could not read staged file list (git exit \(status)) — failing closed")
        }
        var hits: [String] = []
        var unreadable: [String] = []
        for (st, f) in entries {
            if st.hasPrefix("D") { continue }   // deleted in index → no blob to scan
            // Lossless decode (NOT gitOut→utf8): a binary blob carrying a secret + invalid UTF-8 used to decode to
            // "" and get skipped (round 1). Latin-1 preserves the ASCII key/base64 shapes the scan matches.
            let r = gitRun(["show", ":\(f)"], cwd: root)
            guard r.status == 0 else { unreadable.append(f); continue }   // added/modified but unreadable → fail closed
            let content = losslessString(r.data)
            guard !content.isEmpty else { continue }
            if !ReceiptChecks.secretScan([content]).passed { hits.append("secret:\(f)") }
            // Host-control content scan for ADDED files only: catches the `.gitattributes *.swift -diff` evasion
            // where an added file renders as a binary patch with no `+` text lines (round 2). Added-only ⇒ whole
            // content IS the change ⇒ no false positives on files that already legitimately use host-control APIs.
            // (Modified files under `-diff` remain a documented heuristic limit — see RECEIPT_THREAT_MODEL.md.)
            if st.hasPrefix("A"), !ReceiptChecks.hostControlIntro([content]).passed { hits.append("host-control:\(f)") }
        }
        let ok = hits.isEmpty && unreadable.isEmpty
        var detail = ok ? "no secrets/host-control in staged file contents (incl. binary)" : ""
        if !hits.isEmpty { detail += "flagged: \(hits.joined(separator: ", ")). " }
        if !unreadable.isEmpty { detail += "UNREADABLE staged blobs (failed closed): \(unreadable.joined(separator: ", "))" }
        return ReceiptCheck(name: "no-secrets-in-content", kind: .deterministic, passed: ok, detail: detail)
    }

    static func runReceiptVerify(_ opts: KistOptions) -> Int32 {
        let root = opts.project
        let (status, diff) = stagedDiff(root: root)
        guard status == 0 else { rcptStderr("could not read staged diff (git exit \(status)) — is this a git repo?"); return 2 }
        guard !diff.isEmpty else { rcptStderr("nothing staged to verify — `git add` your change first."); return 2 }
        let base = gitOut(["rev-parse", "HEAD"], cwd: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let files = stagedFiles(root: root)
        let key = ReceiptKey.load()
        let verifier = KistRunner.effectiveIssuerVerifier(projectRoot: root)
        let smuggle = stagedReceiptDirIntegrity(root: root, key: key.0, verifier: verifier)
        var cmdChecks: [ReceiptCheck] = [
            stagedContentSecretCheck(root: root),
            ReceiptCheck(name: "receipts-dir-clean", kind: .deterministic, passed: smuggle == nil,
                         detail: smuggle ?? "no non-receipt content under .kist/receipts"),
        ]
        if let cmd = opts.verifyCommand {
            cmdChecks.append(CommandCheck(name: "verify-cmd", command: cmd).evaluate { runShell($0, cwd: root) })
        }
        // Proof-carrying claims: evaluate the patch's self-asserted, machine-checkable claims against the ACTUAL
        // staged diff and fold them into the receipt. A required claim that doesn't hold fails the verdict → the
        // change can't merge. Binding: the proof set must name THIS change's digest (else it describes another).
        if let pp = opts.proofsPath {
            let digest = ReceiptSubject.digest(ofDiff: diff)
            if let data = FileManager.default.contents(atPath: pp),
               let set = try? JSONDecoder().decode(ProofSet.self, from: data) {
                // Binding: an empty diffDigest means "check against whatever is staged" (the agent didn't pre-know
                // the digest); a non-empty digest is STRICTLY enforced (the set names a specific change).
                if set.diffDigest.isEmpty || set.diffDigest == digest {
                    cmdChecks.append(contentsOf: ProofChecker.evaluate(diff: diff, changedFiles: files, claims: set.claims))
                } else {
                    cmdChecks.append(ReceiptCheck(name: "proof:binding", kind: .deterministic, passed: false,
                        detail: "proof set is for a different change (digest mismatch) — regenerate it for this diff"))
                }
            } else {
                cmdChecks.append(ReceiptCheck(name: "proof:load", kind: .deterministic, passed: false,
                    detail: "could not read a proof set from \(pp)"))
            }
        }
        let (sealed, saved) = ReceiptCLI.verify(projectRoot: root, baseSHA: base, changedFiles: files, diff: diff,
                                                commandChecks: cmdChecks, key: key,
                                                now: Date().timeIntervalSince1970, issuer: "kist")
        print(ReceiptCLI.summary(sealed))
        rcptStderr(saved ? "receipt stored under .kist/receipts/" : "⚠ receipt NOT stored (write failed)")
        return sealed.receipt.verdict == .pass ? 0 : 1
    }

    static func runReceiptGuard(_ opts: KistOptions) -> Int32 {
        let root = opts.project
        let (status, diff) = stagedDiff(root: root)
        // FAIL-CLOSED on any git error — an error reading the diff is NOT "nothing staged". Admitting blind here
        // is exactly the fail-open Codex flagged CRITICAL. (git launch fail ⇒ status -1.)
        guard status == 0 else {
            rcptStderr("✗ kist BLOCKED this commit: could not read the staged diff (git exit \(status)) — "
                     + "refusing to admit a change it cannot see."); return 1
        }
        if diff.isEmpty {
            // Genuinely nothing staged ⇒ nothing to gate. But if files ARE staged yet the diff rendered empty,
            // that's anomalous (a diff that failed to render) → fail-closed, don't admit blind.
            if stagedFiles(root: root).isEmpty { return 0 }
            rcptStderr("✗ kist BLOCKED this commit: staged files present but the diff is empty — "
                     + "refusing to admit a change it cannot see."); return 1
        }
        let key = ReceiptKey.load().0
        let verifier = KistRunner.effectiveIssuerVerifier(projectRoot: root)
        if let why = stagedReceiptDirIntegrity(root: root, key: key, verifier: verifier) {
            rcptStderr("✗ kist BLOCKED this commit: \(why)"); return 1
        }
        switch ReceiptCLI.guardDecision(projectRoot: root, diff: diff, key: key) {
        case .admit: break
        case .reject(let why): rcptStderr("✗ kist BLOCKED this commit: \(why)"); return 1
        }
        // Issuer tier: when keys are pinned, the local commit also needs a valid pinned-issuer signature.
        if !verifier.isEmpty {
            let digest = ReceiptSubject.digest(ofDiff: diff)
            guard let att = ReceiptStore(projectRoot: root).loadAttestation(diffDigest: digest),
                  case .valid = verifier.verify(att, diffDigest: digest) else {
                rcptStderr("✗ kist BLOCKED this commit: no valid pinned-issuer signature "
                         + "(sign with `kist --sign-receipt`)"); return 1
            }
        }
        rcptStderr("✓ kist: verification receipt valid — commit allowed."); return 0
    }

    static func installReceiptHook(_ opts: KistOptions) -> Int32 {
        let root = opts.project
        let gitDir = gitOut(["rev-parse", "--absolute-git-dir"], cwd: root).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gitDir.isEmpty else { rcptStderr("not a git repository."); return 1 }
        // Resolve the EFFECTIVE hooks dir via git — this honors `core.hooksPath`, which would otherwise make git
        // ignore a hook we wrote to $GIT_DIR/hooks (Codex round 2 HIGH). Relative results are rooted at the repo.
        var hooksDir = gitOut(["rev-parse", "--git-path", "hooks"], cwd: root).trimmingCharacters(in: .whitespacesAndNewlines)
        if hooksDir.isEmpty { hooksDir = (gitDir as NSString).appendingPathComponent("hooks") }
        else if !(hooksDir as NSString).isAbsolutePath { hooksDir = (root as NSString).appendingPathComponent(hooksDir) }
        try? FileManager.default.createDirectory(atPath: hooksDir, withIntermediateDirectories: true)
        let hookPath = (hooksDir as NSString).appendingPathComponent("pre-commit")
        // Embed the ABSOLUTE path of THIS kist binary — never bare `kist` (which could resolve to a different/
        // stale kist on PATH and silently fail to gate). Resolve symlinks so it's stable.
        let exePath = Bundle.main.executablePath.map { ($0 as NSString).resolvingSymlinksInPath }
            ?? CommandLine.arguments[0]
        // SINGLE-QUOTE + escape both embedded strings (Codex HIGH: a repo path or binary path containing $(),
        // backticks, `"` or `\` was substituted/executed at commit time when embedded in double quotes). Inside
        // single quotes every metacharacter is literal; the only escape needed is `'` → `'\''`.
        func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let exeQ = shq(exePath), rootQ = shq(root)
        let marker = "# kist-verification-guard"
        let script = """
        #!/bin/sh
        \(marker)
        # A commit requires a valid receipt for its staged change. Produce one with: kist --verify (then commit).
        # This LOCAL hook is convenience/defense-in-depth — it is BYPASSABLE (git commit --no-verify, or removing
        # the hook). The AUTHORITATIVE gate is the server-side required check (GitHub App). Do not rely on the
        # hook as the security boundary.
        exec \(exeQ) --guard --project \(rootQ)
        """
        // NEVER clobber a user's existing pre-commit hook (pen-test finding). "Ours" = the marker appears as its
        // OWN line (not merely a substring in prose) — so a hook that just mentions the string isn't clobbered
        // (Codex round 2 LOW). If one exists and isn't ours, REFUSE with chain instructions.
        let ownsHook: (String) -> Bool = { hook in
            hook.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.trimmingCharacters(in: .whitespaces) == marker }
        }
        if let existing = try? String(contentsOfFile: hookPath, encoding: .utf8), !ownsHook(existing) {
            rcptStderr("""
            ✗ refusing to overwrite an existing pre-commit hook at \(hookPath).
            Add this line to your hook to chain the guard:
              \(exeQ) --guard --project \(rootQ) || exit 1
            Or move your hook aside and re-run --install-guard.
            """)
            return 1
        }
        do { try script.write(toFile: hookPath, atomically: true, encoding: .utf8); chmod(hookPath, 0o755) }
        catch { rcptStderr("could not write hook: \(error)"); return 1 }
        rcptStderr("installed pre-commit guard → \(hookPath)\nA commit now requires `kist --verify` first. "
                 + "NOTE: this LOCAL hook is bypassable (--no-verify) — the server-side check is the real gate.")
        return 0
    }
}
