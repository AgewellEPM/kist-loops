import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AgentCore

struct LiveModelMetadata: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case huggingFace
        case ollamaLocal
    }

    var source: Source
    var providerHint: String
    var modelID: String
    var sourceURL: String
    var author: String?
    var license: String?
    var tags: [String]
    var gated: Bool
    var isPrivate: Bool
    var disabled: Bool
    var sha: String?
    var fileNames: [String]
    var fileSizes: [String: Int64]
    var usedStorageBytes: Int64?
    var downloads: Int?
    var details: [String: String]

    var hasModelCard: Bool {
        fileNames.contains { $0.lowercased() == "readme.md" }
    }

    var hasTokenizerConfig: Bool {
        fileNames.contains { $0.lowercased().hasSuffix("tokenizer_config.json") }
    }

    var hasSafeWeightFormat: Bool {
        fileNames.contains { name in
            let lower = name.lowercased()
            return lower.hasSuffix(".safetensors") || lower.hasSuffix(".gguf")
        }
    }
}

struct LiveModelMetadataDecision: Equatable, Sendable {
    var accepted: Bool
    var reasons: [String]
    var warnings: [String]
    var allowedLicense: String?

    static func evaluate(_ metadata: LiveModelMetadata,
                         maxStorageGB: Int = 32,
                         allowedLicenses: Set<String> = LiveModelMetadataGate.defaultAllowedLicenses) -> LiveModelMetadataDecision {
        var reasons: [String] = []
        var warnings: [String] = []
        let normalizedLicense = LiveModelMetadataGate.normalizeLicense(metadata.license, tags: metadata.tags)

        if metadata.source == .huggingFace {
            if metadata.isPrivate { reasons.append("repository is private") }
            if metadata.disabled { reasons.append("repository is disabled") }
            if metadata.gated { reasons.append("repository is gated and cannot be auto-downloaded") }
            if metadata.author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                reasons.append("missing author/provenance owner")
            }
            if metadata.sha?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                reasons.append("missing immutable revision SHA")
            } else if let sha = metadata.sha, !LiveModelMetadataGate.isFullRevisionSHA(sha) {
                reasons.append("revision SHA is not a full immutable 40-character hex commit")
            }
            if !metadata.hasModelCard { reasons.append("missing README/model card") }
            if !metadata.hasSafeWeightFormat { reasons.append("no safetensors or GGUF weight file found") }
        } else {
            warnings.append("Ollama metadata verifies an installed local model, not a pre-download registry record")
            if metadata.license == nil { reasons.append("installed Ollama model did not expose license text") }
            if metadata.details["parameter_size"] == nil {
                warnings.append("Ollama details did not include parameter size")
            }
            if metadata.details["quantization_level"] == nil {
                warnings.append("Ollama details did not include quantization level")
            }
        }

        if let normalizedLicense {
            if !allowedLicenses.contains(normalizedLicense) {
                reasons.append("license '\(normalizedLicense)' is not in the allowlist")
            }
        } else {
            reasons.append("missing machine-readable license")
        }

        if let bytes = metadata.usedStorageBytes {
            let limit = Int64(maxStorageGB) * 1_073_741_824
            if bytes > limit {
                reasons.append("repository storage \(LiveModelMetadataGate.formatBytes(bytes)) exceeds \(maxStorageGB) GB gate")
            }
        } else if metadata.source == .huggingFace {
            warnings.append("storage size unavailable; require manual size check before download")
        }

        if !metadata.hasTokenizerConfig {
            warnings.append("tokenizer_config.json not found; inspect template/stops before agent loops")
        }

        return LiveModelMetadataDecision(accepted: reasons.isEmpty,
                                         reasons: reasons,
                                         warnings: warnings,
                                         allowedLicense: normalizedLicense)
    }
}

struct LiveModelMetadataGateReport: Equatable, Sendable {
    var path: String
    var text: String
    var spec: String
    var metadata: LiveModelMetadata?
    var decision: LiveModelMetadataDecision?
    var acquisitionManifest: LocalModelAcquisitionManifest?
    var acquisitionManifestPath: String?
    var seededTasks: Int
    var memoryRecords: Int
    var writeSucceeded: Bool
    var writeError: String?
    var manifestWriteSucceeded: Bool
    var manifestWriteError: String?
    var fetchError: String?
}

struct LocalModelAcquisitionDecision: Equatable, Sendable {
    var accepted: Bool
    var reasons: [String]
    var warnings: [String]
}

struct LocalModelAcquisitionPreflightReport: Equatable, Sendable {
    var path: String
    var text: String
    var manifestPath: String
    var manifest: LocalModelAcquisitionManifest?
    var decision: LocalModelAcquisitionDecision
    var seededTasks: Int
    var memoryRecords: Int
    var writeSucceeded: Bool
    var writeError: String?
    var loadError: String?
}

enum LocalModelAcquisitionStage: String, Codable, CaseIterable, Sendable {
    case dryRun = "dry-run"
    case download
    case inspect
    case onboard
    case benchmark

    static func parse(_ raw: String) -> LocalModelAcquisitionStage? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "dry-run", "dryrun", "probe", "check":
            return .dryRun
        case "download", "fetch":
            return .download
        case "inspect", "show":
            return .inspect
        case "onboard", "install-profile", "profile":
            return .onboard
        case "benchmark", "bench", "eval":
            return .benchmark
        default:
            return nil
        }
    }
}

