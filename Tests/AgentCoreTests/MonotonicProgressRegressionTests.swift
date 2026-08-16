import XCTest
@testable import AgentCore

final class MonotonicProgressRegressionTests: XCTestCase {
    func testOnlyTypedMaterialReceiptsAdvanceRevision() {
        var state = MonotonicProgressSnapshot()
        let artifact = ReasoningArtifactReference(id: "artifact", path: "Sources/A.swift",
                                                  revision: "sha-1")
        let receipts: [ReasoningProgressReceipt] = [
            .init(id: "artifact-1", evidence: .artifact(artifact), at: 1),
            .init(id: "effect-1", evidence: .workspaceMutation(
                effectID: "write-1", paths: ["Sources/A.swift"]), at: 2),
            .init(id: "check-1", evidence: .checkTransition(.init(
                id: "tests", name: "tests", state: .passed)), at: 3),
            .init(id: "delegation-1", evidence: .delegationCompleted(
                effectID: "delegate-1", childID: "child", artifactIDs: ["artifact"]), at: 4),
        ]

        for receipt in receipts {
            XCTAssertTrue(MonotonicProgressReducer.apply(receipt, to: &state))
        }
        XCTAssertEqual(state.revision, 4)
        XCTAssertEqual(state.receipts.map(\.id), receipts.map(\.id))
    }

    func testDuplicateEffectsUnchangedArtifactsAndRepeatedChecksDoNotAdvance() {
        var state = MonotonicProgressSnapshot()
        XCTAssertTrue(MonotonicProgressReducer.apply(.init(
            id: "a1", evidence: .artifact(.init(id: "a", path: "a", revision: "1"))),
            to: &state))
        XCTAssertFalse(MonotonicProgressReducer.apply(.init(
            id: "a2", evidence: .artifact(.init(id: "a", path: "a", revision: "1"))),
            to: &state))
        XCTAssertTrue(MonotonicProgressReducer.apply(.init(
            id: "a3", evidence: .artifact(.init(id: "a", path: "a", revision: "2"))),
            to: &state))
        XCTAssertTrue(MonotonicProgressReducer.apply(.init(
            id: "e1", evidence: .externalStateChange(effectID: "deploy", target: "staging")),
            to: &state))
        XCTAssertFalse(MonotonicProgressReducer.apply(.init(
            id: "e2", evidence: .externalStateChange(effectID: "deploy", target: "staging")),
            to: &state))
        XCTAssertTrue(MonotonicProgressReducer.apply(.init(
            id: "c1", evidence: .checkTransition(.init(id: "lint", name: "lint", state: .passed))),
            to: &state))
        XCTAssertFalse(MonotonicProgressReducer.apply(.init(
            id: "c2", evidence: .checkTransition(.init(id: "lint", name: "lint", state: .passed))),
            to: &state))
        XCTAssertEqual(state.revision, 4)
    }

    func testReadListAndSearchCannotDecodeAsProgressEvidence() {
        for operation in ["read", "list", "search"] {
            let json = #"{"# + operation + #"":{"effectID":"success"}}"#
            XCTAssertThrowsError(try JSONDecoder().decode(
                ReasoningProgressEvidence.self, from: Data(json.utf8)),
                "\(operation) success must not be representable as material progress")
        }
    }
}
