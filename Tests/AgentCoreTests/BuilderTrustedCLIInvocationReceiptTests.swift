import Foundation
import XCTest
@testable import AgentCore

final class BuilderTrustedCLIInvocationReceiptTests: XCTestCase {
    private let fingerprint = String(repeating: "a", count: 64)

    private func binding() throws -> BuilderTrustedTelemetryBinding {
        try .init(contractFingerprint: fingerprint, nodeID: "cli-worker", attempt: 1,
                  stage: .build)
    }

    private func provider(stdoutScript: String) -> CLIChatProvider {
        CLIChatProvider(
            id: "claude-cli", name: "fixture", iconName: "cpu", keyAccount: "",
            defaultModel: "fixture-model", availableModels: [AIModel(id: "fixture-model")],
            binaryName: "/bin/sh", argsForModel: { _ in ["-c", stdoutScript] },
            parseOutput: { $0 })
    }

    private func completion(
        provider: CLIChatProvider, settings: ModelSettings = ModelSettings()
    ) async throws -> (String, TokenUsage) {
        let stream = try await provider.stream(
            messages: [.init(role: .user, content: "exact request")],
            model: "fixture-model", settings: settings, apiKey: nil)
        var text = ""
        var usage = TokenUsage.zero
        for try await event in stream {
            switch event {
            case .delta(let chunk): text += chunk
            case .usage(let input, let output):
                usage = .init(promptTokens: input, completionTokens: output)
            default: break
            }
        }
        return (text, usage)
    }

