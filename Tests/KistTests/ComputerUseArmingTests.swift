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

    func testExplicitMCPPolicyBlocksExactNeutralNameControlsAndAllowsLSPHover() {
        let controls = [
            "tinky-vision-control__os_click",
            "perslis__vm_control",
            "perslis__vm_launch",
            "vm-guest-isolated__guest_choose",
            "vm-guest-isolated__guest_enter_text",
            "vm-guest-isolated__guest_send_keys",
            "vm-guest-isolated__guest_execute",
        ]
        for name in controls {
            XCTAssertFalse(KistRunner.admitsMCPTool(
                name: name, explicitComputerUseRequirement: true, enableComputerUse: false),
                "explicit control tool must be absent while unarmed: \(name)")
            XCTAssertTrue(KistRunner.admitsMCPTool(
                name: name, explicitComputerUseRequirement: true, enableComputerUse: true),
                "explicit user arming admits the configured control tool: \(name)")
        }

        XCTAssertTrue(KistRunner.admitsMCPTool(
            name: "lsp-swift__hover", explicitComputerUseRequirement: false,
            enableComputerUse: false),
            "explicit no-control metadata must override the legacy 'hover' false positive")
    }

    func testLegacyMCPConfigRetainsConservativeHostControlHeuristic() {
        XCTAssertFalse(KistRunner.admitsMCPTool(
            name: "desktop__click", explicitComputerUseRequirement: nil,
            enableComputerUse: false))
        XCTAssertTrue(KistRunner.admitsMCPTool(
            name: "github__create_issue", explicitComputerUseRequirement: nil,
            enableComputerUse: false))
    }
}
