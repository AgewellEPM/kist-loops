import XCTest
@testable import AgentCore

final class LocalModelAdmissionTests: XCTestCase {
    let gib = LocalModelMemory.gib
    var healthy: LocalModelMemory { .init(physicalBytes: 16 * gib, availableBytes: 10 * gib, pressure: 1) }
    var info: [String: Any] { [
        "general.architecture": "qwen2", "qwen2.block_count": 28,
        "qwen2.attention.head_count": 12, "qwen2.attention.head_count_kv": 2,
        "qwen2.embedding_length": 1536, "qwen2.context_length": 32768
    ] }
    let endpoint = URL(string: "http://127.0.0.1:11434/api/chat")!

    func testMachCountersDoNotDoubleCountSpeculativeOrAnonymousMemory() {
        XCTAssertEqual(LocalModelMemory.reclaimablePages(free: 100, inactive: 300, anonymous: 500), 100)
        XCTAssertEqual(LocalModelMemory.reclaimablePages(free: 100, inactive: 500, anonymous: 300), 300)
    }

    func testOneAndHalfBModelUsesArchitectureCacheAndWorkspaceNotParameterMultiplier() {
        let result = LocalModelAdmission.evaluate(model: "qwen2.5-coder:1.5b", weights: 986_062_089,
            info: info, context: 16_384, memory: healthy)
        XCTAssertTrue(result.admitted)
        XCTAssertEqual(result.kvBytes, 469_762_048) // 16K * 28 layers * 2 KV heads * 128 dims * K,V * f16
        XCTAssertEqual(result.workspaceBytes, gib)
        XCTAssertEqual(result.requiredBytes, 986_062_089 + 469_762_048 + gib)
        XCTAssertEqual(result.sharding, "single_host_no_memory_sharding")
        XCTAssertFalse(result.providerError.isRetryable)
    }

    func testSeventyBAndFileShardsDoNotTurnDiskIntoRAM() {
        let result = LocalModelAdmission.evaluate(model: "70b-split-into-ten-files", weights: 40 * gib,
            info: info, context: 4096, memory: healthy)
        XCTAssertFalse(result.admitted)
        XCTAssertEqual(result.weightsBytes, 40 * gib)
        XCTAssertNil(result.kvBytes)
        XCTAssertTrue(result.nextStep.contains("splitting adds no RAM"))
    }

    func testAvailableMemoryReserveAndPressureOverridePhysicalRAM() {
        for memory in [LocalModelMemory(physicalBytes: 16 * gib, availableBytes: 2 * gib, pressure: 1),
                       .init(physicalBytes: 16 * gib, availableBytes: 14 * gib, pressure: 2),
                       .init(physicalBytes: 16 * gib, availableBytes: 14 * gib, pressure: 4),
                       .init(physicalBytes: 16 * gib, availableBytes: 14 * gib, pressure: -1)] {
            XCTAssertFalse(LocalModelAdmission.evaluate(model: "small", weights: gib, info: info,
                context: 4096, memory: memory).admitted)
        }
        XCTAssertEqual(healthy.requestBudgetBytes, 8 * gib)
    }

    func testLargeContextCannotQuietlyShrinkOrUseOptimisticQuantizedCache() {
        var metadata = info
        metadata["qwen2.attention.head_count_kv"] = 12
        let result = LocalModelAdmission.evaluate(model: "text", weights: 2 * gib, info: metadata,
            context: 32768, memory: .init(physicalBytes: 16 * gib, availableBytes: 8 * gib, pressure: 1))
        XCTAssertFalse(result.admitted)
        XCTAssertEqual(result.contextTokens, 32768)
        XCTAssertEqual(result.kvBytes, 5_637_144_576)
        XCTAssertTrue(result.reason.contains("context cache"))
    }

    func testMissingUnsupportedMalformedAndExcessiveMetadataFailClosed() {
        var cases: [[String: Any]] = [[:], ["general.architecture": "deepseek2"]]
        for value: Any in [true, -1, 2.5, "28", NSNumber(value: UInt64.max)] {
            var corrupt = info
            corrupt["qwen2.block_count"] = value
            cases.append(corrupt)
        }
        var badKey = info
        badKey["qwen2.attention.key_length"] = -1
        cases.append(badKey)
        for metadata in cases {
            XCTAssertFalse(LocalModelAdmission.evaluate(model: "custom", weights: gib,
                info: metadata, context: 4096, memory: healthy).admitted)
        }
        XCTAssertFalse(LocalModelAdmission.evaluate(model: "custom", weights: gib,
            info: info, context: 65536, memory: healthy).admitted)
    }

