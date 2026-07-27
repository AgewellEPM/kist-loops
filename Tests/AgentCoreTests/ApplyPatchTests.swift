import XCTest
@testable import AgentCore

final class ApplyPatchTests: XCTestCase {

    // MARK: engine (pure)

    func testParseAddUpdateDeleteMove() throws {
        let patch = """
        *** Begin Patch
        *** Add File: new.txt
        +hello
        +world
        *** Update File: a.swift
        *** Move to: b.swift
        @@
         let x = 1
        -let y = 2
        +let y = 3
        *** Delete File: gone.txt
        *** End Patch
        """
        let ops = try ApplyPatch.parse(patch)
        XCTAssertEqual(ops.count, 3)
        XCTAssertEqual(ops[0], .add(path: "new.txt", content: "hello\nworld"))
        guard case .update(let p, let move, let hunks) = ops[1] else { return XCTFail() }
        XCTAssertEqual(p, "a.swift"); XCTAssertEqual(move, "b.swift"); XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(ops[2], .delete(path: "gone.txt"))
    }

    func testApplyHunkLocatesByContextNoLineNumbers() throws {
        let file = "import Foundation\n\nlet x = 1\nlet y = 2\nlet z = 3\n"
        let hunk = [ApplyPatch.HunkLine(kind: .context, text: "let x = 1"),
                    ApplyPatch.HunkLine(kind: .remove, text: "let y = 2"),
                    ApplyPatch.HunkLine(kind: .add, text: "let y = 22")]
        let out = try ApplyPatch.applyHunks([hunk], to: file, path: "f")
        XCTAssertTrue(out.contains("let y = 22"))
        XCTAssertFalse(out.contains("let y = 2\n"))
        XCTAssertTrue(out.contains("let z = 3"))   // rest untouched
    }

    func testHunkNoMatchThrows() {
        let hunk = [ApplyPatch.HunkLine(kind: .remove, text: "nonexistent line")]
        XCTAssertThrowsError(try ApplyPatch.applyHunks([hunk], to: "a\nb\nc", path: "f")) { err in
            XCTAssertEqual(err as? ApplyPatch.PatchError, .hunkNoMatch(path: "f"))
        }
    }

    func testTrailingWhitespaceFuzzyMatch() throws {
        let file = "let x = 1   \nlet y = 2\n"   // trailing spaces in the file
        let hunk = [ApplyPatch.HunkLine(kind: .context, text: "let x = 1"),   // hunk has none
                    ApplyPatch.HunkLine(kind: .remove, text: "let y = 2"),
                    ApplyPatch.HunkLine(kind: .add, text: "let y = 9")]
        let out = try ApplyPatch.applyHunks([hunk], to: file, path: "f")
        XCTAssertTrue(out.contains("let y = 9"))
    }

    func testEnvelopeAndEmptyErrors() {
        XCTAssertThrowsError(try ApplyPatch.parse("no envelope here"))
        XCTAssertThrowsError(try ApplyPatch.parse("*** Begin Patch\n*** End Patch")) { err in
            XCTAssertEqual(err as? ApplyPatch.PatchError, .empty)
        }
    }

    func testEscapeDetection() {
        XCTAssertTrue(ApplyPatch.touchesEscapingPath("*** Begin Patch\n*** Add File: /etc/evil\n*** End Patch", projectRoot: "/p"))
        XCTAssertTrue(ApplyPatch.touchesEscapingPath("*** Update File: ../../x\n", projectRoot: "/p"))
        XCTAssertFalse(ApplyPatch.touchesEscapingPath("*** Update File: src/a.swift\n", projectRoot: "/p"))
    }

    // MARK: tool (real confined filesystem)

    func testToolAppliesMultiFilePatchAtomically() async throws {
        let raw = NSTemporaryDirectory() + "patch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        let root = ToolContext.canonicalize(raw)!   // canonicalize AFTER the dir exists
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "let y = 2\n".write(toFile: root + "/a.swift", atomically: true, encoding: .utf8)
        let ctx = ToolContext(projectRoot: root)

        let patch = """
        *** Begin Patch
        *** Add File: docs/new.md
        +# New
        *** Update File: a.swift
        @@
        -let y = 2
        +let y = 42
        *** End Patch
        """
        let r = try await ApplyPatchTool().execute(arguments: ["patch": patch], context: ctx)
        XCTAssertTrue(r.success, r.output)
        XCTAssertEqual(try String(contentsOfFile: root + "/a.swift", encoding: .utf8), "let y = 42\n")
        XCTAssertEqual(try String(contentsOfFile: root + "/docs/new.md", encoding: .utf8), "# New")   // parent created
    }

    func testToolFailsCleanlyAndWritesNothingOnBadHunk() async throws {
        let raw = NSTemporaryDirectory() + "patch2-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        let root = ToolContext.canonicalize(raw)!
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "original\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        let ctx = ToolContext(projectRoot: root)
        // The Add would succeed, but the Update hunk can't match → whole patch validates in memory FIRST,
        // so NOTHING is written (atomic).
        let patch = """
        *** Begin Patch
        *** Add File: should_not_exist.txt
        +x
        *** Update File: a.txt
        @@
        -this line is not in the file
        +replacement
        *** End Patch
        """
        let r = try await ApplyPatchTool().execute(arguments: ["patch": patch], context: ctx)
        XCTAssertFalse(r.success)
        XCTAssertTrue((r.error ?? "").contains("did not match"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/should_not_exist.txt"))   // atomic: no partial write
        XCTAssertEqual(try String(contentsOfFile: root + "/a.txt", encoding: .utf8), "original\n")
    }

    func testApplyPatchClassifiedDangerousOnEscape() {
        let safe = "*** Begin Patch\n*** Update File: a.swift\n@@\n-x\n+y\n*** End Patch"
        let evil = "*** Begin Patch\n*** Add File: /etc/evil\n+x\n*** End Patch"
        XCTAssertEqual(ReversibilityClassifier.assess(tool: "apply_patch", args: ["patch": safe], projectRoot: "/p"), .mutating)
        XCTAssertEqual(ReversibilityClassifier.assess(tool: "apply_patch", args: ["patch": evil], projectRoot: "/p"), .dangerous)
    }
}
