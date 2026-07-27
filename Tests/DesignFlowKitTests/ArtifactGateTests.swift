import XCTest
@testable import DesignFlowKit

/// The trust spine, pinned PER STAGE. Every agent kind must be independently
/// gated — a single "the gate works" assertion is insufficient (a missed sibling
/// stage is exactly how boolean-flip theater sneaks back in).
final class ArtifactGateTests: XCTestCase {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testMissingArtifactBlocksEveryStage() {
        let gate = ArtifactGate()
        let ws = tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        for stage in AgentKind.allCases {
            XCTAssertThrowsError(try gate.verify(stage: stage, in: ws),
                                 "\(stage.displayName): missing artifact must block") { error in
                guard case ArtifactGate.GateError.missing = error else {
                    return XCTFail("\(stage.displayName): expected .missing, got \(error)")
                }
            }
        }
    }

    func testEmptyArtifactBlocksEveryStage() throws {
        let gate = ArtifactGate()
        let ws = tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        for stage in AgentKind.allCases {
            let fileURL = ws.appendingPathComponent(stage.artifactPath)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "".write(to: fileURL, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try gate.verify(stage: stage, in: ws),
                                 "\(stage.displayName): empty artifact must block") { error in
                guard case ArtifactGate.GateError.empty = error else {
                    return XCTFail("\(stage.displayName): expected .empty, got \(error)")
                }
            }
        }
    }

    /// The Codex finding: a reused workspace's stale artifact must NOT satisfy the
    /// gate. If the file predates the stage and its mtime never advanced, block.
    func testStaleArtifactBlocksEveryStage() throws {
        let gate = ArtifactGate()
        let ws = tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        for stage in AgentKind.allCases {
            let fileURL = ws.appendingPathComponent(stage.artifactPath)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "stale content from a prior run".write(to: fileURL, atomically: true, encoding: .utf8)
            // prior == the file's own current mtime; nothing rewrites it afterward.
            let prior = ArtifactGate.modificationTime(fileURL)
            XCTAssertNotNil(prior, "\(stage.displayName): could not read mtime")
            XCTAssertThrowsError(try gate.verify(stage: stage, in: ws, priorModification: prior),
                                 "\(stage.displayName): stale artifact must block") { error in
                guard case ArtifactGate.GateError.stale = error else {
                    return XCTFail("\(stage.displayName): expected .stale, got \(error)")
                }
            }
        }
    }

    /// A file that WAS advanced after the snapshot passes (real fresh work).
    func testFreshlyRewrittenArtifactPassesEveryStage() throws {
        let gate = ArtifactGate()
        let ws = tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        for stage in AgentKind.allCases {
            let fileURL = ws.appendingPathComponent(stage.artifactPath)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Snapshot a prior time in the distant past, then write "now".
            let prior = Date(timeIntervalSince1970: 0)
            try "fresh output".write(to: fileURL, atomically: true, encoding: .utf8)
            XCTAssertNoThrow(try gate.verify(stage: stage, in: ws, priorModification: prior),
                             "\(stage.displayName): freshly written artifact must pass")
        }
    }

    func testNonEmptyArtifactPassesEveryStage() throws {
        let gate = ArtifactGate()
        let ws = tempDir()
        defer { try? FileManager.default.removeItem(at: ws) }
        for stage in AgentKind.allCases {
            let fileURL = ws.appendingPathComponent(stage.artifactPath)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "real content".write(to: fileURL, atomically: true, encoding: .utf8)
            XCTAssertNoThrow(try gate.verify(stage: stage, in: ws),
                             "\(stage.displayName): non-empty artifact must pass")
        }
    }
}
