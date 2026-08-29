import XCTest
@testable import AgentCore

final class SMLCommandAdmissionTests: XCTestCase {
    func testAdmissionBindsTransportLeaseRegistryScopeAndReplayID() async throws {
        let replay = TestSMLReplayGuard()
        let admitted = try await SMLCommandAdmission.admit(
            candidate(), authority: authority(), nowEpoch: 1_010, replayGuard: replay
        )

        XCTAssertEqual(admitted.commandID, "command-1842")
        XCTAssertEqual(admitted.task, "TASK-1842")
        XCTAssertEqual(admitted.leaseID, "lease-77")

        do {
            _ = try await SMLCommandAdmission.admit(
                candidate(), authority: authority(), nowEpoch: 1_011, replayGuard: replay
            )
            XCTFail("replayed command must fail closed")
        } catch {
            XCTAssertEqual(error as? SMLCommandAdmissionError, .replayedCommand)
        }
    }

    func testAdmissionRejectsSelfAssertedActorAndScopeExpansion() async {
        let replay = TestSMLReplayGuard()
        let wrongActor = SMLCommandAuthority(
            authenticatedActor: "operator.someone_else",
            leaseID: "lease-77",
            roles: ["manager"],
            tasks: ["TASK-1842"],
            operations: ["workflow.run"],
            scope: ["repository": .string("staging")]
        )
        do {
            _ = try await SMLCommandAdmission.admit(
                candidate(), authority: wrongActor, nowEpoch: 1_010, replayGuard: replay
            )
            XCTFail("actor mismatch must fail closed")
        } catch {
            XCTAssertEqual(error as? SMLCommandAdmissionError, .actorMismatch)
        }

        let narrowedAuthority = SMLCommandAuthority(
            authenticatedActor: "operator.luke",
            leaseID: "lease-77",
            roles: ["manager"],
            tasks: ["TASK-1842"],
            operations: ["workflow.run"],
            scope: ["repository": .string("read_only")]
        )
        do {
            _ = try await SMLCommandAdmission.admit(
                candidate(), authority: narrowedAuthority, nowEpoch: 1_010,
                replayGuard: TestSMLReplayGuard()
            )
            XCTFail("scope expansion must fail closed")
        } catch {
            XCTAssertEqual(
                error as? SMLCommandAdmissionError,
                .scopeDenied(path: "scope.repository")
            )
        }
    }

    func testAdmissionRejectsExpiredAndFutureCommandsBeforeReplayClaim() async {
        do {
            _ = try await SMLCommandAdmission.admit(
                candidate(issuedAt: 100), authority: authority(maximumAge: 300),
                nowEpoch: 1_000, replayGuard: TestSMLReplayGuard()
            )
            XCTFail("expired command must fail closed")
        } catch {
            XCTAssertEqual(error as? SMLCommandAdmissionError, .commandExpired)
        }

        do {
            _ = try await SMLCommandAdmission.admit(
                candidate(issuedAt: 1_100), authority: authority(futureSkew: 30),
                nowEpoch: 1_000, replayGuard: TestSMLReplayGuard()
            )
            XCTFail("future command must fail closed")
        } catch {
            XCTAssertEqual(error as? SMLCommandAdmissionError, .commandFromFuture)
        }
    }

    private func candidate(issuedAt: Double = 1_000) -> SMLCommandCandidate {
        let command = SMLCommandEnvelope(
            commandID: "command-1842",
            actor: "operator.luke",
            role: "manager",
            task: "TASK-1842",
            op: "workflow.run",
            scope: ["repository": .string("staging")],
            issuedAtEpoch: issuedAt
        )
        return SMLCommandCandidate(command: command, validationReport: command.validate())
    }

    private func authority(
        maximumAge: Double = 300, futureSkew: Double = 30
    ) -> SMLCommandAuthority {
        SMLCommandAuthority(
            authenticatedActor: "operator.luke",
            leaseID: "lease-77",
            roles: ["manager"],
            tasks: ["TASK-1842"],
            operations: ["workflow.run"],
            scope: ["repository": .string("staging")],
            maximumCommandAgeSeconds: maximumAge,
            maximumFutureSkewSeconds: futureSkew
        )
    }
}

private actor TestSMLReplayGuard: SMLCommandReplayGuard {
    private var claimed = Set<String>()

    func claim(commandID: String, expiresAtEpoch: Double) async throws -> Bool {
        guard expiresAtEpoch.isFinite else { return false }
        return claimed.insert(commandID).inserted
    }
}