    func testExplicitKeyAndValueDimensionsAreUsed() {
        var metadata = info
        metadata["qwen2.attention.key_length"] = 256
        metadata["qwen2.attention.value_length"] = 64
        let result = LocalModelAdmission.evaluate(model: "custom", weights: gib,
            info: metadata, context: 4096, memory: healthy)
        XCTAssertEqual(result.kvBytes, 146_800_640)
    }

    func testProbeOnlyReadsMetadataAndRechecksIdentity() async throws {
        var calls: [String] = []
        let result = try await OllamaAdmission.report(endpoint: endpoint, model: "qwen", context: 4096,
            memory: { self.healthy }, fetch: { url, body in
                calls.append(url.path)
                if url.path == "/api/show" {
                    XCTAssertEqual(body, ["model": "qwen:latest"])
                    return ["model_info": self.info]
                }
                XCTAssertNil(body)
                return ["models": [["name": "qwen:latest", "size": self.gib, "digest": "one"]]]
            })
        XCTAssertTrue(result.admitted)
        XCTAssertEqual(calls, ["/api/tags", "/api/show", "/api/tags"])
    }

    func testPressureAndRemoteHostsNeverContactMetadataOrStartClusters() async throws {
        for (url, memory) in [(endpoint, LocalModelMemory(physicalBytes: 16 * gib, availableBytes: 12 * gib, pressure: 2)),
                              (URL(string: "http://192.168.1.2:11434/api/chat")!, healthy)] {
            let result = try await OllamaAdmission.report(endpoint: url, model: "qwen", context: 4096,
                memory: { memory }, fetch: { _, _ in XCTFail("must not contact backend"); return [:] })
            XCTAssertFalse(result.admitted)
        }
    }

    func testOversizedWeightsAreRejectedBeforeReadingModelMetadata() async throws {
        var calls = 0
        let result = try await OllamaAdmission.report(endpoint: endpoint, model: "huge", context: 4096,
            memory: { self.healthy }, fetch: { url, _ in
                calls += 1
                XCTAssertEqual(url.path, "/api/tags")
                return ["models": [["name": "huge:latest", "size": 40 * self.gib, "digest": "one"]]]
            })
        XCTAssertFalse(result.admitted)
        XCTAssertEqual(calls, 1)
    }

    func testPressureChangeAndTagReplacementDuringProbePreventLoad() async throws {
        for replaceTag in [false, true] {
            var snapshots = 0
            var reads = 0
            let result = try await OllamaAdmission.report(endpoint: endpoint, model: "qwen", context: 4096,
                memory: {
                    snapshots += 1
                    return snapshots > 1 ? .init(physicalBytes: 16 * self.gib, availableBytes: self.gib, pressure: 2) : self.healthy
                }, fetch: { url, _ in
                    reads += 1
                    if url.path == "/api/show" { return ["model_info": self.info] }
                    return ["models": [["name": "qwen:latest", "size": self.gib,
                                         "digest": replaceTag && reads == 3 ? "changed" : "one"]]]
                })
            XCTAssertFalse(result.admitted)
            XCTAssertTrue(result.reason.contains(replaceTag ? "identity changed" : "memory pressure"))
        }
    }

    func testVisionCannotUseTextCacheEstimate() async throws {
        let result = try await OllamaAdmission.report(endpoint: endpoint, model: "qwen", context: 4096,
            memory: { self.healthy }, fetch: { url, _ in
                if url.path == "/api/show" { return ["model_info": self.info, "capabilities": ["vision", "completion"]] }
                return ["models": [["name": "qwen:latest", "size": self.gib, "digest": "one"]]]
            })
        XCTAssertFalse(result.admitted)
        XCTAssertTrue(result.reason.contains("multimodal"))
    }

    func testCancellationIsNotConvertedToFallback() async {
        do {
            _ = try await OllamaAdmission.report(endpoint: endpoint, model: "qwen", context: 4096,
                memory: { self.healthy }, fetch: { _, _ in throw CancellationError() })
            XCTFail("expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