struct LocalModelAcquisitionRunnableCommand: Equatable, Sendable {
    struct Invocation: Equatable, Sendable {
        var label: String
        var executable: String
        var arguments: [String]

        var display: String {
            LiveModelMetadataGate.shellCommand([executable] + arguments)
        }
    }

    var stage: LocalModelAcquisitionStage
    var manifestCommand: String
    var invocations: [Invocation]
    var timeoutSeconds: Int
}

struct LocalModelAcquisitionProcessResult: Equatable, Sendable {
    var label: String
    var command: String
    var exitCode: Int32
    var timedOut: Bool
    var stdout: String
    var stderr: String

    var succeeded: Bool { exitCode == 0 && !timedOut }
}

struct LocalModelAcquisitionRunOutcome: Equatable, Sendable {
    var results: [LocalModelAcquisitionProcessResult]

    var succeeded: Bool { !results.isEmpty && results.allSatisfy(\.succeeded) }
}

struct LocalModelAcquisitionDependencyBlocker: Equatable, Sendable {
    var executable: String
    var reason: String
    var setupCommand: String
    var verifyCommand: String
}

struct LocalModelAcquisitionArtifactFile: Codable, Equatable, Sendable {
    var path: String
    var bytes: Int64
    var sha256: String
}

struct LocalModelAcquisitionArtifactAttestation: Codable, Equatable, Sendable {
    var approvalID: String
    var policyHash: String
    var modelID: String
    var revisionSHA: String?
    var localDirectory: String
    var createdAt: Double
    var accepted: Bool
    var requiredFilesPresent: Bool
    var fileCount: Int
    var totalBytes: Int64
    var sampledFiles: [LocalModelAcquisitionArtifactFile]
    var blockers: [String]
    var warnings: [String]
    var seal: String?
}

struct LocalModelAcquisitionRunReport: Equatable, Sendable {
    var path: String
    var text: String
    var manifestPath: String
    var stage: LocalModelAcquisitionStage?
    var manifest: LocalModelAcquisitionManifest?
    var decision: LocalModelAcquisitionDecision
    var command: LocalModelAcquisitionRunnableCommand?
    var outcome: LocalModelAcquisitionRunOutcome?
    var markerPath: String?
    var dependencyBlockers: [LocalModelAcquisitionDependencyBlocker]
    var artifactAttestation: LocalModelAcquisitionArtifactAttestation?
    var artifactAttestationPath: String?
    var seededTasks: Int
    var memoryRecords: Int
    var writeSucceeded: Bool
    var writeError: String?
    var loadError: String?
}

typealias LocalModelAcquisitionExecutor = (LocalModelAcquisitionRunnableCommand, String) -> LocalModelAcquisitionRunOutcome
typealias LocalModelAcquisitionDependencyResolver = (LocalModelAcquisitionRunnableCommand) -> [LocalModelAcquisitionDependencyBlocker]

struct LocalModelAcquisitionManifest: Codable, Equatable, Sendable {
    struct Commands: Codable, Equatable, Sendable {
        var dryRun: String?
        var download: String?
        var inspect: String
        var onboard: String?
        var benchmark: String
    }

    var schemaVersion: Int
    var approvalID: String
    var policyVersion: String
    var policyHash: String
    var createdAt: Double
    var spec: String
    var source: String
    var providerHint: String
    var modelID: String
    var sourceURL: String
    var author: String?
    var license: String
    var revisionSHA: String?
    var storageBytes: Int64?
    var fileNames: [String]
    var fileSizes: [String: Int64]
    var localDirectory: String
    var gateReportPath: String
    var commands: Commands
    var nextGates: [String]
    var seal: String?

    init(schemaVersion: Int,
         approvalID: String,
         policyVersion: String,
         policyHash: String,
         createdAt: Double,
         spec: String,
         source: String,
         providerHint: String,
         modelID: String,
         sourceURL: String,
         author: String?,
         license: String,
         revisionSHA: String?,
         storageBytes: Int64?,
         fileNames: [String],
         fileSizes: [String: Int64],
         localDirectory: String,
         gateReportPath: String,
         commands: Commands,
         nextGates: [String],
         seal: String?) {
        self.schemaVersion = schemaVersion
        self.approvalID = approvalID
        self.policyVersion = policyVersion
        self.policyHash = policyHash
        self.createdAt = createdAt
        self.spec = spec
        self.source = source
        self.providerHint = providerHint
        self.modelID = modelID
        self.sourceURL = sourceURL
        self.author = author
        self.license = license
        self.revisionSHA = revisionSHA
        self.storageBytes = storageBytes
        self.fileNames = fileNames
        self.fileSizes = fileSizes
        self.localDirectory = localDirectory
        self.gateReportPath = gateReportPath
        self.commands = commands
        self.nextGates = nextGates
        self.seal = seal
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case approvalID
        case policyVersion
        case policyHash
        case createdAt
        case spec
        case source
        case providerHint
        case modelID
        case sourceURL
        case author
        case license
        case revisionSHA
        case storageBytes
        case fileNames
        case fileSizes
        case localDirectory
        case gateReportPath
        case commands
        case nextGates
        case seal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        approvalID = try container.decode(String.self, forKey: .approvalID)
        policyVersion = try container.decode(String.self, forKey: .policyVersion)
        policyHash = try container.decode(String.self, forKey: .policyHash)
        createdAt = try container.decode(Double.self, forKey: .createdAt)
        spec = try container.decode(String.self, forKey: .spec)
        source = try container.decode(String.self, forKey: .source)
        providerHint = try container.decode(String.self, forKey: .providerHint)
        modelID = try container.decode(String.self, forKey: .modelID)
        sourceURL = try container.decode(String.self, forKey: .sourceURL)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        license = try container.decode(String.self, forKey: .license)
        revisionSHA = try container.decodeIfPresent(String.self, forKey: .revisionSHA)
        storageBytes = try container.decodeIfPresent(Int64.self, forKey: .storageBytes)
        fileNames = try container.decode([String].self, forKey: .fileNames)
        fileSizes = try container.decodeIfPresent([String: Int64].self, forKey: .fileSizes) ?? [:]
        localDirectory = try container.decode(String.self, forKey: .localDirectory)
        gateReportPath = try container.decode(String.self, forKey: .gateReportPath)
        commands = try container.decode(Commands.self, forKey: .commands)
        nextGates = try container.decode([String].self, forKey: .nextGates)
        seal = try container.decodeIfPresent(String.self, forKey: .seal)
    }
}

