import XCTest
@testable import Kist

final class ReplStyleTests: XCTestCase {
    func testModeAliasesParse() {
        XCTAssertEqual(ReplStyle.Mode.parse("deep research"), .science)
        XCTAssertEqual(ReplStyle.Mode.parse("quick"), .build)
        XCTAssertEqual(ReplStyle.Mode.parse("best-friend"), .friend)
        XCTAssertEqual(ReplStyle.Mode.parse("no-bs"), .nobs)
        XCTAssertEqual(ReplStyle.Mode.parse("brutal"), .nobs)
        XCTAssertEqual(ReplStyle.Mode.parse("convo"), .conversation)
        XCTAssertEqual(ReplStyle.Mode.parse("off"), .normal)
        XCTAssertNil(ReplStyle.Mode.parse("banana"))
    }

    func testReadingLevelParse() {
        XCTAssertEqual(ReplStyle.ReadingLevel.parse("1st"), .grade1)
        XCTAssertEqual(ReplStyle.ReadingLevel.parse("grade 3"), .grade3)
        XCTAssertEqual(ReplStyle.ReadingLevel.parse("college"), .college)
        XCTAssertEqual(ReplStyle.ReadingLevel.parse("highschool"), .highSchool)
        XCTAssertEqual(ReplStyle.ReadingLevel.parse("12"), .college)   // 11+ → college
        XCTAssertNil(ReplStyle.ReadingLevel.parse("nope"))
    }

    func testDirectiveReflectsModeAndLevel() {
        var s = ReplStyle(mode: .nobs, readingLevel: .college, persona: nil)
        let d = s.directive() ?? ""
        XCTAssertTrue(d.contains("NO-BS MODE"))
        XCTAssertTrue(d.contains("college"))
        XCTAssertTrue(d.hasPrefix("[STYLE]"))
        // normal + no level + no persona → no directive
        s = ReplStyle()
        XCTAssertNil(s.directive())
        XCTAssertTrue(s.isDefault)
    }

    func testPersonaOverridesModeVoice() {
        let s = ReplStyle(mode: .build, readingLevel: .grade2, persona: "Talk like a calm mentor.")
        let d = s.directive() ?? ""
        XCTAssertTrue(d.contains("PERSONA"))
        XCTAssertTrue(d.contains("calm mentor"))
        XCTAssertFalse(d.contains("QUICK-BUILD MODE"), "an explicit persona replaces the built-in mode voice")
        XCTAssertTrue(d.contains("grade 2"), "reading level still applies alongside a persona")
    }

    func testRoundTripPersistence() throws {
        let root = NSTemporaryDirectory() + "replstyle_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        var s = ReplStyle(); s.mode = .friend; s.readingLevel = .grade5; s.persona = nil
        s.save(projectRoot: root)
        let loaded = ReplStyle.load(projectRoot: root)
        XCTAssertEqual(loaded.mode, .friend)
        XCTAssertEqual(loaded.readingLevel, .grade5)
    }
}
