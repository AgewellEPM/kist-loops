import Foundation

/// Verify-before-done: the trust spine applied to the completion signal. The most corrosive agent failure
/// is "it said it was done but wasn't" — it edited code, never compiled or tested it, and claimed success.
///
/// This deterministic gate refuses that: if the run MUTATED code (edit/write/patch/move) but ran NO
/// SUCCESSFUL build/test command AFTER the last mutation, a "done" claim is UNVERIFIED, and the loop steers
/// the model to actually verify before finishing (nudged once, so it can't loop forever). It reuses the
/// trajectory the loop already records — grounded in what the agent actually DID, not what it claims.
public struct CompletionVerifier: Sendable {
    /// Actions that change code and therefore create something that must be verified.
    public static let mutatingTools: Set<String> = ["write_file", "edit_file", "apply_patch", "move_file"]
    /// Where a build/test actually happens. If shell is off, we can't require this (see `canRunCommands`).
    public static let verifyingTools: Set<String> = ["run_command"]

    public enum Verdict: Sendable, Equatable {
        case accept
        case needsVerification(reason: String)
        public var isAccept: Bool { if case .accept = self { return true }; return false }
    }

    public init() {}

    /// Non-source files whose edit needs NO build/test — docs, config, data, lockfiles. Editing a
    /// README or a YAML config is a legitimate deliverable; demanding a build/test for it is an
    /// over-block (R7 review catch: the hardened done-gate was failing doc/config-only turns). The
    /// extension is read from the mutation's `path=`/`file=` fingerprint; an UNKNOWN path stays
    /// build-requiring (conservative — never launders a source change as done).
    static let nonSourceExtensions: Set<String> = [
        "md", "markdown", "mdx", "rst", "adoc", "org", "txt", "text",
        "json", "yaml", "yml", "toml", "cfg", "conf", "ini", "env", "properties", "plist",
        "lock", "csv", "tsv", "log", "gitignore", "gitattributes", "editorconfig", "dockerignore", "license",
    ]

    /// A mutation that REQUIRES a build/test: a mutating tool whose target is source code (or whose
    /// path we can't read — fail strict). A clearly-non-source edit (docs/config) does not.
    static func mutationNeedsBuild(_ r: ActionRecord) -> Bool {
        guard mutatingTools.contains(r.tool) else { return false }
        guard let ext = pathExtension(fromFingerprint: r.argsFingerprint) else { return true }   // unknown ⇒ strict
        return !nonSourceExtensions.contains(ext)
    }

    /// Extract the lowercased file extension from a record's `path=`/`file=` fingerprint field, or nil
    /// when no path is present (⇒ caller stays strict). "" when the path has no extension.
    static func pathExtension(fromFingerprint fp: String) -> String? {
        for field in fp.split(separator: "&") {
            let kv = field.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, kv[0] == "path" || kv[0] == "file" else { continue }
            let path = String(kv[1])
            guard let dot = path.lastIndex(of: "."), path.index(after: dot) < path.endIndex else { return "" }
            return path[path.index(after: dot)...].lowercased()
        }
        return nil
    }

    public func check(trajectory: [ActionRecord], canRunCommands: Bool) -> Verdict {
        // Can't run a build/test (shell off) ⇒ don't block on something the agent can't do.
        guard canRunCommands else { return .accept }
        // No SOURCE-CODE change ⇒ nothing to verify (research/read-only, or only docs/config touched).
        guard let lastMutation = trajectory.lastIndex(where: { Self.mutationNeedsBuild($0) }) else {
            return .accept
        }
        // Was there a SUCCESSFUL build/test AFTER the last code change? TEETH: a bare successful
        // run_command is NOT enough — `ls`/`echo`/`cat` "passing" proves nothing. The command must
        // actually be a build / test / typecheck / lint (classified from its fingerprint).
        let after = trajectory[(lastMutation + 1)...]
        let verified = after.contains {
            Self.verifyingTools.contains($0.tool) && $0.success && CommandClassifier.isBuildOrTest($0.argsFingerprint)
        }
        if verified { return .accept }
        // Distinguish "ran nothing" from "ran a non-verifying command" so the steer is honest.
        let ranSomething = after.contains { Self.verifyingTools.contains($0.tool) && $0.success }
        let reason = ranSomething
            ? "you changed code and ran a command, but it wasn't a build/test — a passing build or test must confirm the change before this is done"
            : "you changed code but ran no build/test after the last edit — a build/test must pass before this is done"
        return .needsVerification(reason: reason)
    }

