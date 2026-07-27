import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var providerManager = ProviderManager.shared
    @StateObject private var settingsManager = ModelSettingsManager.shared
    @StateObject private var whisperManager = MLXWhisperServerManager.shared

    // API Keys
    @AppStorage("anthropic_api_key") private var anthropicKey = ""
    @AppStorage("openai_api_key") private var openaiKey = ""

    // Local model settings
    @AppStorage("ollama_base_url") private var ollamaURL = "http://localhost:11434"
    @AppStorage("ollama_model") private var ollamaModel = "llama3.2"
    @AppStorage("mlx_base_url") private var mlxURL = "http://localhost:8080"

    // Agent settings
    @AppStorage("deepseek_api_key") private var deepseekKey = ""
    @StateObject private var agentSettingsManager = AgentSettingsManager.shared

    // Appearance
    @AppStorage("font_size") private var fontSize: Double = 14

    // Voice settings
    @AppStorage("voice_engine") private var voiceEngine: String = "apple"
    @AppStorage("mlx_whisper_url") private var mlxWhisperURL: String = "http://localhost:8081"
    @AppStorage("mlx_whisper_autostart") private var mlxWhisperAutostart: Bool = true
    @AppStorage("mlx_whisper_model") private var mlxWhisperModel: String = "small"
    @AppStorage("mlx_whisper_streaming") private var mlxWhisperStreaming: Bool = true
    @AppStorage("mlx_whisper_stream_interval") private var mlxWhisperStreamInterval: Double = 1.5

    @State private var selectedTab = "model"
    @State private var showingAddPreset = false
    @State private var newPresetName = ""
    @State private var newPresetPrompt = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            // Model Controls Tab
            modelControlsTab
                .tabItem {
                    Label("Model", systemImage: "slider.horizontal.3")
                }
                .tag("model")

            // Providers Tab
            providersTab
                .tabItem {
                    Label("Providers", systemImage: "cpu")
                }
                .tag("providers")

            // Appearance Tab
            appearanceTab
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }
                .tag("appearance")

            // Agent Tab
            agentSettingsTab
                .tabItem {
                    Label("Agent", systemImage: "cpu")
                }
                .tag("agent")

            // About Tab
            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag("about")

            // Voice Tab
            voiceTab
                .tabItem {
                    Label("Voice", systemImage: "mic")
                }
                .tag("voice")
        }
        .frame(width: 500, height: 500)
        .padding()
    }

    // MARK: - Model Controls Tab

    private var modelControlsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Temperature
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Temperature")
                            .fontWeight(.medium)
                        Spacer()
                        Text(String(format: "%.2f", settingsManager.globalSettings.temperature))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $settingsManager.globalSettings.temperature,
                        in: ModelSettings.temperatureRange,
                        step: 0.05
                    )
                    Text("Lower = more focused, Higher = more creative")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Top P
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Top P (Nucleus Sampling)")
                            .fontWeight(.medium)
                        Spacer()
                        Text(String(format: "%.2f", settingsManager.globalSettings.topP))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $settingsManager.globalSettings.topP,
                        in: ModelSettings.topPRange,
                        step: 0.05
                    )
                }

                // Top K
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Top K")
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(settingsManager.globalSettings.topK)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(settingsManager.globalSettings.topK) },
                            set: { settingsManager.globalSettings.topK = Int($0) }
                        ),
                        in: Double(ModelSettings.topKRange.lowerBound)...Double(ModelSettings.topKRange.upperBound),
                        step: 1
                    )
                }

                Divider()

                // Max Tokens
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Max Tokens")
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(settingsManager.globalSettings.maxTokens)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(settingsManager.globalSettings.maxTokens) },
                            set: { settingsManager.globalSettings.maxTokens = Int($0) }
                        ),
                        in: Double(ModelSettings.maxTokensRange.lowerBound)...Double(ModelSettings.maxTokensRange.upperBound),
                        step: 256
                    )
                }

                // Repeat Penalty (for local models)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Repeat Penalty")
                            .fontWeight(.medium)
                        Spacer()
                        Text(String(format: "%.2f", settingsManager.globalSettings.repeatPenalty))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $settingsManager.globalSettings.repeatPenalty,
                        in: ModelSettings.repeatPenaltyRange,
                        step: 0.05
                    )
                    Text("For Ollama/MLX models")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // System Prompt
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("System Prompt")
                            .fontWeight(.medium)
                        Spacer()
                        Picker("Preset", selection: $settingsManager.selectedPresetId) {
                            Text("Custom").tag(nil as UUID?)
                            ForEach(settingsManager.allPresets) { preset in
                                Text(preset.name).tag(preset.id as UUID?)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }

                    TextEditor(text: $settingsManager.globalSettings.systemPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )

                    HStack {
                        Button("Save as Preset") {
                            showingAddPreset = true
                        }

                        Spacer()

                        Button("Reset to Default") {
                            settingsManager.resetToDefaults()
                        }
                    }
                }

                Divider()

                // Additional Options
                Toggle("Stream Responses", isOn: $settingsManager.globalSettings.streamResponses)

                HStack {
                    Text("Seed (optional)")
                    Spacer()
                    TextField(
                        "Random",
                        value: $settingsManager.globalSettings.seed,
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                }
            }
            .padding()
        }
        .sheet(isPresented: $showingAddPreset) {
            addPresetSheet
        }
    }

    private var addPresetSheet: some View {
        VStack(spacing: 16) {
            Text("Save System Prompt Preset")
                .font(.headline)

            TextField("Preset Name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $newPresetPrompt)
                .frame(height: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

            HStack {
                Button("Cancel") {
                    showingAddPreset = false
                    newPresetName = ""
                    newPresetPrompt = ""
                }

                Spacer()

                Button("Save") {
                    if !newPresetName.isEmpty {
                        let prompt = newPresetPrompt.isEmpty ? settingsManager.globalSettings.systemPrompt : newPresetPrompt
                        settingsManager.addCustomPreset(name: newPresetName, prompt: prompt)
                        showingAddPreset = false
                        newPresetName = ""
                        newPresetPrompt = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newPresetName.isEmpty)
            }
        }
        .padding()
        .frame(width: 350, height: 250)
        .onAppear {
            newPresetPrompt = settingsManager.globalSettings.systemPrompt
        }
    }

    // MARK: - Providers Tab

    @State private var anthropicKeyStatus: APIKeyStatus = .unknown
    @State private var openaiKeyStatus: APIKeyStatus = .unknown
    @State private var deepseekKeyStatus: APIKeyStatus = .unknown
    @State private var grokKeyStatus: APIKeyStatus = .unknown
    @State private var ollamaStatus: APIKeyStatus = .unknown

    // Model selections
    @AppStorage("anthropic_model") private var anthropicModel = "claude-fable-5"
    @AppStorage("openai_model") private var openaiModel = "gpt-5.5"
    @AppStorage("deepseek_model") private var deepseekModel = "deepseek-v4-pro"
    @AppStorage("grok_model") private var grokModel = "grok-4.3"
    @AppStorage("grok_api_key") private var grokKey = ""

    private var providersTab: some View {
        ScrollView {
            Form {
                Section("Claude (Anthropic)") {
                    APIKeyField(
                        key: $anthropicKey,
                        status: $anthropicKeyStatus,
                        placeholder: "sk-ant-...",
                        onValidate: { await validateAnthropicKey() }
                    )
                    Picker("Model", selection: $anthropicModel) {
                        Text("Claude Fable 5").tag("claude-fable-5")
                        Text("Claude Opus 4.8").tag("claude-opus-4-8-20251215")
                        Text("Claude Sonnet 4.5").tag("claude-sonnet-4-5-20250514")
                        Text("Claude Sonnet 4").tag("claude-sonnet-4-20250514")
                        Text("Claude 3.5 Sonnet").tag("claude-3-5-sonnet-20241022")
                        Text("Claude 3.5 Haiku").tag("claude-3-5-haiku-20241022")
                        Text("Claude 3 Opus").tag("claude-3-opus-20240229")
                    }
                    Text("Get your API key from console.anthropic.com")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("GPT (OpenAI)") {
                    APIKeyField(
                        key: $openaiKey,
                        status: $openaiKeyStatus,
                        placeholder: "sk-...",
                        onValidate: { await validateOpenAIKey() }
                    )
                    Picker("Model", selection: $openaiModel) {
                        Text("GPT-5.5").tag("gpt-5.5")
                        Text("GPT-5.4").tag("gpt-5.4")
                        Text("GPT-4o").tag("gpt-4o")
                        Text("GPT-4o Mini").tag("gpt-4o-mini")
                        Text("GPT-4 Turbo").tag("gpt-4-turbo")
                        Text("o1").tag("o1")
                        Text("o1 Mini").tag("o1-mini")
                    }
                    Text("Get your API key from platform.openai.com")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("DeepSeek") {
                    APIKeyField(
                        key: $deepseekKey,
                        status: $deepseekKeyStatus,
                        placeholder: "sk-...",
                        onValidate: { await validateDeepSeekKey() }
                    )
                    Picker("Model", selection: $deepseekModel) {
                        Text("DeepSeek V4 Pro").tag("deepseek-v4-pro")
                        Text("DeepSeek V4").tag("deepseek-v4")
                        Text("DeepSeek V4 Flash").tag("deepseek-v4-flash")
                        Text("DeepSeek Chat (deprecated)").tag("deepseek-chat")
                        Text("DeepSeek Reasoner (deprecated)").tag("deepseek-reasoner")
                    }
                    Text("Get your API key from platform.deepseek.com")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Grok (xAI)") {
                    APIKeyField(
                        key: $grokKey,
                        status: $grokKeyStatus,
                        placeholder: "xai-...",
                        onValidate: { await validateGrokKey() }
                    )
                    Picker("Model", selection: $grokModel) {
                        Text("Grok 4.3").tag("grok-4.3")
                        Text("Grok Code Fast 1").tag("grok-code-fast-1")
                        Text("Grok 2").tag("grok-2-latest")
                        Text("Grok 2 Vision").tag("grok-2-vision-1212")
                        Text("Grok Beta").tag("grok-beta")
                    }
                    Text("Get your API key from console.x.ai")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Ollama (Local)") {
                    HStack {
                        TextField("Server URL", text: $ollamaURL)
                            .textFieldStyle(.roundedBorder)
                        Button(action: { Task { await checkOllamaConnection() } }) {
                            if case .validating = ollamaStatus {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.plain)
                        statusIcon(for: ollamaStatus)
                    }
                    TextField("Model Name", text: $ollamaModel)
                        .textFieldStyle(.roundedBorder)
                    Text("Run: ollama run \(ollamaModel)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("MLX (Apple Silicon)") {
                    TextField("Server URL", text: $mlxURL)
                        .textFieldStyle(.roundedBorder)
                    Text("Run: mlx_lm.server --model mlx-community/...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: anthropicKey) { _, new in
            DispatchQueue.main.async {
                ProviderManager.shared.setAPIKey(new, for: AnthropicProvider())
                anthropicKeyStatus = .unknown
            }
        }
        .onChange(of: openaiKey) { _, new in
            DispatchQueue.main.async {
                ProviderManager.shared.setAPIKey(new, for: OpenAIProvider())
                openaiKeyStatus = .unknown
            }
        }
        .onChange(of: deepseekKey) { _, new in
            DispatchQueue.main.async {
                ProviderManager.shared.setAPIKey(new, for: DeepSeekProvider())
                deepseekKeyStatus = .unknown
            }
        }
        .onChange(of: grokKey) { _, new in
            DispatchQueue.main.async {
                ProviderManager.shared.setAPIKey(new, for: GrokProvider())
                grokKeyStatus = .unknown
            }
        }
    }

    // MARK: - API Key Validation

    private func validateAnthropicKey() async {
        anthropicKeyStatus = .validating
        guard !anthropicKey.isEmpty else {
            anthropicKeyStatus = .invalid("No key entered")
            return
        }

        do {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(anthropicKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "claude-3-5-haiku-20241022",
                "max_tokens": 10,
                "messages": [["role": "user", "content": "hi"]]
            ])

            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    anthropicKeyStatus = .valid
                } else if httpResponse.statusCode == 401 {
                    anthropicKeyStatus = .invalid("Invalid API key")
                } else {
                    anthropicKeyStatus = .valid // Other errors mean key is valid but request failed
                }
            }
        } catch {
            anthropicKeyStatus = .invalid("Connection failed")
        }
    }

    private func validateOpenAIKey() async {
        openaiKeyStatus = .validating
        guard !openaiKey.isEmpty else {
            openaiKeyStatus = .invalid("No key entered")
            return
        }

        do {
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(openaiKey)", forHTTPHeaderField: "Authorization")

            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    openaiKeyStatus = .valid
                } else if httpResponse.statusCode == 401 {
                    openaiKeyStatus = .invalid("Invalid API key")
                } else {
                    openaiKeyStatus = .invalid("Error: \(httpResponse.statusCode)")
                }
            }
        } catch {
            openaiKeyStatus = .invalid("Connection failed")
        }
    }

    private func validateDeepSeekKey() async {
        deepseekKeyStatus = .validating
        guard !deepseekKey.isEmpty else {
            deepseekKeyStatus = .invalid("No key entered")
            return
        }

        do {
            var request = URLRequest(url: URL(string: "https://api.deepseek.com/v1/models")!)
            request.setValue("Bearer \(deepseekKey)", forHTTPHeaderField: "Authorization")

            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    deepseekKeyStatus = .valid
                } else if httpResponse.statusCode == 401 {
                    deepseekKeyStatus = .invalid("Invalid API key")
                } else {
                    deepseekKeyStatus = .invalid("Error: \(httpResponse.statusCode)")
                }
            }
        } catch {
            deepseekKeyStatus = .invalid("Connection failed")
        }
    }

    private func validateGrokKey() async {
        grokKeyStatus = .validating
        guard !grokKey.isEmpty else {
            grokKeyStatus = .invalid("No key entered")
            return
        }

        do {
            var request = URLRequest(url: URL(string: "https://api.x.ai/v1/models")!)
            request.setValue("Bearer \(grokKey)", forHTTPHeaderField: "Authorization")

            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    grokKeyStatus = .valid
                } else if httpResponse.statusCode == 401 {
                    grokKeyStatus = .invalid("Invalid API key")
                } else {
                    grokKeyStatus = .invalid("Error: \(httpResponse.statusCode)")
                }
            }
        } catch {
            grokKeyStatus = .invalid("Connection failed")
        }
    }

    private func checkOllamaConnection() async {
        ollamaStatus = .validating
        do {
            let url = URL(string: "\(ollamaURL)/api/tags")!
            let (_, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                ollamaStatus = .valid
            } else {
                ollamaStatus = .invalid("Server not responding")
            }
        } catch {
            ollamaStatus = .invalid("Connection failed")
        }
    }

    @ViewBuilder
    private func statusIcon(for status: APIKeyStatus) -> some View {
        switch status {
        case .unknown:
            EmptyView()
        case .validating:
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 20, height: 20)
        case .valid:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .invalid(let reason):
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
                .help(reason)
        }
    }

    // MARK: - Appearance Tab

    private var appearanceTab: some View {
        Form {
            Section("Font") {
                HStack {
                    Text("Size: \(Int(fontSize))")
                    Slider(value: $fontSize, in: 10...24, step: 1)
                }
            }

            Section("Window") {
                Text("The chat window automatically floats above other windows.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Agent Tab

    private var agentSettingsTab: some View {
        Form {
            Section("DeepSeek API") {
                SecureField("API Key", text: $deepseekKey)
                    .textFieldStyle(.roundedBorder)
                Text("Get your API key from platform.deepseek.com")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Code Model", selection: $agentSettingsManager.settings.codeModel) {
                    Text("DeepSeek V4 Pro").tag("deepseek-v4-pro")
                    Text("DeepSeek V4").tag("deepseek-v4")
                    Text("DeepSeek V4 Flash").tag("deepseek-v4-flash")
                    Text("DeepSeek Chat (deprecated)").tag("deepseek-chat")
                    Text("DeepSeek Reasoner (deprecated)").tag("deepseek-reasoner")
                }
            }

            Section("Conversation Agent") {
                Picker("Model", selection: $agentSettingsManager.settings.conversationModel) {
                    Text("Claude").tag("claude")
                    Text("GPT-4").tag("gpt")
                }
                Text("Used for understanding user intent")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Build Settings") {
                HStack {
                    TextField("Project Path", text: $agentSettingsManager.settings.projectPath)
                        .textFieldStyle(.roundedBorder)

                    Button("Browse...") {
                        selectProjectFolder()
                    }
                }

                TextField("Scheme", text: $agentSettingsManager.settings.scheme)
                    .textFieldStyle(.roundedBorder)
                Text("Leave empty to use default scheme")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Auto-Fix") {
                Toggle("Automatically fix build errors", isOn: $agentSettingsManager.settings.autoFixErrors)

                if agentSettingsManager.settings.autoFixErrors {
                    Stepper(
                        "Max fix attempts: \(agentSettingsManager.settings.maxFixAttempts)",
                        value: $agentSettingsManager.settings.maxFixAttempts,
                        in: 1...5
                    )
                }
            }

            Section("Execution Controls") {
                Toggle("One-shot execution (plan → 1 action → verify)", isOn: $agentSettingsManager.settings.oneShotMode)
                Toggle("Require plan approval", isOn: $agentSettingsManager.settings.requirePlanApproval)
                Toggle("Plan preview before iterative run", isOn: $agentSettingsManager.settings.planPreviewBeforeIterative)
                Toggle("Run tests after write", isOn: $agentSettingsManager.settings.runTestsAfterWrite)
                Toggle("Auto-install dependencies on build failure", isOn: $agentSettingsManager.settings.autoInstallDependencies)
                Stepper(
                    "Max loop iterations: \(agentSettingsManager.settings.iterationLimit)",
                    value: $agentSettingsManager.settings.iterationLimit,
                    in: 1...50
                )
                Text("Hard safety cap for iterative agent loops.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: deepseekKey) { _, new in
            DispatchQueue.main.async {
                ProviderManager.shared.setAPIKey(new, for: DeepSeekProvider())
            }
        }
    }

    private func selectProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select your Xcode project folder"

        if panel.runModal() == .OK, let url = panel.url {
            agentSettingsManager.settings.projectPath = url.path
        }
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Floating Chat")
                .font(.title)
                .fontWeight(.bold)

            Text("Version 1.0.0")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            Text("A floating chat window that connects to multiple AI providers including Claude, GPT, Ollama, and MLX local models.")
                .multilineTextAlignment(.center)
                .font(.body)
                .foregroundColor(.secondary)
                .padding()

            Spacer()

            Text("Built for macOS with SwiftUI")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding()
    }

    // MARK: - Voice Tab
    private var voiceTab: some View {
        Form {
            Section("Engine") {
                Picker("Voice Engine", selection: $voiceEngine) {
                    Text("Apple Speech").tag("apple")
                    Text("MLX Whisper Server").tag("mlx")
                }
                .pickerStyle(.segmented)
            }

            if voiceEngine == "mlx" {
                Section("MLX Whisper Server") {
                    TextField("Server URL", text: $mlxWhisperURL)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Auto-start local server", isOn: $mlxWhisperAutostart)
                    TextField("Model (e.g. small, base, medium)", text: $mlxWhisperModel)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 12) {
                        Circle()
                            .fill(whisperManager.isServerRunning ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(whisperManager.isServerRunning ? "Running" : (whisperManager.isStarting ? "Starting..." : "Stopped"))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Start Now") {
                            Task { @MainActor in
                                await whisperManager.start(serverURL: mlxWhisperURL, model: mlxWhisperModel)
                            }
                        }
                        .disabled(whisperManager.isStarting || whisperManager.isServerRunning)
                        Button("Stop") {
                            whisperManager.stop()
                        }
                        .disabled(!whisperManager.isServerRunning)
                    }
                    if !whisperManager.serverOutput.isEmpty {
                        Text(whisperManager.serverOutput.suffix(400))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(Color.secondary.opacity(0.08))
                            .cornerRadius(6)
                    }
                    Text("Start a local server that accepts POST /transcribe with raw audio bytes and returns { text: ... }. For example, run a Flask server backed by mlx-whisper.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Streaming") {
                    Toggle("Stream partial results", isOn: $mlxWhisperStreaming)
                    HStack {
                        Text("Interval: \(String(format: "%.1fs", mlxWhisperStreamInterval))")
                        Slider(value: $mlxWhisperStreamInterval, in: 0.5...3.0, step: 0.5)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            Task { @MainActor in
                // Kick a health check to update indicator if server already up
                await whisperManager.ensureRunning(serverURL: mlxWhisperURL, model: mlxWhisperModel)
            }
        }
    }
}

// MARK: - API Key Status

enum APIKeyStatus {
    case unknown
    case validating
    case valid
    case invalid(String)
}

// MARK: - API Key Field with Validation

struct APIKeyField: View {
    @Binding var key: String
    @Binding var status: APIKeyStatus
    var placeholder: String = ""
    var onValidate: () async -> Void

    @State private var isValidating = false

    var body: some View {
        HStack(spacing: 8) {
            SecureField(placeholder, text: $key)
                .textFieldStyle(.roundedBorder)

            Button(action: {
                Task {
                    await onValidate()
                }
            }) {
                switch status {
                case .validating:
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 24, height: 24)
                case .valid:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 18))
                case .invalid:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 18))
                case .unknown:
                    Image(systemName: "questionmark.circle")
                        .foregroundColor(.secondary)
                        .font(.system(size: 18))
                }
            }
            .buttonStyle(.plain)
            .disabled(key.isEmpty)
            .help(statusHelp)
        }
    }

    private var statusHelp: String {
        switch status {
        case .unknown: return "Click to verify API key"
        case .validating: return "Validating..."
        case .valid: return "API key is valid"
        case .invalid(let reason): return reason
        }
    }
}
