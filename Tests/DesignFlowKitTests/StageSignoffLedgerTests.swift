import XCTest
import AgentCore
@testable import DesignFlowKit

/// The ForgeSeal-sealed signoff chain. Proves both guards independently:
/// per-entry HMAC seal AND the hash chain, both fail-closed on tamper.
final class StageSignoffLedgerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Deterministic, disk-free key for the whole test (no ~/.mythos writes).
        ForgeSeal.forceEphemeralKeyForTesting()
    }
    override func tearDown() {
        ForgeSeal.resetCacheForTesting()
        super.tearDown()
    }

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("signoff-\(UUID().uuidString).jsonl")
    }

    func testAppendBuildsAnIntactSealedChain() throws {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url) }
        let ledger = StageSignoffLedger(fileURL: url)
        let stages: [AgentKind] = [.uiDesigner, .designAnalyst, .developer, .buildArchitect]
        for (i, stage) in stages.enumerated() {
            let s = try ledger.append(projectID: "proj", stage: stage, artifactPath: stage.artifactPath,
                                      commitSHA: "sha\(i)", artifactHash: "ah", committedPaths: [stage.artifactPath], atEpoch: Double(1000 + i))
            XCTAssertEqual(s.seq, i)
            XCTAssertTrue(s.sealValid, "\(stage.displayName): seal must verify")
        }
        let entries = ledger.entries()
        XCTAssertEqual(entries.count, stages.count)
        XCTAssertNil(ledger.verifyChain(), "chain must be intact")
        // Per-stage: every declared stage has a sealed, chain-linked entry.
        for (i, stage) in stages.enumerated() {
            XCTAssertEqual(entries[i].stage, stage, "\(stage.displayName): wrong stage at seq \(i)")
            XCTAssertTrue(entries[i].sealValid)
        }
    }

    func testTamperedFieldFailsSealAndTruncatesTail() throws {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url) }
        let ledger = StageSignoffLedger(fileURL: url)
        try ledger.append(projectID: "p", stage: .uiDesigner, artifactPath: "a", commitSHA: "s0", artifactHash: "ah", committedPaths: ["a"], atEpoch: 1)
        try ledger.append(projectID: "p", stage: .designAnalyst, artifactPath: "b", commitSHA: "s1", artifactHash: "ah", committedPaths: ["b"], atEpoch: 2)
        XCTAssertEqual(ledger.entries().count, 2)

        // Flip the commitSHA of entry 0 on disk WITHOUT re-sealing — canonical changes, seal breaks.
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        lines[0] = lines[0].replacingOccurrences(of: "\"commitSHA\":\"s0\"", with: "\"commitSHA\":\"HACKED\"")
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(ledger.verifyChain(), 0, "tampered entry 0 must be the first broken link")
        XCTAssertEqual(ledger.entries().count, 0, "a broken head drops the whole tail (fail-closed)")
    }

    func testBrokenChainHashIsDetected() throws {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url) }
        let ledger = StageSignoffLedger(fileURL: url)
        try ledger.append(projectID: "p", stage: .uiDesigner, artifactPath: "a", commitSHA: "s0", artifactHash: "ah", committedPaths: ["a"], atEpoch: 1)
        try ledger.append(projectID: "p", stage: .designAnalyst, artifactPath: "b", commitSHA: "s1", artifactHash: "ah", committedPaths: ["b"], atEpoch: 2)

        // Corrupt entry 1's prevHash so the chain link no longer matches entry 0.
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        lines[1] = lines[1].replacingOccurrences(of: "\"prevHash\":\"", with: "\"prevHash\":\"deadbeef")
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(ledger.verifyChain(), 1, "the broken link is at seq 1")
        XCTAssertEqual(ledger.entries().count, 1, "only the intact prefix survives")
    }

    func testForeignSealIsRejected() throws {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url) }
        let ledger = StageSignoffLedger(fileURL: url)
        try ledger.append(projectID: "p", stage: .uiDesigner, artifactPath: "a", commitSHA: "s0", artifactHash: "ah", committedPaths: ["a"], atEpoch: 1)
        // Rotate the install key: the previously-valid seal is now foreign → dropped.
        ForgeSeal.forceEphemeralKeyForTesting()
        XCTAssertEqual(ledger.entries().count, 0, "a seal from another key must not verify")
    }
}
