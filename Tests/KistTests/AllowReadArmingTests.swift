import XCTest
import AgentCore
@testable import Kist

/// `--allow-read <dir>`: extra READ-ONLY roots for the file tools (e.g. /Volumes for a CD/USB
/// drive). Same fail-closed arming contract as the other flags: explicit, repeatable, and NEVER
/// inherited by a nested kist (an agent spawning `kist --allow-read /` must not widen its own
/// read surface).
final class AllowReadArmingTests: XCTestCase {

    func testOffByDefault() {
        unsetenv("KIST_ACTIVE")
        let o = KistOptions.parse(["do a thing"])
        XCTAssertTrue(o.allowReadPaths.isEmpty, "external read roots are DEFAULT-DENY")
    }

    func testRepeatableFlagCollectsRoots() {
        unsetenv("KIST_ACTIVE")
        let o = KistOptions.parse(["--allow-read", "/Volumes", "--allow-read", "/tmp/cd", "go"])
        XCTAssertEqual(o.allowReadPaths, ["/Volumes", "/tmp/cd"])
        XCTAssertEqual(o.goal, "go")
    }

    func testMissingArgumentIsAnOptionError() {
        unsetenv("KIST_ACTIVE")
        let o = KistOptions.parse(["--allow-read"])
        XCTAssertTrue(o.allowReadPaths.isEmpty)
        XCTAssertTrue(o.optionErrors.contains { $0.contains("--allow-read") },
                      "a dangling --allow-read must be surfaced, not silently ignored")
    }

    func testNestedKistNeverInheritsReadRoots() {
        setenv("KIST_ACTIVE", "1", 1)
        defer { unsetenv("KIST_ACTIVE") }
        let o = KistOptions.parse(["--allow-read", "/Volumes", "do a thing"])
        XCTAssertTrue(o.allowReadPaths.isEmpty, "a nested kist must NOT self-widen its read surface")
        XCTAssertTrue(o.nestedRefusedEscalation, "the strip is surfaced, never silent")
    }
}