enum LiveModelMetadataGate {
    static let acquisitionPolicyVersion = "local-model-acquisition-v1"

    static let defaultAllowedLicenses: Set<String> = [
        "apache-2.0", "mit", "bsd-2-clause", "bsd-3-clause", "cc-by-4.0", "cc0-1.0"
    ]

    struct Request: Equatable, Sendable {
        var source: LiveModelMetadata.Source
        var providerHint: String
        var modelID: String

        var displaySpec: String { "\(providerHint):\(modelID)" }
    }

    static func parseRequest(_ raw: String) -> Request? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let aliases = [
            ("huggingface:", "hf"),
            ("hugging-face:", "hf"),
            ("hf:", "hf"),
            ("mlx:", "mlx"),
            ("ollama:", "ollama")
        ]
        for (prefix, provider) in aliases where clean.lowercased().hasPrefix(prefix) {
            let model = String(clean.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSafeModelID(model) else { return nil }
            let source: LiveModelMetadata.Source = provider == "ollama" ? .ollamaLocal : .huggingFace
            return Request(source: source, providerHint: provider, modelID: model)
        }
        guard isSafeModelID(clean) else { return nil }
        return Request(source: .huggingFace, providerHint: "hf", modelID: clean)
    }

    static func render(spec: String,
                       metadata: LiveModelMetadata?,
                       decision: LiveModelMetadataDecision?,
                       fetchError: String?,
                       acquisitionManifest: LocalModelAcquisitionManifest?,
                       acquisitionManifestPath: String?,
                       manifestWriteSucceeded: Bool,
                       manifestWriteError: String?,
                       path: String,
                       seededTasks: Int,
                       memoryRecords: Int) -> String {
        var lines = [
            "# Live Model Metadata Gate",
            "",
            "Spec: \(spec)",
            "",
            "## Policy",
            "- Fetch live metadata before any Hugging Face download.",
            "- Reject private, disabled, gated, unknown-license, oversize, or unsafe-format repositories.",
            "- Ollama metadata is local-installed verification only; it is not a pre-download registry approval.",
            "- Passing this gate still does not install or promote the model. It only clears metadata for the next sandbox step.",
            "",
        ]

        if let fetchError {
            lines += [
                "## Result",
                "REJECTED: metadata fetch failed.",
                "",
                "Fetch error: \(fetchError)"
            ]
        } else if let metadata, let decision {
            lines += [
                "## Result",
                decision.accepted ? "ACCEPTED: metadata clears the allowlist gate." : "REJECTED: metadata failed the allowlist gate.",
                "",
                "Source: \(metadata.source.rawValue)",
                "Model: \(metadata.modelID)",
                "URL: \(metadata.sourceURL)",
                "Author: \(metadata.author ?? "unknown")",
                "License: \(decision.allowedLicense ?? metadata.license ?? "unknown")",
                "Gated/private/disabled: \(metadata.gated)/\(metadata.isPrivate)/\(metadata.disabled)",
                "SHA: \(metadata.sha ?? "unknown")",
                "Storage: \(metadata.usedStorageBytes.map(formatBytes) ?? "unknown")",
                "Files: \(metadata.fileNames.count)",
                "Acquisition manifest: \(acquisitionManifestPath ?? "not written")",
                "Approval ID: \(acquisitionManifest?.approvalID ?? "none")",
                "",
                "Reasons:"
            ]
            lines += decision.reasons.isEmpty ? ["- none"] : decision.reasons.map { "- \($0)" }
            lines += ["", "Warnings:"]
            lines += decision.warnings.isEmpty ? ["- none"] : decision.warnings.map { "- \($0)" }
            if !metadata.details.isEmpty {
                lines += ["", "Details:"]
                lines += metadata.details.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value)" }
            }
            lines += [
                "",
                "Files sampled:",
            ]
            lines += metadata.fileNames.prefix(20).map { "- \($0)" }
            if metadata.fileNames.count > 20 { lines.append("- ... +\(metadata.fileNames.count - 20) more") }
            if let acquisitionManifest {
                lines += [
                    "",
                    "Manifest commands:",
                    "- dry-run: \(acquisitionManifest.commands.dryRun ?? "not available")",
                    "- download: \(acquisitionManifest.commands.download ?? "not authorized by this manifest")",
                    "- inspect: \(acquisitionManifest.commands.inspect)",
                    "- onboard: \(acquisitionManifest.commands.onboard ?? "not available")",
                    "- benchmark: \(acquisitionManifest.commands.benchmark)"
                ]
            }
            if !manifestWriteSucceeded, let manifestWriteError {
                lines += ["", "Manifest write error: \(manifestWriteError)"]
            }
        } else {
            lines += ["## Result", "REJECTED: no metadata available."]
        }

