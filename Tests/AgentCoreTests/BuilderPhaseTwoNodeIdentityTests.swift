import XCTest
@testable import AgentCore

extension BuilderPhaseTwoTests {
    func testGovernedWorkerIdentityRejectsWrongNodeBeforeVerification() throws {
        XCTAssertNoThrow(
            try BuilderGovernedWorkerIdentity.validate(
                actual: "scheduled-node",
                expected: "scheduled-node"
            )
        )

        XCTAssertThrowsError(
            try BuilderGovernedWorkerIdentity.validate(
                actual: "substituted-node",
                expected: "scheduled-node"
            )
        ) { error in
            XCTAssertEqual(
                error as? BuilderGovernedWorkerIdentityError,
                BuilderGovernedWorkerIdentityError(
                    expected: "scheduled-node",
                    actual: "substituted-node"
                )
            )
        }
    }
}
