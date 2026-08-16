import XCTest
@testable import AgentCore

/// Regression pin for Codex finding P1-D: on macOS, `LAContext.interactionNotAllowed` alone does NOT
/// suppress the legacy ACL login-password dialog for GUI-created / old-signature Keychain items — the
/// base code paired it with `kSecUseAuthenticationUIFail` so those value-bearing reads/updates fail
/// closed (errSecInteractionNotAllowed) instead of blocking on a dialog after an ad-hoc rebuild.
///
/// Real Keychain I/O is not unit-testable (no ACL fixtures, no headless dialog), so this asserts the
/// invariant at the SOURCE level. Multi-site discipline: the UI-fail option must be present at BOTH the
/// read site (`keychainRecord`, which carries `kSecReturnData`) and the update site
/// (`synchronizeKeychain`, which calls `SecItemUpdate`). Each site has its own named assertion so a
/// failure tells you exactly which one regressed.
final class KeyStoreLegacyKeychainTests: XCTestCase {

    /// Resolve KeyStore.swift relative to THIS test file so the assertion is CWD-independent.
    /// Tests/AgentCoreTests/KeyStoreLegacyKeychainTests.swift → ../../Sources/AgentCore/KeyStore.swift
    private func keyStoreSource(file: StaticString = #filePath) throws -> String {
        let testsDir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()   // Tests/AgentCoreTests
        let repoRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent() // repo root
        let src = repoRoot.appendingPathComponent("Sources/AgentCore/KeyStore.swift")
        return try String(contentsOf: src, encoding: .utf8)
    }

    /// Isolate the body of a `private func` so a per-site assertion cannot be satisfied by an unrelated
    /// site elsewhere in the file. Returns the substring from the function signature to the matching
    /// closing brace (brace-balanced), or nil if the function is absent.
    private func functionBody(named name: String, in source: String) -> String? {
        guard let sigRange = source.range(of: "func \(name)(") else { return nil }
        // Find the opening brace of the body after the signature.
        guard let openBrace = source.range(of: "{", range: sigRange.upperBound..<source.endIndex) else { return nil }
        var depth = 0
        var idx = openBrace.lowerBound
        while idx < source.endIndex {
            let ch = source[idx]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[openBrace.lowerBound...idx])
                }
            }
            idx = source.index(after: idx)
        }
        return nil
    }

    /// The exact legacy-ACL backstop we require. Matching the literal `kSecUseAuthenticationUIFail`
    /// pinned to `kSecUseAuthenticationUI` is enough — that is the option the base code paired with the
    /// noninteractive context, and the only one that turns the legacy dialog into a fail-closed error.
    private let uiFailPattern = "kSecUseAuthenticationUI"
    private let uiFailValue = "kSecUseAuthenticationUIFail"

    /// The backstop is applied via a shared helper `applyLegacyUIFail(to:)`, so each SITE asserts it
    /// invokes that helper (the call is what wires the fail-closed option in), and a separate test below
    /// pins that the helper actually sets the UI-fail option. Together this keeps the per-site discipline
    /// even though the literal lives in one place (DRY): a site that stops calling the helper fails here.
    private let uiFailCall = "applyLegacyUIFail("

    func testReadSiteFailsClosedOnLegacyACL() throws {
        let source = try keyStoreSource()
        // The value-bearing read that decrypts the secret; without UI-fail a legacy item would prompt.
        guard let body = functionBody(named: "keychainRecord", in: source) else {
            return XCTFail("read site keychainRecord(forAccount:staleMetadataFloor:) not found in KeyStore.swift")
        }
        XCTAssertTrue(body.contains(uiFailCall),
                      "READ site (keychainRecord) must call applyLegacyUIFail(&query) so a GUI-created / "
                    + "old-signature Keychain item fails closed instead of popping the ACL dialog.")
    }

    func testUpdateSiteFailsClosedOnLegacyACL() throws {
        let source = try keyStoreSource()
        // The SecItemUpdate path that stamps metadata / rotates the value; same legacy-ACL hazard.
        guard let body = functionBody(named: "synchronizeKeychain", in: source) else {
            return XCTFail("update site synchronizeKeychain(_:account:includeValue:) not found in KeyStore.swift")
        }
        XCTAssertTrue(body.contains(uiFailCall),
                      "UPDATE site (synchronizeKeychain) must call applyLegacyUIFail(&query) so a legacy "
                    + "Keychain item's SecItemUpdate fails closed instead of blocking on the ACL dialog.")
    }

    /// The helper both sites call must actually pin the UI-fail option — if it stops setting
    /// `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail`, the per-site calls become no-ops.
    func testLegacyUIFailHelperSetsFailClosedOption() throws {
        let source = try keyStoreSource()
        guard let body = functionBody(named: "applyLegacyUIFail", in: source) else {
            return XCTFail("helper applyLegacyUIFail(to:) not found in KeyStore.swift")
        }
        XCTAssertTrue(body.contains(uiFailPattern) && body.contains(uiFailValue),
                      "applyLegacyUIFail must set kSecUseAuthenticationUI = kSecUseAuthenticationUIFail "
                    + "(the only option that turns the legacy ACL dialog into a fail-closed error).")
    }

    /// Defense-in-depth: the noninteractive context is necessary but NOT sufficient on its own for legacy
    /// items — the finding is precisely that pairing. Pin that the context binding is still present too, so
    /// a future edit can't "fix" one half by deleting the other.
    func testNoninteractiveContextStillBoundAtBothSites() throws {
        let source = try keyStoreSource()
        for site in ["keychainRecord", "synchronizeKeychain"] {
            guard let body = functionBody(named: site, in: source) else {
                XCTFail("site \(site) not found in KeyStore.swift"); continue
            }
            XCTAssertTrue(body.contains("applyNoninteractiveAuthentication"),
                          "\(site) must still bind the noninteractive LAContext (paired with UI-fail, not replaced by it).")
        }
    }
}
