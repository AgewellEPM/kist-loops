import XCTest
@testable import AgentCore

/// Guards on the edit/write apply path: leaked markers, catastrophic truncation,
/// dropped imports. Two layers of tests:
///   1. PURE — the validator logic and its false-positive safety.
///   2. MULTI-SITE — the invariant is wired at EVERY apply site individually
///      (edit_file, write_file, apply_patch), so a future refactor that drops the
///      guard from one tool fails a named test for THAT tool (per the multi-site rule).
final class EditGuardsTests: XCTestCase {

    private var root: String!

    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "editguards-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
    }
    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }
    private func ctx() -> ToolContext { ToolContext(projectRoot: root, shell: .denied) }
    private func write(_ rel: String, _ body: String) throws {
        try body.write(toFile: root + "/" + rel, atomically: true, encoding: .utf8)
    }
    private func read(_ rel: String) -> String? { try? String(contentsOfFile: root + "/" + rel, encoding: .utf8) }

    // MARK: - Pure validator

    func testMarkerIntroducedIsRefused() {
        let block = EditGuards.validate(old: "let a = 1\n", new: "let a = 1\n<<<<<<< HEAD\n", path: "f.swift", localized: true)
        XCTAssertNotNil(block); XCTAssertEqual(block?.success, false)
    }

    func testMarkerAlreadyPresentIsNotRefused() {
        // old already contains the token → the edit did not INTRODUCE it → allowed.
        let old = "doc describing <<<<<<< markers\n"
        let new = old + "one more line\n"
        XCTAssertNil(EditGuards.validate(old: old, new: new, path: "notes.md", localized: true))
    }

    func testPatchEnvelopeLeakRefused() {
        let block = EditGuards.validate(old: "x\n", new: "x\n*** End Patch\n", path: "f", localized: false)
        XCTAssertNotNil(block)   // marker check applies even for non-localized writes
    }

    func testLazyPlaceholderRefused() {
        let new = "func f() {\n    // ... existing code ...\n}\n"
        XCTAssertNotNil(EditGuards.validate(old: "func f() {\n    doWork()\n}\n", new: new, path: "f.swift", localized: true))
    }

    func testLazyPlaceholderCaseInsensitive() {
        // "... Existing code ..." (capitalized) must not dodge the guard (DeepSeek review).
        let new = "func f() {\n    // ... Existing Code ...\n}\n"
        XCTAssertNotNil(EditGuards.validate(old: "func f() {\n    work()\n}\n", new: new, path: "f.swift", localized: true))
    }

    func testConflictSeparatorRefused() {
        // A lone "=======" line introduced = leftover merge separator (DeepSeek review).
        let block = EditGuards.validate(old: "a = 1\n", new: "a = 1\n=======\nb = 2\n", path: "f.swift", localized: false)
        XCTAssertNotNil(block); XCTAssertEqual(block?.success, false)
    }

    func testLongEqualsDividerNotRefused() {
        // A legitimate long "====…" section divider (not exactly 7) must NOT be flagged.
        let new = "// =====================\nlet x = 1\n"
        XCTAssertNil(EditGuards.validate(old: "let x = 0\n", new: new, path: "f.swift", localized: true))
    }

    func testProseMentioningExistingCodeNotRefused() {
        // A comment ABOUT existing code, not a "..." placeholder, must not trip the guard.
        let new = "// this preserves existing code paths for callers\nlet x = 1\n"
        XCTAssertNil(EditGuards.validate(old: "let x = 0\n", new: new, path: "f.swift", localized: true))
    }

    func testCatastrophicTruncationLocalizedRefused() {
        let old = String(repeating: "a = 1\n", count: 60)   // 360 chars
        let new = "a = 1\n"                                  // ~6 chars → lost >98%
        let block = EditGuards.validate(old: old, new: new, path: "big.swift", localized: true)
        XCTAssertNotNil(block); XCTAssertEqual(block?.success, false)
    }

    func testCatastrophicTruncationNotAppliedToWholeFileWrite() {
        // write_file (non-localized) may legitimately shrink a file arbitrarily.
        let old = String(repeating: "a = 1\n", count: 60)
        XCTAssertNil(EditGuards.validate(old: old, new: "a = 1\n", path: "big.swift", localized: false))
    }

    func testTruncationSkippedForTinyFiles() {
        XCTAssertNil(EditGuards.validate(old: "hi\n", new: "", path: "t.swift", localized: true))
    }

    func testMassDroppedImportsRefused() {
        // 3+ imports vanishing in one localized edit = apply bug.
        let old = "import Foundation\nimport UIKit\nimport Combine\nimport OSLog\nlet x = 1\n"
        let new = "import Foundation\nlet x = 1\n"   // dropped 3
        let block = EditGuards.validate(old: old, new: new, path: "v.swift", localized: true)
        XCTAssertNotNil(block); XCTAssertEqual(block?.success, false)
    }

    func testSingleImportRemovalAllowed() {
        // Removing one unused import is normal refactoring — must NOT be blocked (Codex false-positive fix).
        let old = "import Foundation\nimport UIKit\nlet x = 1\n"
        let new = "import Foundation\nlet x = 1\n"   // dropped 1
        XCTAssertNil(EditGuards.validate(old: old, new: new, path: "v.swift", localized: true))
    }

    func testKeptImportsNotRefused() {
        let old = "import Foundation\nimport UIKit\nlet x = 1\n"
        let new = "import Foundation\nimport UIKit\nlet x = 2\n"
        XCTAssertNil(EditGuards.validate(old: old, new: new, path: "v.swift", localized: true))
    }

    func testImportLineExtractionAcrossLanguages() {
        let src = "import Foundation\nfrom os import path\n#include <stdio.h>\nuse std::io;\nconst x = require('fs')\nlet a = 1\n"
        let imports = EditGuards.importLines(in: src)
        XCTAssertTrue(imports.contains("import Foundation"))
        XCTAssertTrue(imports.contains("from os import path"))
        XCTAssertTrue(imports.contains("#include <stdio.h>"))
        XCTAssertTrue(imports.contains("use std::io;"))
        XCTAssertTrue(imports.contains("const x = require('fs')"))
        XCTAssertFalse(imports.contains("let a = 1"))
    }

    // MARK: - MULTI-SITE: each apply tool honors the guard (named per tool)

    func testEditFileToolRefusesMarkerAndWritesNothing() async throws {
        try write("f.swift", "let a = 1\nlet b = 2\n")
        let r = try await EditFileTool().execute(
            arguments: ["path": "f.swift", "old_text": "let b = 2", "new_text": "<<<<<<< HEAD\nlet b = 3"],
            context: ctx())
        XCTAssertFalse(r.success, "edit_file must refuse a marker-introducing edit")
        XCTAssertEqual(read("f.swift"), "let a = 1\nlet b = 2\n", "edit_file must write nothing when guarded")
    }

    func testWriteFileToolRefusesMarkerAndDoesNotCreate() async throws {
        let r = try await WriteFileTool().execute(
            arguments: ["path": "g.swift", "content": "line\n>>>>>>> theirs\n"],
            context: ctx())
        XCTAssertFalse(r.success, "write_file must refuse a marker-introducing write")
        XCTAssertNil(read("g.swift"), "write_file must not create the file when guarded")
    }

    func testApplyPatchToolRefusesMarkerAndWritesNothing() async throws {
        try write("h.swift", "let x = 1\nlet y = 2\n")
        let patch = """
        *** Begin Patch
        *** Update File: h.swift
        @@
         let x = 1
        -let y = 2
        +<<<<<<< HEAD
        +let y = 3
        *** End Patch
        """
        let r = try await ApplyPatchTool().execute(arguments: ["patch": patch], context: ctx())
        XCTAssertFalse(r.success, "apply_patch must refuse a marker-introducing hunk")
        XCTAssertEqual(read("h.swift"), "let x = 1\nlet y = 2\n", "apply_patch must write nothing when guarded")
    }

    func testApplyPatchMoveDestinationIsGuardedAsLocalized() async throws {
        // Update+Move whose destination catastrophically truncates must be refused (Codex MED #3):
        // the move destination is a localized edit (its old content = the source's bytes).
        let big = String(repeating: "let n = 1\n", count: 60)   // ~600 chars
        try write("src.swift", big)
        // Hunk removes almost everything, then moves to dst.swift → destination loses >60%.
        let removals = big.split(separator: "\n").map { "-\($0)" }.joined(separator: "\n")
        let patch = """
        *** Begin Patch
        *** Update File: src.swift
        *** Move to: dst.swift
        @@
        \(removals)
        +let n = 1
        *** End Patch
        """
        let r = try await ApplyPatchTool().execute(arguments: ["patch": patch], context: ctx())
        XCTAssertFalse(r.success, "move destination truncation must be guarded")
        XCTAssertEqual(read("src.swift"), big, "source must be untouched when guard trips")
        XCTAssertNil(read("dst.swift"), "destination must not be written when guard trips")
    }

    /// Proves the localized flag is set correctly PER SITE: write_file (non-localized)
    /// allows a big shrink; edit_file (localized) refuses the equivalent truncation.
    func testWriteFileAllowsBigShrinkButEditFileRefusesTruncation() async throws {
        let big = String(repeating: "x = 1\n", count: 80)   // 480 chars
        // write_file: intentional whole-file shrink is allowed.
        try write("w.swift", big)
        let w = try await WriteFileTool().execute(arguments: ["path": "w.swift", "content": "x = 1\n"], context: ctx())
        XCTAssertTrue(w.success, "write_file should allow an intentional whole-file shrink")
        XCTAssertEqual(read("w.swift"), "x = 1\n")
        // edit_file: replacing almost the whole file via one edit is treated as truncation.
        try write("e.swift", big)
        let e = try await EditFileTool().execute(
            arguments: ["path": "e.swift", "old_text": big, "new_text": "x = 1\n"], context: ctx())
        XCTAssertFalse(e.success, "edit_file should refuse a >60% localized truncation")
        XCTAssertEqual(read("e.swift"), big, "edit_file must write nothing when truncation-guarded")
    }
}
