import XCTest
@testable import Kist

/// Pins the NL sandbox-control contract: the exact phrases Luke uses MUST fire, and ordinary
/// work/questions must NEVER be hijacked into booting a VM. Per-phrase assertions (multi-site
/// discipline) so a regression names the phrase that broke, not just "parsing changed".
final class SandboxIntentTests: XCTestCase {

    // MARK: positives — the commands Luke asked for, verbatim shapes

    func testRunItHeadless() {
        XCTAssertEqual(SandboxIntent.parse("run it headless"), .run(mode: "headless", pos: nil))
    }
    func testRunHeadless() {
        XCTAssertEqual(SandboxIntent.parse("run headless"), .run(mode: "headless", pos: nil))
    }
    func testRunSandboxHeadless() {
        XCTAssertEqual(SandboxIntent.parse("run the sandbox headless"), .run(mode: "headless", pos: nil))
    }
    func testSmallWindowAtTop() {
        XCTAssertEqual(SandboxIntent.parse("run it in a small window sitting at the top of my screen"),
                       .run(mode: "window", pos: "top"))
    }
    func testWindowNoPos() {
        XCTAssertEqual(SandboxIntent.parse("run it in a window"), .run(mode: "window", pos: nil))
    }
    func testOpenSandboxWindow() {
        XCTAssertEqual(SandboxIntent.parse("open the sandbox in a window"), .run(mode: "window", pos: nil))
    }
    func testFullWindow() {
        XCTAssertEqual(SandboxIntent.parse("run the sandbox in a full window"), .run(mode: "full", pos: nil))
    }
    func testTopLeftPos() {
        XCTAssertEqual(SandboxIntent.parse("run it in a small window in the top left corner"),
                       .run(mode: "window", pos: "topleft"))
    }
    func testBareSandboxRunDefaultsHeadless() {
        // No presentation named → headless (visibility must be opt-in, never a surprise window).
        XCTAssertEqual(SandboxIntent.parse("spin up the sandbox"), .run(mode: "headless", pos: nil))
    }
    func testStop() {
        XCTAssertEqual(SandboxIntent.parse("stop the sandbox"), .stop)
        XCTAssertEqual(SandboxIntent.parse("shut down the sandbox"), .stop)
    }
    func testStatus() {
        XCTAssertEqual(SandboxIntent.parse("sandbox status"), .status)
    }

    // MARK: negatives — a mention is not a command

    func testQuestionsNeverFire() {
        XCTAssertNil(SandboxIntent.parse("what is headless mode?"))
        XCTAssertNil(SandboxIntent.parse("how does the sandbox work"))
        XCTAssertNil(SandboxIntent.parse("explain the sandbox window placement"))
    }
    func testOtherHeadlessWorkNotHijacked() {
        // "headless" about OTHER work must not boot a VM.
        XCTAssertNil(SandboxIntent.parse("run the tests headless"))
        XCTAssertNil(SandboxIntent.parse("run the agent loop headless"))
        XCTAssertNil(SandboxIntent.parse("start the build headless"))
    }
    func testSandboxNounOutranksWorkNoun() {
        // Naming the sandbox explicitly wins even when a work noun appears.
        XCTAssertEqual(SandboxIntent.parse("run the sandbox headless"), .run(mode: "headless", pos: nil))
    }
    func testOrdinaryWorkNeverFires() {
        XCTAssertNil(SandboxIntent.parse("build a login page"))
        XCTAssertNil(SandboxIntent.parse("open safari and check youtube"))
        XCTAssertNil(SandboxIntent.parse("run the deploy script"))
    }
    func testLongProseNeverFires() {
        let prose = String(repeating: "we should think about the sandbox window strategy ", count: 5)
        XCTAssertNil(SandboxIntent.parse(prose))
    }
    func testWindowsOSMentionNotHijacked() {
        // "windows" (the OS) contains "window" — a win98 ask must stay with the legacy router.
        XCTAssertNil(SandboxIntent.parse("install winamp on windows 98"))
    }

    // MARK: wrapper resolution

    func testWrapperPathEnvOverrideWins() {
        setenv("KIST_VMSANDBOX", "/tmp/fake-vmsandbox", 1)
        defer { unsetenv("KIST_VMSANDBOX") }
        XCTAssertEqual(SandboxIntent.wrapperPath(), "/tmp/fake-vmsandbox")
    }
}
