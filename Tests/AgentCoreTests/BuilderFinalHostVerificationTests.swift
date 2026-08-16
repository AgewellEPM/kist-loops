import Foundation
import XCTest
@testable import AgentCore

final class BuilderFinalHostVerificationTests: XCTestCase {
    private enum EvidenceMode: Sendable, Equatable { case valid, missing, forged }

    func testKistDeterministicFinalAcceptsCommandsFromMultipleBuilderOSScopes() async throws {
        let receipt = try await run(mode: .valid)
        XCTAssertTrue(receipt.accepted)
        XCTAssertEqual(receipt.verification.provider, "kist")
        XCTAssertEqual(receipt.verification.model, "deterministic")
        XCTAssertEqual(receipt.verification.commandEvidence?.count, 2)
        XCTAssertTrue(receipt.verification.commandEvidence?.allSatisfy {
            $0.trustedCommandReference?.isBuilderOSSandboxed == true
        } ?? false)
    }

    func testKistDeterministicFinalRejectsMissingCommandEvidence() async throws {
        await assertFinalVerificationDenied(mode: .missing)
    }

    func testKistDeterministicFinalRejectsForgedCommandReference() async throws {
        await assertFinalVerificationDenied(mode: .forged)
    }

    private func assertFinalVerificationDenied(mode: EvidenceMode) async {
        do {
            _ = try await run(mode: mode)
            XCTFail("host deterministic final proof must fail without exact trusted evidence")
        } catch let error as BuilderRunError {
            guard case .finalVerificationFailed = error else {
                return XCTFail("expected finalVerificationFailed, got \(error)")
            }
        } catch {
            XCTFail("expected BuilderRunError, got \(error)")
        }
    }

    private func run(mode: EvidenceMode) async throws -> BuilderFinalReceipt {
        let fixture = BuilderRunTestFixtures.makeStore("builder-final-host")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let contract = BuilderRunTestFixtures.contract(id: "host-final-contract")
        let graph = try BuilderGraph(nodes: [
            BuilderNode(
                id: "read", objective: "inspect",
                resources: [.init(path: "Sources", access: .read)])
        ])
        let runner = try BuilderRun(
            contract: contract, graph: graph, store: fixture.store,
            execute: { BuilderRunTestFixtures.worker(for: $0) },
            verify: { request in
                switch request {
                case .node(_, let node, _, _):
                    return BuilderVerifierReceipt(
                        scope: .node(node.id), provider: "host", model: "deterministic",
                        deterministic: true, passed: true,
                        checks: [.init(name: "node", passed: true)])
                case .final(let finalContract, _, _):
                    return try await self.finalProof(
                        contract: finalContract, base: fixture.root, mode: mode)
                }
            },
            review: { _ in BuilderRunTestFixtures.approvedReview() })
        return try await runner.run()
    }

    private func finalProof(
        contract: BuilderContract, base: URL, mode: EvidenceMode
    ) async throws -> BuilderVerifierReceipt {
        let fingerprint = BuilderEvidenceDigest.sha256(String(
            decoding: try BuilderDurableIO.canonicalData(contract), as: UTF8.self))
        let subject = BuilderEvidenceDigest.sha256("host-final-subject")
        let count = mode == .valid ? 2 : 1
        var evidence: [BuilderCommandEvidenceReceipt] = []
        for index in 0..<count {
            let root = base.appendingPathComponent(
                "final-scope-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let request = BuilderSandboxAttestationRequest(
                contractFingerprint: fingerprint,
                builderContractID: contract.id,
                nodeID: "final-verification", attempt: 1,
                stagedRoot: root.path,
                governedRootDigest: BuilderEvidenceDigest.sha256(root.path),
                challenge: UUID().uuidString, stage: .verification)
            let attestation = try await BuilderOSProcessSandboxAttestor().attest(request)
            let result = try await BuilderOSProcessSandboxAttestor.withRegisteredScope(
                workspace: BuilderExecutionWorkspace(
                    rootPath: root.path,
                    rootIdentity: try BuilderWorkspaceRootIdentity.capture(
                        rootPath: root.path),
                    attestation: attestation),
                builderContractID: contract.id
            ) {
                await ToolRegistry([RunCommandTool()]).execute(
                    name: "run_command",
                    arguments: [
                        "executable": "/usr/bin/printf",
                        "args": ["%s", "verified-\(index)"],
                    ],
                    context: ToolContext(
                        projectRoot: root.path,
                        shell: ShellPolicy(
                            enabled: true, autoApprove: true, allow: ["printf"]),
                        sandbox: .disabled))
            }
            guard result.success, let original = result.trustedCommandReference else {
                throw BuilderRunError.finalVerificationFailed(
                    result.error ?? "trusted final command reference is absent")
            }
            let reference: BuilderTrustedCommandReference
            if mode == .forged {
                reference = try BuilderTrustedCommandReference(
                    observationID: original.observationID,
                    invocationID: original.invocationID,
                    gateArgumentsDigest: original.gateArgumentsDigest,
                    requestedArgumentsDigest: original.requestedArgumentsDigest,
                    effectiveLauncherDigest: original.effectiveLauncherDigest,
                    effectiveEnvironmentDigest: original.effectiveEnvironmentDigest,
                    sandboxProfileDigest: BuilderEvidenceDigest.sha256("forged-profile"),
                    stdoutDigest: original.stdoutDigest,
                    stderrDigest: original.stderrDigest,
                    stdoutByteCount: original.stdoutByteCount,
                    stderrByteCount: original.stderrByteCount,
                    exitCode: original.exitCode,
                    timedOut: original.timedOut,
                    wasSignalled: original.wasSignalled,
                    wallTimeMilliseconds: original.wallTimeMilliseconds)
            } else {
                reference = original
            }
            evidence.append(BuilderCommandEvidenceReceipt.boundPrehashed(
                tool: "run_command", verifierStatus: .passed,
                exitCode: reference.exitCode, allowedExitCodes: "0",
                semanticStatus: "clean_exit",
                argsFingerprint: reference.gateArgumentsDigest,
                outputDigest: reference.fullStreamDigest,
                boundedRedactedOutputExcerpt: result.output,
                subjectDigestAfter: subject,
                contractFingerprint: fingerprint,
                trustedCommandReference: reference))
        }
        return BuilderVerifierReceipt(
            scope: .final, provider: "kist", model: "deterministic",
            deterministic: true, passed: true,
            checks: [.init(name: "final-host", passed: true)],
            verificationSubject: "fixture://host-final",
            baselineDigest: subject, subjectDigest: subject,
            contractFingerprint: fingerprint,
            completionMode: .verificationOnly,
            commandEvidence: mode == .missing ? nil : evidence)
    }
}
