import Foundation

/// Purpose→provider bindings for the `CALL_MODEL` driver, loaded from
/// `<projectRoot>/.kist/sml/models.json`. Each admitted model purpose maps to an exact
/// provider/model pair — the workflow never chooses the model, the host does.
public struct SMLModelPurposeBindings: Sendable {
    public struct Binding: Sendable {
        public let providerId: String
        public let model: String
        public let systemPrompt: String?
        public let maxTokens: Int

        public init(providerId: String, model: String, systemPrompt: String? = nil,
                    maxTokens: Int = 4_096) {
            self.providerId = providerId
            self.model = model
            self.systemPrompt = systemPrompt
            self.maxTokens = maxTokens
        }
    }

    public static let schemaVersion = 1
    public static let relativePath = ".kist/sml/models.json"

    public let purposes: [String: Binding]

    public init(purposes: [String: Binding]) {
        self.purposes = purposes
    }

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case missing(path: String)
        case unreadable(path: String, reason: String)
        case malformed(path: String, reason: String)
        case unsupportedSchemaVersion(Int)

        public var description: String {
            switch self {
            case .missing(let path):
                return "SML model bindings are missing: \(path) — CALL_MODEL steps need "
                    + "purpose→provider bindings (\"purposes\": {\"<purpose>\": "
                    + "{\"provider\": ..., \"model\": ...}})"
            case .unreadable(let path, let reason):
                return "SML model bindings are unsafe or unreadable: \(path) (\(reason))"
            case .malformed(let path, let reason):
                return "SML model bindings are malformed: \(path) (\(reason))"
            case .unsupportedSchemaVersion(let version):
                return "SML model bindings schema_version \(version) is unsupported "
                    + "(expected \(schemaVersion))"
            }
        }
    }

    public static func load(projectRoot: String) throws -> SMLModelPurposeBindings {
        let url = URL(fileURLWithPath: projectRoot).appendingPathComponent(relativePath)
        let data: Data
        do {
            data = try SMLHostConfigurationFile.read(
                projectRoot: projectRoot,
                relativePath: relativePath
            )
        } catch SMLHostConfigurationFile.ReadError.missing {
            throw LoadError.missing(path: url.path)
        } catch {
            throw LoadError.unreadable(path: url.path, reason: String(describing: error))
        }

        do {
            let root = try SMLHostConfigurationFile.decodeRoot(from: data)
            try SMLHostConfigurationFile.requireOnlyKeys(
                root,
                allowed: ["schema_version", "purposes"],
                path: "models"
            )
            let version = try SMLHostConfigurationFile.requiredInteger(
                root["schema_version"], path: "models.schema_version")
            guard version == schemaVersion else {
                throw LoadError.unsupportedSchemaVersion(version)
            }
            let rawPurposes = try SMLHostConfigurationFile.requiredObject(
                root["purposes"], path: "models.purposes")
            guard rawPurposes.count <= SMLHostConfigurationFile.maximumBindings else {
                throw SMLHostConfigurationFile.SchemaError(
                    reason: "models.purposes exceeds "
                        + "\(SMLHostConfigurationFile.maximumBindings) entries")
            }

            var purposes: [String: Binding] = [:]
            for purpose in rawPurposes.keys.sorted() {
                _ = try SMLHostConfigurationFile.reference(
                    purpose, path: "models.purposes key")
                let entryPath = "models.purposes.\(purpose)"
                let entry = try SMLHostConfigurationFile.requiredObject(
                    rawPurposes[purpose], path: entryPath)
                try SMLHostConfigurationFile.requireOnlyKeys(
                    entry,
                    allowed: ["provider", "model", "system_prompt", "max_tokens"],
                    path: entryPath
                )
                let provider = try SMLHostConfigurationFile.requiredString(
                    entry["provider"], path: "\(entryPath).provider")
                guard SMLValidationSupport.identifierIsValid(provider) else {
                    throw SMLHostConfigurationFile.SchemaError(
                        reason: "\(entryPath).provider is not a valid provider identifier")
                }
                let model = try SMLHostConfigurationFile.boundedText(
                    try SMLHostConfigurationFile.requiredString(
                        entry["model"], path: "\(entryPath).model"),
                    path: "\(entryPath).model",
                    maximumBytes: SMLHostConfigurationFile.maximumShortStringBytes
                )
                let systemPrompt: String?
                if let prompt = try SMLHostConfigurationFile.optionalString(
                    entry["system_prompt"], path: "\(entryPath).system_prompt") {
                    systemPrompt = try SMLHostConfigurationFile.boundedText(
                        prompt,
                        path: "\(entryPath).system_prompt",
                        maximumBytes: SMLHostConfigurationFile.maximumLongStringBytes,
                        allowEmpty: true,
                        allowFormattingWhitespace: true
                    )
                } else {
                    systemPrompt = nil
                }
                let maxTokens = try SMLHostConfigurationFile.optionalInteger(
                    entry["max_tokens"], path: "\(entryPath).max_tokens") ?? 4_096
                guard (256...32_768).contains(maxTokens) else {
                    throw SMLHostConfigurationFile.SchemaError(
                        reason: "\(entryPath).max_tokens must be within 256...32768")
                }
                purposes[purpose] = Binding(
                    providerId: provider,
                    model: model,
                    systemPrompt: systemPrompt,
                    maxTokens: maxTokens
                )
            }
            return SMLModelPurposeBindings(purposes: purposes)
        } catch let error as LoadError {
            throw error
        } catch {
            throw LoadError.malformed(path: url.path, reason: String(describing: error))
        }
    }
}

