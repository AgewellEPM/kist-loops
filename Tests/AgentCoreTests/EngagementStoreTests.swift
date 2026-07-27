import XCTest
@testable import AgentCore

final class EngagementStoreTests: XCTestCase {
    private var tmp: String!
    private var store: EngagementStore!

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "kist-eng-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        store = EngagementStore(root: tmp)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: tmp) }

    private func eng(_ id: String, repos: [String] = ["acme/web"]) -> SecurityEngagement {
        SecurityEngagement(id: id, program: "P", attestedBy: "luke", attestedAtISO: "2026-06-29T00:00:00Z",
                           targets: repos.map { SecurityTarget(kind: .repo, value: $0) },
                           safeHarbor: true, rulesURL: nil, testingLimits: ["no destructive payloads"])
    }

    func testSaveLoadRoundTrip() throws {
        let e = eng("acme-2026")
        try store.save(e)
        let back = try store.load(id: "acme-2026")
        XCTAssertEqual(back, e)
        XCTAssertTrue(back!.inScope(repo: "acme/web").isInScope)
    }

    func testLoadMissingIsNil() throws {
        XCTAssertNil(try store.load(id: "nope"))
    }

    func testListReturnsAllSortedById() throws {
        try store.save(eng("b"))
        try store.save(eng("a"))
        try store.save(eng("c"))
        XCTAssertEqual(store.list().map(\.id), ["a", "b", "c"])
    }

    func testSaveOverwrites() throws {
        try store.save(eng("x", repos: ["acme/web"]))
        try store.save(eng("x", repos: ["acme/api"]))
        let back = try store.load(id: "x")
        XCTAssertTrue(back!.inScope(repo: "acme/api").isInScope)
        XCTAssertFalse(back!.inScope(repo: "acme/web").isInScope)
        XCTAssertEqual(store.list().count, 1)
    }

    func testDeleteRevokes() throws {
        try store.save(eng("gone"))
        try store.delete(id: "gone")
        XCTAssertNil(try store.load(id: "gone"))
        try store.delete(id: "gone")   // idempotent no-op
    }

    // path-traversal: a malicious id must not escape the store dir.
    func testTraversalIdIsSanitized() throws {
        try store.save(eng("../../etc/passwd"))
        // The file lands inside the store (sanitized), not at the traversal target.
        let escaped = FileManager.default.fileExists(atPath: tmp + "/../../etc/passwd.json")
        XCTAssertFalse(escaped)
        XCTAssertEqual(store.list().count, 1)   // it IS retrievable, just safely named
    }

    // a corrupt authorization file must surface loudly (throw), never be coerced into an empty scope.
    func testCorruptFileThrowsOnLoadAndIsSkippedInList() throws {
        try store.save(eng("good"))
        let badPath = tmp + "/" + EngagementStore.safe("bad") + ".json"
        try "{ not valid json".write(toFile: badPath, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load(id: "bad"))      // present-but-corrupt → loud
        XCTAssertEqual(store.list().map(\.id), ["good"])     // one bad file doesn't hide the valid one
    }
}
