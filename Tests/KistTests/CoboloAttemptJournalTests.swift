import Foundation
import XCTest
import AgentCore
@testable import Kist

final class CoboloAttemptJournalTests: XCTestCase {
    func testFileJournalCreatesOwnerOnlySealedRecordAndAdvancesMonotonically() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.container) }
        let journal = try CoboloFileAttemptJournal(
            baseDirectory: fixture.journal, projectRoot: fixture.project)

        let initial = try journal.create(binding: fixture.binding)
        let advanced = try journal.advance(
            binding: fixture.binding, expectedHighWater: 0,
            revision: 0, planDigest: String(repeating: "c", count: 64))
        let loaded = try XCTUnwrap(journal.load(binding: fixture.binding))

        XCTAssertEqual(initial.highWater, 0)
        XCTAssertEqual(advanced.highWater, 1)
        XCTAssertEqual(loaded, advanced)
        XCTAssertTrue(ForgeSeal.verify(loaded.canonicalSealInput, seal: loaded.seal))
        XCTAssertEqual(try permissions(fixture.journal), 0o700)
        XCTAssertEqual(
            try permissions((fixture.journal as NSString)
                .appendingPathComponent("\(fixture.binding.runID).json")),
            0o600
        )
    }

    func testFileJournalRejectsForgedSealAndBindingReplay() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.container) }
        let journal = try CoboloFileAttemptJournal(
            baseDirectory: fixture.journal, projectRoot: fixture.project)
        _ = try journal.create(binding: fixture.binding)
        let recordPath = (fixture.journal as NSString)
            .appendingPathComponent("\(fixture.binding.runID).json")
        let data = try Data(contentsOf: URL(fileURLWithPath: recordPath))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["seal"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: recordPath), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: recordPath)

        XCTAssertThrowsError(try journal.load(binding: fixture.binding))

        let replayBinding = CoboloAttemptJournalBinding(
            runID: fixture.binding.runID,
            contractID: String(repeating: "d", count: 64),
            projectRoot: fixture.project,
            maximumAttempts: fixture.binding.maximumAttempts)
        XCTAssertThrowsError(try journal.load(binding: replayBinding))
    }

    func testFileJournalRejectsWorkspaceOverlap() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-cobolo-journal-overlap-\(UUID().uuidString)",
                                  isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)

        XCTAssertThrowsError(try CoboloFileAttemptJournal(
            baseDirectory: container.appendingPathComponent("journal").path,
            projectRoot: container.path))
    }

    func testMemoryJournalRejectsCounterMismatchAndGapAdvance() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.container) }
        let journal = CoboloMemoryAttemptJournal()
        _ = try journal.create(binding: fixture.binding)

        XCTAssertThrowsError(try journal.advance(
            binding: fixture.binding, expectedHighWater: 1,
            revision: 1, planDigest: String(repeating: "e", count: 64)))
        _ = try journal.advance(
            binding: fixture.binding, expectedHighWater: 0,
            revision: 0, planDigest: String(repeating: "e", count: 64))
        XCTAssertThrowsError(try journal.advance(
            binding: fixture.binding, expectedHighWater: 0,
            revision: 0, planDigest: String(repeating: "f", count: 64)))
    }

    private func makeFixture() throws -> (
        container: String, project: String, journal: String,
        binding: CoboloAttemptJournalBinding
    ) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-cobolo-journal-\(UUID().uuidString)",
                                  isDirectory: true)
        let project = container.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project, withIntermediateDirectories: true)
        let journal = container.appendingPathComponent("anchor", isDirectory: true)
        let binding = CoboloAttemptJournalBinding(
            runID: String(repeating: "a", count: 64),
            contractID: String(repeating: "b", count: 64),
            projectRoot: project.resolvingSymlinksInPath().path,
            maximumAttempts: 3)
        return (container.path, project.path, journal.path, binding)
    }

    private func permissions(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o7777
    }
}