/// Production `CALL_MODEL` driver: executes one admitted model purpose against kist's REAL
/// provider registry (`ProviderRegistry.stream`, exact-route, no fallback — the host bound this
/// purpose to this provider on purpose) and writes the collected text into the declared output
/// field. The prompt is host-shaped: instruction arguments plus the task state snapshot, never
/// free-form driver invention. An empty response is a FAILED outcome, not empty state.
public struct SMLModelCapabilityDriver: SMLInstructionDriver {
    public let id = "kist-model-driver"

    private let bindings: SMLModelPurposeBindings
    private let providers: ProviderRegistry
    private let clock: @Sendable () -> Double

    public init(
        bindings: SMLModelPurposeBindings,
        providers: ProviderRegistry,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.bindings = bindings
        self.providers = providers
        self.clock = clock
    }

    public func supports(_ request: SMLCapabilityRequest) -> Bool {
        request.operation == .callModel && bindings.purposes[request.reference] != nil
    }

    public func execute(
        _ invocation: SMLCapabilityInvocation
    ) async throws -> SMLCapabilityOutcome {
        let request = invocation.request
        guard let binding = bindings.purposes[request.reference] else {
            throw SMLCapabilityDriverConfigurationError.unknownModelPurpose(request.reference)
        }
        let outputField = try SMLCapabilityDriverSupport.outputField(of: request)
        let prompt = Self.prompt(for: request)

        var settings = ModelSettings(maxTokens: binding.maxTokens)
        if let system = binding.systemPrompt {
            settings.systemPrompt = system
        }

        var collected = ""
        var failure: String?
        do {
            let stream = try await providers.stream(
                providerId: binding.providerId,
                model: binding.model,
                messages: [ChatMessage(role: .user, content: prompt)],
                settings: settings,
                allowFallback: false,
                routePolicy: .exact
            )
            for try await event in stream {
                if case .delta(let text) = event {
                    collected += text
                }
            }
        } catch {
            failure = String(describing: error)
        }

        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        let succeeded = failure == nil && !trimmed.isEmpty
        var statePatch: SMLObject = [:]
        if succeeded, let outputField {
            statePatch[outputField] = .string(trimmed)
        }
        return SMLCapabilityDriverSupport.outcome(
            for: invocation,
            driverID: id,
            status: succeeded ? .passed : .failed,
            statePatch: statePatch,
            evidencePayload: [
                "purpose": .string(request.reference),
                "provider": .string(binding.providerId),
                "model": .string(binding.model),
                "output_schema": request.outputSchema.map { .string($0) } ?? .null,
                "response": .string(trimmed),
                "error": failure.map { .string($0) } ?? .null,
            ],
            receiptID: "model.\(request.reference).\(succeeded ? "passed" : "failed")",
            observedAtEpoch: clock()
        )
    }

    /// Deterministic prompt assembly: the instruction's `prompt` argument (or the purpose name),
    /// followed by the task-state snapshot as sorted-key JSON. No hidden context.
    static func prompt(for request: SMLCapabilityRequest) -> String {
        var head = "Task purpose: \(request.reference)"
        if case .string(let explicit)? = request.arguments["prompt"], !explicit.isEmpty {
            head = explicit
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let stateJSON = (try? encoder.encode(request.state))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "\(head)\n\nCurrent workflow state:\n\(stateJSON)"
    }
}
