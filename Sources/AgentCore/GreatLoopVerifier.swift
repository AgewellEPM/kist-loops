import Foundation

/// Phase 0 — the anti-Goodhart done-gate for the great-loop. Research is blunt: the central failure of a
/// self-improving loop is optimizing a proxy — DGM faked test logs; shipping Claude Code and Codex both
/// reward-hacked by editing/deleting test files. So a long-horizon cycle's "done" must NOT be the model's
/// say-so: it must bottom out in EXECUTION and be un-gameable.
///
/// This composes two existing, deterministic guards over a cycle's evidence:
///   1. `CIIntegrityGuard` — did the diff GAME the verifier (deleted a test, XCTSkip, `.only`, `|| true`,
///      harness mutation)? Any finding is a HARD block, regardless of a green result.
///   2. `CompletionVerifier` — is it execution-grounded? Code changed ⇒ a real build/test must have PASSED
///      after the last edit (not `ls`; the command classifier already enforces "real build/test").
///
/// Pure over the cycle's evidence — no shell, no clocks — so the policy is unit-tested deterministically.
public enum GreatLoopVerifier {
    public enum Verdict: Equatable, Sendable {
        case verified
        case unverified(reason: String)     // no real build/test passed after edits
        case gamed(findings: [String])      // verifier-gaming detected — HARD block
        public var isVerified: Bool { if case .verified = self { return true }; return false }
        public var reason: String {
            switch self {
            case .verified: return "verified"
            case .unverified(let r): return r
            case .gamed(let f): return "verifier-gaming blocked — " + f.joined(separator: " · ")
            }
        }
    }

    public static func verify(trajectory: [ActionRecord], canRunCommands: Bool,
                              changedFiles: [String], diff: String) -> Verdict {
        // Anti-Goodhart FIRST: a gamed diff blocks done even if everything is green.
        let findings = CIIntegrityGuard.inspect(committedFiles: changedFiles, committedDiff: diff)
        if !findings.isEmpty {
            return .gamed(findings: findings.map { "\($0.kind): \($0.detail)" })
        }
        // Execution-grounded: code changed ⇒ a real build/test must have passed after the last edit.
        if case .needsVerification(let why) = CompletionVerifier()
            .check(trajectory: trajectory, canRunCommands: canRunCommands) {
            return .unverified(reason: why)
        }
        return .verified
    }
}
