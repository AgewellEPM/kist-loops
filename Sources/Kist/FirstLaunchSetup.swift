import Foundation
import AgentCore

/// Uses the same picker as /model. Setup completes before any agent, MCP or tool loop starts.
enum FirstLaunchSetup {
    struct LocalChoice: Decodable, Equatable {
        let model: String
        let installed: Bool
        let bytes: Int64
    }

    static func shouldRun(arguments: [String], isTTY: Bool, nested: Bool,
                          config: KistConfig) -> Bool {
        guard isTTY, !nested else { return false }
        if arguments == ["--setup"] { return true }
        return arguments.isEmpty && config.provider == nil && config.providerPolicyError == nil
    }

    static func entries(registry: ProviderRegistry, locals: [LocalChoice]) -> [ModelPickerState.Entry] {
        let cloud = registry.providers.filter { $0.id != "ollama" && $0.id != "mlx" && $0.id != "cobol" }
        var entries = registry.provider(id: "ollama") == nil ? [] : locals.map {
            ModelPickerState.Entry(providerId: "ollama", model: $0.model,
                detail: "local · no API charges · " + ($0.installed ? "installed" : "download \(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file))"))
        }
        entries += ModelPicker.entries(providerModels: Dictionary(uniqueKeysWithValues:
            cloud.map { ($0.id, $0.availableModels.map(\.id)) }),
            providers: cloud.map(\.id), hasKey: { id in
                guard let provider = registry.provider(id: id) else { return false }
                return registry.hasKey(for: provider)
            })
        return entries
    }

    static func run(config: KistConfig) async -> Bool {
        if let error = config.providerPolicyError {
            KistRunner.err("Setup cannot change an invalid provider policy: \(error)")
            return false
        }
        let registry = KistRunner.makeRegistry(config: config)
        let bridge = FirstLaunchLocalBridge()
        let locals = (try? bridge.inventory()) ?? []
        let choices = entries(registry: registry, locals: locals)
        guard !choices.isEmpty else {
            KistRunner.err("No models are permitted by this configuration.")
            return false
        }
        KistRunner.note("Choose your model. Local runs on this computer; cloud models use your provider's pricing.")
        if locals.isEmpty, registry.provider(id: "ollama") != nil {
            KistRunner.note("Automatic local setup needs the packaged Kist launcher.")
        }
        let current = ProviderBinding(providerId: config.provider ?? choices[0].providerId,
                                      model: config.model ?? choices[0].model)
        while let choice = ModelPicker.run(entries: choices, current: current) {
            guard let provider = registry.provider(id: choice.providerId) else { continue }
            let model = provider.resolvedModel(choice.model)
            do {
                if choice.providerId == "ollama" {
                    KistRunner.note("Preparing \(model)…")
                    try bridge.prepare(model: model)
                } else if provider.requiresAPIKey && !registry.hasKey(for: provider) {
                    let key = AddModelFlow.readHiddenKey("API key for \(provider.name) (hidden; blank cancels): ")
                    guard !key.isEmpty else { continue }
                    try SecretWriter.write(account: provider.keyAccount, key: key)
                } else if let cli = provider as? CLIChatProvider, !cli.isLocallyAvailable() {
                    throw SetupError.unavailable("\(provider.name) needs its own installed and authenticated CLI.")
                }
                guard KistConfig.writeStartupSelection(provider: provider.id, model: model,
                                                       localOnly: provider.id == "ollama") else {
                    throw SetupError.unavailable("Could not save the selected model; existing configuration was preserved.")
                }
                KistRunner.note(provider.id == "ollama"
                    ? "Ready · \(model) · local only · paid-provider fallback disabled"
                    : "Ready · \(provider.name) · \(model)")
                return true
            } catch {
                KistRunner.err("Setup could not finish: \(error.localizedDescription)")
            }
        }
        KistRunner.note("Setup cancelled. No conversation or agent task started.")
        return false
    }

    enum SetupError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? { if case .unavailable(let text) = self { return text }; return nil }
    }
}

/// The distributable launcher owns model installation and the bounded local runtime.
/// Arguments are never shell-interpolated and no repository file selects this executable.
struct FirstLaunchLocalBridge {
    let environment: [String: String]
    init(environment: [String: String] = ProcessInfo.processInfo.environment) { self.environment = environment }

    func inventory() throws -> [FirstLaunchSetup.LocalChoice] {
        let data = try call(["inventory"], capture: true)
        return try JSONDecoder().decode([FirstLaunchSetup.LocalChoice].self, from: data)
    }

    func prepare(model: String) throws { _ = try call(["prepare", model], capture: false) }

    private func call(_ arguments: [String], capture: Bool) throws -> Data {
        guard let helper = environment["KIST_LOCAL_SETUP_HELPER"], helper.hasPrefix("/"),
              let python = environment["KIST_LOCAL_SETUP_PYTHON"], python.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: python),
              FileManager.default.fileExists(atPath: helper) else {
            throw FirstLaunchSetup.SetupError.unavailable("Launch Kist with its installed launcher to prepare a local model.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [helper] + arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        let pipe = Pipe()
        if capture { process.standardOutput = pipe }
        else { process.standardOutput = FileHandle.standardOutput }
        try process.run()
        var data = Data()
        if capture {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                data.append(chunk)
                if data.count > 65_536 { process.terminate(); break }
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= 65_536 else {
            throw FirstLaunchSetup.SetupError.unavailable("Local model preparation failed; choose another model or retry setup.")
        }
        return data
    }
}
