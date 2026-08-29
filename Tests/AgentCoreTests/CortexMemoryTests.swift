import XCTest
@testable import AgentCore

final class CortexMemoryTests: XCTestCase {
    private var root: String!
    private var cortex: CortexMemory!
    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "cortex-\(UUID().uuidString)"
        cortex = CortexMemory(root: root)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    private func writeRaw(_ relative: String, _ body: String) throws {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try body.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testLegacyMarkdownIsVisibleForAuditButNeverOperationalContext() throws {
        try writeRaw("preferences.md", "MODEL-WRITTEN PREFERENCE MUST STAY RAW")
        try writeRaw("projects/kist.md", "MODEL-WRITTEN PROJECT FACT MUST STAY RAW")
        try writeRaw("journal/2026-06-29.md", "MODEL-WRITTEN JOURNAL MUST STAY RAW")

        XCTAssertEqual(cortex.context(projectName: "kist", journalDays: 30), "")
        XCTAssertEqual(cortex.show("preferences.md"),
                       "MODEL-WRITTEN PREFERENCE MUST STAY RAW")
        XCTAssertEqual(Set(cortex.files()), [
            "preferences.md", "projects/kist.md", "journal/2026-06-29.md",
        ])
    }

    func testEveryRuntimeMutationFailsClosedWithoutCreatingFiles() {
        for operation in [
            { try self.cortex.seedIfNeeded() },
            { try self.cortex.remember("new preference") },
            { try self.cortex.rememberProject("kist", "new fact") },
            { try self.cortex.logWork("new journal", date: "2026-06-29") },
        ] {
            XCTAssertThrowsError(try operation()) { error in
                guard case CortexMemory.CortexError.auditOnly = error else {
                    return XCTFail("expected audit-only refusal, got \(error)")
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root))
    }

    func testSafeNameAndShowContainmentRemainFailClosed() throws {
        try writeRaw("preferences.md", "operator audit")
        XCTAssertEqual(CortexMemory.safe("../../etc/passwd"), "------etc-passwd")
        XCTAssertNil(cortex.show("../../../etc/passwd"))
        XCTAssertNil(cortex.show("/etc/passwd"))
        XCTAssertEqual(cortex.show("preferences.md"), "operator audit")
    }
}
