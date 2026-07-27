import XCTest
@testable import AgentCore

/// L2 preflight guardrail: warn iff an UNARMED run holds host-control TCC grants. Pure logic tested with
/// injected grant state (the live grant is machine-dependent).
final class HostControlPreflightTests: XCTestCase {
    func testArmedNeverWarnsRegardlessOfGrants() {
        XCTAssertNil(HostControlPreflight.warning(enableComputerUse: true, heldGrants: ["Accessibility"]))
        XCTAssertNil(HostControlPreflight.warning(enableComputerUse: true, heldGrants: ["Accessibility", "Screen Recording"]))
    }

    func testUnarmedWithoutGrantsDoesNotWarn() {
        XCTAssertNil(HostControlPreflight.warning(enableComputerUse: false, heldGrants: []))
    }

    func testUnarmedWithGrantsWarnsAndNamesThem() {
        let w = HostControlPreflight.warning(enableComputerUse: false, heldGrants: ["Accessibility", "Screen Recording"])
        XCTAssertNotNil(w)
        XCTAssertTrue(w!.contains("Accessibility"))
        XCTAssertTrue(w!.contains("Screen Recording"))
        XCTAssertTrue(w!.contains("--enable-computer-use"), "the warning tells the operator how to arm intentionally")
    }
}
