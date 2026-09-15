import XCTest
@testable import AgentCore

final class ProcedureReadIntegrityTests: XCTestCase {
    private var root = ""
    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private var store: ProcedureStore { ProcedureStore(projectRoot: root) }

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "procedure-read-integrity-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        root = try XCTUnwrap(ToolContext.canonicalize(root))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: root)
    }

    private func deposit() throws -> Procedure {
        try XCTUnwrap(store.deposit(title: "Repair orchidRegistry mirror", task: "orchidRegistry timeout",
            steps: "rebuild the mirror index", source: "synthetic-signoff:original",
            at: now.addingTimeInterval(-3_600)).procedure)
    }

    func testRecalledProcedureLocatorResolvesItsExactStoredVersion() throws {
        let procedure = try deposit()
        let recall = try AgentMemoryAccess(projectRoot: root).recall(query: "orchidRegistry timeout", at: now)
        let entry = try XCTUnwrap(recall.entries.first { $0.id == "procedure-\(procedure.id)-v1" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.locator),
                      "the source shown to the agent must resolve to the actual immutable version file")
        if let data = FileManager.default.contents(atPath: entry.locator) {
            let decoded = try JSONDecoder().decode(Procedure.self, from: data)
            XCTAssertEqual(decoded, procedure)
        }
    }

    func testUnreadableSupersedingVersionDoesNotResurrectOldProcedureInRecall() throws {
        let old = try deposit()
        let retired = try XCTUnwrap(store.supersede(id: old.id, by: "replacement", at: now).procedure)
        XCTAssertTrue(store.retrieve(applicability: "orchidRegistry timeout", at: now).isEmpty)
        let path = root + "/" + ProcedureStore.directory + "/\(old.id)-v000002.json"
        XCTAssertEqual(retired.version, 2)
        try Data("{\"incomplete\":".utf8).write(to: URL(fileURLWithPath: path))
        let recall = try AgentMemoryAccess(projectRoot: root).recall(query: "orchidRegistry timeout", at: now)
        XCTAssertFalse(recall.entries.contains { $0.id.hasPrefix("procedure-\(old.id)-") },
                       "uncertain latest lifecycle cannot authorize an older active procedure")
        XCTAssertTrue(recall.issues.contains { $0.lowercased().contains("procedure") },
                      "procedure degradation must be visible to the recall caller")
    }

    func testProcedureInventoryLimitIsReportedInsteadOfSilentCompleteRecall() throws {
        _ = try deposit()
        let folder = root + "/" + ProcedureStore.directory
        for index in 0..<ProcedureStore.maximumRecords {
            try Data("{}".utf8).write(to: URL(fileURLWithPath: folder + "/invalid-\(index).json"))
        }
        let recall = try AgentMemoryAccess(projectRoot: root).recall(query: "orchidRegistry timeout", at: now)
        XCTAssertTrue(recall.issues.contains { $0.lowercased().contains("procedure") },
                      "exceeding the procedure inventory bound must be disclosed")
    }

    func testBlankReinforcementSourceCannotRefreshExistingProcedure() throws {
        let old = try deposit()
        let result = store.reinforce(id: old.id, verifiedSource: " \n ", at: now)
        XCTAssertNil(result.procedure, "an existing source does not validate an empty new confirmation")
        XCTAssertNotNil(result.issue)
        XCTAssertEqual(store.latest(id: old.id), old, "refusal must preserve the original anchor and version")
    }

    func testReusingSameSourceCannotBecomeAnotherConfirmation() throws {
        let old = try deposit()
        let result = store.reinforce(id: old.id, verifiedSource: "synthetic-signoff:original", at: now)
        XCTAssertNil(result.procedure, "the same evidence is not a new verified reuse")
        XCTAssertNotNil(result.issue)
        XCTAssertEqual(store.latest(id: old.id), old, "replayed evidence must not change the decay anchor")
    }

    func testWhitespaceNormalizationPreservesPublishedIdentity() throws {
        let value = try XCTUnwrap(store.deposit(title: "  Mirror repair \n", task: " cache timeout ",
            steps: "inspect cache", source: "synthetic:one", at: now).procedure)
        XCTAssertEqual(store.latest(id: value.id), value,
                       "normalizing a title or task must not invalidate the published identity")
    }

    func testAcceptedLargeVersionRemainsReadable() throws {
        let steps = String(repeating: "inspect cache\n", count: 1_000)
        let first = try XCTUnwrap(store.deposit(title: "Large procedure", task: "cache repair", steps: steps,
            source: "synthetic:" + String(repeating: "a", count: 950), at: now).procedure)
        for index in 1..<Procedure.maximumSources {
            let next = try XCTUnwrap(store.reinforce(id: first.id,
                verifiedSource: "synthetic:\(index):" + String(repeating: "b", count: 950),
                at: now.addingTimeInterval(Double(index))).procedure)
            XCTAssertEqual(store.latest(id: first.id), next,
                           "the reader must accept every successfully published bounded record")
        }
    }

    func testSourceReplayIsRejectedAfterItLeavesTheVisibleSourceWindow() throws {
        let first = try deposit()
        for index in 1...Procedure.maximumSources {
            XCTAssertNotNil(store.reinforce(id: first.id, verifiedSource: "synthetic:reuse-\(index)",
                at: now.addingTimeInterval(Double(index))).procedure)
        }
        let before = try XCTUnwrap(store.latest(id: first.id))
        XCTAssertFalse(before.sources.contains("synthetic-signoff:original"))
        let replay = store.reinforce(id: first.id, verifiedSource: "synthetic-signoff:original",
                                     at: now.addingTimeInterval(60))
        XCTAssertNil(replay.procedure, "bounded display history does not make old evidence new")
        XCTAssertNotNil(replay.issue)
        XCTAssertEqual(store.latest(id: first.id), before)
    }
}
