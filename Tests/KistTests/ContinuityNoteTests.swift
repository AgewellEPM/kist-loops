import XCTest
@testable import Kist

/// Cross-cycle continuity note. Each great-loop cycle is a fresh conversation; without this reminder the
/// model re-creates work a prior cycle already did (dogfood: package built at ./ then re-created under
/// ./MathKit/ → duplication, never converged). These pin when the note fires and what it carries.
final class ContinuityNoteTests: XCTestCase {

    func testNoNoteOnFirstCycle() {
        // Cycle 0: nothing has been done yet — no continuity note (and never a phantom "already in progress").
        XCTAssertNil(KistRunner.continuityNote(cycleIndex: 0, changedFiles: ["Package.swift"]))
    }

    func testNoNoteWhenNothingChanged() {
        // A read-only / analysis task changes no files → nothing to continue.
        XCTAssertNil(KistRunner.continuityNote(cycleIndex: 3, changedFiles: []))
    }

    func testNoteListsPriorFilesAndSaysContinue() {
        let note = KistRunner.continuityNote(cycleIndex: 1, changedFiles: ["Package.swift", "Sources/MathKit/MathKit.swift"])
        XCTAssertNotNil(note)
        XCTAssertTrue(note!.contains("CONTINUE"))
        XCTAssertTrue(note!.contains("do NOT recreate"))
        XCTAssertTrue(note!.contains("new subdirectory"), "must warn against the observed subdir-duplication failure")
        XCTAssertTrue(note!.contains("Package.swift"))
        XCTAssertTrue(note!.contains("Sources/MathKit/MathKit.swift"))
    }

    func testNoteCapsTheFileList() {
        let many = (0..<200).map { "file\($0).swift" }
        let note = KistRunner.continuityNote(cycleIndex: 2, changedFiles: many)!
        // Bounded so a big changeset can't blow the context (cap 60).
        XCTAssertFalse(note.contains("file80.swift"))
        XCTAssertTrue(note.contains("file0.swift"))
    }
}
