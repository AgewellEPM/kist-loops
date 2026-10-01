import XCTest
@testable import AgentCore

final class ManagedLocalModelTests: XCTestCase {
    let candidate = ManagedLocalModel.catalog[0]
    let endpoint = URL(string: "http://127.0.0.1:11434/api/chat")!

    func testAcquisitionTransportFailureCanFallbackButCancellationStaysCancellation() async {
        for cancel in [false, true] {
            let manager = OllamaModelAcquisition(prepare: { _, _ in
                if cancel { throw CancellationError() }
                throw URLError(.notConnectedToInternet)
            }, hostResources: { (16 * 1_073_741_824, 1) })
            do {
                try await manager.ensure(model: candidate.model, endpoint: endpoint.absoluteString)
                XCTFail("Expected failure")
            } catch is CancellationError {
                XCTAssertTrue(cancel)
            } catch let error as AIProviderError {
                XCTAssertFalse(cancel)
                guard case .transport(let reason) = error else { return XCTFail("Must use bounded provider fallback") }
                XCTAssertTrue(reason.hasPrefix("Local model unavailable:"))
            } catch { XCTFail("Unclassified acquisition failure: \(error)") }
        }
    }

    func testInventoryReuseNeedsNoNetworkMetadataOrDownload() async throws {
        let fixture = Fixture(candidate: candidate, installed: true)
        try await prepare(fixture)
        XCTAssertEqual(fixture.calls, ["tags"])
    }

    func testMissingModelChecksMetadataAndVerifiesDigestAfterDownload() async throws {
        let fixture = Fixture(candidate: candidate)
        try await prepare(fixture)
        XCTAssertEqual(fixture.calls, ["tags", "metadata", "download", "tags"])
    }

    func testBadLicenseLowDiskOrChangedDigestNeverBecomeReady() async {
        for scenario in ["license", "disk", "digest", "already-changed"] {
            let fixture = Fixture(candidate: candidate, installed: scenario == "already-changed")
            fixture.badLicense = scenario == "license"
            fixture.badDigest = scenario == "digest" || scenario == "already-changed"
            do {
                try await prepare(fixture, disk: scenario == "disk" ? 0 : 32 * 1_073_741_824)
                XCTFail("Unexpected readiness: \(scenario)")
            } catch { }
            if scenario != "digest" { XCTAssertFalse(fixture.calls.contains("download")) }
        }
    }

    func testMemoryPressureAndSmallHostsRejectLargeModel() {
        XCTAssertTrue(candidate.fits(memoryBytes: 16 * 1_073_741_824, memoryPressure: 1))
        XCTAssertFalse(candidate.fits(memoryBytes: 8 * 1_073_741_824, memoryPressure: 0))
        XCTAssertTrue(candidate.fits(memoryBytes: 16 * 1_073_741_824, memoryPressure: 2))
        XCTAssertFalse(candidate.fits(memoryBytes: 16 * 1_073_741_824, memoryPressure: 4))
        XCTAssertNil(ManagedLocalModel.lookup("hf.co/random/model"))
        XCTAssertNil(ManagedLocalModel.lookup("qwen3.5:9b"))
    }

    func testRemoteHostsAndMalformedMetadataCannotAuthorizeDownloads() {
        XCTAssertTrue(ManagedLocalModel.isLoopback(endpoint))
        for value in ["http://example.com/api/chat", "http://127.0.0.1.evil/api/chat",
                      "http://user:secret@127.0.0.1/api/chat", "http://127.0.0.1/api/chat?redirect=1"] {
            XCTAssertFalse(ManagedLocalModel.isLoopback(URL(string: value)!))
        }
        let fixture = Fixture(candidate: candidate)
        for key in ["id", "private", "gated", "sha", "cardData"] {
            var metadata = fixture.metadata
            metadata.removeValue(forKey: key)
            XCTAssertFalse(ManagedLocalModel.validateMetadata(metadata, candidate: candidate), key)
        }
    }

    func testPullProgressCountsUniqueLayersAndRejectsOversizeOrErrors() throws {
        var progress = LocalModelPullProgress(maximumBytes: 10)
        func frame(_ digit: String, _ total: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["digest": "sha256:" + String(repeating: digit, count: 64), "total": total])
        }
        try progress.consume(frame("a", 6))
        try progress.consume(frame("a", 6))
        XCTAssertFalse(progress.complete)
        XCTAssertThrowsError(try progress.consume(frame("b", 6)))
        XCTAssertThrowsError(try progress.consume(Data(#"{"error":"denied"}"#.utf8)))
        var finished = LocalModelPullProgress(maximumBytes: 10)
        try finished.consume(Data(#"{"status":"success"}"#.utf8))
        XCTAssertTrue(finished.complete)
    }

    private func prepare(_ fixture: Fixture, disk: Int64 = 32 * 1_073_741_824) async throws {
        try await OllamaModelAcquisition.prepare(candidate, chatURL: endpoint,
            json: { fixture.json($0) }, download: { _, _ in fixture.download() }, freeBytes: { disk })
    }

    final class Fixture: @unchecked Sendable {
        let candidate: ManagedLocalModel
        var installed: Bool
        var badLicense = false
        var badDigest = false
        var calls: [String] = []
        init(candidate: ManagedLocalModel, installed: Bool = false) {
            self.candidate = candidate; self.installed = installed
        }
        var metadata: [String: Any] {
            ["id": candidate.huggingFaceRepo, "private": false, "gated": false,
             "sha": String(repeating: "a", count: 40),
             "cardData": ["license": badLicense ? "unknown" : "apache-2.0"]]
        }
        func json(_ url: URL) -> [String: Any] {
            if url.lastPathComponent == "tags" {
                calls.append("tags")
                return ["models": installed ? [["name": candidate.model,
                    "digest": badDigest ? "changed" : candidate.manifestDigest]] : []]
            }
            calls.append("metadata")
            return metadata
        }
        func download() { calls.append("download"); installed = true }
    }
}
