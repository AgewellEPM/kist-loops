import XCTest
@testable import AgentCore

/// Read-only git tool. Tests: pure argv construction, the safety rails (subcommand
/// whitelist, rev-flag rejection, path confinement, blame-needs-path), registration,
/// and a real run against an isolated temporary repository.
final class GitToolTests: XCTestCase {

    private var root: String!
    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "git-tool-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
    }
    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }
    private func ctx() -> ToolContext { ToolContext(projectRoot: root, shell: .denied) }

    // MARK: - pure argv builder

    func testStatusArgs() throws {
        let a = try GitTool.buildArgs(sub: "status", rev: nil, relPath: nil, max: 30)
        XCTAssertEqual(a.suffix(3), ["status", "--porcelain=v1", "-b"])
    }

    func testEveryInvocationIsHardened() throws {
        // The code-exec neutralizers must lead every subcommand's argv.
        for sub in ["status", "diff", "log", "show"] {
            let a = try GitTool.buildArgs(sub: sub, rev: nil, relPath: (sub == "blame" ? "x" : nil), max: 30)
            XCTAssertEqual(a.first, "--no-pager", "\(sub) must run with --no-pager")
            XCTAssertTrue(a.contains("core.fsmonitor=false"), "\(sub) must disable fsmonitor hook")
            XCTAssertTrue(a.contains("core.hooksPath=/dev/null"), "\(sub) must neutralize hooks")
        }
        // diff-bearing subcommands also disable external diff/textconv drivers.
        for sub in ["diff", "log", "show"] {
            let a = try GitTool.buildArgs(sub: sub, rev: nil, relPath: nil, max: 30)
            XCTAssertTrue(a.contains("--no-ext-diff"), "\(sub) must pass --no-ext-diff")
            XCTAssertTrue(a.contains("--no-textconv"), "\(sub) must pass --no-textconv")
        }
        XCTAssertTrue(try GitTool.buildArgs(sub: "blame", rev: nil, relPath: "x", max: 30).contains("--no-textconv"))
    }

    func testDiffArgsWithRevAndPathUseDashDash() throws {
        let a = try GitTool.buildArgs(sub: "diff", rev: "HEAD~1", relPath: "Sources/App.swift", max: 30)
        XCTAssertTrue(a.contains("diff"))
        XCTAssertTrue(a.contains("HEAD~1"))
        let dd = a.firstIndex(of: "--")!
        XCTAssertEqual(a[dd + 1], "Sources/App.swift", "path must follow -- so it can't be a flag")
    }

    func testLogArgsRespectMax() throws {
        let a = try GitTool.buildArgs(sub: "log", rev: nil, relPath: nil, max: 7)
        XCTAssertTrue(a.contains("-n")); XCTAssertTrue(a.contains("7"))
    }

    func testBlameRequiresPath() {
        XCTAssertThrowsError(try GitTool.buildArgs(sub: "blame", rev: nil, relPath: nil, max: 30)) { e in
            guard let te = e as? ToolError, case .missingParameter = te else { return XCTFail("expected missingParameter") }
        }
    }

    // MARK: - safety rails

    func testUnknownSubcommandRefused() async throws {
        let r = try await GitTool().execute(arguments: ["subcommand": "push"], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.error?.contains("unsupported subcommand"), true, "mutating subcommands must be refused")
    }

    func testRevStartingWithDashRefused() async throws {
        let r = try await GitTool().execute(arguments: ["subcommand": "log", "rev": "--output=/etc/x"], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.error?.contains("must not start with '-'"), true, "a flag-shaped rev must be refused")
    }

    func testPathEscapeRefused() async throws {
        do {
            _ = try await GitTool().execute(arguments: ["subcommand": "diff", "path": "../escape"], context: ctx())
            XCTFail("expected pathEscape")
        } catch let e as ToolError {
            guard case .pathEscape = e else { return XCTFail("expected pathEscape, got \(e)") }
        }
    }

    func testMaxClamped() {
        XCTAssertEqual(GitTool().clampedMax(nil), 30)
        XCTAssertEqual(GitTool().clampedMax(0), 1)
        XCTAssertEqual(GitTool().clampedMax(99999), 500)
    }

    // MARK: - registration

    func testRegisteredAndReadOnly() {
        XCTAssertTrue(ToolRegistry.headless().all().contains { $0.name == "git" })
        XCTAssertTrue(HeadlessAgentLoop.readOnlyTools.contains("git"))
    }

    // MARK: - real process run

    func testStatusOnIsolatedRealRepoDoesNotDependOnCheckoutMetadata() async throws {
        guard let git = GitTool.gitPath() else { throw XCTSkip("git not installed") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["init", "-q"]
        process.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "fixture git init failed")

        let r = try await GitTool().execute(arguments: ["subcommand": "status"],
                                            context: ToolContext(projectRoot: root, shell: .denied))
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.metadata["subcommand"], "status")
    }
}