        lines += [
            "",
            "## Next Gate",
            "- If rejected: do not download. Resolve the listed blockers or pick another candidate.",
            "- If accepted: run `/model acquire <manifest.json>` first; only a verified acquisition manifest can expose dry-run/download/onboard gates.",
            "",
            "## Artifacts",
            "Report: \(path)",
            "Acquisition manifest: \(acquisitionManifestPath ?? "none")",
            "Seeded tasks: \(seededTasks)",
            "Knowledge index records: \(memoryRecords)"
        ]
        return lines.joined(separator: "\n")
    }

    static func makeAcquisitionManifest(spec: String,
                                        metadata: LiveModelMetadata,
                                        decision: LiveModelMetadataDecision,
                                        gateReportPath: String,
                                        createdAt: Double) -> LocalModelAcquisitionManifest? {
        guard decision.accepted, let allowedLicense = decision.allowedLicense else { return nil }
        let identity = metadata.sha ?? sha256Hex(metadata.sourceURL)
        let localDirectory = ".kist/models/\(modelSlug(metadata.modelID))-\(String(identity.prefix(12)))"
        let tokenizerPath = metadata.fileNames.contains { $0.lowercased().hasSuffix("tokenizer_config.json") }
            ? "\(localDirectory)/tokenizer_config.json"
            : localDirectory
        let commands = acquisitionCommands(metadata: metadata,
                                           localDirectory: localDirectory,
                                           tokenizerPath: tokenizerPath)
        let nextGates = [
            "Run the manifest dry-run command first and compare expected size/files.",
            "Download only into the manifest localDirectory.",
            "Run inspect/onboard before any agent loop uses this model.",
            "Run benchmark/eval against the current default before promotion.",
            "Record promotion or rejection with evidence and rollback path."
        ]
        let policyHash = acquisitionPolicyHash(spec: spec,
                                               source: metadata.source.rawValue,
                                               providerHint: metadata.providerHint,
                                               modelID: metadata.modelID,
                                               revisionSHA: metadata.sha,
                                               license: allowedLicense,
                                               localDirectory: localDirectory,
                                               gateReportPath: gateReportPath,
                                               commands: commands)
        var manifest = LocalModelAcquisitionManifest(
            schemaVersion: 1,
            approvalID: "LMA-\(String(policyHash.prefix(16)))",
            policyVersion: acquisitionPolicyVersion,
            policyHash: policyHash,
            createdAt: createdAt,
            spec: spec,
            source: metadata.source.rawValue,
            providerHint: metadata.providerHint,
            modelID: metadata.modelID,
            sourceURL: metadata.sourceURL,
            author: metadata.author,
            license: allowedLicense,
            revisionSHA: metadata.sha,
            storageBytes: metadata.usedStorageBytes,
            fileNames: metadata.fileNames.sorted(),
            fileSizes: metadata.fileSizes,
            localDirectory: localDirectory,
            gateReportPath: gateReportPath,
            commands: commands,
            nextGates: nextGates,
            seal: nil)
        manifest.seal = ForgeSeal.sign(manifestSealCanonical(manifest))
        return manifest
    }

    static func validateAcquisitionManifest(_ manifest: LocalModelAcquisitionManifest) -> LocalModelAcquisitionDecision {
        var reasons: [String] = []
        var warnings: [String] = []
        let parsedSpec = parseRequest(manifest.spec)

        if manifest.schemaVersion != 1 {
            reasons.append("unsupported schemaVersion \(manifest.schemaVersion)")
        }
        if manifest.policyVersion != acquisitionPolicyVersion {
            reasons.append("unsupported policyVersion \(manifest.policyVersion)")
        }
        if !defaultAllowedLicenses.contains(manifest.license) {
            reasons.append("license '\(manifest.license)' is not in the allowlist")
        }
        if manifest.modelID != parsedSpec?.modelID {
            reasons.append("manifest modelID does not match spec")
        }
        if manifest.providerHint != parsedSpec?.providerHint {
            reasons.append("manifest providerHint does not match spec")
        }
        if manifest.source != parsedSpec?.source.rawValue {
            reasons.append("manifest source does not match spec")
        }
        if !isSafeModelID(manifest.modelID) {
            reasons.append("manifest modelID contains unsafe characters")
        }
        if !isSafeRelativePath(manifest.localDirectory, requiredPrefix: ".kist/models/") {
            reasons.append("localDirectory must be a safe project-relative .kist/models path")
        }
        if !isSafeRelativePath(manifest.gateReportPath, requiredPrefix: ".kist/learning/local-models/") {
            reasons.append("gateReportPath must be a safe project-relative metadata report path")
        }
        for file in manifest.fileNames where !isSafeManifestFileName(file) {
            reasons.append("manifest file list contains unsafe file path '\(file)'")
        }
        for (file, size) in manifest.fileSizes {
            if !isSafeManifestFileName(file) {
                reasons.append("manifest file size map contains unsafe file path '\(file)'")
            }
            if !manifest.fileNames.contains(file) {
                reasons.append("manifest file size map contains file not listed in fileNames '\(file)'")
            }
            if size < 0 {
                reasons.append("manifest file size for '\(file)' is negative")
            }
        }

        if let expectedCommands = expectedCommands(for: manifest) {
            if manifest.commands != expectedCommands {
                reasons.append("manifest commands do not match the policy-generated command set")
            }
        } else {
            reasons.append("manifest source/provider fields cannot produce an expected command set")
        }

        let expectedHash = acquisitionPolicyHash(spec: manifest.spec,
                                                 source: manifest.source,
                                                 providerHint: manifest.providerHint,
                                                 modelID: manifest.modelID,
                                                 revisionSHA: manifest.revisionSHA,
                                                 license: manifest.license,
                                                 localDirectory: manifest.localDirectory,
                                                 gateReportPath: manifest.gateReportPath,
                                                 commands: manifest.commands)
        if manifest.policyHash != expectedHash {
            reasons.append("policyHash does not match manifest contents")
        }
        if manifest.approvalID != "LMA-\(String(expectedHash.prefix(16)))" {
            reasons.append("approvalID does not match policyHash")
        }
        if ForgeSeal.verify(manifestSealCanonical(manifest), seal: manifest.seal ?? "") == false {
            reasons.append("manifest seal is missing or invalid")
        }

        switch manifest.source {
        case LiveModelMetadata.Source.huggingFace.rawValue:
            if manifest.sourceURL != "https://huggingface.co/\(manifest.modelID)" {
                reasons.append("sourceURL does not match Hugging Face model id")
            }
            if manifest.revisionSHA.map(isFullRevisionSHA) != true {
                reasons.append("Hugging Face manifest requires a full immutable 40-character revision SHA")
            }
            if manifest.commands.download == nil || manifest.commands.dryRun == nil {
                reasons.append("Hugging Face manifest must include dry-run and download commands")
            }
        case LiveModelMetadata.Source.ollamaLocal.rawValue:
            if manifest.commands.download != nil || manifest.commands.dryRun != nil {
                reasons.append("Ollama installed-local manifests must not authorize download commands")
            }
            warnings.append("Ollama manifest verifies an installed local model only; it is not a registry download approval")
        default:
            reasons.append("unknown manifest source '\(manifest.source)'")
        }

        return LocalModelAcquisitionDecision(accepted: reasons.isEmpty,
                                             reasons: dedupe(reasons),
                                             warnings: dedupe(warnings))
    }

    static func expectedCommands(for manifest: LocalModelAcquisitionManifest) -> LocalModelAcquisitionManifest.Commands? {
        let tokenizerPath = manifest.fileNames.contains { $0.lowercased().hasSuffix("tokenizer_config.json") }
            ? "\(manifest.localDirectory)/tokenizer_config.json"
            : manifest.localDirectory
        let benchmark = "/bench local model \(manifest.modelID); /eval local model \(manifest.modelID)"
        switch manifest.source {
        case LiveModelMetadata.Source.huggingFace.rawValue:
            guard let sha = manifest.revisionSHA, isFullRevisionSHA(sha) else { return nil }
            let base = [
                "hf", "download", manifest.modelID,
                "--revision", sha,
                "--local-dir", manifest.localDirectory
            ]
            let onboard = manifest.providerHint == "mlx"
                ? shellCommand(["kist", "--onboard", "mlx:\(manifest.modelID)", "--onboard-doc", tokenizerPath])
                : nil
            return LocalModelAcquisitionManifest.Commands(
                dryRun: shellCommand(base + ["--dry-run"]),
                download: shellCommand(base),
                inspect: shellCommand(["kist", "--inspect-model", tokenizerPath]),
                onboard: onboard,
                benchmark: benchmark)
        case LiveModelMetadata.Source.ollamaLocal.rawValue:
            return LocalModelAcquisitionManifest.Commands(
                dryRun: nil,
                download: nil,
                inspect: shellCommand(["ollama", "show", manifest.modelID]),
                onboard: shellCommand(["kist", "--onboard", "ollama:\(manifest.modelID)"]),
                benchmark: benchmark)
        default:
            return nil
        }
    }

    static func runnableCommand(for stage: LocalModelAcquisitionStage,
                                manifest: LocalModelAcquisitionManifest) -> LocalModelAcquisitionRunnableCommand? {
        let tokenizerPath = manifest.fileNames.contains { $0.lowercased().hasSuffix("tokenizer_config.json") }
            ? "\(manifest.localDirectory)/tokenizer_config.json"
            : manifest.localDirectory
        switch stage {
        case .dryRun:
            guard manifest.source == LiveModelMetadata.Source.huggingFace.rawValue,
                  let sha = manifest.revisionSHA,
                  let manifestCommand = manifest.commands.dryRun else { return nil }
            return LocalModelAcquisitionRunnableCommand(
                stage: stage,
                manifestCommand: manifestCommand,
                invocations: [
                    .init(label: "dry-run",
                          executable: "hf",
                          arguments: ["download", manifest.modelID,
                                      "--revision", sha,
                                      "--local-dir", manifest.localDirectory,
                                      "--dry-run"])
                ],
                timeoutSeconds: 180)
        case .download:
            guard manifest.source == LiveModelMetadata.Source.huggingFace.rawValue,
                  let sha = manifest.revisionSHA,
                  let manifestCommand = manifest.commands.download else { return nil }
            return LocalModelAcquisitionRunnableCommand(
                stage: stage,
                manifestCommand: manifestCommand,
                invocations: [
                    .init(label: "download",
                          executable: "hf",
                          arguments: ["download", manifest.modelID,
                                      "--revision", sha,
                                      "--local-dir", manifest.localDirectory])
                ],
                timeoutSeconds: 3_600)
        case .inspect:
            if manifest.source == LiveModelMetadata.Source.ollamaLocal.rawValue {
                return LocalModelAcquisitionRunnableCommand(
                    stage: stage,
                    manifestCommand: manifest.commands.inspect,
                    invocations: [.init(label: "inspect", executable: "ollama", arguments: ["show", manifest.modelID])],
                    timeoutSeconds: 180)
            }
            return LocalModelAcquisitionRunnableCommand(
                stage: stage,
                manifestCommand: manifest.commands.inspect,
                invocations: [.init(label: "inspect", executable: "kist", arguments: ["--inspect-model", tokenizerPath])],
                timeoutSeconds: 180)
        case .onboard:
            guard let manifestCommand = manifest.commands.onboard else { return nil }
            if manifest.source == LiveModelMetadata.Source.ollamaLocal.rawValue {
                return LocalModelAcquisitionRunnableCommand(
                    stage: stage,
                    manifestCommand: manifestCommand,
                    invocations: [.init(label: "onboard", executable: "kist", arguments: ["--onboard", "ollama:\(manifest.modelID)"])],
                    timeoutSeconds: 300)
            }
            guard manifest.providerHint == "mlx" else { return nil }
            return LocalModelAcquisitionRunnableCommand(
                stage: stage,
                manifestCommand: manifestCommand,
                invocations: [
                    .init(label: "onboard",
                          executable: "kist",
                          arguments: ["--onboard", "mlx:\(manifest.modelID)", "--onboard-doc", tokenizerPath])
                ],
                timeoutSeconds: 300)
        case .benchmark:
            return LocalModelAcquisitionRunnableCommand(
                stage: stage,
                manifestCommand: manifest.commands.benchmark,
                invocations: [
                    .init(label: "bench", executable: "kist", arguments: ["--bench", "local model \(manifest.modelID)"]),
                    .init(label: "eval", executable: "kist", arguments: ["--eval", "local model \(manifest.modelID)"])
                ],
                timeoutSeconds: 900)
        }
    }

    static func manifestJSONData(_ manifest: LocalModelAcquisitionManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    static func manifestSealCanonical(_ manifest: LocalModelAcquisitionManifest) -> String {
        let commands = manifest.commands
        let fileNames = manifest.fileNames.sorted().map(ForgeSeal.field).joined(separator: ",")
        let fileSizes = manifest.fileSizes.sorted { $0.key < $1.key }
            .map { "\(ForgeSeal.field($0.key)):\($0.value)" }
            .joined(separator: ",")
        let gates = manifest.nextGates.map(ForgeSeal.field).joined(separator: ",")
        return [
            "schema=\(manifest.schemaVersion)",
            "approval=\(ForgeSeal.field(manifest.approvalID))",
            "policyVersion=\(ForgeSeal.field(manifest.policyVersion))",
            "policyHash=\(ForgeSeal.field(manifest.policyHash))",
            "createdAt=\(manifest.createdAt)",
            "spec=\(ForgeSeal.field(manifest.spec))",
            "source=\(ForgeSeal.field(manifest.source))",
            "provider=\(ForgeSeal.field(manifest.providerHint))",
            "model=\(ForgeSeal.field(manifest.modelID))",
            "url=\(ForgeSeal.field(manifest.sourceURL))",
            "author=\(ForgeSeal.field(manifest.author ?? ""))",
            "license=\(ForgeSeal.field(manifest.license))",
            "revision=\(ForgeSeal.field(manifest.revisionSHA ?? ""))",
            "storage=\(manifest.storageBytes.map(String.init) ?? "")",
            "files=\(fileNames)",
            "sizes=\(fileSizes)",
            "local=\(ForgeSeal.field(manifest.localDirectory))",
            "gate=\(ForgeSeal.field(manifest.gateReportPath))",
            "dry=\(ForgeSeal.field(commands.dryRun ?? ""))",
            "download=\(ForgeSeal.field(commands.download ?? ""))",
            "inspect=\(ForgeSeal.field(commands.inspect))",
            "onboard=\(ForgeSeal.field(commands.onboard ?? ""))",
            "benchmark=\(ForgeSeal.field(commands.benchmark))",
            "next=\(gates)"
        ].joined(separator: "|")
    }

    static func normalizeLicense(_ license: String?, tags: [String]) -> String? {
        let raw = license?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fromLicense = raw.flatMap { $0.isEmpty ? nil : $0 }
        let fromTags = tags.compactMap { tag -> String? in
            let lower = tag.lowercased()
            guard lower.hasPrefix("license:") else { return nil }
            return String(lower.dropFirst("license:".count))
        }.first
        guard let value = fromLicense ?? fromTags else { return nil }
        let normalized = value
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        if normalized.contains("apache-2") { return "apache-2.0" }
        if normalized == "mit" || normalized.contains("mit-license") { return "mit" }
        if normalized.contains("bsd-3") { return "bsd-3-clause" }
        if normalized.contains("bsd-2") { return "bsd-2-clause" }
        if normalized.contains("cc-by-4") { return "cc-by-4.0" }
        if normalized.contains("cc0") { return "cc0-1.0" }
        return normalized
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.1f MB", mb)
    }

    static func modelSlug(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        let lower = value.lowercased().replacingOccurrences(of: "/", with: "-")
        let filtered = lower.map { allowed.contains($0) ? $0 : "-" }
        return String(filtered).split(separator: "-").joined(separator: "-")
    }

    private static func isSafeModelID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 180 else { return false }
        guard !value.contains(".."), !value.contains("?"), !value.contains("#") else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:")
        return value.allSatisfy { allowed.contains($0) }
    }

    static func isFullRevisionSHA(_ value: String) -> Bool {
        let hex = Set("0123456789abcdefABCDEF")
        return value.count == 40 && value.allSatisfy { hex.contains($0) }
    }

    private static func isSafeRelativePath(_ value: String, requiredPrefix: String) -> Bool {
        guard !value.isEmpty,
              value.hasPrefix(requiredPrefix),
              !value.hasPrefix("/"),
              !value.contains(".."),
              !value.contains("\0") else { return false }
        return true
    }

    private static func isSafeManifestFileName(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains(".."),
              !value.contains("\0") else { return false }
        return true
    }

    private static func acquisitionCommands(metadata: LiveModelMetadata,
                                            localDirectory: String,
                                            tokenizerPath: String) -> LocalModelAcquisitionManifest.Commands {
        let benchmark = "/bench local model \(metadata.modelID); /eval local model \(metadata.modelID)"
        switch metadata.source {
        case .huggingFace:
            var base = ["hf", "download", metadata.modelID]
            if let sha = metadata.sha {
                base += ["--revision", sha]
            }
            base += ["--local-dir", localDirectory]
            let dryRun = shellCommand(base + ["--dry-run"])
            let download = shellCommand(base)
            let onboard = metadata.providerHint == "mlx"
                ? shellCommand(["kist", "--onboard", "mlx:\(metadata.modelID)", "--onboard-doc", tokenizerPath])
                : nil
            return LocalModelAcquisitionManifest.Commands(
                dryRun: dryRun,
                download: download,
                inspect: shellCommand(["kist", "--inspect-model", tokenizerPath]),
                onboard: onboard,
                benchmark: benchmark)
        case .ollamaLocal:
            return LocalModelAcquisitionManifest.Commands(
                dryRun: nil,
                download: nil,
                inspect: shellCommand(["ollama", "show", metadata.modelID]),
                onboard: shellCommand(["kist", "--onboard", "ollama:\(metadata.modelID)"]),
                benchmark: benchmark)
        }
    }

    static func shellCommand(_ parts: [String]) -> String {
        parts.map(shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=+,%@")
        if !value.isEmpty, value.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func sha256Hex(_ text: String) -> String {
        MythosCrypto.sha256(Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func acquisitionPolicyHash(spec: String,
                                              source: String,
                                              providerHint: String,
                                              modelID: String,
                                              revisionSHA: String?,
                                              license: String,
                                              localDirectory: String,
                                              gateReportPath: String,
                                              commands: LocalModelAcquisitionManifest.Commands) -> String {
        let policyInput = [
            acquisitionPolicyVersion,
            spec,
            source,
            providerHint,
            modelID,
            revisionSHA ?? "no-sha",
            license,
            localDirectory,
            gateReportPath,
            commands.dryRun ?? "",
            commands.download ?? "",
            commands.inspect,
            commands.onboard ?? "",
            commands.benchmark
        ].joined(separator: "\n")
        return sha256Hex(policyInput)
    }

    private static func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values where seen.insert(value).inserted {
            out.append(value)
        }
        return out
    }
}

struct LiveModelMetadataFetcher {
    typealias DataLoader = (URLRequest) async throws -> (Data, URLResponse)

    var load: DataLoader

    init(load: @escaping DataLoader = { request in
        try await URLSession.shared.data(for: request)
    }) {
        self.load = load
    }

    func fetch(_ request: LiveModelMetadataGate.Request) async -> Result<LiveModelMetadata, Error> {
        switch request.source {
        case .huggingFace:
            return await fetchHuggingFace(providerHint: request.providerHint, modelID: request.modelID)
        case .ollamaLocal:
            return await fetchOllama(modelID: request.modelID)
        }
    }

    func fetchHuggingFace(providerHint: String, modelID: String) async -> Result<LiveModelMetadata, Error> {
        guard var components = URLComponents(string: "https://huggingface.co/api/models/\(modelID)") else {
            return .failure(MetadataError.invalidURL)
        }
        components.queryItems = [
            "author", "cardData", "gated", "private", "disabled", "sha",
            "siblings", "tags", "usedStorage", "downloads", "lastModified"
        ].map { URLQueryItem(name: "expand", value: $0) }
        guard let url = components.url else { return .failure(MetadataError.invalidURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await load(req)
            guard let http = response as? HTTPURLResponse else { return .failure(MetadataError.noHTTPResponse) }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(MetadataError.httpStatus(http.statusCode))
            }
            let decoded = try JSONDecoder().decode(HuggingFaceModelResponse.self, from: data)
            let siblings = decoded.siblings ?? []
            let names = siblings.compactMap(\.rfilename)
            let fileSizes = siblings.reduce(into: [String: Int64]()) { out, sibling in
                guard let name = sibling.rfilename, let size = sibling.size else { return }
                out[name] = size
            }
            let total = decoded.usedStorage
                ?? siblings.compactMap(\.size).reduce(Int64(0), +)
            let cardLicense = decoded.cardData?.license
            let tagLicense = decoded.tags?.first { $0.lowercased().hasPrefix("license:") }
            let license = cardLicense ?? tagLicense.map { String($0.dropFirst("license:".count)) }
            return .success(LiveModelMetadata(
                source: .huggingFace,
                providerHint: providerHint,
                modelID: decoded.id ?? modelID,
                sourceURL: "https://huggingface.co/\(modelID)",
                author: decoded.author,
                license: license,
                tags: decoded.tags ?? [],
                gated: decoded.gated.boolValue,
                isPrivate: decoded.isPrivate ?? false,
                disabled: decoded.disabled ?? false,
                sha: decoded.sha,
                fileNames: names.sorted(),
                fileSizes: fileSizes,
                usedStorageBytes: total == 0 ? nil : total,
                downloads: decoded.downloads,
                details: ["lastModified": decoded.lastModified].compactMapValues { $0 }))
        } catch {
            return .failure(error)
        }
    }

    func fetchOllama(modelID: String) async -> Result<LiveModelMetadata, Error> {
        guard let url = URL(string: "http://localhost:11434/api/show") else {
            return .failure(MetadataError.invalidURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(OllamaShowRequest(model: modelID, verbose: true))
        do {
            let (data, response) = try await load(req)
            guard let http = response as? HTTPURLResponse else { return .failure(MetadataError.noHTTPResponse) }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(MetadataError.httpStatus(http.statusCode))
            }
            let decoded = try JSONDecoder().decode(OllamaShowResponse.self, from: data)
            let details = decoded.details?.compactStringValues() ?? [:]
            return .success(LiveModelMetadata(
                source: .ollamaLocal,
                providerHint: "ollama",
                modelID: modelID,
                sourceURL: "http://localhost:11434/api/show",
                author: details["family"],
                license: decoded.license,
                tags: [],
                gated: false,
                isPrivate: false,
                disabled: false,
                sha: nil,
                fileNames: [],
                fileSizes: [:],
                usedStorageBytes: decoded.size,
                downloads: nil,
                details: details))
        } catch {
            return .failure(error)
        }
    }

    enum MetadataError: Error, CustomStringConvertible {
        case invalidURL
        case noHTTPResponse
        case httpStatus(Int)

        var description: String {
            switch self {
            case .invalidURL: return "invalid metadata URL"
            case .noHTTPResponse: return "metadata request did not return HTTP response"
            case .httpStatus(let code): return "metadata endpoint returned HTTP \(code)"
            }
        }
    }
}

private struct HuggingFaceModelResponse: Decodable {
    var id: String?
    var author: String?
    var cardData: CardData?
    var tags: [String]?
    var gated: FlexibleBool
    var isPrivate: Bool?
    var disabled: Bool?
    var sha: String?
    var siblings: [Sibling]?
    var usedStorage: Int64?
    var downloads: Int?
    var lastModified: String?

    enum CodingKeys: String, CodingKey {
        case oid = "_id"
        case id
        case modelId = "modelId"
        case author, cardData, tags, gated, disabled, sha, siblings, usedStorage, downloads, lastModified
        case isPrivate = "private"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .modelId)
            ?? c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decodeIfPresent(String.self, forKey: .oid)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        cardData = try c.decodeIfPresent(CardData.self, forKey: .cardData)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        gated = try c.decodeIfPresent(FlexibleBool.self, forKey: .gated) ?? FlexibleBool(false)
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate)
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled)
        sha = try c.decodeIfPresent(String.self, forKey: .sha)
        siblings = try c.decodeIfPresent([Sibling].self, forKey: .siblings)
        usedStorage = try c.decodeIfPresent(Int64.self, forKey: .usedStorage)
        downloads = try c.decodeIfPresent(Int.self, forKey: .downloads)
        lastModified = try c.decodeIfPresent(String.self, forKey: .lastModified)
    }

    struct CardData: Decodable { var license: String? }
    struct Sibling: Decodable {
        var rfilename: String?
        var size: Int64?
    }
}

