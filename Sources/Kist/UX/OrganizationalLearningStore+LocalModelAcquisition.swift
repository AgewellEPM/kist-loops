import Foundation
import AgentCore

extension OrganizationalLearningStore {
    func runLocalModelAcquisitionPreflight(manifestPath rawPath: String) -> LocalModelAcquisitionPreflightReport {
        ensureMemoryArchitecture()
        let cleanPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayPath = Self.safe(cleanPath.isEmpty ? "missing-manifest-path" : cleanPath)
        let timestamp = Int(now().timeIntervalSince1970)

        var manifest: LocalModelAcquisitionManifest?
        var loadError: String?
        var storedManifestPath = displayPath
        if cleanPath.isEmpty {
            loadError = "missing acquisition manifest path"
        } else if let resolved = resolveProjectFile(cleanPath) {
            storedManifestPath = Self.projectRelative(resolved, root: projectRoot)
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: resolved))
                manifest = try JSONDecoder().decode(LocalModelAcquisitionManifest.self, from: data)
            } catch {
                loadError = String(describing: error)
            }
        } else {
            loadError = "manifest path must exist inside the project root"
        }

        let decision = manifest.map(LiveModelMetadataGate.validateAcquisitionManifest)
            ?? LocalModelAcquisitionDecision(accepted: false,
                                             reasons: [loadError ?? "manifest unavailable"],
                                             warnings: [])
        let reportSlug = manifest?.approvalID ?? displayPath
        let path = localModelsRoot + "/\(timestamp)-acquire-\(Self.slug(reportSlug)).md"
        let relativePath = Self.projectRelative(path, root: projectRoot)
        let seededTasks = seedLocalModelAcquisitionPreflightTasks(manifestPath: storedManifestPath,
                                                                  manifest: manifest,
                                                                  decision: decision,
                                                                  reportPath: relativePath)
        let memoryRecords = recordLocalModelAcquisitionPreflightMemory(manifestPath: storedManifestPath,
                                                                       manifest: manifest,
                                                                       decision: decision,
                                                                       reportPath: relativePath,
                                                                       loadError: loadError)
        let text = renderLocalModelAcquisitionPreflight(manifestPath: storedManifestPath,
                                                        manifest: manifest,
                                                        decision: decision,
                                                        reportPath: relativePath,
                                                        seededTasks: seededTasks,
                                                        memoryRecords: memoryRecords,
                                                        loadError: loadError)
        var writeSucceeded = false
        var writeError: String?
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            writeSucceeded = true
        } catch {
            writeError = String(describing: error)
        }
        return LocalModelAcquisitionPreflightReport(path: relativePath,
                                                    text: text,
                                                    manifestPath: storedManifestPath,
                                                    manifest: manifest,
                                                    decision: decision,
                                                    seededTasks: seededTasks,
                                                    memoryRecords: memoryRecords,
                                                    writeSucceeded: writeSucceeded,
                                                    writeError: writeError,
                                                    loadError: loadError)
    }

    func runLocalModelAcquisitionStage(stage rawStage: String,
                                       manifestPath rawPath: String,
                                       executor: LocalModelAcquisitionExecutor = OrganizationalLearningStore.executeLocalModelAcquisitionCommand,
                                       dependencyResolver: LocalModelAcquisitionDependencyResolver = OrganizationalLearningStore.localModelAcquisitionDependencyBlockers) -> LocalModelAcquisitionRunReport {
        ensureMemoryArchitecture()
        let cleanPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayPath = Self.safe(cleanPath.isEmpty ? "missing-manifest-path" : cleanPath)
        let timestamp = Int(now().timeIntervalSince1970)
        let stage = LocalModelAcquisitionStage.parse(rawStage)

        var manifest: LocalModelAcquisitionManifest?
        var loadError: String?
        var storedManifestPath = displayPath
        if cleanPath.isEmpty {
            loadError = "missing acquisition manifest path"
        } else if let resolved = resolveProjectFile(cleanPath) {
            storedManifestPath = Self.projectRelative(resolved, root: projectRoot)
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: resolved))
                manifest = try JSONDecoder().decode(LocalModelAcquisitionManifest.self, from: data)
            } catch {
                loadError = String(describing: error)
            }
        } else {
            loadError = "manifest path must exist inside the project root"
        }

        var decision = manifest.map(LiveModelMetadataGate.validateAcquisitionManifest)
            ?? LocalModelAcquisitionDecision(accepted: false,
                                             reasons: [loadError ?? "manifest unavailable"],
                                             warnings: [])
        if stage == nil {
            decision.accepted = false
            decision.reasons.append("unknown acquisition stage '\(rawStage)'")
        }

        var command: LocalModelAcquisitionRunnableCommand?
        if let stage, let manifest, decision.accepted {
            command = LiveModelMetadataGate.runnableCommand(for: stage, manifest: manifest)
            if command == nil {
                decision.accepted = false
                decision.reasons.append("manifest does not authorize acquisition stage '\(stage.rawValue)'")
            }
        }
        if let stage, let manifest, decision.accepted {
            let blockers = localModelAcquisitionStageBlockers(stage: stage, manifest: manifest)
            if !blockers.isEmpty {
                decision.accepted = false
                decision.reasons.append(contentsOf: blockers)
            }
        }
        if let command, decision.accepted {
            let mismatches = command.invocations
                .filter { $0.display != command.manifestCommand && command.stage != .benchmark }
                .map { "structured invocation '\($0.display)' does not match manifest command '\(command.manifestCommand)'" }
            if !mismatches.isEmpty {
                decision.accepted = false
                decision.reasons.append(contentsOf: mismatches)
            }
        }
        var dependencyBlockers: [LocalModelAcquisitionDependencyBlocker] = []
        if let command, decision.accepted {
            dependencyBlockers = dependencyResolver(command)
            if !dependencyBlockers.isEmpty {
                decision.accepted = false
                decision.reasons.append(contentsOf: dependencyBlockers.map {
                    "missing dependency '\($0.executable)': \($0.reason)"
                })
            }
        }
        if let command, decision.accepted {
            let executableBlockers = Self.localModelAcquisitionExecutableTrustBlockers(command,
                                                                                      projectRoot: projectRoot)
            if !executableBlockers.isEmpty {
                decision.accepted = false
                decision.reasons.append(contentsOf: executableBlockers)
            }
        }
        decision.reasons = Self.unique(decision.reasons)
        decision.warnings = Self.unique(decision.warnings)

        var outcome: LocalModelAcquisitionRunOutcome?
        if decision.accepted, let command {
            outcome = executor(command, projectRoot)
            if outcome?.succeeded != true {
                decision.accepted = false
                decision.reasons.append("acquisition stage command failed")
                decision.reasons = Self.unique(decision.reasons)
            }
        }

        var artifactAttestation: LocalModelAcquisitionArtifactAttestation?
        var artifactAttestationPath: String?
        if stage == .download, let manifest, outcome?.succeeded == true {
            let attestation = makeLocalModelAcquisitionArtifactAttestation(manifest: manifest)
            artifactAttestation = attestation
            artifactAttestationPath = writeLocalModelAcquisitionArtifactAttestation(attestation, manifest: manifest)
            if artifactAttestationPath == nil {
                decision.accepted = false
                decision.reasons.append("artifact attestation could not be written")
            }
            if !attestation.accepted {
                decision.accepted = false
                decision.reasons.append(contentsOf: attestation.blockers.map { "artifact attestation failed: \($0)" })
            }
            decision.reasons = Self.unique(decision.reasons)
            decision.warnings = Self.unique(decision.warnings + attestation.warnings)
        }

        let reportSlug = [manifest?.approvalID, stage?.rawValue].compactMap { $0 }.joined(separator: "-")
        let path = localModelsRoot + "/\(timestamp)-run-\(Self.slug(reportSlug.isEmpty ? displayPath : reportSlug)).md"
        let relativePath = Self.projectRelative(path, root: projectRoot)
        var markerPath: String?
        if let stage, let manifest, outcome?.succeeded == true, decision.accepted {
            markerPath = writeLocalModelAcquisitionStageMarker(stage: stage,
                                                               manifest: manifest,
                                                               command: command?.manifestCommand ?? "",
                                                               reportPath: relativePath)
            if markerPath == nil {
                decision.accepted = false
                decision.reasons.append("success marker could not be written")
                decision.reasons = Self.unique(decision.reasons)
            }
        }
        let seededTasks = seedLocalModelAcquisitionRunTasks(manifestPath: storedManifestPath,
                                                            manifest: manifest,
                                                            stage: stage,
                                                            decision: decision,
                                                            dependencyBlockers: dependencyBlockers,
                                                            artifactAttestation: artifactAttestation,
                                                            artifactAttestationPath: artifactAttestationPath,
                                                            reportPath: relativePath)
        let memoryRecords = recordLocalModelAcquisitionRunMemory(manifestPath: storedManifestPath,
                                                                 manifest: manifest,
                                                                 stage: stage,
                                                                 decision: decision,
                                                                 reportPath: relativePath)
        let text = renderLocalModelAcquisitionRun(manifestPath: storedManifestPath,
                                                  stage: stage,
                                                  manifest: manifest,
                                                  decision: decision,
                                                  command: command,
                                                  outcome: outcome,
                                                  dependencyBlockers: dependencyBlockers,
                                                  artifactAttestation: artifactAttestation,
                                                  artifactAttestationPath: artifactAttestationPath,
                                                  reportPath: relativePath,
                                                  markerPath: markerPath,
                                                  seededTasks: seededTasks,
                                                  memoryRecords: memoryRecords,
                                                  loadError: loadError)
        var writeSucceeded = false
        var writeError: String?
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            writeSucceeded = true
        } catch {
            writeError = String(describing: error)
        }
        return LocalModelAcquisitionRunReport(path: relativePath,
                                              text: text,
                                              manifestPath: storedManifestPath,
                                              stage: stage,
                                              manifest: manifest,
                                              decision: decision,
                                              command: command,
                                              outcome: outcome,
                                              markerPath: markerPath,
                                              dependencyBlockers: dependencyBlockers,
                                              artifactAttestation: artifactAttestation,
                                              artifactAttestationPath: artifactAttestationPath,
                                              seededTasks: seededTasks,
                                              memoryRecords: memoryRecords,
                                              writeSucceeded: writeSucceeded,
                                              writeError: writeError,
                                              loadError: loadError)
    }

    func renderLocalModelAcquisitionPreflight(manifestPath: String,
                                                      manifest: LocalModelAcquisitionManifest?,
                                                      decision: LocalModelAcquisitionDecision,
                                                      reportPath: String,
                                                      seededTasks: Int,
                                                      memoryRecords: Int,
                                                      loadError: String?) -> String {
        var lines = [
            "# Local Model Acquisition Preflight",
            "",
            "Manifest: \(manifestPath)",
            "",
            "## Result",
            decision.accepted ? "VERIFIED: acquisition manifest is intact and policy-approved." : "REJECTED: acquisition manifest failed verification.",
            ""
        ]
        if let loadError {
            lines += ["Load error: \(loadError)", ""]
        }
        if let manifest {
            lines += [
                "Approval ID: \(manifest.approvalID)",
                "Policy: \(manifest.policyVersion)",
                "Model: \(manifest.modelID)",
                "Provider hint: \(manifest.providerHint)",
                "Source: \(manifest.sourceURL)",
                "License: \(manifest.license)",
                "Revision SHA: \(manifest.revisionSHA ?? "not applicable")",
                "Local directory: \(manifest.localDirectory)",
                ""
            ]
        }
        lines += ["Reasons:"]
        lines += decision.reasons.isEmpty ? ["- none"] : decision.reasons.map { "- \($0)" }
        lines += ["", "Warnings:"]
        lines += decision.warnings.isEmpty ? ["- none"] : decision.warnings.map { "- \($0)" }
        if decision.accepted, let manifest {
            lines += [
                "",
                "## Approved Command Set",
                "- dry-run: \(manifest.commands.dryRun ?? "not available")",
                "- download: \(manifest.commands.download ?? "not authorized by this manifest")",
                "- inspect: \(manifest.commands.inspect)",
                "- onboard: \(manifest.commands.onboard ?? "not available")",
                "- benchmark: \(manifest.commands.benchmark)",
                "",
                "## Hard Rule",
                "Run the dry-run first. Do not run any download command except the exact command above."
            ]
        } else {
            lines += [
                "",
                "## Hard Rule",
                "Do not download. Re-run `/model vet` and use a freshly verified acquisition manifest."
            ]
        }
        lines += [
            "",
            "## Artifacts",
            "Report: \(reportPath)",
            "Seeded tasks: \(seededTasks)",
            "Knowledge index records: \(memoryRecords)"
        ]
        return lines.joined(separator: "\n")
    }

    func renderLocalModelAcquisitionRun(manifestPath: String,
                                                stage: LocalModelAcquisitionStage?,
                                                manifest: LocalModelAcquisitionManifest?,
                                                decision: LocalModelAcquisitionDecision,
                                                command: LocalModelAcquisitionRunnableCommand?,
                                                outcome: LocalModelAcquisitionRunOutcome?,
                                                dependencyBlockers: [LocalModelAcquisitionDependencyBlocker],
                                                artifactAttestation: LocalModelAcquisitionArtifactAttestation?,
                                                artifactAttestationPath: String?,
                                                reportPath: String,
                                                markerPath: String?,
                                                seededTasks: Int,
                                                memoryRecords: Int,
                                                loadError: String?) -> String {
        let resultLine: String
        if outcome?.succeeded == true, decision.accepted {
            resultLine = "PASS: acquisition stage completed and evidence was recorded."
        } else if outcome?.succeeded == true {
            resultLine = "FAIL: acquisition stage command ran, but post-run gates failed."
        } else if outcome != nil {
            resultLine = "FAIL: acquisition stage command ran but did not pass."
        } else if decision.accepted {
            resultLine = "READY: acquisition stage is approved but did not run."
        } else {
            resultLine = "BLOCKED: acquisition stage was not allowed to run."
        }
        var lines = [
            "# Local Model Acquisition Run",
            "",
            "Manifest: \(manifestPath)",
            "Stage: \(stage?.rawValue ?? "unknown")",
            "",
            "## Result",
            resultLine,
            ""
        ]
        if let loadError {
            lines += ["Load error: \(loadError)", ""]
        }
        if let manifest {
            lines += [
                "Approval ID: \(manifest.approvalID)",
                "Policy hash: \(manifest.policyHash)",
                "Model: \(manifest.modelID)",
                "Provider hint: \(manifest.providerHint)",
                "Local directory: \(manifest.localDirectory)",
                ""
            ]
        }
        lines += ["Reasons:"]
        lines += decision.reasons.isEmpty ? ["- none"] : decision.reasons.map { "- \($0)" }
        lines += ["", "Warnings:"]
        lines += decision.warnings.isEmpty ? ["- none"] : decision.warnings.map { "- \($0)" }
        if !dependencyBlockers.isEmpty {
            lines += ["", "## Dependency Preflight"]
            for blocker in dependencyBlockers {
                lines += [
                    "",
                    "Missing: \(blocker.executable)",
                    "Reason: \(blocker.reason)",
                    "Setup: \(blocker.setupCommand)",
                    "Verify: \(blocker.verifyCommand)"
                ]
            }
        }
        if let artifactAttestation {
            lines += [
                "",
                "## Artifact Attestation",
                artifactAttestation.accepted ? "PASS: local artifacts match the manifest gate." : "BLOCKED: local artifacts failed the manifest gate.",
                "",
                "Path: \(artifactAttestationPath ?? "not written")",
                "Required files: \(artifactAttestation.requiredFilesPresent ? "present" : "missing")",
                "Files scanned: \(artifactAttestation.fileCount)",
                "Total size: \(LiveModelMetadataGate.formatBytes(artifactAttestation.totalBytes))",
                "",
                "Blockers:"
            ]
            lines += artifactAttestation.blockers.isEmpty ? ["- none"] : artifactAttestation.blockers.map { "- \($0)" }
            lines += ["", "Warnings:"]
            lines += artifactAttestation.warnings.isEmpty ? ["- none"] : artifactAttestation.warnings.map { "- \($0)" }
            if !artifactAttestation.sampledFiles.isEmpty {
                lines += ["", "Files sampled:"]
                lines += artifactAttestation.sampledFiles.prefix(20).map {
                    "- \($0.path) (\(LiveModelMetadataGate.formatBytes($0.bytes)))"
                }
                if artifactAttestation.sampledFiles.count > 20 {
                    lines.append("- ... +\(artifactAttestation.sampledFiles.count - 20) more")
                }
            }
        }
        if let command {
            lines += [
                "",
                "## Manifest Command",
                command.manifestCommand,
                "",
                "## Structured Invocation"
            ]
            for invocation in command.invocations {
                lines.append("- \(invocation.label): \(invocation.display)")
            }
        }
        if let outcome {
            lines += ["", "## Command Output"]
            for result in outcome.results {
                lines += [
                    "",
                    "### \(result.label)",
                    "Command: \(result.command)",
                    "Exit: \(result.exitCode)\(result.timedOut ? " (timed out)" : "")",
                    "Stdout:",
                    Self.trimCommandOutput(result.stdout),
                    "Stderr:",
                    Self.trimCommandOutput(result.stderr)
                ]
            }
        } else {
            lines += [
                "",
                "## Command Output",
                "No command executed."
            ]
        }
        lines += [
            "",
            "## Artifacts",
            "Report: \(reportPath)",
            "Success marker: \(markerPath ?? "not written")",
            "Artifact attestation: \(artifactAttestationPath ?? "not written")",
            "Seeded tasks: \(seededTasks)",
            "Knowledge index records: \(memoryRecords)"
        ]
        return lines.joined(separator: "\n")
    }

    func localModelAcquisitionStageBlockers(stage: LocalModelAcquisitionStage,
                                                    manifest: LocalModelAcquisitionManifest) -> [String] {
        var blockers: [String] = []
        let isHF = manifest.source == LiveModelMetadata.Source.huggingFace.rawValue
        switch stage {
        case .dryRun:
            break
        case .download:
            if !localModelAcquisitionStagePassed(.dryRun, manifest: manifest) {
                blockers.append("download requires a successful dry-run marker for the same approvalID and policyHash")
            }
        case .inspect:
            let downloadPassed = localModelAcquisitionStagePassed(.download, manifest: manifest)
            if isHF && !downloadPassed {
                blockers.append("inspect requires a successful download marker for the same approvalID and policyHash")
            } else if isHF && !localModelAcquisitionArtifactAttestationPassed(manifest: manifest) {
                blockers.append("inspect requires a successful local artifact attestation for the same approvalID and policyHash")
            }
        case .onboard:
            if !localModelAcquisitionStagePassed(.inspect, manifest: manifest) {
                blockers.append("onboard requires a successful inspect marker for the same approvalID and policyHash")
            }
        case .benchmark:
            if !localModelAcquisitionStagePassed(.onboard, manifest: manifest) {
                blockers.append("benchmark requires a successful onboard marker for the same approvalID and policyHash")
            }
        }
        return blockers
    }

    func seedLocalModelAcquisitionPreflightTasks(manifestPath: String,
                                                        manifest: LocalModelAcquisitionManifest?,
                                                        decision: LocalModelAcquisitionDecision,
                                                        reportPath: String) -> Int {
        let store = PlanStore(projectRoot: projectRoot)
        var count = 0
        func add(_ title: String, _ kind: PlanTask.Kind, _ owner: String,
                 _ detail: String, _ acceptance: String, _ verification: String,
                 _ evidence: [String]) {
            guard !localModelScoutTaskExists(title: title) else { return }
            store.add(title: title,
                      detail: detail,
                      owner: owner,
                      kind: kind,
                      acceptance: acceptance,
                      verification: verification,
                      evidence: evidence)
            count += 1
        }

        let evidence = [reportPath, manifestPath]
        if decision.accepted, let manifest {
            add("ACTION: Run local model acquisition dry-run -- \(manifest.approvalID)", .action, "local-model-scout",
                "Execute only the manifest dry-run command and compare expected files, size, local directory, source, and revision.",
                "Dry-run completes without changing the default model and confirms the pinned revision/local directory.",
                manifest.commands.dryRun ?? "ollama show \(manifest.modelID)",
                evidence)
            if let download = manifest.commands.download {
                add("ACTION: Download manifest-approved local model -- \(manifest.approvalID)", .action, "local-model-scout",
                    "Download only after the dry-run passes, using the exact manifest command.",
                    "Model files land under \(manifest.localDirectory); no default routing changes happen during download.",
                    download,
                    evidence)
            }
            add("TEST: Inspect/onboard manifest-approved local model -- \(manifest.approvalID)", .test, "local-model-scout",
                "Inspect template/stops and run onboarding before any worker can route to this model.",
                "`kist --inspect-model` and onboarding evidence are attached, or the model is rejected.",
                [manifest.commands.inspect, manifest.commands.onboard].compactMap { $0 }.joined(separator: " && "),
                evidence)
            add("DECISION: Promote or reject manifest-approved local model -- \(manifest.approvalID)", .decision, "captain",
                "Decide whether the model remains shadow-only, becomes role-bound, or is rejected.",
                "Decision includes benchmark/eval evidence, rollback path, and a Teach Captain rule only if durable.",
                manifest.commands.benchmark,
                evidence)
        } else {
            let blockers = decision.reasons.joined(separator: "; ")
            add("REVIEW: Reject or repair local model acquisition manifest -- \(manifestPath)", .review, "local-model-scout",
                "Do not download from this manifest. Blockers: \(blockers)",
                "A fresh `/model vet` manifest is generated and passes `/model acquire` before any download command is used.",
                "/model vet <spec> && /model acquire <manifest.json>",
                [reportPath])
        }
        return count
    }

    func seedLocalModelAcquisitionRunTasks(manifestPath: String,
                                                   manifest: LocalModelAcquisitionManifest?,
                                                   stage: LocalModelAcquisitionStage?,
                                                   decision: LocalModelAcquisitionDecision,
                                                   dependencyBlockers: [LocalModelAcquisitionDependencyBlocker],
                                                   artifactAttestation: LocalModelAcquisitionArtifactAttestation?,
                                                   artifactAttestationPath: String?,
                                                   reportPath: String) -> Int {
        let store = PlanStore(projectRoot: projectRoot)
        var count = 0
        func add(_ title: String, _ kind: PlanTask.Kind, _ owner: String,
                 _ detail: String, _ acceptance: String, _ verification: String,
                 _ evidence: [String]) {
            guard !localModelScoutTaskExists(title: title) else { return }
            store.add(title: title,
                      detail: detail,
                      owner: owner,
                      kind: kind,
                      acceptance: acceptance,
                      verification: verification,
                      evidence: evidence)
            count += 1
        }
        guard let manifest, let stage else { return 0 }
        let evidence = [reportPath, manifestPath]
        if !dependencyBlockers.isEmpty {
            for blocker in dependencyBlockers {
                add("ACTION: Install local model acquisition dependency -- \(blocker.executable)", .action, "local-model-scout",
                    "Install the missing executable before retrying the \(stage.rawValue) stage. Reason: \(blocker.reason)",
                    "`\(blocker.verifyCommand)` succeeds and the acquisition stage can be retried without dependency blockers.",
                    "\(blocker.setupCommand) && \(blocker.verifyCommand)",
                    evidence)
            }
        } else if stage == .download, let artifactAttestation, !artifactAttestation.accepted {
            let blockerText = artifactAttestation.blockers.joined(separator: "; ")
            add("REVIEW: Repair local model artifact attestation -- \(manifest.approvalID)", .review, "local-model-scout",
                "The download command ran, but artifact attestation blocked promotion. Blockers: \(blockerText)",
                "Local files match the manifest, unsafe artifacts are removed, and `/model run download \(manifestPath)` writes both attestation and success marker.",
                "/model run download \(manifestPath)",
                evidence + [artifactAttestationPath].compactMap { $0 })
        } else if decision.accepted {
            switch stage {
            case .dryRun:
                if let download = manifest.commands.download {
                    add("ACTION: Download manifest-approved local model -- \(manifest.approvalID)", .action, "local-model-scout",
                        "The dry-run passed; download may now run, but only through the manifest runner.",
                        "Download completes into \(manifest.localDirectory) and records a matching success marker.",
                        "/model run download \(manifestPath)",
                        evidence + [download])
                }
            case .download:
                add("TEST: Inspect manifest-approved local model -- \(manifest.approvalID)", .test, "local-model-scout",
                    "The download passed; inspect the template/stops before onboarding.",
                    "Inspect command passes and records a matching success marker.",
                    "/model run inspect \(manifestPath)",
                    evidence + [manifest.commands.inspect])
            case .inspect:
                if manifest.commands.onboard != nil {
                    add("TEST: Onboard manifest-approved local model -- \(manifest.approvalID)", .test, "local-model-scout",
                        "The inspect stage passed; run onboarding before any worker can use the model.",
                        "Onboarding passes and records a matching success marker.",
                        "/model run onboard \(manifestPath)",
                        evidence)
                }
            case .onboard:
                add("DECISION: Benchmark/promote manifest-approved local model -- \(manifest.approvalID)", .decision, "captain",
                    "Onboarding passed; compare this model against the current default before promotion.",
                    "Benchmark/eval evidence supports a role-bound promotion, shadow-only status, or rejection.",
                    "/model run benchmark \(manifestPath)",
                    evidence + [manifest.commands.benchmark])
            case .benchmark:
                add("DECISION: Teach or reject local model promotion -- \(manifest.approvalID)", .decision, "captain",
                    "Benchmarking completed; promote only if evidence beats the current route for a specific role.",
                    "A Teach Captain rule exists for the role binding, or rejection rationale is recorded.",
                    "/teach local model \(manifest.modelID) only after benchmark evidence supports a role-bound route",
                    evidence)
            }
        } else {
            add("REVIEW: Repair blocked local model acquisition stage -- \(manifest.approvalID)", .review, "local-model-scout",
                "Stage \(stage.rawValue) did not run. Blockers: \(decision.reasons.joined(separator: "; "))",
                "The missing prior marker, manifest issue, or command failure is repaired before retry.",
                "/model acquire \(manifestPath)",
                evidence)
        }
        return count
    }

    @discardableResult
    func recordLocalModelAcquisitionPreflightMemory(manifestPath: String,
                                                           manifest: LocalModelAcquisitionManifest?,
                                                           decision: LocalModelAcquisitionDecision,
                                                           reportPath: String,
                                                           loadError: String?) -> Int {
        let verdict = decision.accepted ? "verified" : "rejected"
        let reasons = decision.reasons.isEmpty ? "none" : decision.reasons.joined(separator: "; ")
        let details = [
            "Manifest: \(manifestPath)",
            "Verdict: \(verdict)",
            "Model: \(manifest?.modelID ?? "unknown")",
            "Approval ID: \(manifest?.approvalID ?? "none")",
            "Policy: \(manifest?.policyVersion ?? "unknown")",
            "Reasons: \(reasons)",
            "Load error: \(loadError ?? "none")"
        ].joined(separator: "\n")
        let record = DiskMemoryRecord(
            id: "AA-local-model-acquire-\(Self.slug(manifest?.approvalID ?? manifestPath).prefix(48))",
            title: "Local Model Acquisition Preflight: \(manifest?.modelID ?? manifestPath)",
            summary: "\(verdict.uppercased()): \(manifest?.modelID ?? manifestPath) -- \(reasons)",
            body: details,
            source: reportPath,
            confidence: decision.accepted ? 88 : 72,
            impact: 4,
            tags: ["local-model", "acquisition-manifest", "download-gate", manifest?.providerHint ?? "unknown"]
        )
        var records = loadJSONL(DiskMemoryRecord.self, path: knowledgeIndexPath)
        if let idx = records.firstIndex(where: { $0.id == record.id }) {
            records[idx] = record
        } else {
            records.append(record)
        }
        return saveJSONL(records, to: knowledgeIndexPath) ? 1 : 0
    }

    func recordLocalModelAcquisitionRunMemory(manifestPath: String,
                                                      manifest: LocalModelAcquisitionManifest?,
                                                      stage: LocalModelAcquisitionStage?,
                                                      decision: LocalModelAcquisitionDecision,
                                                      reportPath: String) -> Int {
        let verdict = decision.accepted ? "passed" : "blocked"
        let title = "Local model acquisition \(stage?.rawValue ?? "unknown") \(verdict): \(manifest?.modelID ?? manifestPath)"
        let body = [
            "Manifest: \(manifestPath)",
            "Report: \(reportPath)",
            "Approval: \(manifest?.approvalID ?? "none")",
            "Stage: \(stage?.rawValue ?? "unknown")",
            "Reasons: \(decision.reasons.isEmpty ? "none" : decision.reasons.joined(separator: "; "))"
        ].joined(separator: "\n")
        let record = DiskMemoryRecord(
            id: "AA-local-model-run-\(Self.slug((manifest?.approvalID ?? manifestPath) + "-" + (stage?.rawValue ?? "unknown")).prefix(48))",
            title: title,
            summary: "\(verdict.uppercased()): \(stage?.rawValue ?? "unknown") -- \(manifest?.modelID ?? manifestPath)",
            body: body,
            source: reportPath,
            confidence: decision.accepted ? 88 : 72,
            impact: 4,
            tags: ["local-model", "acquisition-run", stage?.rawValue ?? "unknown", manifest?.providerHint ?? "unknown"]
        )
        var records = loadJSONL(DiskMemoryRecord.self, path: knowledgeIndexPath)
        if let idx = records.firstIndex(where: { $0.id == record.id }) {
            records[idx] = record
        } else {
            records.append(record)
        }
        return saveJSONL(records, to: knowledgeIndexPath) ? 1 : 0
    }

}
