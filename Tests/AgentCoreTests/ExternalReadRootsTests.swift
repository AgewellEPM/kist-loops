import XCTest
import Foundation
@testable import AgentCore

/// External READ-ONLY roots (`--allow-read`, e.g. /Volumes for a CD/USB drive) — the fix for the
/// 2026-07-28 death-spiral where the model burned 787k tokens ping-ponging ask_user because
/// list_files refused /Volumes/CM6000_1 with no recovery path.
///
/// MULTI-SITE DISCIPLINE: the same pattern (read resolution) lives at N tool sites, and the
/// mirror pattern (writes must stay project-confined) lives at M sites. Every site gets its OWN
/// assertion below — one assertion proving "the bug" is fixed is insufficient (a missed sibling
/// re-introduces it for one tool only, which is exactly how the original bug shipped).
final class ExternalReadRootsTests: XCTestCase {

    private var project: String!    // the confinement root
    private var external: String!   // simulates a mounted volume (e.g. /Volumes/CD)
    private var outside: String!    // outside BOTH roots — must stay unreachable

    override func setUpWithError() throws {
        func makeTmp(_ label: String) throws -> String {
            let p = NSTemporaryDirectory() + "extread-\(label)-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
            return ToolContext.canonicalize(p)!
        }
        project = try makeTmp("project")
        external = try makeTmp("volume")
        outside = try makeTmp("outside")
        try "hello from the CD\nsecond line".write(toFile: external + "/readme.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: external + "/data", withIntermediateDirectories: true)
        try "needle-on-cd" .write(toFile: external + "/data/notes.txt", atomically: true, encoding: .utf8)
        try "secret".write(toFile: outside + "/secret.txt", atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        for p in [project, external, outside] { if let p { try? FileManager.default.removeItem(atPath: p) } }
    }

    private func armedContext() -> ToolContext {
        ToolContext(projectRoot: project, externalReadRoots: [external])
    }

    // MARK: - ConfinedRoot.readOnly — every mutating primitive refuses, per-op

    func testReadOnlyRootRefusesEveryMutatingPrimitive() throws {
        let ro = try ConfinedRoot(root: external, readOnly: true)
        // One labeled assertion PER primitive: a regression in any single site names itself.
        let ops: [(String, () throws -> Void)] = [
            ("writeData",     { try ro.writeData("x.txt", Data("x".utf8), createParents: false) }),
            ("writeString",   { try ro.writeString("y.txt", "y", createParents: false) }),
            ("move",          { try ro.move("readme.txt", "renamed.txt") }),
            ("removeFile",    { try ro.removeFile("readme.txt") }),
            ("makeDirectory", { try ro.makeDirectory("newdir") }),
        ]
        for (label, op) in ops {
            XCTAssertThrowsError(try op(), "read-only root must refuse \(label)") { error in
                XCTAssertTrue("\(error)".contains("READ-ONLY"), "\(label) refusal must say WHY: \(error)")
            }
        }
        // Reads still work on the same instance.
        XCTAssertTrue(try ro.readString("readme.txt").contains("hello from the CD"))
    }

    // MARK: - ToolContext routing

    func testRelativeAndInProjectPathsStillUseProjectRoot() throws {
        let ctx = armedContext()
        let (relRoot, _) = try ctx.confinedRootForReading("sub/file.txt")
        XCTAssertEqual(relRoot.rootPath, project)
        XCTAssertFalse(relRoot.readOnly, "project root stays writable")
        let (absRoot, _) = try ctx.confinedRootForReading(project + "/sub/file.txt")
        XCTAssertEqual(absRoot.rootPath, project)
    }

    func testAbsolutePathUnderExternalRootRoutesToReadOnlyRoot() throws {
        let (root, path) = try armedContext().confinedRootForReading(external + "/readme.txt")
        XCTAssertEqual(root.rootPath, external)
        XCTAssertTrue(root.readOnly, "external roots must come back READ-ONLY")
        XCTAssertTrue(try root.readString(path).contains("hello from the CD"))
    }

    func testPathOutsideAllRootsEscapesAndNamesReadableRoots() {
        XCTAssertThrowsError(try armedContext().confinedRootForReading(outside + "/secret.txt")) { error in
            let msg = "\(error)"
            XCTAssertTrue(msg.contains("escapes the project root"), msg)
            XCTAssertTrue(msg.contains(self.external), "the error must NAME what IS readable: \(msg)")
        }
    }

    func testUnarmedContextBehavesExactlyAsBefore() {
        let ctx = ToolContext(projectRoot: project)   // no externalReadRoots
        XCTAssertThrowsError(try ctx.confinedRootForReading(external + "/readme.txt"))
    }

    func testRootSlashIsRefusedAsExternalRoot() {
        let ctx = ToolContext(projectRoot: project, externalReadRoots: ["/"])
        XCTAssertTrue(ctx.externalReadRoots.isEmpty, "/ would un-confine every read — must be dropped")
    }

    func testNonexistentExternalRootGrantsNothing() {
        let ctx = ToolContext(projectRoot: project, externalReadRoots: ["/no/such/dir-\(UUID().uuidString)"])
        XCTAssertTrue(ctx.externalReadRoots.isEmpty)
    }

    func testDotDotInsideExternalPathCannotEscape() {
        // /external/data/../../outside must not resolve into a grant.
        let sneaky = external + "/data/../../" + (outside as NSString).lastPathComponent + "/secret.txt"
        XCTAssertThrowsError(try armedContext().confinedRootForReading(sneaky))
    }

    func testResolvedPathForReadingAcceptsExternalAndRefusesOutside() throws {
        let ctx = armedContext()
        XCTAssertEqual(try ctx.resolvedPathForReading(external + "/readme.txt", mustExist: true),
                       external + "/readme.txt")
        XCTAssertThrowsError(try ctx.resolvedPathForReading(external + "/missing.png", mustExist: true)) { e in
            guard case ToolError.notFound = e as! ToolError else { return XCTFail("wanted notFound, got \(e)") }
        }
        XCTAssertThrowsError(try ctx.resolvedPathForReading(outside + "/secret.txt", mustExist: true))
    }

    // MARK: - READ tools succeed under an armed external root — one assertion PER tool site

    func testListFilesReadsExternalRoot() async throws {
        let r = try await ListFilesTool().execute(arguments: ["path": external!], context: armedContext())
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("readme.txt"), r.output)
        XCTAssertTrue(r.output.contains("data/"), r.output)
    }

    func testReadFileReadsExternalRoot() async throws {
        let r = try await ReadFileTool().execute(arguments: ["path": external + "/readme.txt"], context: armedContext())
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("hello from the CD"), r.output)
    }

