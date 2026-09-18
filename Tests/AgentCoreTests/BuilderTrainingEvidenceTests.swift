import Foundation
import XCTest
@testable import AgentCore

final class BuilderTrainingEvidenceTests: XCTestCase {
    func testAcceptedRunIsInspectedWithoutChangingItsDurableState() async throws {
        let fixture = BuilderRunTestFixtures.makeStore("training-evidence")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let contract = BuilderRunTestFixtures.contract(id: "training-evidence-contract")
        let graph = try BuilderGraph(nodes: [.init(id: "read", objective: "inspect",
                                                   resources: [.init(path: "Sources", access: .read)])])
        let runner = try BuilderRun(contract: contract, graph: graph, store: fixture.store,
            execute: { BuilderRunTestFixtures.worker(for: $0) },
            verify: { await BuilderRunTestFixtures.passingVerification($0) },
            review: { _ in BuilderRunTestFixtures.approvedReview() })
        _ = try await runner.run()
        let file = fixture.root.appendingPathComponent("run.json")
        let journal = fixture.root.appendingPathComponent(".run.json.high-water")
        let before = try Data(contentsOf: file), journalBefore = try Data(contentsOf: journal)
        let report = try BuilderTrainingEvidence.inspect(before)
        XCTAssertTrue(report.historicalAccepted, report.issues.joined(separator: "; "))
        XCTAssertEqual(report.contractID, contract.id)
        XCTAssertTrue(report.mutations.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try Data(contentsOf: journal), journalBefore)

        var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        changed["seal"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try BuilderTrainingEvidence.inspect(
            JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys, .withoutEscapingSlashes])))
        XCTAssertThrowsError(try BuilderTrainingEvidence.inspect(before + Data("\n".utf8)))
    }

    func testSignedIncompleteSnapshotCannotBecomeASuccessLabel() throws {
        let snapshot = BuilderRunSnapshot(contractID: "pending", route: .direct, nodeStates: [:],
                                          finalReceipt: nil, updatedAt: Date())
        let canonical = try BuilderDurableIO.canonicalData(snapshot)
        let envelope = SealedBuilderRunSnapshot(snapshot: snapshot,
            seal: ForgeSeal.sign(String(decoding: canonical, as: UTF8.self)))
        let report = try BuilderTrainingEvidence.inspect(BuilderDurableIO.canonicalData(envelope))
        XCTAssertFalse(report.historicalAccepted)
        XCTAssertTrue(report.issues.contains("no accepted final receipt"))
    }
}
