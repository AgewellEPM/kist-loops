import XCTest
@testable import AgentCore

// PROTOTYPE — host_snapshot auth gate. Fail-closed: missing expected secret, missing supplied token, and
// mismatch all reject; only a present matching token authorizes. Constant-time compare asserted.
final class HostSnapshotAuthTests: XCTestCase {

    func testMissingExpectedSecretIsFailClosed() {
        // Even a "supplied" token cannot pass if the host has no configured secret.
        if case .authorized = HostSnapshotAuth.authorize(expected: nil, supplied: "anything") {
            XCTFail("no configured secret must reject")
        }
        if case .authorized = HostSnapshotAuth.authorize(expected: "", supplied: "anything") {
            XCTFail("empty configured secret must reject")
        }
    }

    func testMissingSuppliedTokenIsFailClosed() {
        if case .authorized = HostSnapshotAuth.authorize(expected: "secret", supplied: nil) {
            XCTFail("missing supplied token must reject")
        }
        if case .authorized = HostSnapshotAuth.authorize(expected: "secret", supplied: "") {
            XCTFail("empty supplied token must reject")
        }
    }

    func testWrongTokenIsFailClosed() {
        guard case let .rejected(rej) = HostSnapshotAuth.authorize(expected: "correct-secret", supplied: "wrong") else {
            return XCTFail("wrong token must reject")
        }
        // Neither the guest-facing reason NOR the internal diagnostic may echo either token.
        XCTAssertFalse(rej.guestReason.contains("correct-secret"), "guest reason must never echo the expected token")
        XCTAssertFalse(rej.guestReason.contains("wrong"), "guest reason must never echo the supplied token")
        XCTAssertFalse(rej.internalReason.contains("correct-secret"), "internal reason must never echo the expected token")
        XCTAssertFalse(rej.internalReason.contains("wrong"), "internal reason must never echo the supplied token")
    }

    // AUTH ORACLE (LOW): the GUEST-facing reason is byte-identical across not-configured / missing /
    // mismatch — the untrusted guest cannot distinguish the host's arming state. The internal (STDERR)
    // reason DOES distinguish them for the operator. Named per failure state (multi-site discipline).
    func testGuestFacingReasonIsIdenticalAcrossAllThreeFailureStates() {
        func reason(expected: String?, supplied: String?) -> (guest: String, internalR: String) {
            guard case let .rejected(rej) = HostSnapshotAuth.authorize(expected: expected, supplied: supplied) else {
                XCTFail("must reject"); return ("", "")
            }
            return (rej.guestReason, rej.internalReason)
        }
        let notConfigured = reason(expected: nil, supplied: "x")          // host not armed
        let missing       = reason(expected: "secret", supplied: nil)     // no token presented
        let mismatch      = reason(expected: "secret", supplied: "wrong") // wrong token
        // Guest sees ONE opaque string for all three.
        XCTAssertEqual(notConfigured.guest, HostSnapshotAuth.guestFacingRejection)
        XCTAssertEqual(missing.guest, HostSnapshotAuth.guestFacingRejection)
        XCTAssertEqual(mismatch.guest, HostSnapshotAuth.guestFacingRejection)
        XCTAssertEqual(notConfigured.guest, missing.guest, "not-configured vs missing must be byte-identical to the guest")
        XCTAssertEqual(missing.guest, mismatch.guest, "missing vs mismatch must be byte-identical to the guest")
        // But the operator's internal reasons ARE distinct (diagnostics preserved).
        XCTAssertNotEqual(notConfigured.internalR, missing.internalR)
        XCTAssertNotEqual(missing.internalR, mismatch.internalR)
    }

    // Whitespace-only tokens (expected OR supplied) are treated as empty — never arm, never pass.
    func testWhitespaceOnlyTokenIsRejected() {
        if case .authorized = HostSnapshotAuth.authorize(expected: "   ", supplied: "   ") {
            XCTFail("a whitespace-only expected secret must not arm the boundary")
        }
        if case .authorized = HostSnapshotAuth.authorize(expected: "secret", supplied: "  \t \n") {
            XCTFail("a whitespace-only supplied token must be rejected")
        }
        // suppliedToken() also trims: a whitespace-only flag/env is not a credential.
        XCTAssertNil(HostSnapshotAuth.suppliedToken(flag: "   ", env: [:]))
        XCTAssertNil(HostSnapshotAuth.suppliedToken(flag: nil, env: [HostSnapshotAuth.tokenEnvVar: "  \t"]))
    }

    func testCorrectTokenProceeds() {
        XCTAssertEqual(HostSnapshotAuth.authorize(expected: "s3cr3t-token", supplied: "s3cr3t-token"),
                       .authorized)
    }

    func testSuppliedTokenPrefersExplicitFlagAsCredential() {
        // Explicit flag present ⇒ the flag is the supplied credential (a WRONG flag is thus checkable/
        // rejectable even when an env secret is configured).
        XCTAssertEqual(HostSnapshotAuth.suppliedToken(flag: "flagtok",
                                                      env: [HostSnapshotAuth.tokenEnvVar: "envtok"]), "flagtok")
        // No flag ⇒ fall back to the env value (single-operator convenience).
        XCTAssertEqual(HostSnapshotAuth.suppliedToken(flag: nil,
                                                      env: [HostSnapshotAuth.tokenEnvVar: "envtok"]), "envtok")
        // Neither ⇒ nil (fail-closed downstream).
        XCTAssertNil(HostSnapshotAuth.suppliedToken(flag: nil, env: [:]))
        XCTAssertNil(HostSnapshotAuth.suppliedToken(flag: "", env: [HostSnapshotAuth.tokenEnvVar: ""]))
    }

    // A WRONG explicit --auth-token must be REJECTED even when the host has a (different) env secret armed.
    func testWrongFlagIsRejectedEvenWhenEnvSecretConfigured() {
        let env = [HostSnapshotAuth.tokenEnvVar: "the-real-secret"]
        let supplied = HostSnapshotAuth.suppliedToken(flag: "guessed-wrong", env: env)
        guard case .rejected = HostSnapshotAuth.authorize(expected: env[HostSnapshotAuth.tokenEnvVar], supplied: supplied) else {
            return XCTFail("a wrong explicit flag must be rejected against the configured env secret")
        }
        // And the CORRECT flag against the same secret authorizes.
        let ok = HostSnapshotAuth.suppliedToken(flag: "the-real-secret", env: env)
        XCTAssertEqual(HostSnapshotAuth.authorize(expected: env[HostSnapshotAuth.tokenEnvVar], supplied: ok), .authorized)
    }

    func testConstantTimeEqualsCorrectness() {
        XCTAssertTrue(HostSnapshotAuth.constantTimeEquals("abc123", "abc123"))
        XCTAssertFalse(HostSnapshotAuth.constantTimeEquals("abc123", "abc124"))
        XCTAssertFalse(HostSnapshotAuth.constantTimeEquals("abc", "abcdef"), "length mismatch must be unequal")
        XCTAssertFalse(HostSnapshotAuth.constantTimeEquals("", "x"))
        XCTAssertTrue(HostSnapshotAuth.constantTimeEquals("", ""))
    }
}
