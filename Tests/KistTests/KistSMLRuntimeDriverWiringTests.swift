import XCTest
@testable import Kist
@testable import AgentCore

final class KistSMLRuntimeDriverWiringTests: XCTestCase {
    func testLaunchProbeRejectsAmbiguousDriversAndAllowsHonestParking() throws {
        let catalog = SMLExecutionAdmissionCatalog(
            toolCapabilities: ["duplicate", "unbound"]
        )
        let ambiguous = SMLCapabilityRouter(drivers: [
            ProbeDriver(id: "driver-a", reference: "duplicate"),
            ProbeDriver(id: "driver-b", reference: "duplicate"),
        ])
        XCTAssertThrowsError(
            try KistRunner.requireDisjointSMLDrivers(router: ambiguous, catalog: catalog)
        ) { error in
            XCTAssertEqual(
                error as? SMLCapabilityRouterError,
                .ambiguousDrivers(["driver-a", "driver-b"])
            )
        }

        let disjoint = SMLCapabilityRouter(drivers: [
            ProbeDriver(id: "driver-a", reference: "duplicate"),
        ])
        XCTAssertNoThrow(
            try KistRunner.requireDisjointSMLDrivers(router: disjoint, catalog: catalog),
            "an admitted reference with no configured driver must remain visibly parked"
        )
    }
}

private struct ProbeDriver: SMLInstructionDriver {
    let id: String
    let reference: String

    func supports(_ request: SMLCapabilityRequest) -> Bool {
        request.operation == .callTool && request.reference == reference
    }

    func execute(
        _ invocation: SMLCapabilityInvocation
    ) async throws -> SMLCapabilityOutcome {
        throw ProbeDriverError.executionMustNotBeCalledByLaunchProbe
    }
}

private enum ProbeDriverError: Error {
    case executionMustNotBeCalledByLaunchProbe
}
