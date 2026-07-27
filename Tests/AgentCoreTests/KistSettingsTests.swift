import XCTest
@testable import AgentCore

/// Pins the `.kist/settings.json` model: precedence merge, key=value validation, disk round-trip.
final class KistSettingsTests: XCTestCase {

    // MARK: precedence

    func testProjectOverridesUserFieldByField() {
        let user = KistSettings(model: "gemini", effort: "low", theme: "dark")
        let project = KistSettings(model: "openai:gpt-5.5", theme: nil)   // project sets model, leaves theme
        let eff = project.merged(over: user)
        XCTAssertEqual(eff.model, "openai:gpt-5.5", "project wins where set")
        XCTAssertEqual(eff.effort, "low", "user value survives where project is nil")
        XCTAssertEqual(eff.theme, "dark", "nil in project does not clobber user")
    }

    // MARK: key=value apply

    func testApplyValidEnumValue() {
        let r = KistSettings.apply(KistSettings(), key: "theme", value: "high-contrast")
        guard case let .updated(s, key, value) = r else { return XCTFail("expected updated, got \(r)") }
        XCTAssertEqual(s.theme, "high-contrast")
        XCTAssertEqual(key, "theme"); XCTAssertEqual(value, "high-contrast")
    }

    func testApplyBooleanNormalizesSpellings() {
        for spelling in ["on", "true", "1", "yes", "ON"] {
            let r = KistSettings.apply(KistSettings(), key: "reasoning", value: spelling)
            guard case let .updated(s, _, value) = r else { return XCTFail("expected updated for \(spelling)") }
            XCTAssertEqual(s.reasoning, true); XCTAssertEqual(value, "on")
        }
        let off = KistSettings.apply(KistSettings(), key: "autoCompact", value: "0")
        guard case let .updated(s, _, _) = off else { return XCTFail("expected updated") }
        XCTAssertEqual(s.autoCompact, false)
    }

    func testApplyUnknownKey() {
        guard case .unknownKey("wat") = KistSettings.apply(KistSettings(), key: "wat", value: "x") else {
            return XCTFail("expected unknownKey")
        }
    }

    func testApplyInvalidEnumValue() {
        guard case let .invalidValue(key, value, allowed) =
                KistSettings.apply(KistSettings(), key: "sandbox", value: "yolo") else {
            return XCTFail("expected invalidValue")
        }
        XCTAssertEqual(key, "sandbox"); XCTAssertEqual(value, "yolo")
        XCTAssertTrue(allowed.contains("confined"))
    }

    func testApplyKeyIsCaseInsensitiveButCanonicalizes() {
        let r = KistSettings.apply(KistSettings(), key: "THEME", value: "mono")
        guard case let .updated(_, key, _) = r else { return XCTFail("expected updated") }
        XCTAssertEqual(key, "theme", "key canonicalizes to schema spelling")
    }

    func testFreeFormModelAcceptsAnyValue() {
        let r = KistSettings.apply(KistSettings(), key: "model", value: "deepseek:deepseek-reasoner")
        guard case let .updated(s, _, _) = r else { return XCTFail("expected updated") }
        XCTAssertEqual(s.model, "deepseek:deepseek-reasoner")
    }

    // MARK: disk round-trip

    func testStoreRoundTripAndPrecedenceOnDisk() throws {
        let root = NSTemporaryDirectory() + "kist-settings-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = KistSettingsStore(projectRoot: root)

        store.save(KistSettings(model: "gemini", theme: "dark"), to: .project)
        let loaded = store.loadScope(.project)
        XCTAssertEqual(loaded.model, "gemini")
        XCTAssertEqual(loaded.theme, "dark")
    }

    func testDisplayValueFallsBackToDash() {
        let s = KistSettings(model: "gemini")
        XCTAssertEqual(s.displayValue(forKey: "model"), "gemini")
        XCTAssertEqual(s.displayValue(forKey: "theme"), "—", "unset shows a dash")
        XCTAssertEqual(s.displayValue(forKey: "reasoning"), "—")
    }
}
