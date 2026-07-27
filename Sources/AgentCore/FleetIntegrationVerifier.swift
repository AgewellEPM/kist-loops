import Foundation

/// Phase B — the COMBINED-TREE regression gate.
///
/// Each fleet agent's signoff verifies its branch IN ISOLATION; no per-agent signoff ever sees what
/// happens when all the signed branches are MERGED TOGETHER. A change that is green alone can break a
/// sibling's behavior on the integration branch (a shared symbol renamed, a contract two agents both
/// touched, an import that now collides). After the supervisor joins the signed in-lease branches onto a
/// FRESH integration branch, this runs the FULL suite on that COMBINED tree:
///
///   GREEN     ⇒ `.ready`                 — the merged result actually passes
///   non-zero  ⇒ `.regressed(exitCode:)`  — a cross-agent regression the isolated signoffs could not see
///   no runner ⇒ `.unavailable(reason:)`  — ABSTAIN; NEVER reports a false green when it couldn't measure
///
/// REPORT-ONLY: it never promotes anything (promotion stays a human action — Mythos never writes main).
/// Pure decision over an INJECTED test runner (default = `./test.sh` on the combined worktree).
public enum FleetIntegrationVerdict: Equatable, Sendable {
    case ready
    case regressed(exitCode: Int32)
    case unavailable(String)

    public var isReady: Bool { if case .ready = self { return true }; return false }

    /// One human-facing line for the supervisor summary / cockpit.
    public var summary: String {
        switch self {
        case .ready:
            return "integration suite GREEN on the combined tree — the merged result passes"
        case .regressed(let code):
            return "integration suite FAILED (exit \(code)) on the COMBINED tree — a cross-agent regression "
                 + "no isolated per-agent signoff could see; do NOT promote until it's fixed"
        case .unavailable(let why):
            return "integration suite NOT run (\(why)) — verify the combined tree manually before promoting"
        }
    }
}

public struct FleetIntegrationVerifier: Sendable {
    private let runTests: @Sendable (_ worktreePath: String) async -> Int32?

    /// `runTests` returns the suite's exit code (0 = pass) or nil = couldn't launch ⇒ `.unavailable`.
    /// Default runs `./test.sh` on the combined worktree.
    public init(runTests: (@Sendable (String) async -> Int32?)? = nil) {
        self.runTests = runTests ?? { path in await FleetIntegrationVerifier.realRunTests(path) }
    }

    /// Run the full suite on the COMBINED integration tree and classify the result. A non-runnable suite
    /// is `.unavailable` (abstain) — it is NEVER coerced to `.ready`, so an un-measured combined tree can
    /// never be reported as green.
    public func verify(worktreePath: String) async -> FleetIntegrationVerdict {
        guard let exit = await runTests(worktreePath) else {
            return .unavailable("no runnable test.sh at \(worktreePath)")
        }
        return exit == 0 ? .ready : .regressed(exitCode: exit)
    }

    /// Run `./test.sh` on the combined tree OFF the main actor. Output is discarded instead of captured:
    /// chatty suites cannot fill a pipe, and a background child that inherits stdout/stderr cannot keep the
    /// verifier blocked after the test runner exits. nil ⇒ couldn't launch (caller maps to `.unavailable`,
    /// never a silent green).
    static func realRunTests(_ worktreePath: String) async -> Int32? {
        let script = (worktreePath as NSString).appendingPathComponent("test.sh")
        guard FileManager.default.fileExists(atPath: script) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Int32?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let out = FileHandle(forWritingAtPath: "/dev/null"),
                      let err = FileHandle(forWritingAtPath: "/dev/null") else {
                    cont.resume(returning: nil); return
                }
                defer { out.closeFile(); err.closeFile() }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = [script]
                p.currentDirectoryURL = URL(fileURLWithPath: worktreePath)
                p.standardOutput = out; p.standardError = err
                do {
                    try p.run()
                } catch {
                    cont.resume(returning: nil); return
                }
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus)
            }
        }
    }
}
