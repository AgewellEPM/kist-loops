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

    func testSeedCreatesPreferencesWithStyle() throws {
        try cortex.seedIfNeeded()
        let prefs = cortex.show("preferences.md")
        XCTAssertNotNil(prefs)
        XCTAssertTrue(prefs!.contains("MODULAR"))
        XCTAssertTrue(prefs!.contains("≤1000 lines"))
    }

    func testRememberAppendsLearnedFact() throws {
        try cortex.remember("Luke prefers SwiftUI over UIKit for new views")
        let prefs = cortex.show("preferences.md")!
        XCTAssertTrue(prefs.contains("SwiftUI over UIKit"))
        XCTAssertTrue(prefs.contains("MODULAR"))   // seeded too
    }

    func testProjectMemory() throws {
        try cortex.rememberProject("kist", "the verify spine is the moat")
        XCTAssertTrue(cortex.show("projects/kist.md")!.contains("verify spine is the moat"))
    }

    func testDailyJournal() throws {
        try cortex.logWork("built the cortex memory system", date: "2026-06-29")
        try cortex.logWork("added the review batcher", date: "2026-06-29")
        let day = cortex.show("journal/2026-06-29.md")!
        XCTAssertTrue(day.contains("built the cortex memory system"))
        XCTAssertTrue(day.contains("added the review batcher"))
        XCTAssertTrue(day.contains("# 2026-06-29"))
    }

    func testContextAssemblesPreferencesProjectAndJournal() throws {
        try cortex.seedIfNeeded()
        try cortex.rememberProject("kist", "moat is verification")
        try cortex.logWork("shipped apply_patch", date: "2026-06-29")
        let ctx = cortex.context(projectName: "kist", journalDays: 3)
        XCTAssertTrue(ctx.contains("WHAT KIST KNOWS ABOUT YOU"))
        XCTAssertTrue(ctx.contains("PROJECT MEMORY (kist)"))
        XCTAssertTrue(ctx.contains("moat is verification"))
        XCTAssertTrue(ctx.contains("shipped apply_patch"))
        XCTAssertTrue(ctx.contains("`cortex` tool"), "injected memory nudges the agent to keep it current")
    }

    func testFilesListsEverythingForVisibility() throws {
        try cortex.seedIfNeeded()
        try cortex.rememberProject("kist", "x")
        try cortex.logWork("y", date: "2026-06-29")
        let files = cortex.files()
        XCTAssertTrue(files.contains("preferences.md"))
        XCTAssertTrue(files.contains("projects/kist.md"))
        XCTAssertTrue(files.contains("journal/2026-06-29.md"))
    }

    // SECURITY: a name/date can't traverse out of the cortex dir.
    func testSafeNameBlocksTraversal() throws {
        try cortex.rememberProject("../../evil", "x")
        XCTAssertFalse(FileManager.default.fileExists(atPath: NSString(string: root + "/../../evil.md").standardizingPath))
        XCTAssertEqual(CortexMemory.safe("../../etc/passwd"), "------etc-passwd")
    }

    // SECURITY (Codex HIGH): a secret in a cortex write is REDACTED, never persisted in plaintext.
    func testSecretsAreRedactedOnWrite() throws {
        try cortex.remember("my key is sk-ant-abcdefghijklmnopqrstuvwxyz0123456789 keep it")
        let prefs = cortex.show("preferences.md") ?? ""
        XCTAssertFalse(prefs.contains("sk-ant-abcdefghijklmnopqrstuvwxyz0123456789"), "secret must not persist")
        try cortex.rememberProject("kist", "AKIA1234567890ABCDEF is the aws id")
        XCTAssertEqual(cortex.show("projects/kist.md")?.contains("AKIA1234567890ABCDEF"), false)
    }

    func testSecretInProjectNameOrHeaderRedacted() throws {
        // A secret in the project NAME must not survive in the filename OR the header (Codex r2).
        try cortex.rememberProject("ghp_012345678901234567890123456789012345", "note")
        for f in cortex.files() where f.hasPrefix("projects/") {
            XCTAssertFalse(f.contains("ghp_012345678901234567890123456789012345"), "secret in filename")
            XCTAssertEqual(cortex.show(f)?.contains("ghp_012345678901234567890123456789012345"), false, "secret in header")
        }
    }

    // Codex LOW: /cortex show can't traverse out of the cortex root.
    func testShowRefusesTraversal() throws {
        try cortex.seedIfNeeded()
        XCTAssertNil(cortex.show("../../../etc/passwd"))
        XCTAssertNil(cortex.show("/etc/passwd"))
        XCTAssertNotNil(cortex.show("preferences.md"))   // legit read still works
    }

    // Codex MED: a cortex file can't grow unbounded — over the cap, an append is refused.
    func testFileSizeCapEnforced() throws {
        let big = String(repeating: "x", count: CortexMemory.maxEntryChars)
        // Many capped entries eventually exceed the file cap → the next append throws CortexError.full.
        XCTAssertThrowsError(try { for _ in 0..<200 { try cortex.remember(big) } }()) { e in
            guard case CortexMemory.CortexError.full = e else { return XCTFail("expected .full, got \(e)") }
        }
    }
}
