import XCTest
@testable import AgentCore

final class MemoryForgettingIntegrityTests: XCTestCase {
    private var root = ""
    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private let marker = "OrchidPrivateMarker"

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "forgetting-integrity-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        root = try XCTUnwrap(ToolContext.canonicalize(root))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: root) }

    private func put(_ path: String, _ data: Data) throws {
        _ = try ConfinedRoot(root: root).createDataIfMissing(path, data, createParents: true)
    }

    func testOversizedEpisodeArchiveIsPreservedAndDeletionIsIncomplete() throws {
        let path = ".mythos/memory/episodes.jsonl"
        let unrelated = Data(("unrelated-prefix\n" + String(repeating: "a", count:
            ProjectMemory.defaultMaxEpisodeBytes) + "\n").utf8)
        let original = unrelated + Data((marker + "\n").utf8)
        try put(path, original)
        let result = MemoryForgetting.forget(term: marker, hostRoot: root, at: now)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: root + "/" + path)), original,
                       "forgetting must not compact away unrelated data outside its read budget")
        XCTAssertNotEqual(result.receipt?.residualClean, true)
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(result.receipt?.removed.isEmpty == true)
    }

    func testOversizedProcedureAndOverlayCannotPassResidualScan() throws {
        for directory in [ProcedureStore.directory, MemoryReactivationStore.directory] {
            let path = directory + "/oversized.json"
            try put(path, Data((String(repeating: "x", count: Procedure.maximumRecordBytes + 1)
                               + marker).utf8))
            XCTAssertTrue(MemoryForgetting.residualContains(term: marker, hostRoot: root),
                          "an unreadable store cannot establish absence: \(directory)")
            let result = MemoryForgetting.forget(term: marker, hostRoot: root, at: now)
            XCTAssertNotEqual(result.receipt?.residualClean, true, directory)
            XCTAssertFalse(result.issues.isEmpty, directory)
            try FileManager.default.removeItem(atPath: root + "/" + path)
        }
    }

    func testLinkedEpisodeArchiveCannotAuthorizeDeletionOrCleanReceipt() throws {
        try put("outside.jsonl", Data((marker + "\n").utf8))
        let memory = root + "/.mythos/memory"
        try FileManager.default.createDirectory(atPath: memory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: memory + "/episodes.jsonl",
                                                   withDestinationPath: root + "/outside.jsonl")
        let result = MemoryForgetting.forget(term: marker, hostRoot: root, at: now)
        XCTAssertNotEqual(result.receipt?.residualClean, true)
        XCTAssertTrue(result.receipt?.removed.isEmpty == true)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: memory + "/episodes.jsonl"), root + "/outside.jsonl")
        XCTAssertEqual(try String(contentsOfFile: root + "/outside.jsonl"), marker + "\n")
    }

    func testOverflowInventoryCannotClaimCompleteOrPurgePartialProcedureChain() throws {
        let store = ProcedureStore(projectRoot: root)
        let procedure = try XCTUnwrap(store.deposit(title: "Forget fixture", task: marker,
            steps: "inspect", source: "fixture:one", at: now).procedure)
        for index in 0..<MemoryForgetting.maximumScanRecords {
            try put(ProcedureStore.directory + "/extra-\(index).json", Data("{}".utf8))
        }
        let result = MemoryForgetting.forget(term: marker, hostRoot: root, at: now)
        XCTAssertNotEqual(result.receipt?.residualClean, true)
        XCTAssertFalse(result.issues.isEmpty)
        let retained = try ConfinedRoot(root: root).readStableData(procedure.relativePath,
                                                                  maxBytes: Procedure.maximumRecordBytes)
        XCTAssertEqual(try JSONDecoder().decode(Procedure.self, from: retained), procedure,
                       "an incomplete inventory cannot authorize a whole-chain purge")
    }

    func testEscapedEpisodeTextIsMatchedSemantically() throws {
        let row = "{\"goal\":\"fixture\",\"success\":true,\"summary\":\"Orchid\\u0050rivateMarker\",\"at\":0}\n"
        try put(".mythos/memory/episodes.jsonl", Data(row.utf8))
        let result = MemoryForgetting.forget(term: marker, hostRoot: root, at: now)
        XCTAssertEqual(result.receipt?.removed.filter { $0.store == "episodes" }.count, 1)
        XCTAssertEqual(result.receipt?.residualClean, true)
        XCTAssertEqual(try String(contentsOfFile: root + "/.mythos/memory/episodes.jsonl"), "")
    }

    func testAllProcedureVersionsContributeActualOverlayTargets() throws {
        let store = ProcedureStore(projectRoot: root)
        let first = try XCTUnwrap(store.deposit(title: "Forget fixture", task: marker,
            steps: "inspect", source: "fixture:one", at: now.addingTimeInterval(-120)).procedure)
        let second = try XCTUnwrap(store.reinforce(id: first.id, verifiedSource: "fixture:two",
                                                 at: now.addingTimeInterval(-60)).procedure)
        for procedure in [first, second] {
            let path = root + "/" + procedure.relativePath
            let entry = AgentMemoryEntry(id: "fixture", title: "", text:
                "Applies to: \(procedure.task)\n" + procedure.steps, locator: path,
                observedAt: procedure.temporal.createdAt, temporal: procedure.temporal)
            let object: [String: Any] = ["schema": 2,
                "targetSHA256": MemoryFailureEvidence.target(entry), "signatures": ["unrelated"]]
            try put(MemoryReactivationStore.directory + "/version-\(procedure.version).json",
                    JSONSerialization.data(withJSONObject: object))
        }
        let result = MemoryForgetting.forget(term: marker, hostRoot: root, at: now)
        XCTAssertEqual(result.receipt?.removed.filter { $0.store == "reactivation" }.count, 2,
                       "removing procedure text must also remove version-bound overlays")
        XCTAssertEqual(try ConfinedRoot(root: root).entries(MemoryReactivationStore.directory).count, 0)
    }

    func testRetentionReportsUnreadableDataInBothStores() throws {
        for directory in [MemoryAdmissionAuditLog.directory, MemoryReactivationStore.directory] {
            let path = directory + "/oversized.json"
            try put(path, Data(repeating: 0x61, count: Procedure.maximumRecordBytes + 1))
            let result = MemoryForgetting.retentionSweep(hostRoot: root, at: now)
            XCTAssertFalse(result.issues.isEmpty, directory)
            XCTAssertTrue(result.receipt.removed.isEmpty, directory)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + path))
            try FileManager.default.removeItem(atPath: root + "/" + path)
        }
    }

    func testFailedEpisodeLockPreservesArchiveAndReportsIncomplete() throws {
        let path = ".mythos/memory/episodes.jsonl"
        try put(path, Data((marker + "\n").utf8))
        try FileManager.default.createDirectory(atPath: root + "/" + path + ".lock",
                                                withIntermediateDirectories: false)
        let result = MemoryForgetting.forget(term: marker, hostRoot: root, at: now)
        XCTAssertNotEqual(result.receipt?.residualClean, true)
        XCTAssertTrue(result.receipt?.removed.isEmpty == true)
        XCTAssertEqual(try String(contentsOfFile: root + "/" + path), marker + "\n")
    }

    func testInvalidDeletionDateIsRefusedWithoutMutation() throws {
        let path = ".mythos/memory/episodes.jsonl"
        try put(path, Data((marker + "\n").utf8))
        let result = MemoryForgetting.forget(term: marker, hostRoot: root,
                                             at: Date(timeIntervalSince1970: .infinity))
        XCTAssertNil(result.receipt)
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertEqual(try String(contentsOfFile: root + "/" + path), marker + "\n")
    }
}
