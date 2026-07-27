import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Thinking Indicator (inlined to avoid Xcode project file issues)

/// Animated "Thinking..." indicator shown while the agent is analyzing
private struct ThinkingIndicatorView: View {
    @State private var dotCount = 0
    @State private var pulseScale: CGFloat = 1.0

    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            // Animated brain icon
            ZStack {
                Circle()
                    .fill(Color.neonCyan.opacity(0.2))
                    .frame(width: 36, height: 36)
                    .scaleEffect(pulseScale)

                Image(systemName: "brain.head.profile")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.neonCyan)
            }
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseScale)
            .onAppear {
                pulseScale = 1.15
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Thinking" + String(repeating: ".", count: dotCount))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.neonCyan)
                    .frame(width: 100, alignment: .leading)

                Text("Analyzing your request...")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            ProgressView()
                .scaleEffect(0.8)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.cardBackground.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.neonCyan.opacity(0.3), lineWidth: 1)
        )
        .onReceive(timer) { _ in
            dotCount = (dotCount + 1) % 4
        }
    }
}

// MARK: - Chat View

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @StateObject private var conversationManager = ConversationManager.shared
    @StateObject private var screenCaptureService = ScreenCaptureService.shared
    @StateObject private var agentEngine = AgentLoopEngine.shared
    @StateObject private var agentSettings = AgentSettingsManager.shared
    @StateObject private var recentCaptures = RecentCaptureStore.shared
    @StateObject private var appPreview = AppPreviewService.shared
    @StateObject private var unifiedRuntime = UnifiedAgentRuntime.shared

    @State private var showProviderPicker = false
    @State private var showSettings = false
    @State private var showLibrary = false
    @State private var isCapturingContext = false
    @State private var showProjectPicker = false
    @State private var showTeamPicker = false
    @State private var showLivePreview = false
    @State private var useUnifiedRuntime = true  // Toggle for new agent runtime
    @State private var showKeyWizard = false

    var body: some View {
        HStack(spacing: 0) {
            // Library Sidebar (slides in from left)
            if showLibrary {
                LibrarySidebarView(
                    conversationManager: conversationManager,
                    isShowing: $showLibrary,
                    onSelectConversation: { conversation in
                        loadConversation(conversation)
                        showLibrary = false
                    }
                )
                .transition(.move(edge: .leading))
            }

            // Main Chat Area
            mainChatView
        }
        .animation(.easeInOut(duration: 0.2), value: showLibrary)
        .sheet(isPresented: $showKeyWizard) {
            APIKeyWizardView(onClose: { showKeyWizard = false })
        }
        .onAppear {
            // First-run: if any provider this setup will use lacks a key, open
            // the wizard so the app can actually talk instead of silently failing.
            if firstUnusableProvider() != nil {
                showKeyWizard = true
            }
        }
    }

    private var mainChatView: some View {
        VStack(spacing: 0) {
            // Header bar
            ChatHeaderView(
                onClose: {
                    NSApp.keyWindow?.close()
                },
                onCopy: {
                    copyAllMessages()
                },
                onNewChat: {
                    _ = conversationManager.createNewConversation()
                    viewModel.clearChat()
                    agentEngine.reset()
                },
                onLibrary: {
                    withAnimation {
                        showLibrary.toggle()
                    }
                },
                showLibraryButton: true,
                isLibraryOpen: showLibrary,
                onTest: { runTests() }
            )

            // Live preview panel at TOP - compact
            AppPreviewView(previewService: appPreview, agentEngine: agentEngine)
                .frame(height: 160)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)

            // Agent team and project indicator - compact
            HStack(spacing: 6) {
                // Team selector
                TeamBanner(
                    team: agentSettings.settings.selectedTeam,
                    onTap: { showTeamPicker = true }
                )

                // Project path
                AgentProjectBanner(
                    projectPath: agentSettings.settings.effectiveProjectPath,
                    stage: agentEngineStage,
                    onChangeProject: {
                        showProjectPicker = true
                    }
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            // Messages area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageView(
                                message: message,
                                onCopy: { viewModel.copyMessage(message) },
                                onRegenerate: {
                                    if message.role == .assistant {
                                        viewModel.regenerateLastResponse()
                                    }
                                }
                            )
                            .id(message.id)
                        }

                        // Show "Thinking..." while agent is working but no results yet
                        // This covers: analyzing state, OR executing but waiting for first action
                        if useUnifiedRuntime && isAgentThinking {
                            ThinkingIndicatorView()
                                .id("thinking-indicator")
                                .padding(.horizontal, 2)
                        }

                        // Show structured agent execution view when we have results
                        if useUnifiedRuntime && shouldShowExecutionView {
                            AgentExecutionView(
                                intent: unifiedRuntime.currentIntent,
                                plan: unifiedRuntime.currentPlan,
                                actionResults: unifiedRuntime.actionResults,
                                currentActionIndex: unifiedRuntime.currentActionIndex,
                                executionState: unifiedRuntime.executionState
                            )
                            .id("agent-execution-view")
                            .padding(.horizontal, 2)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let lastMessage = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: viewModel.messages.last?.content) { _, _ in
                    if let lastMessage = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                // Scroll to execution view when state changes
                .onChange(of: unifiedRuntime.executionState) { _, _ in
                    if unifiedRuntime.executionState != .idle {
                        withAnimation {
                            proxy.scrollTo("agent-execution-view", anchor: .bottom)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            // Error banner with retry and settings options
            if viewModel.showError, let error = viewModel.errorMessage {
                ErrorBannerView(
                    message: error,
                    onDismiss: { viewModel.showError = false },
                    onRetry: { viewModel.retryLastMessage() },
                    onOpenSettings: { showSettings = true },
                    isRetryable: viewModel.lastErrorWasRetryable,
                    isAuthError: viewModel.lastErrorWasAuth
                )
            }

            // Attached image preview
            if viewModel.attachedImage != nil {
                attachedImagePreview
            }

            // Active context indicator
            if let context = conversationManager.contextMemory.activeContexts.first {
                activeContextBanner(context)
            }

            // Plan approval bar for Unified Runtime
            if useUnifiedRuntime, unifiedRuntime.isWaitingForApproval, let plan = unifiedRuntime.currentPlan {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                    Text("Approve plan? \(plan.planSteps.count) steps, \(plan.actions.count) actions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Approve") { unifiedRuntime.approvePlan() }
                        .buttonStyle(.borderedProminent)
                    Button("Reject") { unifiedRuntime.rejectPlan() }
                        .buttonStyle(.bordered)
                }
                .padding(8)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 10)
            }

            // Input area - Agent mode is always on
            chatInputArea
        }
        .frame(minWidth: 320, minHeight: 400)
        .background(Color.chatBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .sheet(isPresented: $showProviderPicker) {
            ProviderPickerView(
                providers: viewModel.availableProviders,
                selectedProvider: viewModel.selectedProvider,
                onSelect: { provider in
                    viewModel.selectProvider(provider)
                    showProviderPicker = false
                    // Reconfigure agent engine with new provider
                    setupAgentEngine()
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showProjectPicker) {
            ProjectFolderPickerView(
                onSelect: { path in
                    agentSettings.settings.projectPath = path
                    showProjectPicker = false
                    // Re-setup the agent engine with the new path
                    setupAgentEngine()
                },
                onCancel: {
                    showProjectPicker = false
                }
            )
        }
        .sheet(isPresented: $showTeamPicker) {
            TeamPickerView(
                selectedTeamId: $agentSettings.settings.selectedTeamId,
                onDismiss: {
                    showTeamPicker = false
                    // Re-setup agent engine with new team
                    setupAgentEngine()
                }
            )
        }
        // Avoid publishing changes during view updates by deferring the save
        .onChange(of: viewModel.messages) { _, _ in
            DispatchQueue.main.async {
                saveCurrentConversation()
            }
        }
    }

    // MARK: - UI Components

    private var attachedImagePreview: some View {
        HStack {
            if let imageData = viewModel.attachedImage,
               let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 60)
                    .cornerRadius(8)
            }

            VStack(alignment: .leading) {
                Text("Image attached")
                    .font(.caption.bold())
                Text("Will be sent with your next message")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: {
                viewModel.removeAttachedImage()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
        .padding(.horizontal)
    }

    private func activeContextBanner(_ context: ActiveContext) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundColor(.accentColor)

            Text("Connected to:")
                .font(.caption)
                .foregroundColor(.secondary)

            Text(context.name)
                .font(.caption.bold())
                .lineLimit(1)

            if let title = context.metadata["windowTitle"], !title.isEmpty {
                Text("– \(title)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let path = context.metadata["documentPath"], !path.isEmpty {
                Button(action: { openPath(path) }) {
                    Image(systemName: "arrow.uturn.right.square")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Open document")
            }

            Button(action: { focusContext(context) }) {
                Image(systemName: "macwindow")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Focus app")

            Button(action: {
                conversationManager.clearActiveContext(type: context.type)
            }) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.1))
    }

    // MARK: - Chat Input Area (extracted to help type checker)

    private var chatInputArea: some View {
        ChatInputView(
            text: $viewModel.inputText,
            isLoading: viewModel.isLoading || agentEngine.isRunning || (useUnifiedRuntime && unifiedRuntime.executionState == .executing),
            selectedProvider: viewModel.selectedProvider,
            hasAttachedImage: viewModel.attachedImage != nil,
            hasRecentWebCapture: recentCaptures.lastScreenshotPath != nil,
            onSend: { runAgentLoop() },
            onStop: {
                if useUnifiedRuntime {
                    unifiedRuntime.cancel()
                } else {
                    agentEngine.stop()
                }
                viewModel.stopGeneration()
            },
            onProviderTap: { showProviderPicker = true },
            onSettingsTap: { showSettings = true },
            onImageAttach: { openImagePicker() },
            onContextCapture: { startContextCapture() },
            onScreenCapture: { captureScreen() },
            onAttachLastWebCapture: { attachLastWebCapture() },
            onAttachLastWebFrames: { attachLastWebFrames() },
            onAttachLastWebFramesGrid: { attachLastWebFramesGrid() },
            hasRecentWebFrames: !recentCaptures.lastFramePaths.isEmpty,
            onTranscribeLastVideo: { transcribeLastVideo(trimSeconds: 30) },
            hasRecentVideo: (recentCaptures.lastVideoMP4Path ?? recentCaptures.lastVideoPath) != nil
        )
    }

    private func attachLastWebCapture() {
        if let path = RecentCaptureStore.shared.lastScreenshotPath,
           let data = FileManager.default.contents(atPath: path) {
            viewModel.attachImage(data, mimeType: "image/png")
        }
    }

    private func attachLastWebFrames() {
        if let first = RecentCaptureStore.shared.lastFramePaths.first,
           let data = FileManager.default.contents(atPath: first) {
            viewModel.attachImage(data, mimeType: "image/png")
        }
    }

    private func attachLastWebFramesGrid() {
        let paths = RecentCaptureStore.shared.lastFramePaths
        if let png = composeGrid(from: paths) {
            viewModel.attachImage(png, mimeType: "image/png")
        }
    }

    private func openPath(_ path: String) {
        if path.lowercased().hasPrefix("http://") || path.lowercased().hasPrefix("https://") {
            if let url = URL(string: path) { NSWorkspace.shared.open(url) }
        } else {
            let url = URL(fileURLWithPath: path)
            NSWorkspace.shared.open(url)
        }
    }

    private func focusContext(_ context: ActiveContext) {
        if context.type == .application, !context.identifier.isEmpty {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == context.identifier }) {
                app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                return
            }
        }
        if let path = context.metadata["documentPath"], !path.isEmpty {
            openPath(path)
        }
    }

    private func runTests() {
        Task { @MainActor in
            let projectPath = agentSettings.settings.effectiveProjectPath
            var args: [String: Any] = [
                "configuration": "Debug",
                "destination": "platform=macOS"
            ]
            if !agentSettings.settings.scheme.isEmpty {
                args["scheme"] = agentSettings.settings.scheme
            }

            let msgId = UUID()
            viewModel.messages.append(ChatMessage(id: msgId, role: .assistant, content: "Running tests..."))

            let result = await ToolRegistry.shared.execute(toolName: "run_tests", arguments: args, projectPath: projectPath)
            let content: String = result.success ? result.output : ("Test run failed: \(result.error ?? "Unknown error")\n\n\(result.output)")

            if let idx = viewModel.messages.firstIndex(where: { $0.id == msgId }) {
                viewModel.messages[idx].content = content
            }
            saveCurrentConversation()
        }
    }

    // MARK: - Actions

    private func loadConversation(_ conversation: ChatConversation) {
        conversationManager.selectConversation(conversation)

        // Convert SerializableMessages back to ChatMessages
        viewModel.messages = conversation.messages.map { msg in
            ChatMessage(
                id: msg.id,
                role: msg.role,
                content: msg.content,
                timestamp: msg.timestamp,
                imageData: msg.imageBase64.flatMap { Data(base64Encoded: $0) }
            )
        }
    }

    private func saveCurrentConversation() {
        guard let conversationId = conversationManager.currentConversationId else { return }
        conversationManager.updateConversation(id: conversationId, messages: viewModel.messages)
    }

    private func openImagePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg, .gif, .movie, .video, .mpeg4Movie, UTType(filenameExtension: "mp4")].compactMap { $0 }
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            let ext = url.pathExtension.lowercased()
            let videoExts = ["mp4", "mov", "webm", "m4v"]
            if videoExts.contains(ext) {
                // Track the selected video and auto-transcribe in background
                RecentCaptureStore.shared.lastVideoPath = url.path
                if ext == "mp4" { RecentCaptureStore.shared.lastVideoMP4Path = url.path }

                Task { @MainActor in
                    // Add placeholder message
                    let msgId = UUID()
                    viewModel.messages.append(ChatMessage(id: msgId, role: .assistant, content: "Transcribing video..."))
                    let args: [String: Any] = [
                        "path": url.path,
                        "trim_seconds": 30
                    ]
                    let result = await ToolRegistry.shared.execute(toolName: "transcribe_media", arguments: args, projectPath: agentSettings.settings.effectiveProjectPath)
                    let content: String
                    if result.success {
                        content = "📝 Transcript\n\n" + result.output
                        if let tpath = result.metadata?["transcript_path"], !tpath.isEmpty {
                            RecentCaptureStore.shared.lastTranscriptPath = tpath
                        }
                    } else {
                        content = "Transcription failed: \(result.error ?? "Unknown error")\n\n\(result.output)"
                    }
                    if let idx = viewModel.messages.firstIndex(where: { $0.id == msgId }) {
                        viewModel.messages[idx].content = content
                    }
                    saveCurrentConversation()
                }
            } else if let imageData = try? Data(contentsOf: url) {
                let mimeType = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
                viewModel.attachImage(imageData, mimeType: mimeType)
            }
        }
    }

    private func startContextCapture() {
        isCapturingContext = true
        screenCaptureService.startContextSelection { context in
            isCapturingContext = false
            if let context = context {
                conversationManager.addActiveContext(context)

                // If context has screen data, attach it
                if let screenData = context.screenData {
                    viewModel.attachImage(screenData, mimeType: "image/png")
                }
            }
        }
    }

    private func captureScreen() {
        Task {
            if let imageData = await screenCaptureService.captureScreen() {
                viewModel.attachImage(imageData, mimeType: "image/png")
            }
        }
    }

    private func transcribeLastVideo(trimSeconds: Int = 0) {
        Task { @MainActor in
            guard let path = recentCaptures.lastVideoMP4Path ?? recentCaptures.lastVideoPath else { return }
            let args: [String: Any] = [
                "path": path,
                "trim_seconds": trimSeconds
            ]

            let msgId = UUID()
            viewModel.messages.append(ChatMessage(id: msgId, role: .assistant, content: "Transcribing video..."))

            let result = await ToolRegistry.shared.execute(toolName: "transcribe_media", arguments: args, projectPath: agentSettings.settings.effectiveProjectPath)
            let content: String
            if result.success {
                content = "📝 Transcript\n\n" + result.output
            } else {
                content = "Transcription failed: \(result.error ?? "Unknown error")\n\n\(result.output)"
            }
            if let idx = viewModel.messages.firstIndex(where: { $0.id == msgId }) {
                viewModel.messages[idx].content = content
            }
            saveCurrentConversation()
        }
    }

    private func copyAllMessages() {
        let allText = viewModel.messages.map { message in
            let prefix = message.role == .user ? "You: " : "AI: "
            return prefix + message.content
        }.joined(separator: "\n\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allText, forType: .string)
    }

    // MARK: - Agent Loop (Always On)

    /// Computed property to get current agent stage for the banner
    private var agentEngineStage: AgentPipelineManager.AgentStage {
        if agentEngine.isRunning {
            // Check what the agent is doing
            if let leadAgentState = agentEngine.agentStates.values.first(where: { $0.isActive }) {
                switch leadAgentState.status {
                case .thinking:
                    return .understanding
                case .usingTool(let toolName):
                    if toolName.contains("build") {
                        return .building
                    } else {
                        return .generating
                    }
                case .waitingForUser:
                    return .idle
                default:
                    return .generating
                }
            }
            return .generating
        }
        return .idle
    }

    /// Whether the agent is "thinking" (working but no visible results yet)
    private var isAgentThinking: Bool {
        let state = unifiedRuntime.executionState
        // Show thinking if:
        // 1. State is analyzing, OR
        // 2. State is executing but we have no action results yet (waiting for first action)
        if state == .analyzing {
            return true
        }
        if state == .executing && unifiedRuntime.actionResults.isEmpty {
            return true
        }
        return false
    }

    /// Whether to show the execution view (we have some results to show)
    private var shouldShowExecutionView: Bool {
        let state = unifiedRuntime.executionState
        // Show execution view if:
        // 1. Not idle and not pure analyzing
        // 2. AND we have some content (action results, or completed/failed state)
        if state == .idle {
            return false
        }
        if state == .analyzing {
            return false
        }
        // Show if we have results OR if state is completed/failed
        return !unifiedRuntime.actionResults.isEmpty || state == .completed || state == .failed
    }

    /// Setup the agent engine with current settings and team configuration
    private func setupAgentEngine() {
        let projectPath = agentSettings.settings.effectiveProjectPath
        let team = agentSettings.settings.selectedTeam

        // Setup the team in the engine
        agentEngine.setupTeam(team, projectPath: projectPath)
    }

    /// The first provider this run will use that requires a key but has none
    /// (nil = all good). Covers the unified-runtime path (current provider) AND
    /// legacy team runs (each member's resolved provider).
    private func firstUnusableProvider() -> (any AIProvider)? {
        let pm = ProviderManager.shared
        func unusable(_ p: any AIProvider) -> Bool { p.requiresAPIKey && !pm.hasAPIKey(for: p) }

        if useUnifiedRuntime {
            return unusable(pm.currentProvider) ? pm.currentProvider : nil
        }
        // Legacy team path: check every team member's resolved provider.
        let team = agentSettings.settings.selectedTeam
        for member in team.agents {
            let cfg = AgentConfig(id: member.memberId, name: member.memberId, provider: member.provider, model: member.model, role: .coder, color: "#000", systemPrompt: nil)
            let p = agentEngine.getProvider(for: cfg)
            if unusable(p) { return p }
        }
        return nil
    }

    /// Run the agent loop - this is the main entry point for all messages
    private func runAgentLoop() {
        let userMessage = viewModel.inputText
        guard !userMessage.isEmpty else { return }

        // PRE-FLIGHT: the model cannot reply without an API key. Fail LOUD and
        // actionable here instead of running the agent and silently showing
        // "Task completed" / "0 actions" (which looks like success but isn't).
        // Checks EVERY provider this run will use (incl. team members), not just
        // the current one.
        if let provider = firstUnusableProvider() {
            viewModel.messages.append(ChatMessage.user(userMessage, imageData: viewModel.attachedImage, imageMimeType: viewModel.attachedImageMimeType))
            viewModel.inputText = ""
            viewModel.attachedImage = nil
            viewModel.attachedImageMimeType = nil
            viewModel.messages.append(ChatMessage(role: .assistant, content: """
            ⚠️ I can't reach the model — no API key is set for **\(provider.name)**.

            Opening the key wizard so you can add one (or switch to a local provider that needs no key). Add a key, then send your message again.
            """))
            showKeyWizard = true
            return
        }

        // If the input is an absolute path, set project path automatically
        if userMessage.hasPrefix("/") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: userMessage, isDirectory: &isDir) {
                var target = userMessage
                if !isDir.boolValue {
                    // If it's a project/workspace file, use its parent folder
                    if userMessage.hasSuffix(".xcodeproj") || userMessage.hasSuffix(".xcworkspace") {
                        target = (userMessage as NSString).deletingLastPathComponent
                    } else {
                        target = (userMessage as NSString).deletingLastPathComponent
                    }
                }
                agentSettings.settings.projectPath = target
            }
        }

        // Get the selected team
        let team = agentSettings.settings.selectedTeam

        // Ensure engine is setup with the team
        if agentEngine.currentSession == nil {
            setupAgentEngine()
        }

        // Auto-attach pending frame from recent captures if present
        if viewModel.attachedImage == nil, let nextPath = recentCaptures.nextAutoAttachPath,
           let data = FileManager.default.contents(atPath: nextPath) {
            viewModel.attachImage(data, mimeType: "image/png")
            recentCaptures.nextAutoAttachPath = nil
        }

        // Add user message to chat UI (include image if attached)
        let userChatMessage = ChatMessage.user(userMessage, imageData: viewModel.attachedImage, imageMimeType: viewModel.attachedImageMimeType)
        viewModel.messages.append(userChatMessage)
        viewModel.inputText = ""
        // Clear attached image after sending
        viewModel.attachedImage = nil
        viewModel.attachedImageMimeType = nil

        // Run the agent loop
        Task {
            // Start live preview to watch the agent work (like Android Studio emulator)
            appPreview.startCapturingXcode()
            showLivePreview = true

            if useUnifiedRuntime {
                // NEW: Use Unified Agent Runtime for structured execution
                unifiedRuntime.projectPath = agentSettings.settings.effectiveProjectPath
                unifiedRuntime.maxIterations = agentSettings.settings.iterationLimit
                unifiedRuntime.requirePlanApproval = agentSettings.settings.requirePlanApproval
                unifiedRuntime.oneShotMode = agentSettings.settings.oneShotMode
                unifiedRuntime.planPreviewBeforeIterative = agentSettings.settings.planPreviewBeforeIterative
                unifiedRuntime.runTestsAfterWrite = agentSettings.settings.runTestsAfterWrite
                unifiedRuntime.autoInstallDependencies = agentSettings.settings.autoInstallDependencies

                let result = await unifiedRuntime.process(userMessage)

                // Handle result - add summary message
                DispatchQueue.main.async {
                    let summaryMessage = ChatMessage(role: .assistant, content: result.message)
                    self.viewModel.messages.append(summaryMessage)
                    self.saveCurrentConversation()

                    // Keep preview visible for a moment after completion
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if self.unifiedRuntime.executionState == .completed ||
                           self.unifiedRuntime.executionState == .failed {
                            self.showLivePreview = false
                        }
                    }
                }
            } else {
                // LEGACY: Use old AgentLoopEngine
                // Create a placeholder message for agent output
                let agentMessage = ChatMessage(role: .assistant, content: "")
                viewModel.messages.append(agentMessage)
                let messageIndex = viewModel.messages.count - 1

                // Process message through team orchestration
                if team.agents.count > 1 {
                    // Multi-agent team
                    await agentEngine.processMessageWithTeam(userMessage, team: team)
                } else {
                    // Solo agent (backwards compatible)
                    await agentEngine.processMessage(userMessage)
                }

                // Defer publishing UI changes to the next run loop to avoid nested updates
                DispatchQueue.main.async {
                    self.syncAgentHistoryToUI(messageIndex: messageIndex)
                    self.saveCurrentConversation()
                    // Keep preview visible for a moment after completion
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if !self.agentEngine.isRunning {
                            self.showLivePreview = false
                        }
                    }
                }
            }
        }
    }

    /// Sync agent conversation history to the UI messages
    private func syncAgentHistoryToUI(messageIndex: Int) {
        // Get the latest response from agent history
        var responseContent = ""

        for message in agentEngine.conversationHistory.suffix(20) {
            switch message {
            case .thinking(_, let content, _, _):
                responseContent += "💭 *Thinking:* \(content.prefix(200))...\n\n"

            case .toolUse(_, let name, let args, _, _):
                let argsStr = args.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                responseContent += "🔧 **Using \(name)**\n"
                if !argsStr.isEmpty {
                    responseContent += "   `\(argsStr.prefix(100))`\n"
                }

            case .toolResult(_, let name, let result, _, _):
                if result.success {
                    let output = result.output.prefix(500)
                    responseContent += "✅ \(name) completed\n"
                    if !output.isEmpty {
                        responseContent += "```\n\(output)\n```\n"
                    }
                } else {
                    responseContent += "❌ \(name) failed: \(result.error ?? "Unknown error")\n"
                }

            case .assistant(_, let content, _, _):
                responseContent += content + "\n"

            case .error(_, let errorMsg, _, _):
                responseContent += "❌ Error: \(errorMsg)\n"

            default:
                break
            }
        }

        // Update the UI message
        if !responseContent.isEmpty {
            viewModel.messages[messageIndex].content = responseContent
        } else {
            viewModel.messages[messageIndex].content = "Agent completed."
        }
    }
}

// MARK: - Grid Composition

extension ChatView {
    /// Compose up to 4 frames into a 2x2 PNG grid
    func composeGrid(from paths: [String], columns: Int = 2, cellSize: CGSize = CGSize(width: 400, height: 300), spacing: CGFloat = 4) -> Data? {
        let imgs = paths.prefix(4).compactMap { NSImage(contentsOfFile: $0) }
        guard !imgs.isEmpty else { return nil }

        let rows = Int(ceil(Double(imgs.count) / Double(columns)))
        let width = CGFloat(columns) * cellSize.width + CGFloat(columns - 1) * spacing
        let height = CGFloat(rows) * cellSize.height + CGFloat(rows - 1) * spacing
        let size = NSSize(width: width, height: height)

        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        for (idx, img) in imgs.enumerated() {
            let row = idx / columns
            let col = idx % columns
            let x = CGFloat(col) * (cellSize.width + spacing)
            let y = height - CGFloat(row + 1) * cellSize.height - CGFloat(row) * spacing
            let rect = NSRect(x: x, y: y, width: cellSize.width, height: cellSize.height)
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        image.unlockFocus()
        return image.pngData()
    }
}
