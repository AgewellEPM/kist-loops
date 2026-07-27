import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AgentCore
@testable import Kist

final class LiveModelMetadataGateTests: XCTestCase {
    private func tempRoot() -> String {
        let root = NSTemporaryDirectory() + "kist_metadata_gate_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func httpResponse(for request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url ?? URL(string: "https://example.com")!,
                        statusCode: status,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!
    }

    private func safeHFMetadataFetcher(modelSize: Int64 = 32,
                                       tokenizerSize: Int64 = 2) -> LiveModelMetadataFetcher {
        LiveModelMetadataFetcher { request in
            let json = """
            {
              "modelId": "owner/safe-model",
              "author": "owner",
              "cardData": { "license": "mit" },
              "tags": ["license:mit"],
              "gated": false,
              "private": false,
              "disabled": false,
              "sha": "0123456789abcdef0123456789abcdef01234567",
              "usedStorage": 123456789,
              "siblings": [
                { "rfilename": "README.md", "size": 10 },
                { "rfilename": "model.safetensors", "size": \(modelSize) },
                { "rfilename": "tokenizer_config.json", "size": \(tokenizerSize) }
              ]
            }
            """
            return (Data(json.utf8), self.httpResponse(for: request))
        }
    }

    func testHuggingFaceMetadataGateAcceptsAllowlistedSafeRepo() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fetcher = LiveModelMetadataFetcher { request in
            XCTAssertEqual(request.url?.host, "huggingface.co")
            let json = """
            {
              "_id": "66eb50118ed4a19697c13511",
              "id": "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
              "modelId": "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
              "author": "mlx-community",
              "cardData": { "license": "apache-2.0" },
              "tags": ["text-generation", "license:apache-2.0"],
              "gated": false,
              "private": false,
              "disabled": false,
              "sha": "0123456789abcdef0123456789abcdef01234567",
              "usedStorage": 123456789,
              "downloads": 42,
              "lastModified": "2026-07-01T00:00:00.000Z",
              "siblings": [
                { "rfilename": "README.md", "size": 10 },
                { "rfilename": "model.safetensors", "size": 32 },
                { "rfilename": "tokenizer_config.json", "size": 2 }
              ]
            }
            """
            return (Data(json.utf8), self.httpResponse(for: request))
        }

        let report = await OrganizationalLearningStore(projectRoot: root)
            .runLiveModelMetadataGate(spec: "mlx:mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
                                      fetcher: fetcher)

