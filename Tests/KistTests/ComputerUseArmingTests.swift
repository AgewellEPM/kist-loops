import XCTest
import AgentCore
@testable import Kist

/// Council-mandated (2026-07-03) default-deny + no-self-escalation for computer-use.
/// - Computer-use is DEFAULT-DENY: armed only with --enable-computer-use (verified at the wiring in
///   KistRunner.buildExtraTools; the flag is the single gate).
/// - A NESTED kist (spawned by an agent's run_command → `kist …`, so KIST_ACTIVE is inherited) must REFUSE
///   to self-escalate: no computer-use arming, no guards-off. Closes the self-reinvocation path the council
///   found (unattended desktop control on an Accessibility-granted machine).
final class ComputerUseArmingTests: XCTestCase {

    func testTopLevelKistCanArmComputerUse() {
        unsetenv("KIST_ACTIVE")                                   // ensure we're not seen as nested
        let o = KistOptions.parse(["--enable-computer-use", "do a thing"])
        XCTAssertTrue(o.enableComputerUse, "the top-level user invocation CAN arm computer-use")
        XCTAssertFalse(o.nestedRefusedEscalation)
    }

    func testUnarmedByDefault() {
        unsetenv("KIST_ACTIVE")
        let o = KistOptions.parse(["do a thing"])
        XCTAssertFalse(o.enableComputerUse, "computer-use is DEFAULT-DENY — off unless explicitly armed")
    }

    func testNestedKistRefusesArmingAndGuardsOff() {
        setenv("KIST_ACTIVE", "1", 1)                            // simulate being spawned by a parent kist
        defer { unsetenv("KIST_ACTIVE") }
        let o = KistOptions.parse(["--enable-computer-use", "--yolo", "do a thing"])
        XCTAssertFalse(o.enableComputerUse, "a nested kist must NOT arm computer-use (self-escalation)")
        XCTAssertFalse(o.yolo, "a nested kist must NOT drop guards")
        XCTAssertFalse(o.auto, "a nested kist must NOT enter autopilot")
        XCTAssertTrue(o.nestedRefusedEscalation, "the refusal is flagged so the runner can surface it, not silent")
    }
}
