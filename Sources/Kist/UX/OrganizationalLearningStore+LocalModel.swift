import Foundation
import AgentCore

extension OrganizationalLearningStore {
    func runLocalModelScout(objective rawObjective: String) -> LocalModelScoutReport {
        ensureMemoryArchitecture()
        let objective = Self.safe(rawObjective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "safe local model acquisition"
            : rawObjective.trimmingCharacters(in: .whitespacesAndNewlines))
        let hardwareMemoryGB = LocalModelScout.defaultMemoryGB()
        let candidates = LocalModelScout.plan(objective: objective,
                                              hardwareMemoryGB: hardwareMemoryGB)
        let timestamp = Int(now().timeIntervalSince1970)
        let path = localModelsRoot + "/\(timestamp)-\(Self.slug(objective)).md"
        let relativePath = Self.projectRelative(path, root: projectRoot)
        let seededTasks = seedLocalModelScoutTasks(objective: objective,
                                                   candidates: candidates,
                                                   reportPath: relativePath)
        var memoryRecords = 0
        var text = LocalModelScout.render(objective: objective,
                                          hardwareMemoryGB: hardwareMemoryGB,
                                          candidates: candidates,
                                          reportPath: relativePath,
                                          seededTasks: seededTasks,
                                          memoryRecords: memoryRecords)
        var writeSucceeded = false
        var writeError: String?
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            writeSucceeded = true

            memoryRecords = recordLocalModelScoutMemory(objective: objective,
                                                        candidates: candidates,
                                                        reportPath: relativePath)
            let finalizedText = LocalModelScout.render(objective: objective,
                                                       hardwareMemoryGB: hardwareMemoryGB,
                                                       candidates: candidates,
                                                       reportPath: relativePath,
                                                       seededTasks: seededTasks,
                                                       memoryRecords: memoryRecords)
            try (finalizedText + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            text = finalizedText
        } catch {
            writeSucceeded = false
            writeError = String(describing: error)
        }
        return LocalModelScoutReport(path: relativePath,
                                     text: text,
                                     objective: objective,
                                     hardwareMemoryGB: hardwareMemoryGB,
                                     candidates: candidates,
                                     seededTasks: seededTasks,
                                     memoryRecords: memoryRecords,
                                     writeSucceeded: writeSucceeded,
                                     writeError: writeError)
    }