    func testGlobFilesWalksExternalRoot() async throws {
        let r = try await GlobFilesTool().execute(arguments: ["pattern": "**/*.txt", "path": external!],
                                                  context: armedContext())
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("readme.txt"), r.output)
        XCTAssertTrue(r.output.contains("data/notes.txt"), r.output)
    }

    func testSearchCodeSearchesExternalRoot() async throws {
        let r = try await SearchCodeTool().execute(arguments: ["pattern": "needle-on-cd", "path": external!],
                                                   context: armedContext())
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("needle-on-cd"), r.output)
    }

    // MARK: - WRITE tools stay project-confined even when armed — one assertion PER tool site

    func testWriteToolsRefuseExternalRootPerSite() async {
        let ctx = armedContext()
        let attempts: [(String, () async throws -> ToolResult)] = [
            ("write_file", { try await WriteFileTool().execute(
                arguments: ["path": self.external + "/evil.txt", "content": "x"], context: ctx) }),
            ("edit_file", { try await EditFileTool().execute(
                arguments: ["path": self.external + "/readme.txt", "old_text": "hello", "new_text": "pwned"], context: ctx) }),
            ("move_file", { try await MoveFileTool().execute(
                arguments: ["from": self.external + "/readme.txt", "to": "stolen.txt"], context: ctx) }),
            ("make_dir", { try await MakeDirTool().execute(
                arguments: ["path": self.external + "/evil-dir"], context: ctx) }),
        ]
        for (label, attempt) in attempts {
            do {
                let r = try await attempt()
                XCTAssertFalse(r.success, "\(label) must NOT succeed on an external read root")
            } catch { /* thrown refusal is the expected shape */ }
        }
        // And the filesystem proves it: nothing was created or renamed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: external + "/evil.txt"), "write_file leaked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: external + "/evil-dir"), "make_dir leaked")
        XCTAssertTrue(try String(contentsOfFile: external + "/readme.txt", encoding: .utf8).contains("hello"),
                      "edit_file/move_file mutated the read-only root")
    }

    // MARK: - Source pins: every wired READ site actually uses the reading resolver

    /// Per-file source assertion (the SURFACES pattern): a refactor that reverts ONE tool back to
    /// the project-only resolver fails HERE with the file named, without re-running the live bug.
    func testEveryReadSiteUsesTheReadingResolver() throws {
        let sources = URL(fileURLWithPath: #filePath)          // …/Tests/AgentCoreTests/ExternalReadRootsTests.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCore/Tools")
        let surfaces: [(file: String, marker: String)] = [
            ("FileTools.swift",           "confinedRootForReading("),
            ("DirectoryTools.swift",      "confinedRootForReading("),
            ("SearchCodeTool.swift",      "confinedRootForReading("),
            ("AstGrepTool.swift",         "confinedRootForReading("),
            ("SymbolsTool.swift",         "confinedRootForReading("),
            ("ViewImageTool.swift",       "resolvedPathForReading("),
            ("AnalyzeMediaTool.swift",    "resolvedPathForReading("),
            ("ReadSpreadsheetTool.swift", "resolvedPathForReading("),
            ("QueryDataTool.swift",       "resolvedPathForReading("),
            ("WatchVideoTool.swift",      "resolvedPathForReading("),
            ("MediaClipTool.swift",       "resolvedPathForReading("),
            ("TranslateDocumentTool.swift", "resolvedPathForReading("),
            // TOCTOU: media/data byte reads go through the openat/O_NOFOLLOW layer, never reopen-by-name.
            ("ViewImageTool.swift",       "readDataForReading("),
            ("AnalyzeMediaTool.swift",    "readDataForReading("),
            ("ReadSpreadsheetTool.swift", "readStringForReading("),
        ]
        for (file, marker) in surfaces {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains(marker), "\(file) no longer routes reads through \(marker)) — external read roots silently broke for this tool")
        }
        // translate_document has FOUR read sites in one function (resolver + 3 inner byte reads) —
        // wiring the resolver alone would pass resolution then fail at the inner reads. Pin all four.
        let translate = try String(contentsOf: sources.appendingPathComponent("TranslateDocumentTool.swift"), encoding: .utf8)
        XCTAssertGreaterThanOrEqual(translate.components(separatedBy: "readDataForReading(").count - 1, 2,
                                    "translate_document lost an inner ForReading byte-read site")
        XCTAssertTrue(translate.contains("readStringForReading("), "translate_document text branch lost its ForReading read")
        // MUTATING sibling stays project-only: ast_grep_apply writes via a spawned process the
        // readOnly backstop can't gate — it must NEVER route through the reading resolver.
        let astGrep = try String(contentsOf: sources.appendingPathComponent("AstGrepTool.swift"), encoding: .utf8)
        if let applyRange = astGrep.range(of: "struct AstGrepApplyTool") {
            XCTAssertFalse(astGrep[applyRange.lowerBound...].contains("ForReading("),
                           "ast_grep_apply must stay project-confined — it mutates via a spawned process")
        } else {
            XCTFail("AstGrepApplyTool not found — update this pin")
        }
    }

    /// Sub-agent contexts (fleet workers, specialist worktrees, best-of-N, evolve candidates) must
    /// propagate the user's arming — a silent drop made the denial steer give FALSE advice
    /// ("relaunch with --allow-read" when the session was already armed). One pin per spawn file.
    func testSpawnSitesPropagateExternalReadRoots() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let spawnFiles = [
            "Sources/AgentCore/PlanExecuteFleetSpawner.swift",
            "Sources/AgentCore/Specialist/SpecialistSpawner.swift",
            "Sources/Kist/KistRunner.swift",
            "Sources/Kist/KistEvolutionCommand.swift",
        ]
        for file in spawnFiles {
            let text = try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("externalReadRoots:"),
                          "\(file) builds a ToolContext without propagating externalReadRoots — sub-agents silently lose the user's --allow-read grant")
        }
    }

    // MARK: - External outputs must be ABSOLUTE (follow-up read_file resolves against the project root)

    func testSearchCodeExternalOutputsAbsolutePaths() async throws {
        let r = try await SearchCodeTool().execute(arguments: ["pattern": "needle-on-cd", "path": external!],
                                                   context: armedContext())
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains(external + "/data/notes.txt"),
                      "external search must emit ABSOLUTE paths (got: \(r.output))")
    }

    func testGlobFilesExternalOutputsAbsolutePaths() async throws {
        let r = try await GlobFilesTool().execute(arguments: ["pattern": "**/*.txt", "path": external!],
                                                  context: armedContext())
        XCTAssertTrue(r.success)
        for line in r.output.split(separator: "\n") {
            XCTAssertTrue(line.hasPrefix(external + "/"),
                          "external glob must emit ABSOLUTE paths, got relative: \(line)")
        }
    }

    func testSymbolsFindExternalOutputsAbsolutePaths() async throws {
        try "func cdSymbol() {}".write(toFile: external + "/data/code.swift", atomically: true, encoding: .utf8)
        let r = try await SymbolsTool().execute(arguments: ["action": "find", "name": "cdSymbol", "path": external!],
                                                context: armedContext())
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains(external + "/data/code.swift"),
                      "external symbols find must emit ABSOLUTE hit paths (got: \(r.output))")
    }

    func testAstGrepApplyRefusesExternalRoot() async {
        // Path resolution precedes the binary check, so this pins the refusal without ast-grep installed.
        do {
            let r = try await AstGrepApplyTool().execute(
                arguments: ["pattern": "a", "rewrite": "b", "path": external!], context: armedContext())
            XCTAssertFalse(r.success, "ast_grep_apply must NOT accept an external read root (it mutates)")
        } catch { /* thrown pathEscape is the expected shape */ }
    }

    // MARK: - TOCTOU-safe read helpers

    func testReadDataForReadingExternalAndCap() throws {
        let ctx = armedContext()
        XCTAssertEqual(String(data: try ctx.readDataForReading(external + "/readme.txt"), encoding: .utf8)?
                        .contains("hello from the CD"), true)
        XCTAssertThrowsError(try ctx.readDataForReading(external + "/readme.txt", maxBytes: 4),
                             "maxBytes must be enforced on the same fd")
        XCTAssertThrowsError(try ctx.readDataForReading(outside + "/secret.txt"))
        XCTAssertTrue(try ctx.readStringForReading(external + "/readme.txt").contains("hello from the CD"))
    }

    // MARK: - Denial steer: the loop must recover instead of ask_user-looping

    func testPathEscapeSteerNamesArmedRoots() {
        let steer = HeadlessAgentLoop.capabilityDenialSteer(
            error: "path '/Volumes/CM6000_1' escapes the project root (/Users/x) — refused",
            tools: .headless(), shellEnabled: false, readableRoots: ["/Volumes"])
        let s = try! XCTUnwrap(steer)
        XCTAssertTrue(s.contains("/Volumes"), "must name the readable root: \(s)")
        XCTAssertTrue(s.contains("STOP"), s)
    }

    func testPathEscapeSteerUnarmedPointsAtAllowRead() {
        let steer = HeadlessAgentLoop.capabilityDenialSteer(
            error: "path '/Volumes/CM6000_1' escapes the project root (/Users/x) — refused",
            tools: .headless(), shellEnabled: false, readableRoots: [])
        let s = try! XCTUnwrap(steer)
        XCTAssertTrue(s.contains("--allow-read"), "must tell the user how to arm it: \(s)")
    }

    func testPathEscapeSteerWithShellSuggestsRunCommand() {
        let steer = HeadlessAgentLoop.capabilityDenialSteer(
            error: "path '/Volumes/CM6000_1' escapes the project root (/Users/x) — refused",
            tools: .headless(), shellEnabled: true, readableRoots: [])
        let s = try! XCTUnwrap(steer)
        XCTAssertTrue(s.contains("run_command"), "shell-on sessions have an immediate alternative: \(s)")
    }
}
