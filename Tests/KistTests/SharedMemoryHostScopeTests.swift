import XCTest
@testable import Kist
@testable import AgentCore

final class SharedMemoryHostScopeTests: XCTestCase {
    func testLegacySupplementalReadersRemainInHostProjectWhileHistoryCanSpanGrants() throws {
        let root = NSTemporaryDirectory() + "host-memory-scope-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        for name in ["current", "foreign", "catalog"] {
            try FileManager.default.createDirectory(atPath: root + "/" + name, withIntermediateDirectories: true)
        }
        let current = try XCTUnwrap(ToolContext.canonicalize(root + "/current"))
        let foreign = try XCTUnwrap(ToolContext.canonicalize(root + "/foreign"))
        let now = Date()
        for project in [current, foreign] {
            let store = OrganizationalLearningStore(projectRoot: project)
            XCTAssertTrue(store.appendGenericMemory(DiskMemoryRecord(id: "fixture", title: "legacyOrchid",
                summary: "clocked supplemental observation"), to: store.knowledgeIndexPath, at: now))
            XCTAssertTrue(store.memoryCandidates(at: now).contains { $0.recordID == "fixture" })
        }
        var opts = KistOptions(project: current); opts.allowReadPaths = [foreign]
        let access = try XCTUnwrap(KistRunner.sharedAgentMemory(root: current, opts: opts,
            projectCatalogRoot: root + "/catalog"))
        let recall = try XCTUnwrap(access.supplementalRecall)
        XCTAssertTrue(recall(current, "legacyOrchid", now).contains { $0.id == "fixture" })
        XCTAssertTrue(recall(foreign, "legacyOrchid", now).isEmpty)
        XCTAssertEqual(try access.selectedProject(foreign).canonicalPath, foreign)
    }

    func testNoMemoryDoesNotCreateProjectCatalog() throws {
        let root = NSTemporaryDirectory() + "host-memory-off-" + UUID().uuidString
        var opts = KistOptions(project: root); opts.noMemory = true
        XCTAssertNil(try KistRunner.sharedAgentMemory(root: root, opts: opts, projectCatalogRoot: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root))
    }
}
