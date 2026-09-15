import XCTest
@testable import Kist
@testable import AgentCore

final class PlanExecuteCorrelationTests: XCTestCase {
    func testStagedExecutionKeepsReplayAtOriginalRoot() throws {
        let root = NSTemporaryDirectory() + "plan-audit-" + UUID().uuidString
        let staging = root + "-staging"
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: staging)
        }
        let bundle = KistRunner.makePlanExecuteCorrelation(
            launchMode: .fresh, freshMissionInstanceID: nil, projectRoot: root,
            providerID: "codex-cli", model: "test", context: ToolContext(projectRoot: staging))
        bundle.runReplay.startTurn(goal: "staged build")
        XCTAssertEqual(bundle.context.projectRoot, staging)
        try FileManager.default.removeItem(atPath: staging)
        XCTAssertEqual(RunReplayStore.read(projectRoot: root, id: bundle.missionID.rawValue).exitCode, 0)
    }

    func testFreshAndResumedMissionUseOneTraceReplayAndToolContextRoot() async throws {
        for launchMode in [PlanExecuteLaunchMode.fresh,
                           .resume(try XCTUnwrap(PlanExecuteMissionID(
                            rawValue: String(repeating: "f", count: 64))))] {
            let root = NSTemporaryDirectory() + "plan-correlation-" + UUID().uuidString
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: root) }
            let supplied = try XCTUnwrap(PlanExecuteMissionID(
                rawValue: String(repeating: "a", count: 64)))
            let bundle = KistRunner.makePlanExecuteCorrelation(
                launchMode: launchMode,
                freshMissionInstanceID: supplied,
                projectRoot: root,
                providerID: "codex-cli",
                model: "gpt-5.6-sol",
                context: ToolContext(projectRoot: root))

            let expected = launchModeMission(launchMode) ?? supplied
            let traceID = await bundle.recorder.traceId
            XCTAssertEqual(bundle.missionID, expected)
            XCTAssertEqual(traceID, expected.rawValue)
            XCTAssertEqual(bundle.runReplay.manifest.runID, expected.rawValue)
            XCTAssertEqual(bundle.context.correlationID, expected.rawValue)
            XCTAssertTrue(bundle.context.traceRecorder === bundle.recorder)
        }
    }

    private func launchModeMission(_ mode: PlanExecuteLaunchMode) -> PlanExecuteMissionID? {
        if case .resume(let mission) = mode { return mission }
        return nil
    }
}
