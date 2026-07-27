import XCTest
@testable import AgentCore

final class ReceiptChecksAndGuardTests: XCTestCase {
    private let key = Data("k".utf8)

    // MARK: deterministic checks
    func testParseAddedLinesSkipsFileHeaders() {
        let diff = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@\n+added line\n-removed\n context"
        XCTAssertEqual(ReceiptChecks.parseAddedLines(diff), ["added line"])
    }

    func testSecretScanCatchesSecretsAndPassesClean() {
        XCTAssertFalse(ReceiptChecks.secretScan(["-----BEGIN RSA PRIVATE KEY-----"]).passed)
        XCTAssertFalse(ReceiptChecks.secretScan(["AKIAIOSFODNN7EXAMPLE"]).passed)
        XCTAssertFalse(ReceiptChecks.secretScan(["let api_key = \"abcdefghijklmnopqrstuvwxyz012345\""]).passed)
        XCTAssertTrue(ReceiptChecks.secretScan(["let count = 42", "func doThing() {}"]).passed)
    }

    func testHostControlIntroCatchesAutomation() {
        XCTAssertFalse(ReceiptChecks.hostControlIntro(["Process().launchPath = \"/usr/bin/osascript\""]).passed)
        XCTAssertFalse(ReceiptChecks.hostControlIntro(["CGEventPost(.cghidEventTap, e)"]).passed)
        XCTAssertTrue(ReceiptChecks.hostControlIntro(["let x = compute()"]).passed)
    }

    func testCommandCheckReflectsExitCode() {
        let pass = CommandCheck(name: "build", command: "swift build").evaluate { _ in (0, "ok") }
        XCTAssertTrue(pass.passed); XCTAssertEqual(pass.kind, .deterministic)
        let fail = CommandCheck(name: "tests", command: "swift test").evaluate { _ in (1, "3 failures") }
        XCTAssertFalse(fail.passed); XCTAssertTrue(fail.detail.contains("exited 1"))
    }

    // MARK: guard decision
    private func sealedReceipt(forDiff diff: String, checks: [ReceiptCheck]) -> SealedReceipt {
        let r = VerificationReceipt(
            subject: ReceiptSubject(baseSHA: "b", changedFiles: ["f"], diffDigest: ReceiptSubject.digest(ofDiff: diff)),
            checks: checks, issuedAtEpoch: 1, issuer: "kist/test")
        return ReceiptSeal.seal(r, key: key, keyID: "k1")
    }
    private let goodChecks = [ReceiptCheck(name: "build", kind: .deterministic, passed: true)]

    func testGuardRejectsWhenNoReceiptExists() {
        let d = ReceiptGuard.decide(currentDiff: "+x", key: key, lookup: { _ in nil })
        XCTAssertFalse(d.isAdmitted)
        if case .reject(let why) = d { XCTAssertTrue(why.contains("no verification receipt")) }
    }

    func testGuardAdmitsAValidPassingReceiptForThisDiff() {
        let diff = "+let a = 1"
        let sealed = sealedReceipt(forDiff: diff, checks: goodChecks)
        let d = ReceiptGuard.decide(currentDiff: diff, key: key,
                                    lookup: { $0 == sealed.receipt.subject.diffDigest ? sealed : nil })
        XCTAssertEqual(d, .admit)
    }

    func testGuardRejectsAReceiptMintedForADifferentDiff() {
        // Attacker verifies a benign change, then tries to merge a malicious one under the same receipt file.
        let benign = "+let a = 1"
        let malicious = "+Process().launchPath = \"/usr/bin/osascript\""
        let sealed = sealedReceipt(forDiff: benign, checks: goodChecks)
        // lookup returns the benign receipt for ANY digest (simulating a swapped/renamed receipt file)
        let d = ReceiptGuard.decide(currentDiff: malicious, key: key, lookup: { _ in sealed })
        XCTAssertFalse(d.isAdmitted, "a receipt can't be reused for a change it didn't verify")
    }

    // MARK: store round-trip
    func testStoreSavesAndLoadsByDigest() {
        let root = NSTemporaryDirectory() + "kist_rcpt_\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = ReceiptStore(projectRoot: root)
        let sealed = sealedReceipt(forDiff: "+z", checks: goodChecks)
        XCTAssertTrue(store.save(sealed))
        XCTAssertEqual(store.load(diffDigest: sealed.receipt.subject.diffDigest), sealed)
        XCTAssertNil(store.load(diffDigest: "nonexistent"))
    }
}

/// Pen-test-driven regression: the fixes + the HONEST known limits of the deterministic secret scan.
extension ReceiptChecksAndGuardTests {
    func testContentScanCatchesSecretAnywhereInContent() {
        // The full-content scan (used for binary/whole-file) catches a key embedded mid-content.
        XCTAssertFalse(ReceiptChecks.secretScan(["header\u{0}\u{1}AKIAIOSFODNN7EXAMPLE\u{2}footer"]).passed,
                       "a secret embedded in blob content is caught")
    }
    func testKnownLimit_splitAcrossLinesEvadesScan() {
        // DOCUMENTED boundary: a secret deliberately split across lines evades the line-based regex. The scan is
        // a cheap BACKSTOP; the verification proof (council/human) is the real gate. Pinned so it's not a surprise.
        XCTAssertTrue(ReceiptChecks.secretScan(["let p1 = \"AKIAIOSF\"", "let p2 = \"ODNN7EXAMPLE\""]).passed,
                      "split-across-lines secret is a KNOWN limit of pattern-scanning (see RECEIPT_THREAT_MODEL.md)")
    }

    /// Codex gate: the widened secret shapes the scan used to miss.
    func testWidenedSecretShapesAreCaught() {
        // JSON form — quote sits BEFORE the separator (the old `[=:]` regex missed this).
        XCTAssertFalse(ReceiptChecks.secretScan(["  \"api_key\": \"abcdefghijklmnopqrst1234\""]).passed)
        XCTAssertFalse(ReceiptChecks.secretScan(["let t = \"ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\""]).passed)
        XCTAssertFalse(ReceiptChecks.secretScan(["token = xoxb-1234567890-abcdefghij"]).passed)
        XCTAssertFalse(ReceiptChecks.secretScan(["let k = \"sk-abcdefghijklmnopqrstuvwx\""]).passed)
        XCTAssertFalse(ReceiptChecks.secretScan(["ASIAABCDEFGHIJKLMNOP"]).passed)   // temporary AWS creds
        XCTAssertTrue(ReceiptChecks.secretScan(["let apiKeyLabel = \"Enter your API key below\""]).passed,
                      "prose mentioning 'api key' with no value must NOT false-positive")
    }

    /// Codex gate: the widened host-control tokens.
    func testWidenedHostControlTokensAreCaught() {
        XCTAssertFalse(ReceiptChecks.hostControlIntro(["let s = NSAppleScript(source: src)"]).passed)
        XCTAssertFalse(ReceiptChecks.hostControlIntro(["CGEventCreateKeyboardEvent(nil, 0, true)"]).passed)
        XCTAssertFalse(ReceiptChecks.hostControlIntro(["let img = CGWindowListCreateImage(rect, .optionAll, 0, [])"]).passed)
        XCTAssertFalse(ReceiptChecks.hostControlIntro(["import ScreenCaptureKit"]).passed)
    }
}