    /// The steer injected when a "done" is unverified.
    public static func steering(reason: String) -> String {
        """
        Not done yet: \(reason).
        Run the project's REAL build and/or test command now (run_command) — e.g. `swift build` / `swift test`,
        `npm test`, `pytest`, `cargo test`, `go test`, `make`. A trivial command like `ls` or `echo` does NOT
        count. If it passes, THEN finish and say exactly what you ran. If it fails, fix it and re-run. Do not
        claim completion on unverified code changes.
        """
    }
}

/// Classifies whether a shell command actually VERIFIES a code change — a build, test, typecheck, or lint —
/// versus a trivial command that proves nothing. Pure; matches on the leading verb, tolerant of the
/// `command=` prefix the trajectory fingerprint carries and of a `cd … &&` preamble.
public enum CommandClassifier {
    static let signals: [String] = [
        "swift build", "swift test", "xcodebuild", "npm test", "npm run build", "yarn test", "yarn build",
        "pnpm test", "pnpm build", "pytest", "unittest", "go test", "go build", "cargo test", "cargo build",
        "cargo check", "cargo clippy", "clippy", "make test", "make build", "make check", "make ", "gradle",
        "mvn test", "mvn ", "dotnet test", "dotnet build", "tsc", "jest", "vitest", "rspec", "phpunit",
        "ctest", "cmake --build", "bazel test", "bazel build", "ruby -c", "node --check", "eslint", "ruff",
        "mypy", "flake8", "rubocop", "pre-commit", "tox",
    ]
    /// Bare-verb commands that verify on their own (run with no args): `make`, `tsc`, `pytest`, …
    static let bareVerbs: Set<String> = [
        "make", "gradle", "tsc", "jest", "vitest", "pytest", "rspec", "phpunit", "ctest", "mypy", "ruff",
        "eslint", "tox", "rubocop", "xcodebuild", "clippy", "flake8", "gcc", "clang", "g++", "cargo",
    ]

    public static func isBuildOrTest(_ text: String) -> Bool {
        var s = text.lowercased()
        if let r = s.range(of: "command=") { s = String(s[r.upperBound...]) }   // strip trajectory prefix
        // STRUCTURED run_command fingerprint form: `args=["test"]&cwd=…&executable=swift`. The safe-promotion
        // path and the cwd param steer models toward executable+args, whose fingerprint SEPARATES the verb
        // from its args — so a genuine `swift test` wouldn't match the contiguous signals below and a real
        // passing build/test would be wrongly rejected by the done-gate. Reconstruct "<executable> <args>"
        // (stripping JSON-array punctuation) so structured invocations match exactly like raw ones.
        if s.contains("executable=") {
            let exe = fingerprintValue("executable", in: s)
            let args = fingerprintValue("args", in: s)
                .replacingOccurrences(of: "[", with: " ").replacingOccurrences(of: "]", with: " ")
                .replacingOccurrences(of: "\"", with: " ").replacingOccurrences(of: ",", with: " ")
            let rebuilt = (exe + " " + args).split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            if !rebuilt.isEmpty { s = rebuilt }
        }
        if signals.contains(where: { s.contains($0) }) { return true }
        // A command that IS just a build verb (no args): match the first token exactly.
        let first = s.split(whereSeparator: { " \t&;|\n".contains($0) }).first.map(String.init) ?? ""
        return bareVerbs.contains(first)
    }

    /// Pull a value for `key` out of a `k1=v1&k2=v2` trajectory fingerprint (empty if absent).
    static func fingerprintValue(_ key: String, in fingerprint: String) -> String {
        for part in fingerprint.split(separator: "&") where part.hasPrefix(key + "=") {
            return String(part.dropFirst(key.count + 1))
        }
        return ""
    }
}