    func testActualTextCLIInvocationBindsExactUnreportedUsageAndConsumesOnce() async throws {
        let cli = provider(stdoutScript: "cat >/dev/null; printf answer")
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: try binding(), registerBudgetAuthority: false) {
                let (text, _) = try await self.completion(provider: cli)
                let raw = BuilderWorkerReceipt(
                    nodeID: "cli-worker", provider: "claude-cli", model: "fixture-model")
                let bound = try raw.bindingObservedCLIInvocationsIfRequired()
                let reuseDenied: Bool
                do {
                    _ = try raw.bindingObservedCLIInvocationsIfRequired()
                    reuseDenied = false
                } catch {
                    reuseDenied = true
                }
                return (text, bound, reuseDenied)
            }
        let value = try captured.0.get()
        XCTAssertEqual(value.0, "answer")
        XCTAssertTrue(value.2)
        let receipt = try XCTUnwrap(value.1.trustedCLIRouteReceipts?.only)
        XCTAssertEqual(receipt.providerID, "claude-cli")
        XCTAssertEqual(receipt.modelID, "fixture-model")
        XCTAssertEqual(receipt.route, "text-protocol")
        XCTAssertFalse(receipt.usageReported)
        XCTAssertEqual(receipt.inputTokens, 0)
        XCTAssertEqual(receipt.outputTokens, 0)
        XCTAssertEqual(receipt.requestFingerprint.count, 64)
        XCTAssertEqual(receipt.responseFingerprint, BuilderEvidenceDigest.sha256("answer"))
        XCTAssertTrue(receipt.isValid)
        XCTAssertTrue(value.1.trustedCLIInvocationsMatch(captured.1, requireComplete: true))
    }

    func testTextProtocolPreservesExactLeadingTrailingAndNewlineBytes() async throws {
        let cli = provider(stdoutScript: "cat >/dev/null; printf '  first\\nsecond  \\n'")
        let (text, usage) = try await completion(provider: cli)
        XCTAssertEqual(text, "  first\nsecond  \n")
        XCTAssertEqual(usage, .zero)
    }

    func testNativeStructuredInvocationCarriesProviderReportedUsage() async throws {
        let envelope = #"{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":7,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4},"structured_output":{"name":"kist"}}"#
        let cli = provider(stdoutScript: "cat >/dev/null; printf '%s' '\(envelope)'")
        let settings: ModelSettings = {
            var value = ModelSettings()
            value.jsonOutput = true
            value.jsonSchema = #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}"#
            return value
        }()
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: try binding(), registerBudgetAuthority: false) {
                let (_, usage) = try await self.completion(provider: cli, settings: settings)
                let worker = try BuilderWorkerReceipt(
                    nodeID: "cli-worker", provider: "claude-cli", model: "fixture-model")
                    .bindingObservedCLIInvocationsIfRequired()
                return (usage, worker)
            }
        let value = try captured.0.get()
        XCTAssertEqual(value.0, TokenUsage(promptTokens: 12, completionTokens: 4))
        let receipt = try XCTUnwrap(value.1.trustedCLIRouteReceipts?.only)
        XCTAssertEqual(receipt.route, "native-structured")
        XCTAssertTrue(receipt.usageReported)
        XCTAssertEqual(receipt.inputTokens, 12)
        XCTAssertEqual(receipt.outputTokens, 4)
    }

    func testActualCLIInvocationEvidenceIsRetainedButProviderRouteIsChargedOnce() async throws {
        let envelope = #"{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":7,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4},"structured_output":{"name":"kist"}}"#
        let cli = provider(stdoutScript: "cat >/dev/null; printf '%s' '\(envelope)'")
        let settings: ModelSettings = {
            var value = ModelSettings()
            value.jsonOutput = true
            value.jsonSchema = #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}"#
            return value
        }()
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: try binding()) {
                let (text, usage) = try await self.completion(
                    provider: cli, settings: settings)
                BuilderTrustedTelemetry.recordProvider(
                    providerID: "claude-cli", modelID: "fixture-model",
                    inputTokens: usage.promptTokens,
                    outputTokens: usage.completionTokens,
                    elapsedMilliseconds: 1,
                    outputDigest: BuilderEvidenceDigest.sha256(text))
                let worker = try BuilderWorkerReceipt(
                    nodeID: "cli-worker", provider: "claude-cli",
                    model: "fixture-model")
                    .bindingObservedCLIInvocationsIfRequired()
                return worker
            }
        let worker = try captured.0.get()
        let charges = try captured.1.compactMap {
            try $0.accountableBudgetObservation()
        }
        XCTAssertEqual(charges.count, 1)
        let charge = try XCTUnwrap(charges.only)
        XCTAssertEqual(charge.tokens, 16)
        XCTAssertEqual(charge.toolCalls, 0)
        XCTAssertEqual(captured.1.filter { $0.kind == .cliProviderInvocation }.count, 1)
        XCTAssertTrue(worker.trustedCLIInvocationsMatch(captured.1, requireComplete: true))
        XCTAssertTrue(captured.1.hasSuccessfulProviderRoute(
            providerID: worker.provider, modelID: worker.model))
        try BuilderTrustedTelemetryAuthority.consume(
            id: charge.id, fingerprint: charge.fingerprint(),
            telemetrySeal: charge.telemetrySeal)
        XCTAssertThrowsError(try BuilderTrustedTelemetryAuthority.consume(
            id: charge.id, fingerprint: charge.fingerprint(),
            telemetrySeal: charge.telemetrySeal))
    }

    func testActualCLIInvocationWithoutProviderRouteRemainsIneligible() async throws {
        let cli = provider(stdoutScript: "cat >/dev/null; printf answer")
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: try binding(), registerBudgetAuthority: false) {
                _ = try await self.completion(provider: cli)
                return try BuilderWorkerReceipt(
                    nodeID: "cli-worker", provider: "claude-cli",
                    model: "fixture-model")
                    .bindingObservedCLIInvocationsIfRequired()
            }
        let worker = try captured.0.get()
        XCTAssertTrue(worker.trustedCLIInvocationsMatch(captured.1, requireComplete: true))
        XCTAssertEqual(captured.1.filter { $0.kind == .cliProviderInvocation }.count, 1)
        XCTAssertFalse(captured.1.hasSuccessfulProviderRoute(
            providerID: worker.provider, modelID: worker.model))
        XCTAssertTrue(try captured.1.compactMap {
            try $0.accountableBudgetObservation()
        }.isEmpty)
    }

    func testRequestedIdentityAndGenericTelemetryCannotForgeCLIReceipt() async throws {
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: try binding(), registerBudgetAuthority: false) {
                BuilderTrustedTelemetry.recordProvider(
                    providerID: "claude-cli", modelID: "fixture-model",
                    inputTokens: 10, outputTokens: 2, elapsedMilliseconds: 1,
                    outputDigest: String(repeating: "b", count: 64))
                return try BuilderWorkerReceipt(
                    nodeID: "cli-worker", provider: "claude-cli", model: "fixture-model")
                    .bindingObservedCLIInvocationsIfRequired()
            }
        XCTAssertThrowsError(try captured.0.get())
        XCTAssertTrue(captured.1.allSatisfy { $0.kind != .cliProviderInvocation })
    }

    func testDecodedForgedReceiptDoesNotMatchTrustedObservation() async throws {
        let cli = provider(stdoutScript: "cat >/dev/null; printf answer")
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: try binding(), registerBudgetAuthority: false) {
                _ = try await self.completion(provider: cli)
                return try BuilderWorkerReceipt(
                    nodeID: "cli-worker", provider: "claude-cli", model: "fixture-model")
                    .bindingObservedCLIInvocationsIfRequired()
            }
        let worker = try captured.0.get()
        let encoded = try JSONEncoder().encode(worker)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var receipts = try XCTUnwrap(
            object["trustedCLIRouteReceipts"] as? [[String: Any]])
        receipts[0]["requestFingerprint"] = String(repeating: "f", count: 64)
        object["trustedCLIRouteReceipts"] = receipts
        let forged = try JSONDecoder().decode(
            BuilderWorkerReceipt.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(forged.trustedCLIInvocationsMatch(captured.1, requireComplete: true))
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
