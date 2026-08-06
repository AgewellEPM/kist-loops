import XCTest
import Foundation
@testable import AgentCore

/// `read_file` on a DIRECTORY used to surface as `.notFound` → humanized "it doesn't exist here" — a
/// lie (the path exists, it's a directory) that sent the self-heal diagnostic researcher in circles
/// after `read_file /Users/lukekist` (the project root) in the 2026-08-04 run. read_file must instead
/// steer to list_files.
///
/// MULTI-SITE: a directory reaches ConfinedRoot two ways — the confinement ROOT itself (empty relative
/// components → `.notFound`) and a NON-root subdirectory (opens, then "not a regular file"). Both must
/// give the same actionable message, so each gets its own assertion.
final class ReadFileDirectoryTests: XCTestCase {

    private var project: String!
    private var subdir: String!

    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "readdir-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        project = ToolContext.canonicalize(base)!
        subdir = project + "/nested"
        try FileManager.default.createDirectory(atPath: subdir, withIntermediateDirectories: true)
        try "hello".write(toFile: project + "/real.txt", atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let project { try? FileManager.default.removeItem(atPath: project) }
    }

    private func ctx() -> ToolContext { ToolContext(projectRoot: project) }

    // Site 1: the confinement ROOT itself (the exact `/Users/lukekist` case from the wild).
    func testReadFileOnProjectRootSaysItIsADirectory() async throws {
        let r = try await ReadFileTool().execute(arguments: ["path": project!], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertTrue((r.error ?? "").contains("is a directory"), "must name the real cause: \(r.error ?? "")")
        XCTAssertTrue((r.error ?? "").contains("list_files"), "must steer to list_files: \(r.error ?? "")")
        XCTAssertFalse((r.error ?? "").contains("doesn't exist"), "must NOT lie that it's missing: \(r.error ?? "")")
    }

    // Site 2: a NON-root subdirectory (reached relative to the project root).
    func testReadFileOnSubdirectorySaysItIsADirectory() async throws {
        let r = try await ReadFileTool().execute(arguments: ["path": "nested"], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertTrue((r.error ?? "").contains("is a directory"), "\(r.error ?? "")")
        XCTAssertTrue((r.error ?? "").contains("list_files"), "\(r.error ?? "")")
    }

    // A genuinely missing path must STILL report not-found (we didn't paper over real absence).
    func testReadFileOnMissingPathStillNotFound() async {
        do {
            _ = try await ReadFileTool().execute(arguments: ["path": "does-not-exist.txt"], context: ctx())
            XCTFail("a missing file must throw")
        } catch let ToolError.notFound(p) {
            XCTAssertEqual(p, "does-not-exist.txt")
        } catch {
            XCTFail("a missing file must throw .notFound, got \(error)")
        }
    }

    // A real file still reads normally.
    func testReadFileOnRealFileStillWorks() async throws {
        let r = try await ReadFileTool().execute(arguments: ["path": "real.txt"], context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertTrue(r.output.contains("hello"))
    }
}
// Note: XCTAssertThrowsErrorAsync is defined once for this target in SkillsWiringTests.swift.
