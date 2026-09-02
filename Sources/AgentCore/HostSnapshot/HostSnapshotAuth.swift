import Foundation

// PROTOTYPE — host_snapshot auth gate (SECURITY BOUNDARY). Fail-closed: the ONLY way past this gate is a
// present, non-whitespace token that matches the expected secret in constant time. Absent expected secret,
// absent supplied token, whitespace-only token, or mismatch → REJECTED, and the caller MUST capture zero
// bytes. Every rejection returns ONE opaque guest-facing reason ("authorization failed") so the untrusted
// guest can't distinguish arming states; the specific cause is operator-only (STDERR).

public enum HostSnapshotAuth {

    /// The SINGLE guest-facing rejection reason. Distinct causes (not-configured / missing / mismatch) all
    /// collapse to this one opaque string so the untrusted guest cannot probe the host's arming state (e.g.
    /// distinguish "no token set" from "wrong token"). The specific cause is available to the operator via
    /// `Rejection.internalReason` (logged to STDERR only), never in the guest-facing JSON.
    public static let guestFacingRejection = "authorization failed"

    /// A rejection carries BOTH the opaque guest-facing reason (goes into the JSON error line the guest
    /// sees) AND the specific internal reason (operator diagnostics, STDERR only).
    public struct Rejection: Sendable, Equatable {
        public let guestReason: String     // ALWAYS guestFacingRejection — the only thing the guest is told
        public let internalReason: String  // the specific cause, for the operator's STDERR log
        public init(internalReason: String) {
            self.guestReason = HostSnapshotAuth.guestFacingRejection
            self.internalReason = internalReason
        }
    }

    public enum Decision: Sendable, Equatable {
        case authorized
        case rejected(Rejection)
    }

    /// Env var the expected token is read from. Preferred over --auth-token so the secret is never in a
    /// process argv another user could read via `ps`.
    public static let tokenEnvVar = "KIST_HOST_SNAPSHOT_TOKEN"

    /// Resolve the SUPPLIED credential this invocation presents. Prefer the EXPLICIT `--auth-token` flag
    /// (so a WRONG flag is genuinely rejected even when the host has an env secret configured — the flag is
    /// a real, checkable credential, not a no-op alias), and fall back to the env var when no flag is given
    /// (single-operator convenience: exporting the secret and invoking is itself the authorization).
    ///
    /// The EXPECTED secret is always the env var (see `authorize`), so the boundary only exists once the
    /// host has armed it via `KIST_HOST_SNAPSHOT_TOKEN`. Injected `env` so this is unit-testable without
    /// mutating the real environment.
    public static func suppliedToken(flag: String?, env: [String: String]) -> String? {
        if let f = flag, !f.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return f }
        if let e = env[tokenEnvVar], !e.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return e }
        return nil
    }

    /// Fail-closed authorization. `expected` is the ground-truth secret (this host's configured token);
    /// `supplied` is what the caller presented. Both must be present, non-empty, and equal under a
    /// constant-time compare. Any missing piece is a rejection — NEVER a silent pass.
    ///
    /// The token is never logged and never placed in ANY reason. A whitespace-only token (expected OR
    /// supplied) is treated as empty — trimmed before the empty check, so "   " never arms the boundary or
    /// passes as a credential. The guest only ever learns `guestFacingRejection`; the specific cause is the
    /// Rejection's internalReason (operator STDERR only).
    public static func authorize(expected: String?, supplied: String?) -> Decision {
        guard let expected, !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(Rejection(internalReason: "host snapshot token not configured (set KIST_HOST_SNAPSHOT_TOKEN)"))
        }
        guard let supplied, !supplied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(Rejection(internalReason: "missing auth token"))
        }
        guard constantTimeEquals(expected, supplied) else {
            return .rejected(Rejection(internalReason: "auth token mismatch"))
        }
        return .authorized
    }

    /// Constant-time string equality that does NOT leak length or content via early exit. We HMAC both
    /// strings under a fresh per-call random key and compare the fixed-width tags: the comparison time is
    /// independent of where (or whether) the inputs diverge, and unequal-length inputs produce unequal
    /// tags without a length-based short-circuit. (swift-crypto's HMAC verify is itself constant-time.)
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let key = MythosCrypto.randomKey()
        let tagA = MythosCrypto.hmacSHA256(key: key, message: Data(a.utf8))
        return MythosCrypto.hmacSHA256Valid(key: key, message: Data(b.utf8), tag: tagA)
    }
}