private struct OllamaShowRequest: Encodable {
    var model: String
    var verbose: Bool
}

private struct OllamaShowResponse: Decodable {
    var license: String?
    var template: String?
    var parameters: String?
    var size: Int64?
    var details: Details?

    struct Details: Decodable {
        var format: String?
        var family: String?
        var families: [String]?
        var parameterSize: String?
        var quantizationLevel: String?

        enum CodingKeys: String, CodingKey {
            case format, family, families
            case parameterSize = "parameter_size"
            case quantizationLevel = "quantization_level"
        }

        func compactStringValues() -> [String: String] {
            var out: [String: String] = [:]
            if let format { out["format"] = format }
            if let family { out["family"] = family }
            if let families, !families.isEmpty { out["families"] = families.joined(separator: ", ") }
            if let parameterSize { out["parameter_size"] = parameterSize }
            if let quantizationLevel { out["quantization_level"] = quantizationLevel }
            return out
        }
    }
}

private struct FlexibleBool: Decodable, Equatable {
    var boolValue: Bool

    init(_ value: Bool) { self.boolValue = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let bool = try? c.decode(Bool.self) {
            boolValue = bool
        } else if let string = try? c.decode(String.self) {
            boolValue = ["true", "yes", "manual", "auto"].contains(string.lowercased())
        } else {
            boolValue = false
        }
    }
}
