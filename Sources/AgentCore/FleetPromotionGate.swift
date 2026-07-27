import Foundation

/// THE EXTERNAL DEPLOY GATE (integration → main). The internal tier (FleetSignoffLedger + ForgeSeal)
/// proves "the captain verified this on THIS machine" — right for joining branches onto an integration
/// branch. But the captain is the BUILDER, so the FINAL promotion to main composes the EXTERNAL Ed25519
/// tier downstream: an adversarial holder (whose private key Mythos never has) must have SIGNED an
/// approval for THIS exact integration build.
///
/// Deterministic + FAIL CLOSED. Requires BOTH: (a) INTERNAL readiness (the captain produced a non-empty,
/// chain-intact, in-lease integration — supplied as `internallyReady`), AND (b) a VALID EXTERNAL
/// attestation (AttestationVerifier `.valid` against a PINNED key; empty trust set ⇒ refuse all) whose
/// attested buildID BINDS to the integration build (cross-build replay refused) and whose
/// (approverKeyID, nonce) is UNCONSUMED (same-approval replay refused).
///
/// THE GATE NEVER WRITES main. It returns GO/NO-GO; the actual main-write is a deliberate human/deploy
/// step that CONSULTS this verdict. Unforgeability is inherited from VerifiedApproval (only mintable on a
/// passed signature). Ported from TinkySDR's Captain (Stage 3); CryptoKit → MythosCrypto. PROTOTYPE.
public struct FleetPromotionDecision: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case promote(buildID: String)     // internally ready AND externally attested for THIS build
        case refuse(reason: String)       // any gate failed — fail closed
    }
    public let verdict: Verdict
    public init(verdict: Verdict) { self.verdict = verdict }

    public var promotable: Bool { if case .promote = verdict { return true }; return false }
    public var refusalReason: String? { if case let .refuse(r) = verdict { return r }; return nil }
}

public enum FleetPromotionGate {

    /// Decide whether `integrationBuildID` may be promoted to main. FAIL CLOSED at every gate; performs NO
    /// git/main write.
    ///
    /// ⚠️ WIRING CONSTRAINT: `integrationBuildID` MUST come from a TRUSTED integration record (the
    /// integration branch HEAD SHA the system reads, or a sealed manifest's build id) — NEVER a
    /// user-controlled string. The gate compares it to the attested buildID but cannot vouch for its
    /// provenance; a caller that lets an attacker set it could match a stale valid attestation.
    ///
    /// `consumedApprovals` are the `replayKey(for:)`s of approvals ALREADY used to promote. NO default:
    /// replay protection is OPT-IN by construction so a call site can't silently forget it (pass `[]`
    /// explicitly for the first promotion, then persist + accumulate).
    public static func decide(integrationBuildID: String,
                              internallyReady: Bool,
                              attestation: SignedApproval?,
                              verifier: AttestationVerifier,
                              consumedApprovals: Set<String>) -> FleetPromotionDecision {
        // Gate A — internal readiness (the captain actually built something mergeable).
        guard internallyReady else {
            return .init(verdict: .refuse(reason:
                "integration not internally ready — no chain-intact, in-lease signoffs to promote"))
        }
        // Gate B — an external attestation must exist at all.
        guard let signed = attestation else {
            return .init(verdict: .refuse(reason:
                "no external attestation supplied — promotion to main requires a signed approval"))
        }
        // Gate C — the attestation's Ed25519 signature must verify against a PINNED key (fail closed).
        switch verifier.verify(signed) {
        case .unknownKey:
            return .init(verdict: .refuse(reason:
                "attestation signed by an unpinned key “\(signed.approval.approverKeyID)” (fail closed)"))
        case .malformed:
            return .init(verdict: .refuse(reason: "attestation signature is malformed (bad base64)"))
        case .badSignature:
            return .init(verdict: .refuse(reason:
                "attestation signature did not verify — wrong key or tampered payload"))
        case .valid(let verified):
            let approval = verified.signed.approval
            // Gate D — BIND the attestation to THIS build (an approval minted for a different build must
            // never promote this integration — cross-build replay).
            guard approval.buildID == integrationBuildID else {
                return .init(verdict: .refuse(reason:
                    "attestation is for build “\(approval.buildID)”, not the integration build “\(integrationBuildID)”"))
            }
            // Gate E — REPLAY: an approval whose (approverKeyID, nonce) was already used to promote can't
            // be re-presented (both are in the signed payload, so neither can be swapped).
            guard !consumedApprovals.contains(Self.replayKey(for: approval)) else {
                return .init(verdict: .refuse(reason:
                    "attestation already consumed — this approval was already used to promote (replay)"))
            }
            return .init(verdict: .promote(buildID: integrationBuildID))
        }
    }

    /// The source-scoped replay key for an approval: `(approverKeyID, nonce)`. The caller records this for
    /// every promoted approval and passes the accumulated set back via `consumedApprovals`. Source-scoped
    /// so two attesters can't collide on an identical nonce string; the NUL separator can't appear in a
    /// keyID/nonce, so the join is injective.
    public static func replayKey(for approval: PromotionApproval) -> String {
        approval.approverKeyID + "\u{0}" + approval.nonce
    }
}
