import Foundation
import AgentCore
#if os(macOS)
import Security
import Darwin
#endif

/// Resolves the identity of a process connected to the broker socket into a `DesktopPeer` for BrokerCore's
/// auth gates. "The socket path is not auth" — so we (1) read the peer's uid, and (2) verify its code
/// signature against a PINNED requirement (confused-deputy defense: only the real `kist` may drive us).
///
/// Dev mode (unsigned binaries, no code-signing identity available) can't satisfy a real requirement, so a
/// `--dev-trust-same-uid` flag trusts same-uid peers WITH A LOUD WARNING. Production ships signed + pinned.
struct PeerAuthenticator {
    /// The pinned client code requirement (production). e.g. `identifier "com.kist.cli" and anchor apple generic`.
    let requirement: String?
    /// Dev escape hatch — NEVER a production default.
    let devTrustSameUID: Bool

    func resolve(fd: Int32) -> DesktopPeer {
        #if os(macOS)
        var uid: uid_t = 0, gid: gid_t = 0
        let uidOK = getpeereid(fd, &uid, &gid) == 0
        let selfUID = getuid()
        guard uidOK else {
            return DesktopPeer(uid: 0, authenticated: false, describedBy: "peer-uid-unavailable")
        }
        // A pinned requirement is AUTHORITATIVE: verify the peer's code signature against it via the audit
        // token. A check we could NOT even perform (nil — token/SecCode API failure) is a DENY, and NEVER a
        // fall-through to dev-trust (fix: a SecCode failure under a pinned requirement must not authenticate).
        if let requirement {
            guard let (satisfies, desc) = Self.verifySignature(fd: fd, requirement: requirement) else {
                return DesktopPeer(uid: uid, authenticated: false, describedBy: "signature-check-unavailable(deny)")
            }
            let ok = satisfies && uid == selfUID
            // Describe honestly: a valid signature that fails the uid gate is NOT "requirement-satisfied".
            let why = ok ? desc : (satisfies ? "uid-mismatch(\(uid)!=\(selfUID))" : desc)
            return DesktopPeer(uid: uid, authenticated: ok, describedBy: why)
        }
        // DEV-ONLY escape hatch, COMPILED OUT of release builds so a runtime flag can never ship an
        // auth-bypass (kist-review): trust same-uid without any code check. Never a production control.
        #if DEBUG
        if devTrustSameUID {
            return DesktopPeer(uid: uid, authenticated: uid == selfUID, describedBy: "dev-trust-same-uid(unsigned)")
        }
        #endif
        return DesktopPeer(uid: uid, authenticated: false, describedBy: "no-requirement(deny)")
        #else
        return DesktopPeer(uid: 0, authenticated: false, describedBy: "unsupported-platform")
        #endif
    }

    #if os(macOS)
    /// Returns (satisfiesRequirement, description) or nil if the peer audit token / SecCode couldn't be built.
    static func verifySignature(fd: Int32, requirement: String) -> (Bool, String)? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        let rc = withUnsafeMutablePointer(to: &token) { p in
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, p, &size)
        }
        // Reject a partial/truncated token — the kernel must have written the FULL audit_token_t, else the
        // token is partly uninitialized and must not be trusted for a SecCode guest lookup (kist-review).
        guard rc == 0, Int(size) == MemoryLayout<audit_token_t>.size else { return nil }
        let tokenData = withUnsafeBytes(of: token) { Data($0) } as CFData
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return nil }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return nil }
        // Stricter validation direction (fail-safe: stricter can only DENY more, never authenticate more) —
        // kist-review flagged empty flags. Verify on signed hardware that legit clients still pass.
        let status = SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), req)
        return (status == errSecSuccess, status == errSecSuccess ? "requirement-satisfied" : "requirement-failed(\(status))")
    }
    #endif
}
