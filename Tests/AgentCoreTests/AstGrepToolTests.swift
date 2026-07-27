import XCTest
@testable import AgentCore

/// ast-grep integration. Tests cover the DETERMINISTIC surface (argv construction,
/// path confinement, graceful binary-absence, tool registration). A live end-to-end
/// rewrite requires the ast-grep binary and is verified separately when installed.
final class AstGrepToolTests: XCTestCase {

    private var root: String!
    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "astgrep-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
    }
    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }
    private func ctx(shell: ShellPolicy = .denied) -> ToolContext { ToolContext(projectRoot: root, shell: shell) }

    // MARK: - pure argv builder

    func testSearchArgsHaveNoRewriteNoUpdate() {
        let args = AstGrep.runArgs(pattern: "foo($A)", rewrite: nil, lang: "swift", relPath: ".", apply: false)
        XCTAssertEqual(args, ["run", "--color", "never", "--pattern", "foo($A)", "--lang", "swift", "--", "."])
        XCTAssertFalse(args.contains("--update-all"))
        XCTAssertFalse(args.contains("--rewrite"))
    }

    func testPreviewArgsHaveRewriteButNotUpdate() {
        let args = AstGrep.runArgs(pattern: "print($A)", rewrite: "log($A)", lang: nil, relPath: "src", apply: false)
        XCTAssertTrue(args.contains("--rewrite"))
        XCTAssertTrue(args.contains("log($A)"))
        XCTAssertFalse(args.contains("--update-all"), "preview must never write")
        XCTAssertFalse(args.contains("--lang"), "lang omitted → no -l flag")
    }

    func testApplyArgsIncludeUpdateAll() {
        let args = AstGrep.runArgs(pattern: "a", rewrite: "b", lang: "ts", relPath: ".", apply: true)
        XCTAssertTrue(args.contains("--update-all"))
        // `--` must precede the path so a hostile pattern/path can't be read as a flag.
        let dd = args.firstIndex(of: "--")!
        XCTAssertEqual(args[dd + 1], ".")
    }

    // MARK: - confinement (independent of the binary)

    func testSearchRejectsPathEscape() async throws {
        do {
            _ = try await AstGrepTool().execute(arguments: ["pattern": "x", "path": "../escape"], context: ctx())
            XCTFail("expected pathEscape")
        } catch let e as ToolError {
            guard case .pathEscape = e else { return XCTFail("expected pathEscape, got \(e)") }
        }
    }

    func testApplyRejectsPathEscape() async throws {
        do {
            _ = try await AstGrepApplyTool().execute(
                arguments: ["pattern": "x", "rewrite": "y", "path": "../escape"],
                context: ctx(shell: ShellPolicy(enabled: true, autoApprove: true)))
            XCTFail("expected pathEscape")
        } catch let e as ToolError {
            guard case .pathEscape = e else { return XCTFail("expected pathEscape, got \(e)") }
        }
    }

    // MARK: - shell gate on the mutating tool

    func testApplyRefusedWhenShellDisabled() async throws {
        // With no binary this may hit the install hint first; both are failures, but when a
        // binary IS present the shell gate must refuse. Assert failure either way, and when
        // ast-grep is installed assert the reason is the shell gate.
        let r = try await AstGrepApplyTool().execute(
            arguments: ["pattern": "a", "rewrite": "b"], context: ctx(shell: .denied))
        XCTAssertFalse(r.success)
        if AstGrep.binaryPath() != nil {
            XCTAssertEqual(r.error?.contains("shell is disabled"), true, "mutating apply must be shell-gated")
        }
    }

    // MARK: - symlink-escape confinement (Codex HIGH #1)

    func testSearchRefusesSymlinkEscape() async throws {
        // A repo-contained symlink pointing OUTSIDE the root must be refused, not scanned.
        let outside = NSTemporaryDirectory() + "astgrep-outside-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: outside)
        do {
            _ = try await AstGrepTool().execute(arguments: ["pattern": "x", "path": "link"], context: ctx())
            XCTFail("expected pathEscape for out-of-root symlink")
        } catch let e as ToolError {
            guard case .pathEscape = e else { return XCTFail("expected pathEscape, got \(e)") }
        }
    }

    func testInRootSymlinkAllowed() throws {
        // A symlink that stays INSIDE the root is fine.
        try FileManager.default.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/inlink", withDestinationPath: root + "/sub")
        XCTAssertNoThrow(try AstGrep.assertConfined(relPath: "inlink", rootPath: root))
    }

    func testBinaryResolutionDoesNotUsePATH() {
        // Hardened resolver only consults fixed standard dirs — never $PATH (Codex HIGH #2).
        XCTAssertEqual(AstGrep.binaryDirs, ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
    }

    // MARK: - graceful absence

    func testGracefulWhenBinaryMissing() async throws {
        guard AstGrep.binaryPath() == nil else {
            throw XCTSkip("ast-grep is installed; absence path not exercised")
        }
        let r = try await AstGrepTool().execute(arguments: ["pattern": "foo($A)"], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.error?.contains("ast-grep"), true, "must return a clear install hint, not crash")
    }

    // MARK: - registration

    func testBothToolsRegisteredInHeadless() {
        let names = Set(ToolRegistry.headless().all().map { $0.name })
        XCTAssertTrue(names.contains("ast_grep"))
        XCTAssertTrue(names.contains("ast_grep_apply"))
    }

    // MARK: - live end-to-end (requires the ast-grep binary)

    private func writeFixture() throws {
        let src = "const x = orderBy({ createdAt: asc });\nconst y = orderBy({ createdAt: asc });\n"
        try src.write(toFile: root + "/a.ts", atomically: true, encoding: .utf8)
    }
    private func fixture() -> String { (try? String(contentsOfFile: root + "/a.ts", encoding: .utf8)) ?? "" }

    func testLiveSearchFindsEverySite() async throws {
        guard AstGrep.binaryPath() != nil else { throw XCTSkip("ast-grep not installed") }
        try writeFixture()
        let r = try await AstGrepTool().execute(
            arguments: ["pattern": "orderBy({ createdAt: asc })", "lang": "ts"], context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("a.ts:1"), "must find first site")
        XCTAssertTrue(r.output.contains("a.ts:2"), "must find second site (structural = every site)")
    }

    func testLivePreviewDoesNotWrite() async throws {
        guard AstGrep.binaryPath() != nil else { throw XCTSkip("ast-grep not installed") }
        try writeFixture()
        let r = try await AstGrepTool().execute(
            arguments: ["pattern": "orderBy({ createdAt: asc })", "rewrite": "orderBy({ createdAt: desc })", "lang": "ts"],
            context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.metadata["mode"], "preview")
        XCTAssertFalse(fixture().contains("desc"), "preview must NOT modify the file")
    }

    func testLiveApplyRewritesEverySite() async throws {
        guard AstGrep.binaryPath() != nil else { throw XCTSkip("ast-grep not installed") }
        try writeFixture()
        let r = try await AstGrepApplyTool().execute(
            arguments: ["pattern": "orderBy({ createdAt: asc })", "rewrite": "orderBy({ createdAt: desc })", "lang": "ts"],
            context: ctx(shell: ShellPolicy(enabled: true, autoApprove: true)))
        XCTAssertTrue(r.success, "apply should succeed with shell enabled: \(r.error ?? "")")
        let after = fixture()
        XCTAssertFalse(after.contains("asc"), "every asc site must be rewritten")
        XCTAssertEqual(after.components(separatedBy: "desc").count - 1, 2, "both sites rewritten")
    }
}