    func runLiveModelMetadataGate(spec rawSpec: String,
                                  fetcher: LiveModelMetadataFetcher = LiveModelMetadataFetcher()) async -> LiveModelMetadataGateReport {
        ensureMemoryArchitecture()
        let cleanSpec = rawSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        let displaySpec = Self.safe(cleanSpec.isEmpty ? "missing-model-spec" : cleanSpec)
        let createdAt = now().timeIntervalSince1970
        let timestamp = Int(createdAt)
        let path = localModelsRoot + "/\(timestamp)-metadata-\(Self.slug(displaySpec)).md"
        let relativePath = Self.projectRelative(path, root: projectRoot)

        var metadata: LiveModelMetadata?
        var decision: LiveModelMetadataDecision?
        var acquisitionManifest: LocalModelAcquisitionManifest?
        var acquisitionManifestPath: String?
        var manifestRequired = false
        var manifestWriteSucceeded = false
        var manifestWriteError: String?
        var fetchError: String?
        if let request = LiveModelMetadataGate.parseRequest(cleanSpec) {
            switch await fetcher.fetch(request) {
            case .success(let fetched):
                metadata = fetched
                decision = LiveModelMetadataDecision.evaluate(fetched)
                if let decision, decision.accepted,
                   let manifest = LiveModelMetadataGate.makeAcquisitionManifest(spec: displaySpec,
                                                                                metadata: fetched,
                                                                                decision: decision,
                                                                                gateReportPath: relativePath,
                                                                                createdAt: createdAt) {
                    manifestRequired = true
                    let manifestPath = localModelsRoot + "/\(timestamp)-acquisition-\(Self.slug(displaySpec)).json"
                    let manifestRelativePath = Self.projectRelative(manifestPath, root: projectRoot)
                    do {
                        let data = try LiveModelMetadataGate.manifestJSONData(manifest)
                        try FileManager.default.createDirectory(atPath: (manifestPath as NSString).deletingLastPathComponent,
                                                                withIntermediateDirectories: true)
                        try data.write(to: URL(fileURLWithPath: manifestPath), options: .atomic)
                        acquisitionManifest = manifest
                        acquisitionManifestPath = manifestRelativePath
                        manifestWriteSucceeded = true
                    } catch {
                        manifestWriteError = String(describing: error)
                    }
                }
            case .failure(let error):
                fetchError = String(describing: error)
            }
        } else {
            fetchError = "invalid model spec; use hf:<owner/repo>, mlx:<owner/repo>, or ollama:<tag>"
        }

        let seededTasks = seedLiveModelMetadataGateTasks(spec: displaySpec,
                                                         metadata: metadata,
                                                         decision: decision,
                                                         reportPath: relativePath,
                                                         manifestPath: acquisitionManifestPath,
                                                         manifest: acquisitionManifest,
                                                         manifestWriteSucceeded: !manifestRequired || manifestWriteSucceeded,
                                                         manifestWriteError: manifestWriteError,
                                                         fetchError: fetchError)
        var memoryRecords = 0
        var text = LiveModelMetadataGate.render(spec: displaySpec,
                                                metadata: metadata,
                                                decision: decision,
                                                fetchError: fetchError,
                                                acquisitionManifest: acquisitionManifest,
                                                acquisitionManifestPath: acquisitionManifestPath,
                                                manifestWriteSucceeded: !manifestRequired || manifestWriteSucceeded,
                                                manifestWriteError: manifestWriteError,
                                                path: relativePath,
                                                seededTasks: seededTasks,
                                                memoryRecords: memoryRecords)
        var writeSucceeded = false
        var writeError: String?
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            writeSucceeded = true

            memoryRecords = recordLiveModelMetadataGateMemory(spec: displaySpec,
                                                              metadata: metadata,
                                                              decision: decision,
                                                              reportPath: relativePath,
                                                              fetchError: fetchError)
            let finalizedText = LiveModelMetadataGate.render(
                spec: displaySpec,
                metadata: metadata,
                decision: decision,
                fetchError: fetchError,
                acquisitionManifest: acquisitionManifest,
                acquisitionManifestPath: acquisitionManifestPath,
                manifestWriteSucceeded: !manifestRequired || manifestWriteSucceeded,
                manifestWriteError: manifestWriteError,
                path: relativePath,
                seededTasks: seededTasks,
                memoryRecords: memoryRecords)
            try (finalizedText + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            text = finalizedText
        } catch {
            writeSucceeded = false
            writeError = String(describing: error)
        }
        return LiveModelMetadataGateReport(path: relativePath,
                                           text: text,
                                           spec: displaySpec,
                                           metadata: metadata,
                                           decision: decision,
                                           acquisitionManifest: acquisitionManifest,
                                           acquisitionManifestPath: acquisitionManifestPath,
                                           seededTasks: seededTasks,
                                           memoryRecords: memoryRecords,
                                           writeSucceeded: writeSucceeded,
                                           writeError: writeError,
                                           manifestWriteSucceeded: !manifestRequired || manifestWriteSucceeded,
                                           manifestWriteError: manifestWriteError,
                                           fetchError: fetchError)
    }

