import XCTest
import Foundation
@testable import AgentCore

final class BuilderOSProcessSandboxAttestorTests: XCTestCase {
    private var base: URL!
    private var staged: URL!
    private var governed: URL!

    override func setUpWithError() throws {
        ForgeSeal.forceEphemeralKeyForTesting()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("builder-os-sandbox-tests-\(UUID().uuidString)", isDirectory: true)
        staged = base.appendingPathComponent("staged", isDirectory: true)
        governed = base.appendingPathComponent("governed", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: governed, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    private func request(attempt: Int = 1, root: URL? = nil,
                         stage: BuilderExecutionStage = .build)
        -> BuilderSandboxAttestationRequest {
        BuilderSandboxAttestationRequest(
            contractFingerprint: BuilderEvidenceDigest.sha256("contract"),
            builderContractID: "builder-contract", nodeID: "build", attempt: attempt,
            stagedRoot: (root ?? staged).path,
            governedRootDigest: BuilderEvidenceDigest.sha256("governed"),
            challenge: BuilderEvidenceDigest.sha256("challenge-\(attempt)-\((root ?? staged).path)"),
            stage: stage)
    }

    private func run(_ path: String, _ args: [String], cwd: URL? = nil,
                     env: [String: String] = ["PATH": "/usr/bin:/bin"])
        -> ProcessGroupRunner.Outcome {
        ProcessGroupRunner.run(
            launchPath: path, launchArgs: args, cwd: (cwd ?? staged).path,
            env: env, timeoutSeconds: 20, capPerStream: 100_000)
    }

    private func withScope<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let request = request()
        let attestation = try await BuilderOSProcessSandboxAttestor().attest(request)
        return try await BuilderOSProcessSandboxAttestor.withRegisteredScope(
            request: request, attestation: attestation, operation: operation)
    }

    func testAllowedStagedWriteSucceeds() async throws {
        #if os(macOS)
        let staged = try XCTUnwrap(staged)
        let outcome = try await withScope {
            self.run("/usr/bin/touch", [staged.appendingPathComponent("allowed.txt").path])
        }
        XCTAssertEqual(outcome.exitCode, 0, outcome.combined)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("allowed.txt").path))
        #else
        throw XCTSkip("real Seatbelt integration test requires macOS")
        #endif
    }

    func testGovernedSiblingAbsoluteWriteIsDeniedAndUnchanged() async throws {
        #if os(macOS)
        let governed = try XCTUnwrap(governed)
        let original = governed.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: original)
        let outcome = try await withScope {
            self.run("/usr/bin/touch", [original.path])
        }
        XCTAssertNotEqual(outcome.exitCode, 0)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
        #else
        throw XCTSkip("real Seatbelt integration test requires macOS")
        #endif
    }

    func testSymlinkEscapeWriteIsDenied() async throws {
        #if os(macOS)
        let governed = try XCTUnwrap(governed)
        let staged = try XCTUnwrap(staged)
        let original = governed.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: original)
        let link = staged.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: governed)
        let outcome = try await withScope {
            self.run("/usr/bin/touch", [link.appendingPathComponent("outside.txt").path])
        }
        XCTAssertNotEqual(outcome.exitCode, 0)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "outside")
        #else
        throw XCTSkip("real Seatbelt integration test requires macOS")
        #endif
    }

    func testSystemAndCompilerReadsRemainAvailable() async throws {
        #if os(macOS)
        let compiler = ["/usr/bin/clang", "/usr/bin/cc", "/usr/bin/swiftc"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard let compiler else { throw XCTSkip("no system compiler is installed") }
        let outcome = try await withScope { self.run(compiler, ["--version"]) }
        XCTAssertEqual(outcome.exitCode, 0, outcome.combined)
        XCTAssertFalse(outcome.stdout.isEmpty && outcome.stderr.isEmpty)
        #else
        throw XCTSkip("real Seatbelt integration test requires macOS")
        #endif
    }

    func testParentProcessArgumentsCannotBeInspected() async throws {
        #if os(macOS)
        let parentPID = getpid()
        let outcome = try await withScope {
            self.run("/bin/ps", ["eww", "-p", "\(parentPID)", "-o", "command="])
        }
        XCTAssertNotEqual(outcome.exitCode, 0, outcome.combined)
        XCTAssertFalse(outcome.combined.contains("AgentCorePackageTests"), outcome.combined)
        #else
        throw XCTSkip("real Seatbelt process-inspection test requires macOS")
        #endif
    }

    func testChildEnvironmentAndArgvDoNotInheritCallerSecretsOrHostPath() async throws {
        #if os(macOS)
        let staged = try XCTUnwrap(staged)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("system Python is unavailable")
        }
        let probe = staged.appendingPathComponent("environment_probe.py")
        try Data("import json, os, sys\nprint(json.dumps({'argv': sys.argv, 'env': dict(os.environ)}, sort_keys=True))\n".utf8)
            .write(to: probe)
        let secret = "EVOLUTION_CALLER_SECRET_\(UUID().uuidString)"
        let hostPath = FileManager.default.currentDirectoryPath
        let outcome = try await withScope {
            self.run(
                "/usr/bin/python3", ["environment_probe.py", "benign-argument"],
                env: ["PATH": "/attacker", "SECRET": secret, "PWD": hostPath])
        }
        XCTAssertEqual(outcome.exitCode, 0, outcome.combined)
        XCTAssertTrue(outcome.stdout.contains("benign-argument"), outcome.stdout)
        XCTAssertFalse(outcome.combined.contains(secret), outcome.combined)
        XCTAssertFalse(outcome.combined.contains(hostPath), outcome.combined)
        #else
        throw XCTSkip("real Seatbelt environment test requires macOS")
        #endif
    }

    func testUnregisteredForgedAndReplayedAttestationsAreRejected() async throws {
        let originalRequest = request()
        let forged = try BuilderSandboxAttestation(
            request: originalRequest, mechanism: "enforced=true", enforced: true,
            evidenceDigest: BuilderEvidenceDigest.sha256("forged"))
        do {
            _ = try await BuilderOSProcessSandboxAttestor.withRegisteredScope(
                request: originalRequest, attestation: forged) { 1 }
            XCTFail("unregistered forged attestation must fail")
        } catch {}

        let issued = try await BuilderOSProcessSandboxAttestor().attest(originalRequest)
        let drifted = request(attempt: 2)
        do {
            _ = try await BuilderOSProcessSandboxAttestor.withRegisteredScope(
                request: drifted, attestation: issued) { 1 }
            XCTFail("cross-attempt attestation reuse must fail")
        } catch {}

        _ = try await BuilderOSProcessSandboxAttestor.withRegisteredScope(
            request: originalRequest, attestation: issued) { 1 }
        do {
            _ = try await BuilderOSProcessSandboxAttestor.withRegisteredScope(
                request: originalRequest, attestation: issued) { 1 }
            XCTFail("attestation replay must fail")
        } catch {}
    }

    func testStructuredArgvDoesNotInvokeShell() async throws {
        #if os(macOS)
        let staged = try XCTUnwrap(staged)
        let injected = staged.appendingPathComponent("injected.txt")
        let payload = "; /usr/bin/touch \(injected.path)"
        let outcome = try await withScope {
            self.run("/usr/bin/printf", ["%s", payload])
        }
        XCTAssertEqual(outcome.exitCode, 0, outcome.combined)
        XCTAssertEqual(outcome.stdout, payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: injected.path))
        #else
        throw XCTSkip("real Seatbelt integration test requires macOS")
        #endif
    }

    func testVerificationCanRefreshExistingGeneratedOutputButNotSourceOrEscapeLink() async throws {
        #if os(macOS)
        let staged = try XCTUnwrap(staged)
        let governed = try XCTUnwrap(governed)
        let generated = staged.appendingPathComponent(".build", isDirectory: true)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        try Data("source\n".utf8).write(to: staged.appendingPathComponent("source.txt"))
        try FileManager.default.createSymbolicLink(
            at: generated.appendingPathComponent("escape"), withDestinationURL: governed)
        let request = request(stage: .verification)
        let attestation = try await BuilderOSProcessSandboxAttestor().attest(request)
        let outcomes = try await BuilderOSProcessSandboxAttestor.withRegisteredScope(
            request: request, attestation: attestation) {
                let generatedWrite = self.run(
                    "/usr/bin/touch", [generated.appendingPathComponent("refreshed").path])
                let sourceWrite = self.run(
                    "/usr/bin/touch", [staged.appendingPathComponent("source.txt").path])
                let escapeWrite = self.run(
                    "/usr/bin/touch", [generated.appendingPathComponent("escape/outside").path])
                return (generatedWrite.exitCode, sourceWrite.exitCode, escapeWrite.exitCode)
            }
        XCTAssertEqual(outcomes.0, 0)
        XCTAssertNotEqual(outcomes.1, 0)
        XCTAssertNotEqual(outcomes.2, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: governed.appendingPathComponent("outside").path))
        #else
        throw XCTSkip("real Seatbelt integration test requires macOS")
        #endif
    }

    func testVerificationScopeReadsExactStageButCannotWriteOrNetworkAndSealsFixedEnvironment() async throws {
        #if os(macOS)
        let staged = try XCTUnwrap(staged)
        try Data("VERIFIED\n".utf8).write(
            to: staged.appendingPathComponent("subject.txt"))
        try Data("from pathlib import Path\nassert Path('subject.txt').read_bytes() == b'VERIFIED\\n'\n".utf8)
            .write(to: staged.appendingPathComponent("test_result.py"))
        let request = request(stage: .verification)
        let attestation = try await BuilderOSProcessSandboxAttestor().attest(request)
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: try BuilderTrustedTelemetryBinding(
                contractFingerprint: request.contractFingerprint,
                nodeID: request.nodeID, attempt: request.attempt, stage: .verification),
            registerBudgetAuthority: false) {
                try await BuilderOSProcessSandboxAttestor.withRegisteredScope(
                    workspace: BuilderExecutionWorkspace(
                        rootPath: staged.path,
                        rootIdentity: try BuilderWorkspaceRootIdentity.capture(
                            rootPath: staged.path),
                        attestation: attestation),
                    builderContractID: request.builderContractID) {
                        let prepared = try XCTUnwrap(
                            BuilderOSProcessSandboxAttestor.preparedLaunch(
                                launchPath: "/bin/cat", launchArgs: ["subject.txt"],
                                cwd: staged.path,
                                environment: ["PATH": "/attacker", "SECRET": "must-not-leak"]))
                        let privateRoot = URL(fileURLWithPath: prepared.environment["HOME"]!)
                            .deletingLastPathComponent().path
                        let invocation = BuilderTrustedToolInvocation.make(
                            toolName: "run_command",
                            argumentsDigest: BuilderEvidenceDigest.sha256("verification-cat"))
                        let read = BuilderTrustedToolInvocationScope.$current.withValue(invocation) {
                            ProcessGroupRunner.run(
                                launchPath: "/bin/cat", launchArgs: ["subject.txt"],
                                cwd: staged.path, env: ["SECRET": "must-not-leak"],
                                timeoutSeconds: 10, capPerStream: 16_384,
                                telemetrySink: BuilderTrustedTelemetry.captureCommandSink(),
                                requestedArgumentsDigest: invocation.argumentsDigest)
                        }
                        let deniedWrite = ProcessGroupRunner.run(
                            launchPath: "/usr/bin/touch", launchArgs: ["denied.txt"],
                            cwd: staged.path, env: [:], timeoutSeconds: 10,
                            capPerStream: 16_384)
                        let tempWrite = ProcessGroupRunner.run(
                            launchPath: "/usr/bin/touch",
                            launchArgs: [prepared.environment["TMPDIR"]! + "allowed.tmp"],
                            cwd: staged.path, env: [:], timeoutSeconds: 10,
                            capPerStream: 16_384)
                        let python = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")
                            ? ProcessGroupRunner.run(
                                launchPath: "/usr/bin/python3", launchArgs: ["test_result.py"],
                                cwd: staged.path, env: [:], timeoutSeconds: 20,
                                capPerStream: 16_384) : nil
                        let network = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")
                            ? ProcessGroupRunner.run(
                                launchPath: "/usr/bin/python3",
                                launchArgs: ["-c", "import socket; s=socket.socket(); s.bind(('127.0.0.1',0))"],
                                cwd: staged.path, env: [:], timeoutSeconds: 20,
                                capPerStream: 16_384) : nil
                        let modesArePrivate = [
                            prepared.environment["HOME"],
                            prepared.environment["TMP"],
                            prepared.environment["XDG_CACHE_HOME"],
                            prepared.environment["SWIFTPM_MODULECACHE_OVERRIDE"],
                            prepared.environment["CLANG_MODULE_CACHE_PATH"],
                        ].compactMap { $0 }.allSatisfy { path in
                            var status = stat()
                            return lstat(path, &status) == 0
                                && (status.st_mode & mode_t(0o077)) == 0
                        }
                        return VerificationSandboxProbe(
                            environment: prepared.environment,
                            environmentDigest: prepared.environmentDigest,
                            profileDigest: prepared.sandboxProfileDigest,
                            policy: prepared.launchArgs.dropFirst().first ?? "",
                            privateRoot: privateRoot, modesArePrivate: modesArePrivate,
                            readExit: read.exitCode, readOutput: read.stdout,
                            reference: read.trustedCommandReference,
                            deniedWriteExit: deniedWrite.exitCode,
                            tempWriteExit: tempWrite.exitCode,
                            pythonExit: python?.exitCode, networkExit: network?.exitCode)
                    }
            }
        let probe = try captured.0.get()
        XCTAssertEqual(probe.readExit, 0, probe.readOutput)
        XCTAssertEqual(probe.readOutput, "VERIFIED\n")
        XCTAssertNotEqual(probe.deniedWriteExit, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: staged.appendingPathComponent("denied.txt").path))
        XCTAssertEqual(probe.tempWriteExit, 0)
        XCTAssertEqual(probe.pythonExit, nil == probe.pythonExit ? nil : 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: staged.appendingPathComponent("__pycache__").path))
        if let networkExit = probe.networkExit { XCTAssertNotEqual(networkExit, 0) }
        XCTAssertNil(probe.environment["SECRET"])
        XCTAssertEqual(probe.environment["PYTHONDONTWRITEBYTECODE"], "1")
        let expectedEnvironmentDigest = BuilderEvidenceDigest.sha256(
            probe.environment.keys.sorted().map {
                "\($0)=\(probe.environment[$0] ?? "")"
            }.joined(separator: "\u{0}"))
        XCTAssertEqual(probe.environmentDigest, expectedEnvironmentDigest)
        XCTAssertTrue(probe.modesArePrivate)
        XCTAssertTrue(probe.policy.contains("(deny network*)"))
        XCTAssertFalse(probe.policy.contains("file-write* (subpath \"\(staged.path)\")"))
        let reference = try XCTUnwrap(probe.reference)
        XCTAssertEqual(reference.effectiveEnvironmentDigest, probe.environmentDigest)
        XCTAssertEqual(reference.sandboxProfileDigest, probe.profileDigest)
        XCTAssertTrue(reference.isValid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: probe.privateRoot))
        #else
        throw XCTSkip("real read-only Seatbelt verification requires macOS")
        #endif
    }
}

private struct VerificationSandboxProbe: Sendable {
    let environment: [String: String]
    let environmentDigest: String
    let profileDigest: String
    let policy: String
    let privateRoot: String
    let modesArePrivate: Bool
    let readExit: Int32
    let readOutput: String
    let reference: BuilderTrustedCommandReference?
    let deniedWriteExit: Int32
    let tempWriteExit: Int32
    let pythonExit: Int32?
    let networkExit: Int32?
}
