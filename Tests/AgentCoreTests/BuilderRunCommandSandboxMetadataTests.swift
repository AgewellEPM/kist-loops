import Foundation
import XCTest
@testable import AgentCore

final class BuilderRunCommandSandboxMetadataTests: XCTestCase {
    func testMetadataDistinguishesBuilderOSSandboxFromGenericSandbox() async throws {
        #if os(macOS)
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("builder-command-metadata-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: staged, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staged) }

        let fingerprint = BuilderEvidenceDigest.sha256("metadata-contract")
        let request = BuilderSandboxAttestationRequest(
            contractFingerprint: fingerprint,
            builderContractID: "metadata-contract",
            nodeID: "verify", attempt: 1,
            stagedRoot: staged.path,
            governedRootDigest: BuilderEvidenceDigest.sha256(staged.path),
            challenge: UUID().uuidString,
            stage: .verification)
        let attestation = try await BuilderOSProcessSandboxAttestor().attest(request)
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: try BuilderTrustedTelemetryBinding(
                contractFingerprint: fingerprint, nodeID: "verify",
                attempt: 1, stage: .verification),
            registerBudgetAuthority: false
        ) {
            try await BuilderOSProcessSandboxAttestor.withRegisteredScope(
                workspace: BuilderExecutionWorkspace(
                    rootPath: staged.path,
                    rootIdentity: try BuilderWorkspaceRootIdentity.capture(
                        rootPath: staged.path),
                    attestation: attestation),
                builderContractID: request.builderContractID
            ) {
                await ToolRegistry([RunCommandTool()]).execute(
                    name: "run_command",
                    arguments: [
                        "executable": "/usr/bin/printf",
                        "args": ["%s", "verified"],
                    ],
                    context: ToolContext(
                        projectRoot: staged.path,
                        shell: ShellPolicy(
                            enabled: true, autoApprove: true, allow: ["printf"]),
                        sandbox: .disabled))
            }
        }
        let governed = try captured.0.get()
        XCTAssertTrue(governed.success, governed.error ?? governed.output)
        XCTAssertEqual(governed.metadata["sandboxed"], "false")
        XCTAssertEqual(governed.metadata["builder_os_sandboxed"], "true")
        XCTAssertNotNil(governed.trustedCommandReference)
        XCTAssertFalse(governed.trustedCommandReference?.effectiveEnvironmentDigest?.isEmpty ?? true)
        XCTAssertFalse(governed.trustedCommandReference?.sandboxProfileDigest?.isEmpty ?? true)

        let ungoverned = await ToolRegistry([RunCommandTool()]).execute(
            name: "run_command",
            arguments: [
                "executable": "/usr/bin/printf",
                "args": ["%s", "plain"],
            ],
            context: ToolContext(
                projectRoot: staged.path,
                shell: ShellPolicy(
                    enabled: true, autoApprove: true, allow: ["printf"]),
                sandbox: .disabled))
        XCTAssertTrue(ungoverned.success, ungoverned.error ?? ungoverned.output)
        XCTAssertEqual(ungoverned.metadata["sandboxed"], "false")
        XCTAssertEqual(ungoverned.metadata["builder_os_sandboxed"], "false")
        #endif
    }
}