    func seedLocalModelScoutTasks(objective: String,
                                          candidates: [LocalModelScoutCandidate],
                                          reportPath: String) -> Int {
        let store = PlanStore(projectRoot: projectRoot)
        var count = 0
        func add(_ title: String, _ kind: PlanTask.Kind, _ owner: String,
                 _ detail: String, _ acceptance: String, _ verification: String,
                 _ evidence: [String] = []) {
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

        let candidateList = candidates.map {
            "\($0.modelID) (\($0.provider), score \($0.score))"
        }.joined(separator: "\n")
        add("RESEARCH: Safe local model scout -- \(objective)", .research, "local-model-scout",
            "Candidate matrix:\n\(candidateList)",
            "Each candidate has source/provenance, license, size, memory fit, template, risk, and eval gates.",
            "/model scout \(objective)",
            [reportPath])
        add("TEST: Local model onboarding gate -- \(objective)", .test, "local-model-scout",
            "Run inspect/onboard checks for the highest-scoring approved candidate without changing the default model.",
            "`kist --inspect-model` and `kist --onboard` pass, or the candidate is rejected with evidence.",
            "Attach inspect/onboard output and keep rollback to the current default model.",
            [reportPath])
        add("TEST: Local-vs-current benchmark -- \(objective)", .test, "local-model-scout",
            "Compare the approved local candidate against the current default/cloud baseline for this exact task family.",
            "Candidate only advances if `/bench` or `/eval` records repeated wins or an explicit low-risk offline benefit.",
            "/bench \(objective); /eval \(objective); /learning",
            [reportPath])
        add("DECISION: Promote or reject local model -- \(objective)", .decision, "captain",
            "Decide whether the candidate stays shadow-only, becomes a role-bound worker, or is rejected.",
            "Promotion includes task family, fallback model, benchmark evidence, and rollback path.",
            "/teach add <local model rule> | confidence: ... | evidence: \(reportPath)",
            [reportPath])
        return count
    }

    @discardableResult
    func recordLocalModelScoutMemory(objective: String,
                                             candidates: [LocalModelScoutCandidate],
                                             reportPath: String) -> Int {
        let top = candidates.first
        let body = candidates.map {
            "\($0.modelID) via \($0.provider): score \($0.score), memory ~\($0.estimatedMemoryGB) GB, gates: \($0.licenseGate) \($0.templateGate)"
        }.joined(separator: "\n")
        let record = DiskMemoryRecord(
            id: "AA-local-model-scout-\(Self.slug(objective).prefix(48))",
            title: "Safe Local Model Scout: \(objective)",
            summary: top.map { "Top candidate \($0.modelID) via \($0.provider), score \($0.score)." }
                ?? "No candidate selected.",
            body: body,
            source: reportPath,
            confidence: top?.score ?? 50,
            impact: 4,
            tags: ["local-model", "hugging-face", "mlx", "ollama", "model-scout"]
        )
        return upsertGenericMemory(
            record, to: knowledgeIndexPath, decayRate: .fast) ? 1 : 0
    }

    func seedLiveModelMetadataGateTasks(spec: String,
                                                metadata: LiveModelMetadata?,
                                                decision: LiveModelMetadataDecision?,
                                                reportPath: String,
                                                manifestPath: String?,
                                                manifest: LocalModelAcquisitionManifest?,
                                                manifestWriteSucceeded: Bool,
                                                manifestWriteError: String?,
                                                fetchError: String?) -> Int {
        let store = PlanStore(projectRoot: projectRoot)
        var count = 0
        func add(_ title: String, _ kind: PlanTask.Kind, _ owner: String,
                 _ detail: String, _ acceptance: String, _ verification: String,
                 _ evidence: [String] = []) {
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

        if decision?.accepted == true, manifestWriteSucceeded, let manifest, manifestPath != nil {
            let modelID = metadata?.modelID ?? spec
            let provider = metadata?.providerHint ?? "hf"
            let evidence = [reportPath, manifestPath].compactMap { $0 }
            add("ACTION: Verify acquisition manifest -- \(spec)", .action, "local-model-scout",
                "Metadata gate passed for \(modelID). Run the acquisition preflight before any dry-run/download command.",
                "The manifest policy hash, approval id, pinned commands, and target directory are verified by `/model acquire`.",
                "/model acquire \(manifestPath ?? "<manifest.json>")",
                evidence)
            add("TEST: Inspect approved local model -- \(spec)", .test, "local-model-scout",
                "Inspect chat template, stop tokens, and provider profile for \(provider):\(modelID) after `/model acquire` and sandbox download.",
                "`kist --inspect-model` identifies usable stops/template, or the candidate is rejected with evidence.",
                manifest.commands.inspect,
                evidence)
            add("TEST: Benchmark metadata-cleared model -- \(spec)", .test, "local-model-scout",
                "Run the candidate against the current default/cloud model for the exact task family before routing work.",
                "`/bench` or `/eval` records repeated wins or an explicit low-risk offline benefit.",
                manifest.commands.benchmark,
                evidence)
            add("DECISION: Promote or reject metadata-cleared model -- \(spec)", .decision, "captain",
                "Decide whether this model remains shadow-only, becomes a role-bound worker, or is rejected.",
                "Promotion includes task family, fallback model, benchmark evidence, rollback path, and Teach Captain rule if durable.",
                "/teach add <model routing lesson> | confidence: ... | evidence: \(reportPath)",
                evidence)
        } else if decision?.accepted == true {
            let blocker = manifestWriteError ?? "accepted metadata did not produce a persisted acquisition manifest"
            add("REVIEW: Resolve local model acquisition manifest persistence -- \(spec)", .review, "local-model-scout",
                "Do not download this candidate. Metadata passed, but the acquisition manifest was not written. Blocker: \(blocker)",
                "Re-run `/model vet` and confirm the JSON acquisition manifest is written before any download command is used.",
                "/model vet \(spec)",
                [reportPath])
        } else {
            let blockers = fetchError
                ?? decision?.reasons.joined(separator: "; ")
                ?? "metadata unavailable"
            add("REVIEW: Resolve local model metadata blockers -- \(spec)", .review, "local-model-scout",
                "Do not download this candidate. Blockers: \(blockers)",
                "The candidate is either replaced or re-run through `/model vet` with all license/provenance blockers cleared.",
                "/model vet \(spec)",
                [reportPath])
        }
        return count
    }

    @discardableResult
    func recordLiveModelMetadataGateMemory(spec: String,
                                                   metadata: LiveModelMetadata?,
                                                   decision: LiveModelMetadataDecision?,
                                                   reportPath: String,
                                                   fetchError: String?) -> Int {
        let verdict = decision?.accepted == true ? "accepted" : "rejected"
        let reasons = decision?.reasons.joined(separator: "; ") ?? fetchError ?? "metadata unavailable"
        let warnings = decision?.warnings.joined(separator: "; ") ?? "none"
        let details = [
            "Spec: \(spec)",
            "Verdict: \(verdict)",
            "Source: \(metadata?.source.rawValue ?? "unknown")",
            "Model: \(metadata?.modelID ?? "unknown")",
            "Author: \(metadata?.author ?? "unknown")",
            "License: \(decision?.allowedLicense ?? metadata?.license ?? "unknown")",
            "SHA: \(metadata?.sha ?? "unknown")",
            "Reasons: \(reasons)",
            "Warnings: \(warnings)"
        ].joined(separator: "\n")
        let record = DiskMemoryRecord(
            id: "AA-live-model-metadata-\(Self.slug(spec).prefix(48))",
            title: "Live Model Metadata Gate: \(spec)",
            summary: "\(verdict.uppercased()): \(metadata?.modelID ?? spec) -- \(reasons)",
            body: details,
            source: reportPath,
            confidence: decision?.accepted == true ? 82 : 70,
            impact: 4,
            tags: ["local-model", "metadata-gate", "license-gate", "provenance", metadata?.providerHint ?? "unknown"]
        )
        return upsertGenericMemory(
            record, to: knowledgeIndexPath, decayRate: .fast) ? 1 : 0
    }

}