        XCTAssertEqual(report.decision?.accepted, true)
        XCTAssertEqual(report.metadata?.modelID, "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
        XCTAssertEqual(report.decision?.allowedLicense, "apache-2.0")
        XCTAssertNil(report.fetchError)
        XCTAssertTrue(report.writeSucceeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + report.path))
        let manifestPath = try XCTUnwrap(report.acquisitionManifestPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + manifestPath))
        XCTAssertTrue(report.manifestWriteSucceeded)
        XCTAssertNil(report.manifestWriteError)
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: root + "/" + manifestPath))
        let manifest = try JSONDecoder().decode(LocalModelAcquisitionManifest.self, from: manifestData)
        XCTAssertEqual(manifest.modelID, "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
        XCTAssertEqual(manifest.revisionSHA, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(manifest.license, "apache-2.0")
        XCTAssertEqual(manifest.localDirectory, ".kist/models/mlx-community-qwen2-5-coder-7b-instruct-4bit-0123456789ab")
        XCTAssertTrue(manifest.commands.dryRun?.contains("hf download") ?? false)
        XCTAssertTrue(manifest.commands.dryRun?.contains("--dry-run") ?? false)
        XCTAssertTrue(manifest.commands.download?.contains("--revision 0123456789abcdef0123456789abcdef01234567") ?? false)
        XCTAssertTrue(manifest.commands.download?.contains("--local-dir .kist/models/mlx-community-qwen2-5-coder-7b-instruct-4bit-0123456789ab") ?? false)
        XCTAssertFalse(manifest.commands.download?.contains(" README.md ") ?? true)
        XCTAssertFalse(manifest.commands.dryRun?.contains(" model.safetensors ") ?? true)
        XCTAssertTrue(manifest.fileNames.contains("README.md"))
        XCTAssertTrue(manifest.fileNames.contains("model.safetensors"))
        XCTAssertTrue(manifest.commands.inspect.contains("kist --inspect-model"))
        XCTAssertTrue(manifest.approvalID.hasPrefix("LMA-"))
        XCTAssertGreaterThanOrEqual(report.seededTasks, 4)
        XCTAssertEqual(report.memoryRecords, 1)
        XCTAssertTrue(report.text.contains("ACCEPTED"))
        XCTAssertTrue(report.text.contains("Acquisition manifest"))
        XCTAssertTrue(report.text.contains("Manifest commands"))

        let plan = PlanStore(projectRoot: root).load()
        XCTAssertTrue(plan.tasks.contains { $0.title.contains("Verify acquisition manifest") })
        XCTAssertTrue(plan.tasks.contains { $0.evidence.contains(manifestPath) })
        XCTAssertFalse(plan.tasks.contains { $0.title.contains("Resolve local model metadata blockers") })
    }

    func testAcquisitionPreflightVerifiesManifestAndSeedsNextGates() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fetcher = LiveModelMetadataFetcher { request in
            let json = """
            {
              "modelId": "owner/safe-model",
              "author": "owner",
              "cardData": { "license": "mit" },
              "tags": ["license:mit"],
              "gated": false,
              "private": false,
              "disabled": false,
              "sha": "0123456789abcdef0123456789abcdef01234567",
              "usedStorage": 123456789,
              "siblings": [
                { "rfilename": "README.md", "size": 10 },
                { "rfilename": "model.safetensors", "size": 32 },
                { "rfilename": "tokenizer_config.json", "size": 2 }
              ]
            }
            """
            return (Data(json.utf8), self.httpResponse(for: request))
        }
        let vet = await OrganizationalLearningStore(projectRoot: root,
                                                    now: { Date(timeIntervalSince1970: 1_700_005_200) })
            .runLiveModelMetadataGate(spec: "mlx:owner/safe-model", fetcher: fetcher)
        let manifestPath = try XCTUnwrap(vet.acquisitionManifestPath)

        let acquire = OrganizationalLearningStore(projectRoot: root,
                                                  now: { Date(timeIntervalSince1970: 1_700_005_300) })
            .runLocalModelAcquisitionPreflight(manifestPath: manifestPath)

        XCTAssertTrue(acquire.decision.accepted, acquire.text)
        XCTAssertTrue(acquire.text.contains("VERIFIED"))
        XCTAssertTrue(acquire.text.contains("Approved Command Set"))
        XCTAssertEqual(acquire.manifest?.approvalID, vet.acquisitionManifest?.approvalID)
        XCTAssertEqual(acquire.seededTasks, 4)
        XCTAssertEqual(acquire.memoryRecords, 1)
        XCTAssertTrue(acquire.writeSucceeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + acquire.path))

        let plan = PlanStore(projectRoot: root).load()
        XCTAssertTrue(plan.tasks.contains { $0.title.contains("Run local model acquisition dry-run") })
        XCTAssertTrue(plan.tasks.contains { $0.title.contains("Download manifest-approved local model") })
        XCTAssertTrue(plan.tasks.contains { $0.evidence.contains(manifestPath) })
    }

    func testAcquisitionPreflightRejectsTamperedManifestCommands() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fetcher = LiveModelMetadataFetcher { request in
            let json = """
            {
              "modelId": "owner/safe-model",
              "author": "owner",
              "cardData": { "license": "mit" },
              "tags": ["license:mit"],
              "gated": false,
              "private": false,
              "disabled": false,
              "sha": "0123456789abcdef0123456789abcdef01234567",
              "usedStorage": 123456789,
              "siblings": [
                { "rfilename": "README.md", "size": 10 },
                { "rfilename": "model.safetensors", "size": 32 },
                { "rfilename": "tokenizer_config.json", "size": 2 }
              ]
            }
            """
            return (Data(json.utf8), self.httpResponse(for: request))
        }
        let vet = await OrganizationalLearningStore(projectRoot: root,
                                                    now: { Date(timeIntervalSince1970: 1_700_005_400) })
            .runLiveModelMetadataGate(spec: "mlx:owner/safe-model", fetcher: fetcher)
        var manifest = try XCTUnwrap(vet.acquisitionManifest)
        manifest.commands.download = "hf download owner/safe-model --revision 0123456789abcdef0123456789abcdef01234567 --local-dir /tmp/evil"
        let tamperedPath = ".kist/learning/local-models/tampered-acquisition.json"
        let tamperedURL = URL(fileURLWithPath: root).appendingPathComponent(tamperedPath)
        try FileManager.default.createDirectory(at: tamperedURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try LiveModelMetadataGate.manifestJSONData(manifest).write(to: tamperedURL)

        let acquire = OrganizationalLearningStore(projectRoot: root,
                                                  now: { Date(timeIntervalSince1970: 1_700_005_500) })
            .runLocalModelAcquisitionPreflight(manifestPath: tamperedPath)

        XCTAssertFalse(acquire.decision.accepted)
        XCTAssertTrue(acquire.text.contains("REJECTED"))
        XCTAssertTrue(acquire.decision.reasons.contains { $0.contains("commands do not match") })
        XCTAssertTrue(acquire.decision.reasons.contains { $0.contains("policyHash") })

        let plan = PlanStore(projectRoot: root).load()
        XCTAssertFalse(plan.tasks.contains { $0.title.contains("Download manifest-approved local model") })
        XCTAssertTrue(plan.tasks.contains { $0.title.contains("Reject or repair local model acquisition manifest") })
    }

    func testAcquisitionRunDryRunExecutesStructuredCommandAndWritesMarker() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fetcher = LiveModelMetadataFetcher { request in
            let json = """
            {
              "modelId": "owner/safe-model",
              "author": "owner",
              "cardData": { "license": "mit" },
              "tags": ["license:mit"],
              "gated": false,
              "private": false,
              "disabled": false,
              "sha": "0123456789abcdef0123456789abcdef01234567",
              "usedStorage": 123456789,
              "siblings": [
                { "rfilename": "README.md", "size": 10 },
                { "rfilename": "model.safetensors", "size": 32 },
                { "rfilename": "tokenizer_config.json", "size": 2 }
              ]
            }
            """
            return (Data(json.utf8), self.httpResponse(for: request))
        }
        let vet = await OrganizationalLearningStore(projectRoot: root,
                                                    now: { Date(timeIntervalSince1970: 1_700_005_600) })
            .runLiveModelMetadataGate(spec: "mlx:owner/safe-model", fetcher: fetcher)
        let manifestPath = try XCTUnwrap(vet.acquisitionManifestPath)

        var captured: LocalModelAcquisitionRunnableCommand?
        let run = OrganizationalLearningStore(projectRoot: root,
                                              now: { Date(timeIntervalSince1970: 1_700_005_700) })
            .runLocalModelAcquisitionStage(stage: "dry-run", manifestPath: manifestPath) { command, _ in
                captured = command
                return LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "dry-run",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "dry run ok",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [] }

        XCTAssertEqual(captured?.stage, .dryRun)
        XCTAssertEqual(captured?.invocations.first?.executable, "hf")
        XCTAssertEqual(captured?.invocations.first?.arguments, [
            "download", "owner/safe-model",
            "--revision", "0123456789abcdef0123456789abcdef01234567",
            "--local-dir", ".kist/models/owner-safe-model-0123456789ab",
            "--dry-run"
        ])
        XCTAssertEqual(run.outcome?.succeeded, true)
        XCTAssertTrue(run.decision.accepted, run.text)
        XCTAssertTrue(run.text.contains("PASS"))
        XCTAssertTrue(run.text.contains("dry run ok"))
        let marker = try XCTUnwrap(run.markerPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + marker))
    }

    func testAcquisitionRunMissingDependencyBlocksBeforeExecution() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fetcher = LiveModelMetadataFetcher { request in
            let json = """
            {
              "modelId": "owner/safe-model",
              "author": "owner",
              "cardData": { "license": "mit" },
              "tags": ["license:mit"],
              "gated": false,
              "private": false,
              "disabled": false,
              "sha": "0123456789abcdef0123456789abcdef01234567",
              "usedStorage": 123456789,
              "siblings": [
                { "rfilename": "README.md", "size": 10 },
                { "rfilename": "model.safetensors", "size": 32 },
                { "rfilename": "tokenizer_config.json", "size": 2 }
              ]
            }
            """
            return (Data(json.utf8), self.httpResponse(for: request))
        }
        let vet = await OrganizationalLearningStore(projectRoot: root,
                                                    now: { Date(timeIntervalSince1970: 1_700_006_000) })
            .runLiveModelMetadataGate(spec: "mlx:owner/safe-model", fetcher: fetcher)
        let manifestPath = try XCTUnwrap(vet.acquisitionManifestPath)
        var executorWasCalled = false

        let run = OrganizationalLearningStore(projectRoot: root,
                                              now: { Date(timeIntervalSince1970: 1_700_006_100) })
            .runLocalModelAcquisitionStage(stage: "dry-run", manifestPath: manifestPath) { command, _ in
                executorWasCalled = true
                return LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "dry-run",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "should not run",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [
                LocalModelAcquisitionDependencyBlocker(executable: "hf",
                                                       reason: "not on PATH",
                                                       setupCommand: "python3 -m pip install --user -U 'huggingface_hub[cli]'",
                                                       verifyCommand: "hf --help")
            ] }

        XCTAssertFalse(executorWasCalled)
        XCTAssertNil(run.outcome)
        XCTAssertNil(run.markerPath)
        XCTAssertFalse(run.decision.accepted)
        XCTAssertEqual(run.dependencyBlockers.first?.executable, "hf")
        XCTAssertTrue(run.text.contains("Dependency Preflight"))
        XCTAssertTrue(run.text.contains("Setup: python3 -m pip install --user -U 'huggingface_hub[cli]'"))

        let plan = PlanStore(projectRoot: root).load()
        XCTAssertTrue(plan.tasks.contains { $0.title.contains("Install local model acquisition dependency -- hf") })
    }

    func testAcquisitionRunDownloadRequiresDryRunMarker() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fetcher = LiveModelMetadataFetcher { request in
            let json = """
            {
              "modelId": "owner/safe-model",
              "author": "owner",
              "cardData": { "license": "mit" },
              "tags": ["license:mit"],
              "gated": false,
              "private": false,
              "disabled": false,
              "sha": "0123456789abcdef0123456789abcdef01234567",
              "usedStorage": 123456789,
              "siblings": [
                { "rfilename": "README.md", "size": 10 },
                { "rfilename": "model.safetensors", "size": 32 },
                { "rfilename": "tokenizer_config.json", "size": 2 }
              ]
            }
            """
            return (Data(json.utf8), self.httpResponse(for: request))
        }
        let vet = await OrganizationalLearningStore(projectRoot: root,
                                                    now: { Date(timeIntervalSince1970: 1_700_005_800) })
            .runLiveModelMetadataGate(spec: "mlx:owner/safe-model", fetcher: fetcher)
        let manifestPath = try XCTUnwrap(vet.acquisitionManifestPath)
        var executorWasCalled = false

        let run = OrganizationalLearningStore(projectRoot: root,
                                              now: { Date(timeIntervalSince1970: 1_700_005_900) })
            .runLocalModelAcquisitionStage(stage: "download", manifestPath: manifestPath) { command, _ in
                executorWasCalled = true
                return LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "download",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "should not run",
                                                       stderr: "")
                ])
            }

        XCTAssertFalse(executorWasCalled)
        XCTAssertNil(run.outcome)
        XCTAssertNil(run.markerPath)
        XCTAssertFalse(run.decision.accepted)
        XCTAssertTrue(run.decision.reasons.contains { $0.contains("dry-run marker") }, run.text)
        XCTAssertTrue(run.text.contains("BLOCKED"))
    }

    func testAcquisitionRunDownloadWritesArtifactAttestationBeforeInspect() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fetcher = LiveModelMetadataFetcher { request in
            let json = """
            {
              "modelId": "owner/safe-model",
              "author": "owner",
              "cardData": { "license": "mit" },
              "tags": ["license:mit"],
              "gated": false,
              "private": false,
              "disabled": false,
              "sha": "0123456789abcdef0123456789abcdef01234567",
              "usedStorage": 123456789,
              "siblings": [
                { "rfilename": "README.md", "size": 10 },
                { "rfilename": "model.safetensors", "size": 32 },
                { "rfilename": "tokenizer_config.json", "size": 2 }
              ]
            }
            """
            return (Data(json.utf8), self.httpResponse(for: request))
        }
        let vet = await OrganizationalLearningStore(projectRoot: root,
                                                    now: { Date(timeIntervalSince1970: 1_700_006_200) })
            .runLiveModelMetadataGate(spec: "mlx:owner/safe-model", fetcher: fetcher)
        let manifestPath = try XCTUnwrap(vet.acquisitionManifestPath)
        let dryRun = OrganizationalLearningStore(projectRoot: root,
                                                 now: { Date(timeIntervalSince1970: 1_700_006_300) })
            .runLocalModelAcquisitionStage(stage: "dry-run", manifestPath: manifestPath) { command, _ in
                LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "dry-run",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "ok",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [] }
        let manifest = try XCTUnwrap(dryRun.manifest)
        let localDir = root + "/" + manifest.localDirectory
        try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)
        try "model card".write(toFile: localDir + "/README.md", atomically: true, encoding: .utf8)
        try Data(repeating: 1, count: 32).write(to: URL(fileURLWithPath: localDir + "/model.safetensors"))
        try "{}".write(toFile: localDir + "/tokenizer_config.json", atomically: true, encoding: .utf8)

        let download = OrganizationalLearningStore(projectRoot: root,
                                                   now: { Date(timeIntervalSince1970: 1_700_006_400) })
            .runLocalModelAcquisitionStage(stage: "download", manifestPath: manifestPath) { command, _ in
                LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "download",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "download ok",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [] }

        XCTAssertTrue(download.decision.accepted, download.text)
        XCTAssertEqual(download.artifactAttestation?.accepted, true)
        XCTAssertNotNil(download.markerPath)
        let attestationPath = try XCTUnwrap(download.artifactAttestationPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/" + attestationPath))
        XCTAssertTrue(download.text.contains("Artifact Attestation"))
        XCTAssertTrue(download.text.contains("PASS: local artifacts match the manifest gate"))

        var inspectWasCalled = false
        let inspect = OrganizationalLearningStore(projectRoot: root,
                                                  now: { Date(timeIntervalSince1970: 1_700_006_500) })
            .runLocalModelAcquisitionStage(stage: "inspect", manifestPath: manifestPath) { command, _ in
                inspectWasCalled = true
                return LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "inspect",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "inspect ok",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [] }

        XCTAssertTrue(inspectWasCalled)
        XCTAssertTrue(inspect.decision.accepted, inspect.text)
        XCTAssertNotNil(inspect.markerPath)
    }

    func testAcquisitionRunDownloadBlocksMarkerWhenArtifactAttestationFails() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fetcher = LiveModelMetadataFetcher { request in
            let json = """
            {
              "modelId": "owner/safe-model",
              "author": "owner",
              "cardData": { "license": "mit" },
              "tags": ["license:mit"],
              "gated": false,
              "private": false,
              "disabled": false,
              "sha": "0123456789abcdef0123456789abcdef01234567",
              "usedStorage": 123456789,
              "siblings": [
                { "rfilename": "README.md", "size": 10 },
                { "rfilename": "model.safetensors", "size": 32 },
                { "rfilename": "tokenizer_config.json", "size": 2 }
              ]
            }
            """
            return (Data(json.utf8), self.httpResponse(for: request))
        }
        let vet = await OrganizationalLearningStore(projectRoot: root,
                                                    now: { Date(timeIntervalSince1970: 1_700_006_600) })
            .runLiveModelMetadataGate(spec: "mlx:owner/safe-model", fetcher: fetcher)
        let manifestPath = try XCTUnwrap(vet.acquisitionManifestPath)
        _ = OrganizationalLearningStore(projectRoot: root,
                                        now: { Date(timeIntervalSince1970: 1_700_006_700) })
            .runLocalModelAcquisitionStage(stage: "dry-run", manifestPath: manifestPath) { command, _ in
                LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "dry-run",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "ok",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [] }

        let download = OrganizationalLearningStore(projectRoot: root,
                                                   now: { Date(timeIntervalSince1970: 1_700_006_800) })
            .runLocalModelAcquisitionStage(stage: "download", manifestPath: manifestPath) { command, _ in
                LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "download",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "download ok",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [] }

        XCTAssertEqual(download.outcome?.succeeded, true)
        XCTAssertFalse(download.decision.accepted)
        XCTAssertNil(download.markerPath)
        XCTAssertNotNil(download.artifactAttestationPath)
        XCTAssertEqual(download.artifactAttestation?.accepted, false)
        XCTAssertTrue(download.decision.reasons.contains { $0.contains("artifact attestation failed") }, download.text)
        XCTAssertTrue(download.text.contains("post-run gates failed"))
        XCTAssertTrue(download.text.contains("BLOCKED: local artifacts failed the manifest gate"))

        let plan = PlanStore(projectRoot: root).load()
        XCTAssertTrue(plan.tasks.contains { $0.title.contains("Repair local model artifact attestation") })
    }

    func testAcquisitionRunInspectRequiresArtifactAttestation() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fetcher = LiveModelMetadataFetcher { request in
            let json = """
            {
              "modelId": "owner/safe-model",
              "author": "owner",
              "cardData": { "license": "mit" },
              "tags": ["license:mit"],
              "gated": false,
              "private": false,
              "disabled": false,
              "sha": "0123456789abcdef0123456789abcdef01234567",
              "usedStorage": 123456789,
              "siblings": [
                { "rfilename": "README.md", "size": 10 },
                { "rfilename": "model.safetensors", "size": 32 },
                { "rfilename": "tokenizer_config.json", "size": 2 }
              ]
            }
            """
            return (Data(json.utf8), self.httpResponse(for: request))
        }
        let vet = await OrganizationalLearningStore(projectRoot: root,
                                                    now: { Date(timeIntervalSince1970: 1_700_006_900) })
            .runLiveModelMetadataGate(spec: "mlx:owner/safe-model", fetcher: fetcher)
        let manifestPath = try XCTUnwrap(vet.acquisitionManifestPath)
        let dryRun = OrganizationalLearningStore(projectRoot: root,
                                                 now: { Date(timeIntervalSince1970: 1_700_007_000) })
            .runLocalModelAcquisitionStage(stage: "dry-run", manifestPath: manifestPath) { command, _ in
                LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "dry-run",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "ok",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [] }
        let manifest = try XCTUnwrap(dryRun.manifest)
        let localDir = root + "/" + manifest.localDirectory
        try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)
        try "model card".write(toFile: localDir + "/README.md", atomically: true, encoding: .utf8)
        try Data(repeating: 1, count: 32).write(to: URL(fileURLWithPath: localDir + "/model.safetensors"))
        try "{}".write(toFile: localDir + "/tokenizer_config.json", atomically: true, encoding: .utf8)
        let download = OrganizationalLearningStore(projectRoot: root,
                                                   now: { Date(timeIntervalSince1970: 1_700_007_100) })
            .runLocalModelAcquisitionStage(stage: "download", manifestPath: manifestPath) { command, _ in
                LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "download",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "download ok",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [] }
        let attestationPath = try XCTUnwrap(download.artifactAttestationPath)
        try FileManager.default.removeItem(atPath: root + "/" + attestationPath)

        var inspectWasCalled = false
        let inspect = OrganizationalLearningStore(projectRoot: root,
                                                  now: { Date(timeIntervalSince1970: 1_700_007_200) })
            .runLocalModelAcquisitionStage(stage: "inspect", manifestPath: manifestPath) { command, _ in
                inspectWasCalled = true
                return LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "inspect",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "should not run",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [] }

        XCTAssertFalse(inspectWasCalled)
        XCTAssertFalse(inspect.decision.accepted)
        XCTAssertTrue(inspect.decision.reasons.contains { $0.contains("artifact attestation") }, inspect.text)
        XCTAssertNil(inspect.markerPath)
    }

    func testAcquisitionPreflightRejectsUnsealedSelfConsistentManifest() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let vet = await OrganizationalLearningStore(projectRoot: root,
                                                    now: { Date(timeIntervalSince1970: 1_700_007_300) })
            .runLiveModelMetadataGate(spec: "mlx:owner/safe-model",
                                      fetcher: safeHFMetadataFetcher())
        let manifestPath = try XCTUnwrap(vet.acquisitionManifestPath)
        let absolutePath = root + "/" + manifestPath
        var manifest = try JSONDecoder().decode(LocalModelAcquisitionManifest.self,
                                                from: Data(contentsOf: URL(fileURLWithPath: absolutePath)))
        manifest.seal = nil
        try LiveModelMetadataGate.manifestJSONData(manifest)
            .write(to: URL(fileURLWithPath: absolutePath), options: [.atomic])

        let preflight = OrganizationalLearningStore(projectRoot: root,
                                                    now: { Date(timeIntervalSince1970: 1_700_007_400) })
            .runLocalModelAcquisitionPreflight(manifestPath: manifestPath)

        XCTAssertFalse(preflight.decision.accepted)
        XCTAssertTrue(preflight.decision.reasons.contains { $0.contains("manifest seal") }, preflight.text)
    }

    func testAcquisitionRunDownloadRejectsTruncatedArtifact() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let vet = await OrganizationalLearningStore(projectRoot: root,
                                                    now: { Date(timeIntervalSince1970: 1_700_007_500) })
            .runLiveModelMetadataGate(spec: "mlx:owner/safe-model",
                                      fetcher: safeHFMetadataFetcher(modelSize: 64))
        let manifestPath = try XCTUnwrap(vet.acquisitionManifestPath)
        let dryRun = OrganizationalLearningStore(projectRoot: root,
                                                 now: { Date(timeIntervalSince1970: 1_700_007_600) })
            .runLocalModelAcquisitionStage(stage: "dry-run", manifestPath: manifestPath) { command, _ in
                LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "dry-run",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "ok",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [] }
        let manifest = try XCTUnwrap(dryRun.manifest)
        let localDir = root + "/" + manifest.localDirectory
        try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)
        try "model card".write(toFile: localDir + "/README.md", atomically: true, encoding: .utf8)
        try Data(repeating: 1, count: 32).write(to: URL(fileURLWithPath: localDir + "/model.safetensors"))
        try "{}".write(toFile: localDir + "/tokenizer_config.json", atomically: true, encoding: .utf8)

        let download = OrganizationalLearningStore(projectRoot: root,
                                                   now: { Date(timeIntervalSince1970: 1_700_007_700) })
            .runLocalModelAcquisitionStage(stage: "download", manifestPath: manifestPath) { command, _ in
                LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "download",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "download ok",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [] }

        XCTAssertFalse(download.decision.accepted)
        XCTAssertNil(download.markerPath)
        XCTAssertTrue(download.text.contains("artifact size mismatch"), download.text)
    }

    func testAcquisitionRunDownloadRejectsUnexpectedAllowedFile() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let vet = await OrganizationalLearningStore(projectRoot: root,
                                                    now: { Date(timeIntervalSince1970: 1_700_007_710) })
            .runLiveModelMetadataGate(spec: "mlx:owner/safe-model",
                                      fetcher: safeHFMetadataFetcher())
        let manifestPath = try XCTUnwrap(vet.acquisitionManifestPath)
        let dryRun = OrganizationalLearningStore(projectRoot: root,
                                                 now: { Date(timeIntervalSince1970: 1_700_007_720) })
            .runLocalModelAcquisitionStage(stage: "dry-run", manifestPath: manifestPath) { command, _ in
                LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "dry-run",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "ok",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [] }
        let manifest = try XCTUnwrap(dryRun.manifest)
        let localDir = root + "/" + manifest.localDirectory
        try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)
        try "model card".write(toFile: localDir + "/README.md", atomically: true, encoding: .utf8)
        try Data(repeating: 1, count: 32).write(to: URL(fileURLWithPath: localDir + "/model.safetensors"))
        try "{}".write(toFile: localDir + "/tokenizer_config.json", atomically: true, encoding: .utf8)
        try Data(repeating: 3, count: 32).write(to: URL(fileURLWithPath: localDir + "/old.safetensors"))

        let download = OrganizationalLearningStore(projectRoot: root,
                                                   now: { Date(timeIntervalSince1970: 1_700_007_730) })
            .runLocalModelAcquisitionStage(stage: "download", manifestPath: manifestPath) { command, _ in
                LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "download",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "download ok",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [] }

        XCTAssertFalse(download.decision.accepted)
        XCTAssertNil(download.markerPath)
        XCTAssertTrue(download.text.contains("unexpected artifact file 'old.safetensors'"), download.text)
    }

    func testAcquisitionRunInspectRejectsStaleMutatedArtifacts() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let vet = await OrganizationalLearningStore(projectRoot: root,
                                                    now: { Date(timeIntervalSince1970: 1_700_007_800) })
            .runLiveModelMetadataGate(spec: "mlx:owner/safe-model",
                                      fetcher: safeHFMetadataFetcher())
        let manifestPath = try XCTUnwrap(vet.acquisitionManifestPath)
        let dryRun = OrganizationalLearningStore(projectRoot: root,
                                                 now: { Date(timeIntervalSince1970: 1_700_007_900) })
            .runLocalModelAcquisitionStage(stage: "dry-run", manifestPath: manifestPath) { command, _ in
                LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "dry-run",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "ok",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [] }
        let manifest = try XCTUnwrap(dryRun.manifest)
        let localDir = root + "/" + manifest.localDirectory
        try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)
        try "model card".write(toFile: localDir + "/README.md", atomically: true, encoding: .utf8)
        try Data(repeating: 1, count: 32).write(to: URL(fileURLWithPath: localDir + "/model.safetensors"))
        try "{}".write(toFile: localDir + "/tokenizer_config.json", atomically: true, encoding: .utf8)
        let download = OrganizationalLearningStore(projectRoot: root,
                                                   now: { Date(timeIntervalSince1970: 1_700_008_000) })
            .runLocalModelAcquisitionStage(stage: "download", manifestPath: manifestPath) { command, _ in
                LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "download",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "download ok",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [] }
        XCTAssertTrue(download.decision.accepted, download.text)
        try Data(repeating: 2, count: 32).write(to: URL(fileURLWithPath: localDir + "/model.safetensors"))

        var inspectWasCalled = false
        let inspect = OrganizationalLearningStore(projectRoot: root,
                                                  now: { Date(timeIntervalSince1970: 1_700_008_100) })
            .runLocalModelAcquisitionStage(stage: "inspect", manifestPath: manifestPath) { command, _ in
                inspectWasCalled = true
                return LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "inspect",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "should not run",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [] }

        XCTAssertFalse(inspectWasCalled)
        XCTAssertFalse(inspect.decision.accepted)
        XCTAssertTrue(inspect.decision.reasons.contains { $0.contains("artifact attestation") }, inspect.text)
    }

    func testAcquisitionRunDownloadRejectsSymlinkedModelsParent() async throws {
        let root = tempRoot()
        let outside = tempRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outside)
        }
        let vet = await OrganizationalLearningStore(projectRoot: root,
                                                    now: { Date(timeIntervalSince1970: 1_700_008_200) })
            .runLiveModelMetadataGate(spec: "mlx:owner/safe-model",
                                      fetcher: safeHFMetadataFetcher())
        let manifestPath = try XCTUnwrap(vet.acquisitionManifestPath)
        let dryRun = OrganizationalLearningStore(projectRoot: root,
                                                 now: { Date(timeIntervalSince1970: 1_700_008_300) })
            .runLocalModelAcquisitionStage(stage: "dry-run", manifestPath: manifestPath) { command, _ in
                LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "dry-run",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "ok",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [] }
        let manifest = try XCTUnwrap(dryRun.manifest)
        try FileManager.default.createSymbolicLink(atPath: root + "/.kist/models",
                                                   withDestinationPath: outside)
        let localDir = root + "/" + manifest.localDirectory
        try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)
        try "model card".write(toFile: localDir + "/README.md", atomically: true, encoding: .utf8)
        try Data(repeating: 1, count: 32).write(to: URL(fileURLWithPath: localDir + "/model.safetensors"))
        try "{}".write(toFile: localDir + "/tokenizer_config.json", atomically: true, encoding: .utf8)

        let download = OrganizationalLearningStore(projectRoot: root,
                                                   now: { Date(timeIntervalSince1970: 1_700_008_400) })
            .runLocalModelAcquisitionStage(stage: "download", manifestPath: manifestPath) { command, _ in
                LocalModelAcquisitionRunOutcome(results: [
                    LocalModelAcquisitionProcessResult(label: "download",
                                                       command: command.invocations[0].display,
                                                       exitCode: 0,
                                                       timedOut: false,
                                                       stdout: "download ok",
                                                       stderr: "")
                ])
            } dependencyResolver: { _ in [] }

        XCTAssertFalse(download.decision.accepted)
        XCTAssertNil(download.markerPath)
        XCTAssertTrue(download.text.contains(".kist/models is a symbolic link"), download.text)
    }

    func testAcquisitionExecutableTrustRejectsProjectLocalBinary() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fakeHF = root + "/hf"
        try "#!/bin/sh\nexit 0\n".write(toFile: fakeHF, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeHF)
        let command = LocalModelAcquisitionRunnableCommand(
            stage: .dryRun,
            manifestCommand: "\(fakeHF) --help",
            invocations: [.init(label: "dry-run", executable: fakeHF, arguments: ["--help"])],
            timeoutSeconds: 1)

        let blockers = OrganizationalLearningStore
            .localModelAcquisitionExecutableTrustBlockers(command, projectRoot: root)

        XCTAssertTrue(blockers.contains { $0.contains("untrusted acquisition executable") }, blockers.joined())
    }

    func testHuggingFaceMetadataGateRejectsGatedUnknownLicenseUnsafeRepo() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fetcher = LiveModelMetadataFetcher { request in
            let json = """
            {
              "_id": "example/bad-model",
              "modelId": "example/bad-model",
              "author": "",
              "tags": [],
              "gated": "manual",
              "private": false,
              "disabled": false,
              "siblings": [
                { "rfilename": "README.md", "size": 10 }
              ]
            }
            """
            return (Data(json.utf8), self.httpResponse(for: request))
        }

        let report = await OrganizationalLearningStore(projectRoot: root)
            .runLiveModelMetadataGate(spec: "hf:example/bad-model", fetcher: fetcher)

        XCTAssertEqual(report.decision?.accepted, false)
        XCTAssertTrue(report.text.contains("REJECTED"))
        XCTAssertTrue(report.text.contains("repository is gated"))
        XCTAssertTrue(report.text.contains("missing machine-readable license"))
        XCTAssertTrue(report.text.contains("no safetensors or GGUF"))
        XCTAssertNil(report.acquisitionManifest)
        XCTAssertNil(report.acquisitionManifestPath)

        let plan = PlanStore(projectRoot: root).load()
        XCTAssertFalse(plan.tasks.contains { $0.title.contains("Verify acquisition manifest") })
        XCTAssertTrue(plan.tasks.contains { $0.title.contains("Resolve local model metadata blockers") })
    }

    func testAcceptedGateDoesNotSeedDownloadWhenManifestWriteFails() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let timestamp = 1_700_005_000
        let blockedManifestPath = root + "/.kist/learning/local-models/\(timestamp)-acquisition-mlx-owner-safe-model.json"
        try FileManager.default.createDirectory(atPath: blockedManifestPath, withIntermediateDirectories: true)
        let fetcher = LiveModelMetadataFetcher { request in
            let json = """
            {
              "modelId": "owner/safe-model",
              "author": "owner",
              "cardData": { "license": "mit" },
              "tags": ["license:mit"],
              "gated": false,
              "private": false,
              "disabled": false,
              "sha": "0123456789abcdef0123456789abcdef01234567",
              "usedStorage": 123456789,
              "siblings": [
                { "rfilename": "README.md", "size": 10 },
                { "rfilename": "--local-dir.safetensors", "size": 123456000 },
                { "rfilename": "tokenizer_config.json", "size": 2 }
              ]
            }
            """
            return (Data(json.utf8), self.httpResponse(for: request))
        }

        let report = await OrganizationalLearningStore(projectRoot: root,
                                                       now: { Date(timeIntervalSince1970: TimeInterval(timestamp)) })
            .runLiveModelMetadataGate(spec: "mlx:owner/safe-model", fetcher: fetcher)

        XCTAssertEqual(report.decision?.accepted, true)
        XCTAssertFalse(report.manifestWriteSucceeded)
        XCTAssertNotNil(report.manifestWriteError)
        XCTAssertNil(report.acquisitionManifest)
        XCTAssertNil(report.acquisitionManifestPath)
        XCTAssertTrue(report.writeSucceeded)
        XCTAssertTrue(report.text.contains("Manifest write error"))

        let plan = PlanStore(projectRoot: root).load()
        XCTAssertFalse(plan.tasks.contains { $0.title.contains("Verify acquisition manifest") })
        XCTAssertTrue(plan.tasks.contains { $0.title.contains("Resolve local model acquisition manifest persistence") })
    }

    func testParseRejectsUnsafeModelSpec() {
        XCTAssertNil(LiveModelMetadataGate.parseRequest("hf:../secret"))
        XCTAssertNil(LiveModelMetadataGate.parseRequest("hf:owner/repo?download=1"))
        XCTAssertNotNil(LiveModelMetadataGate.parseRequest("hf:owner/repo"))
        XCTAssertNotNil(LiveModelMetadataGate.parseRequest("ollama:qwen2.5-coder:7b"))
    }

    func testOllamaShowMetadataIsLocalVerificationOnly() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fetcher = LiveModelMetadataFetcher { request in
            XCTAssertEqual(request.url?.host, "localhost")
            let json = """
            {
              "license": "MIT",
              "size": 123456789,
              "details": {
                "format": "gguf",
                "family": "qwen2",
                "parameter_size": "7B",
                "quantization_level": "Q4_K_M"
              }
            }
            """
            return (Data(json.utf8), self.httpResponse(for: request))
        }

        let report = await OrganizationalLearningStore(projectRoot: root)
            .runLiveModelMetadataGate(spec: "ollama:qwen2.5-coder:7b", fetcher: fetcher)

        XCTAssertEqual(report.metadata?.source, .ollamaLocal)
        XCTAssertEqual(report.decision?.accepted, true)
        XCTAssertNil(report.acquisitionManifest?.commands.download)
        XCTAssertEqual(report.acquisitionManifest?.commands.inspect, "ollama show qwen2.5-coder:7b")
        XCTAssertTrue(report.decision?.warnings.contains { $0.contains("installed local model") } ?? false)
        XCTAssertTrue(report.text.contains("Ollama metadata verifies an installed local model"))
    }
}
