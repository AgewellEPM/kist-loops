import XCTest
@testable import Kist
import AgentCore

/// Integration tests for the server-authoritative `--ci-guard` range gate, driven against a REAL git repo.
/// These pin the two dogfood-found holes as regressions: (A) an unresolvable base must FAIL CLOSED, never gate a
/// silently-narrowed range; (B) arbitrary content smuggled under the diff-excluded `.kist/receipts/` must be
/// blocked. XCTSkip when git isn't on PATH (CI images without git).
final class ReceiptCIGuardTests: XCTestCase {

    private var repo = ""
    private let key = "ci-org-shared-secret-key-1234567890"

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw XCTSkip("git not available")
        }
        repo = NSTemporaryDirectory() + "kist_ci_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        setenv("KIST_RECEIPT_KEY", key, 1)
        git("init", "-q"); git("config", "user.email", "t@t"); git("config", "user.name", "t")
        git("config", "core.autocrlf", "false")
    }
    override func tearDownWithError() throws {
        unsetenv("KIST_RECEIPT_KEY")
        if !repo.isEmpty { try? FileManager.default.removeItem(atPath: repo) }
    }

    @discardableResult
    private func git(_ args: String...) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: repo)
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try? p.run(); let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private func write(_ path: String, _ contents: String) {
        let full = (repo as NSString).appendingPathComponent(path)
        try? FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? contents.write(toFile: full, atomically: true, encoding: .utf8)
    }
    private func opts(base: String? = nil, head: String? = nil) -> KistOptions {
        var o = KistOptions(project: repo); o.ciGuard = true; o.ciGuardBase = base; o.ciGuardHead = head; return o
    }

    func testUnresolvableBaseFailsClosed() {   // HOLE A
        write("f.txt", "1\n"); git("add", "."); git("commit", "-qm", "c1")
        write("f.txt", "1\n2\n"); git("add", "f.txt"); git("commit", "-qm", "c2 no receipt")
        // No base/head args, no origin remote → base cannot be resolved → MUST exit 2 (not gate a narrowed range).
        XCTAssertEqual(KistRunner.runReceiptCIGuard(opts()), 2)
    }

    func testLegitReceiptedCommitAdmits() {
        write("code.swift", "let a = 1\n"); git("add", "."); git("commit", "-qm", "init")
        let base = git("rev-parse", "HEAD")
        write("code.swift", "let a = 1\nlet b = 2\n"); git("add", "code.swift")
        var vo = KistOptions(project: repo); vo.verifyReceipt = true
        _ = KistRunner.runReceiptVerify(vo)
        git("add", ".kist/receipts"); git("commit", "-qm", "code+receipt")
        XCTAssertEqual(KistRunner.runReceiptCIGuard(opts(base: base, head: "HEAD")), 0)
    }

    func testSmuggledFileUnderReceiptsIsBlocked() {   // HOLE B
        write("code.swift", "let a = 1\n"); git("add", "."); git("commit", "-qm", "init")
        let base = git("rev-parse", "HEAD")
        write(".kist/receipts/notareceipt.swift", "let backdoor = evil()\n")   // arbitrary content, not a receipt
        git("add", ".kist/receipts/notareceipt.swift"); git("commit", "-qm", "smuggle")
        XCTAssertEqual(KistRunner.runReceiptCIGuard(opts(base: base, head: "HEAD")), 1,
                       "content under the excluded receipts dir that isn't a valid receipt must block")
    }

    func testWrappedReceiptFileIsBlocked() {   // Codex stop-gate: valid receipt + injected extra content
        write("code.swift", "let a = 1\n"); git("add", "."); git("commit", "-qm", "init")
        let base = git("rev-parse", "HEAD")
        write("code.swift", "let a = 1\nlet b = 2\n"); git("add", "code.swift")
        var vo = KistOptions(project: repo); vo.verifyReceipt = true
        _ = KistRunner.runReceiptVerify(vo)
        // Wrap the just-written receipt file with an extra key while keeping the sealed sub-object valid.
        let rdir = (repo as NSString).appendingPathComponent(".kist/receipts")
        let file = (try? FileManager.default.contentsOfDirectory(atPath: rdir))?.first { $0.hasSuffix(".json") }
        let path = (rdir as NSString).appendingPathComponent(file ?? "x")
        if let data = FileManager.default.contents(atPath: path),
           var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            obj["EVIL"] = "smuggled AKIAIOSFODNN7EXAMPLE"
            let wrapped = try! JSONSerialization.data(withJSONObject: obj)
            try! wrapped.write(to: URL(fileURLWithPath: path))
        }
        git("add", "code.swift", ".kist/receipts"); git("commit", "-qm", "wrapped receipt")
        XCTAssertEqual(KistRunner.runReceiptCIGuard(opts(base: base, head: "HEAD")), 1,
                       "a receipt file wrapped with extra content must be blocked (whole-file authentication)")
    }

    /// The Ed25519 ISSUER-SIGNATURE tier end-to-end: with a pinned issuer, an UNSIGNED change is blocked and a
    /// SIGNED one admits. Proves the enterprise win — the HMAC receipt alone (same-trust-domain) is no longer
    /// sufficient once an issuer is pinned. HOME is redirected so the real issuer store is never touched.
    func testIssuerSignatureTierRequiresAndAcceptsSignature() throws {
        let origHome = ProcessInfo.processInfo.environment["HOME"]
        let home = NSTemporaryDirectory() + "kist_issuer_home_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        setenv("HOME", home, 1)
        defer { if let o = origHome { setenv("HOME", o, 1) } else { unsetenv("HOME") }
                try? FileManager.default.removeItem(atPath: home) }

        // Pin an issuer (public key) + keep its private key.
        let kp = MythosCrypto.ed25519GenerateKeyPair()
        try ReceiptIssuerKeyStore().pinning(keyID: "acme", publicKeyB64: kp.publicRaw.base64EncodedString()).save()
        let privPath = home + "/issuer-acme.key"
        try kp.privateRaw.base64EncodedString().write(toFile: privPath, atomically: true, encoding: .utf8)

        write("code.swift", "let a = 1\n"); git("add", "."); git("commit", "-qm", "init")
        let base = git("rev-parse", "HEAD")
        write("code.swift", "let a = 1\nlet b = 2\n"); git("add", "code.swift")
        var vo = KistOptions(project: repo); vo.verifyReceipt = true
        _ = KistRunner.runReceiptVerify(vo)

        // Committed WITHOUT a signature → the pinned-issuer tier blocks it.
        git("add", ".kist/receipts"); git("commit", "-qm", "code+receipt (unsigned)")
        XCTAssertEqual(KistRunner.runReceiptCIGuard(opts(base: base, head: "HEAD")), 1,
                       "with an issuer pinned, an unsigned change must be blocked (HMAC alone is insufficient)")

        // Now sign that change's receipt and amend the sidecar in → admits.
        var so = KistOptions(project: repo); so.signReceipt = "latest"; so.issuerKeyPath = privPath
        // "latest" derives from the staged diff — re-stage the same change so the digest matches.
        git("reset", "--soft", base)
        git("add", "code.swift")
        _ = KistRunner.runReceiptVerify(vo)
        XCTAssertEqual(KistRunner.runSignReceipt(so), 0)
        git("add", ".kist/receipts"); git("commit", "-qm", "code+receipt+sig")
        XCTAssertEqual(KistRunner.runReceiptCIGuard(opts(base: base, head: "HEAD")), 0,
                       "a change signed by the pinned issuer must admit")
    }

    /// Revocation: a change that was validly signed by an issuer is REJECTED once that issuer is revoked — the
    /// compromised-key / rotation primitive, enforced at the gate.
    func testRevokedIssuerSignatureIsRejected() throws {
        let origHome = ProcessInfo.processInfo.environment["HOME"]
        let home = NSTemporaryDirectory() + "kist_rev_home_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        setenv("HOME", home, 1)
        defer { if let o = origHome { setenv("HOME", o, 1) } else { unsetenv("HOME") }
                try? FileManager.default.removeItem(atPath: home) }

        let kp = MythosCrypto.ed25519GenerateKeyPair()
        try ReceiptIssuerKeyStore().pinning(keyID: "acme", publicKeyB64: kp.publicRaw.base64EncodedString()).save()
        let privPath = home + "/issuer-acme.key"
        try kp.privateRaw.base64EncodedString().write(toFile: privPath, atomically: true, encoding: .utf8)

        write("code.swift", "let a = 1\n"); git("add", "."); git("commit", "-qm", "init")
        let base = git("rev-parse", "HEAD")
        write("code.swift", "let a = 1\nlet b = 2\n"); git("add", "code.swift")
        var vo = KistOptions(project: repo); vo.verifyReceipt = true
        _ = KistRunner.runReceiptVerify(vo)
        var so = KistOptions(project: repo); so.signReceipt = "latest"; so.issuerKeyPath = privPath
        XCTAssertEqual(KistRunner.runSignReceipt(so), 0)
        git("add", ".kist/receipts"); git("commit", "-qm", "signed by acme")
        XCTAssertEqual(KistRunner.runReceiptCIGuard(opts(base: base, head: "HEAD")), 0, "acme-signed admits")

        // Revoke acme → the same signature is now rejected.
        try ReceiptIssuerKeyStore.load().revoking(keyID: "acme").save()
        XCTAssertEqual(KistRunner.runReceiptCIGuard(opts(base: base, head: "HEAD")), 1,
                       "once the issuer is revoked, its previously-valid signature must be rejected")
    }

    /// Anti-rollback: a PR that reverts the root-signed trust bundle to an OLDER (still validly-signed) version —
    /// re-trusting a revoked issuer — is refused, even though the old bundle's root signature is intact.
    func testTrustBundleRollbackIsBlocked() throws {
        let origHome = ProcessInfo.processInfo.environment["HOME"]
        let home = NSTemporaryDirectory() + "kist_rb_home_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        setenv("HOME", home, 1)
        defer { if let o = origHome { setenv("HOME", o, 1) } else { unsetenv("HOME") }
                try? FileManager.default.removeItem(atPath: home) }

        let rootKP = MythosCrypto.ed25519GenerateKeyPair()
        let alice = MythosCrypto.ed25519GenerateKeyPair().publicRaw.base64EncodedString()
        let bob = MythosCrypto.ed25519GenerateKeyPair().publicRaw.base64EncodedString()
        // v1 bundle: alice + bob trusted (epoch 1000).
        let v1 = try SignedTrustBundle.make(
            bundle: TrustBundle(issuers: ["alice": alice, "bob": bob], revoked: [:], rootKeyID: "root",
                                issuedAtEpoch: 1000),
            rootPrivateKeyRaw: rootKP.privateRaw)
        // v2 bundle: alice REVOKED (epoch 2000).
        let v2 = try SignedTrustBundle.make(
            bundle: TrustBundle(issuers: ["bob": bob], revoked: ["alice": ReceiptIssuerKeyStore.fingerprint(alice)!],
                                rootKeyID: "root", issuedAtEpoch: 2000),
            rootPrivateKeyRaw: rootKP.privateRaw)
        try ReceiptRootKeyStore().pinning(keyID: "root", publicKeyB64: rootKP.publicRaw.base64EncodedString()).save()

        func writeBundle(_ b: SignedTrustBundle) { write(".kist/trust-bundle.json", String(decoding: b.canonicalBytes(), as: UTF8.self)) }
        write("seed", "x\n"); writeBundle(v1); git("add", "."); git("commit", "-qm", "v1")
        writeBundle(v2); git("add", "."); git("commit", "-qm", "v2 revoke alice")
        let base = git("rev-parse", "HEAD")
        writeBundle(v1); git("add", "."); git("commit", "-qm", "sneaky rollback to v1")   // re-trust revoked alice

        XCTAssertEqual(KistRunner.runReceiptCIGuard(opts(base: base, head: "HEAD")), 1,
                       "rolling the trust bundle back to re-trust a revoked issuer must be blocked")
    }

    /// Pure trust-bundle transition policy — the equal-epoch / downgrade rules, unit-tested without git.
    func testBundleTransitionPolicy() throws {
        let rootKP = MythosCrypto.ed25519GenerateKeyPair()
        let rv = TrustBundleVerifier(trustedRoots: [.init(keyID: "root", publicKeyB64: rootKP.publicRaw.base64EncodedString())])
        let alice = MythosCrypto.ed25519GenerateKeyPair().publicRaw.base64EncodedString()
        func signed(issuers: [String: String], revoked: [String: String], epoch: Double) throws -> SignedTrustBundle {
            try SignedTrustBundle.make(bundle: TrustBundle(issuers: issuers, revoked: revoked, rootKeyID: "root",
                                                           issuedAtEpoch: epoch), rootPrivateKeyRaw: rootKP.privateRaw)
        }
        let baseB = try signed(issuers: [:], revoked: ["alice": ReceiptIssuerKeyStore.fingerprint(alice)!], epoch: 1000)

        // No base bundle ⇒ nothing to roll back.
        XCTAssertNil(KistRunner.bundleTransitionReason(baseSigned: nil, headSigned: baseB, rootVerifier: rv))
        // Head removed a bundle base had ⇒ block.
        XCTAssertNotNil(KistRunner.bundleTransitionReason(baseSigned: baseB, headSigned: nil, rootVerifier: rv))
        // Unchanged ⇒ ok.
        XCTAssertNil(KistRunner.bundleTransitionReason(baseSigned: baseB, headSigned: baseB, rootVerifier: rv))
        // Lower epoch content change ⇒ block.
        let lower = try signed(issuers: ["alice": alice], revoked: [:], epoch: 500)
        XCTAssertNotNil(KistRunner.bundleTransitionReason(baseSigned: baseB, headSigned: lower, rootVerifier: rv))
        // SAME epoch, DIFFERENT content (re-adds alice) ⇒ block (the Codex bg-gate point).
        let sameEpoch = try signed(issuers: ["alice": alice], revoked: [:], epoch: 1000)
        XCTAssertNotNil(KistRunner.bundleTransitionReason(baseSigned: baseB, headSigned: sameEpoch, rootVerifier: rv),
                        "a same-epoch content change that re-adds a revoked issuer must be blocked")
        // HIGHER epoch (root's prerogative to un-revoke) ⇒ allowed.
        let higher = try signed(issuers: ["alice": alice], revoked: [:], epoch: 2000)
        XCTAssertNil(KistRunner.bundleTransitionReason(baseSigned: baseB, headSigned: higher, rootVerifier: rv))
        // No pinned root ⇒ bundles inert.
        XCTAssertNil(KistRunner.bundleTransitionReason(baseSigned: baseB, headSigned: lower,
                     rootVerifier: TrustBundleVerifier(trustedRoots: [])))

        // Cross-root downgrade: with TWO pinned roots, swapping base's root for another pinned root is blocked.
        let root2 = MythosCrypto.ed25519GenerateKeyPair()
        let rv2 = TrustBundleVerifier(trustedRoots: [
            .init(keyID: "root", publicKeyB64: rootKP.publicRaw.base64EncodedString()),
            .init(keyID: "root2", publicKeyB64: root2.publicRaw.base64EncodedString())])
        let headByRoot2 = try SignedTrustBundle.make(
            bundle: TrustBundle(issuers: ["alice": alice], revoked: [:], rootKeyID: "root2", issuedAtEpoch: 9999),
            rootPrivateKeyRaw: root2.privateRaw)
        XCTAssertNotNil(KistRunner.bundleTransitionReason(baseSigned: baseB, headSigned: headByRoot2, rootVerifier: rv2),
                        "switching the signing root across a transition must be blocked even at a higher epoch")
    }

    func testCleanMergeOfReceiptedBranchPasses() {   // gate6: no false-block on a legit merge workflow
        write("f", "base\n"); git("add", "."); git("commit", "-qm", "init")
        let base = git("rev-parse", "HEAD")
        git("checkout", "-qb", "feature")
        write("f", "base\nfeature\n"); git("add", "f")
        var vo = KistOptions(project: repo); vo.verifyReceipt = true
        _ = KistRunner.runReceiptVerify(vo)
        git("add", ".kist/receipts"); git("commit", "-qm", "feature+receipt")
        let mainBranch = git("rev-parse", "--abbrev-ref", "HEAD@{-1}")
        git("checkout", "-q", mainBranch.isEmpty ? "-" : mainBranch)
        git("merge", "-q", "--no-ff", "feature", "-m", "merge feature")
        XCTAssertEqual(KistRunner.runReceiptCIGuard(opts(base: base, head: "HEAD")), 0,
                       "a clean merge of a fully-receipted feature branch must PASS (no false block)")
    }

    func testGitlinkUnderReceiptsIsBlocked() {   // gate5 HIGH: non-blob entry must not fail open
        write("code.swift", "let a = 1\n"); git("add", "."); git("commit", "-qm", "init")
        let base = git("rev-parse", "HEAD")
        // Stage a fake gitlink (submodule, mode 160000) under .kist/receipts via update-index. A non-zero SHA so
        // git records a real 160000 entry (an all-zero SHA is treated specially and yields no diff entry).
        git("update-index", "--add", "--cacheinfo",
            "160000,deadbeefdeadbeefdeadbeefdeadbeefdeadbeef,.kist/receipts/sub")
        git("commit", "-qm", "gitlink under receipts")
        XCTAssertEqual(KistRunner.runReceiptCIGuard(opts(base: base, head: "HEAD")), 1,
                       "a gitlink/submodule under the excluded receipts dir must be blocked, not skipped")
    }

    func testAddThenDeleteInSideBranchIsGated() {   // gate5 HIGH: --first-parent history gap
        write("f", "base\n"); git("add", "."); git("commit", "-qm", "init")
        let base = git("rev-parse", "HEAD")
        git("checkout", "-qb", "side")
        write(".kist/receipts/evil.swift", "let evil = 1\n"); git("add", ".kist/receipts/evil.swift"); git("commit", "-qm", "add evil")
        git("rm", "-q", ".kist/receipts/evil.swift"); git("commit", "-qm", "delete evil")
        let mainBranch = git("rev-parse", "--abbrev-ref", "HEAD@{-1}")
        git("checkout", "-q", mainBranch.isEmpty ? "-" : mainBranch)
        git("merge", "-q", "--no-ff", "side", "-m", "merge")
        // Content added on the side branch (then removed before the empty-net merge) is still gated.
        XCTAssertEqual(KistRunner.runReceiptCIGuard(opts(base: base, head: "HEAD")), 1,
                       "side-branch content must be gated even if the net merge diff is empty")
    }

    func testMixedValidReceiptPlusSmuggleIsBlocked() {   // HOLE B, the sharp case
        write("code.swift", "let a = 1\n"); git("add", "."); git("commit", "-qm", "init")
        let base = git("rev-parse", "HEAD")
        write("code.swift", "let a = 1\nlet b = 2\n"); git("add", "code.swift")
        var vo = KistOptions(project: repo); vo.verifyReceipt = true
        _ = KistRunner.runReceiptVerify(vo)                          // legit receipt for the code
        write(".kist/receipts/evil.swift", "let evil = 1\n")         // smuggle alongside the real receipt
        git("add", ".kist/receipts"); git("commit", "-qm", "code+receipt+smuggle")
        XCTAssertEqual(KistRunner.runReceiptCIGuard(opts(base: base, head: "HEAD")), 1,
                       "a valid code receipt must NOT let a smuggled file ride in under .kist/receipts")
    }
}
