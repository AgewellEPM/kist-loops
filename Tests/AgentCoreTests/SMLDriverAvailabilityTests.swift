import XCTest
@testable import AgentCore

final class SMLDriverAvailabilityTests: XCTestCase {
    func testAdmittedMissingToolHasNoRouteBeforeClaim() throws {
        let driver = SMLToolCapabilityDriver(
            allowedCapabilities: ["missing.build", "read_file"],
            registry: ToolRegistry([ReadFileTool()]),
            context: ToolContext(projectRoot: "/unused"))
        let router = SMLCapabilityRouter(drivers: [driver])
        XCTAssertThrowsError(try router.driverID(for: SMLCapabilityRouter.probeRequest(
            operation: .callTool, reference: "missing.build"))) { error in
            XCTAssertEqual(error as? SMLCapabilityRouterError,
                           .noDriver(operation: "CALL_TOOL", reference: "missing.build"))
        }
        XCTAssertEqual(try router.driverID(for: SMLCapabilityRouter.probeRequest(
            operation: .callTool, reference: "read_file")), driver.id)
        XCTAssertFalse(driver.supports(SMLCapabilityRouter.probeRequest(
            operation: .callTool, reference: "write_file")))
    }

    func testObservationRequiresInstalledReadOnlyImplementationBeforeClaim() throws {
        let driver = SMLObservationCapabilityDriver(
            allowedSources: ["missing.sensor", "write_file", "read_file"],
            registry: ToolRegistry([ReadFileTool(), WriteFileTool(), ListFilesTool()]),
            context: ToolContext(projectRoot: "/unused"))
        let router = SMLCapabilityRouter(drivers: [driver])
        for name in ["missing.sensor", "write_file", "list_files"] {
            XCTAssertThrowsError(try router.driverID(for: SMLCapabilityRouter.probeRequest(
                operation: .observe, reference: name))) { error in
                XCTAssertEqual(error as? SMLCapabilityRouterError,
                               .noDriver(operation: "OBSERVE", reference: name))
            }
        }
        XCTAssertEqual(try router.driverID(for: SMLCapabilityRouter.probeRequest(
            operation: .observe, reference: "read_file")), driver.id)
    }
}
