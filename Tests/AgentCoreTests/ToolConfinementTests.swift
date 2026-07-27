import XCTest
import Foundation
@testable import AgentCore

/// Per-tool confinement regression — drives each headless tool through the LIVE path
/// (`ToolRegistry.headless().execute(...)`), NOT `ConfinedRoot` directly, against real
/// symlinks pointing out of the project root.
///
/// This is the test that was missing: `ConfinedRoot` shipped fully tested but DEAD —
/// no tool routed through it, so the real tool paths stayed TOCTOU-vulnerable while the
/// primitive's own suite passed. These assertions pin the invariant at the tool layer,
/// one per tool (multi-site discipline), so a future un-wiring fails loudly here.
final class ToolConfinementTests: XCTestCase {

    private var root: String!
    private var external: String!         // dir OUTSIDE root, the symlink target
    private let secret = "TOP-SECRET-OUTSIDE-ROOT"

    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "toolconfine-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)

        let ext = NSTemporaryDirectory() + "toolconfine-ext-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: ext, withIntermediateDirectories: true)
        external = ToolContext.canonicalize(ext)
        try secret.write(toFile: external + "/secret.txt", atomically: true, encoding: .utf8)

        // Two escape vectors planted INSIDE the root:
        try FileManager.default.createSymbolicLink(atPath: root + "/linkfile", withDestinationPath: external + "/secret.txt")
        try FileManager.default.createSymbolicLink(atPath: root + "/linkdir", withDestinationPath: external)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(atPath: root) }
        if let external { try? FileManager.default.removeItem(atPath: external) }
    }

    private func ctx() -> ToolContext { ToolContext(projectRoot: root) }
    private func run(_ name: String, _ args: [String: Any]) async -> ToolResult {
        await ToolRegistry.headless().execute(name: name, arguments: args, context: ctx())
    }

    // MARK: - Escape attempts must be refused (one per tool)

    func testReadFile_throughSymlinkLeaf_refused() async {
        let r = await run("read_file", ["path": "linkfile"])
        XCTAssertFalse(r.success, "read_file must refuse a symlinked leaf")
        XCTAssertFalse(r.output.contains(secret), "must not leak external file contents")
    }

    func testReadFile_throughSymlinkIntermediate_refused() async {
        let r = await run("read_file", ["path": "linkdir/secret.txt"])
        XCTAssertFalse(r.success, "read_file must refuse a symlinked intermediate dir")
        XCTAssertFalse(r.output.contains(secret))
    }

    func testReadFile_directoryReturnsToolFailureNotProcessCrash() async throws {
        try FileManager.default.createDirectory(atPath: root + "/adir", withIntermediateDirectories: true)
        let r = await run("read_file", ["path": "adir"])
        XCTAssertFalse(r.success, "read_file on a directory must be a recoverable tool failure")
        XCTAssertTrue((r.error ?? r.output).contains("not a regular file"))
    }

    func testWriteFile_throughSymlinkedDir_refused() async {
        let r = await run("write_file", ["path": "linkdir/evil.txt", "content": "x"])
        XCTAssertFalse(r.success, "write_file must refuse to create through a symlinked dir")
        XCTAssertFalse(FileManager.default.fileExists(atPath: external + "/evil.txt"),
                       "nothing may be written outside the root")
    }

    func testWriteFile_symlinkLeaf_doesNotClobberTarget() async {
        // Writing a name that is a symlink replaces the LINK, never the external target.
        let r = await run("write_file", ["path": "linkfile", "content": "HACKED"])
        // (write may succeed by replacing the link in-root) — the invariant is the target is safe:
        XCTAssertEqual(try? String(contentsOfFile: external + "/secret.txt", encoding: .utf8), secret,
                       "external target must be untouched")
        _ = r
    }

    func testEditFile_throughSymlinkLeaf_refused() async {
        let r = await run("edit_file", ["path": "linkfile", "old_text": "TOP", "new_text": "X"])
        XCTAssertFalse(r.success, "edit_file must refuse a symlinked leaf")
        XCTAssertEqual(try? String(contentsOfFile: external + "/secret.txt", encoding: .utf8), secret)
    }

    func testListFiles_symlinkedDir_refused() async {
        let r = await run("list_files", ["path": "linkdir"])
        XCTAssertFalse(r.success, "list_files must refuse a symlinked directory")
        XCTAssertFalse(r.output.contains("secret.txt"), "must not enumerate outside the root")
    }

    func testGlobFiles_doesNotDescendSymlinkedDir() async {
        // A real file proves glob still works; the symlinked dir's contents must be invisible.
        _ = await run("write_file", ["path": "real/keep.txt", "content": "1"])
        let r = await run("glob_files", ["pattern": "**/*.txt"])
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("real/keep.txt"), "glob must still find in-root files")
        XCTAssertFalse(r.output.contains("secret.txt"), "glob must not surface symlinked-out files")
        XCTAssertFalse(r.output.contains("linkfile"), "symlinks themselves are not followed")
    }

    func testSearchCode_doesNotReadThroughSymlinks() async {
        _ = await run("write_file", ["path": "real/code.txt", "content": "needle here"])
        let r = await run("search_code", ["pattern": secret])
        XCTAssertTrue(r.success)
        XCTAssertFalse(r.output.contains(secret), "search must not read symlinked-out files")
        // And a normal in-root search still works:
        let r2 = await run("search_code", ["pattern": "needle"])
        XCTAssertTrue(r2.output.contains("real/code.txt:1"))
    }

    // MARK: - The discriminating test (fails on the dead-code state)

    func testReadFile_inRootSymlink_notFollowed_provesWiringIsLive() async {
        // NOTE on test design: the out-of-root symlink tests above pass on BOTH the old
        // `resolvedPath` (realpath containment) AND the new ConfinedRoot, so they do not by
        // themselves prove the rewire happened. THIS one does: an in-root symlink to an
        // in-root target is FOLLOWED by realpath (old, dead-code path → read succeeds) but
        // REFUSED by ConfinedRoot's O_NOFOLLOW (new). It pins both that the wiring is live
        // and the documented "in-repo symlinks are not followed" contract.
        _ = await run("write_file", ["path": "realdir/target.txt", "content": "in-root-data"])
        try? FileManager.default.createSymbolicLink(atPath: root + "/slink", withDestinationPath: root + "/realdir")
        let r = await run("read_file", ["path": "slink/target.txt"])
        XCTAssertFalse(r.success, "ConfinedRoot must not follow an in-root symlinked dir — proves the tools route through it, not resolvedPath")
        XCTAssertFalse(r.output.contains("in-root-data"))
    }

    func testSearchCode_withSubdirBase_reconstructsRootRelativePaths() async {
        // Pins the basePrefix fix: a subdir base must yield root-relative hit paths and must
        // not search files outside the base.
        _ = await run("write_file", ["path": "sub/deep/code.txt", "content": "needle-x"])
        _ = await run("write_file", ["path": "other.txt", "content": "needle-x"])
        let r = await run("search_code", ["pattern": "needle-x", "path": "sub"])
        XCTAssertTrue(r.success, r.error ?? "")
        XCTAssertTrue(r.output.contains("sub/deep/code.txt:1"), r.output)
        XCTAssertFalse(r.output.contains("other.txt"), "must not search outside the base")
    }

    // MARK: - Happy path through the live registry (rewire didn't break normal use)

    func testRoundTripThroughLiveRegistry() async {
        let w = await run("write_file", ["path": "a/b.txt", "content": "hello\nworld"])
        XCTAssertTrue(w.success, w.error ?? "")

        let r = await run("read_file", ["path": "a/b.txt"])
        XCTAssertTrue(r.output.contains("hello") && r.output.contains("world"))

        let e = await run("edit_file", ["path": "a/b.txt", "old_text": "world", "new_text": "kist"])
        XCTAssertTrue(e.success, e.error ?? "")
        let r2 = await run("read_file", ["path": "a/b.txt"])
        XCTAssertTrue(r2.output.contains("kist"))
        XCTAssertFalse(r2.output.contains("world"))

        let ls = await run("list_files", ["path": "a"])
        XCTAssertTrue(ls.output.contains("b.txt"))
    }
}
