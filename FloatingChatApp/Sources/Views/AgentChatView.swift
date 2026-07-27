import SwiftUI
import AppKit
import AVKit
import WebKit

/// The Claude Code-style agentic chat interface
struct AgentChatView: View {
    @StateObject private var engine = AgentLoopEngine.shared
    @State private var inputText = ""
    @State private var showAgentPicker = false
    @State private var showSettings = false
    @State private var showResumePicker = false

    let projectPath: String

    init(projectPath: String) {
        self.projectPath = projectPath
    }

    // Dark theme colors
    private let darkBg = Color(red: 0.08, green: 0.08, blue: 0.10)
    private let darkSecondary = Color(red: 0.12, green: 0.12, blue: 0.14)

    var body: some View {
        VStack(spacing: 0) {
            // Header with agent indicators
            agentHeader

            Divider()
                .background(Color.white.opacity(0.1))

            // Message list
            // FIXED: Use message.id for stable identity, not enumerated offset
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(engine.conversationHistory) { message in
                            AgentMessageBubble(message: message, agents: engine.currentSession?.agents ?? [])
                                .id(message.id)
                        }

                        // Show current thinking
                        ForEach(Array(engine.agentStates.values.filter { $0.isActive }), id: \.id) { state in
                            if !state.currentThought.isEmpty {
                                ThinkingBubble(
                                    agentId: state.id,
                                    text: state.currentThought,
                                    agents: engine.currentSession?.agents ?? []
                                )
                            }
                        }

                        // ADDED: Streaming indicator when processing
                        if engine.isRunning {
                            StreamingIndicator()
                                .padding(.leading)
                        }
                    }
                    .padding()
                }
                .background(darkBg)
                .onChange(of: engine.conversationHistory.count) { _, _ in
                    // FIXED: Check for empty before scrolling to avoid crash
                    if let lastMessage = engine.conversationHistory.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Pending user input prompt
            if let pending = engine.pendingUserInput {
                UserInputPromptView(pending: pending) { response in
                    // FIXED: submitUserInput is now sync (no Task/await needed)
                    engine.submitUserInput(response)
                }
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // Input area
            AgentInputArea(
                text: $inputText,
                isProcessing: engine.isRunning,
                activeAgents: engine.agentStates.values.filter { $0.isActive }.map { $0.id },
                onSend: sendMessage,
                onStop: { engine.stop() },
                onAddAgent: { showAgentPicker = true }
            )
            .background(darkSecondary)
        }
        .background(darkBg)
        .preferredColorScheme(.dark)
        .onAppear {
            // Defer to next run loop to avoid publishing during view update
            DispatchQueue.main.async {
                setupDefaultAgents()
            }
        }
        .sheet(isPresented: $showAgentPicker) {
            AgentPickerSheet(onSelect: { config in
                engine.addAgent(config)
                showAgentPicker = false
            })
        }
        // FIXED: Add the missing settings sheet
        .sheet(isPresented: $showSettings) {
            AgentSettingsSheet()
        }
        .sheet(isPresented: $showResumePicker) {
            ResumePickerView(onClose: { showResumePicker = false })
        }
    }

    // MARK: - Header

    private var agentHeader: some View {
        HStack(spacing: 12) {
            // Active agents
            ForEach(engine.currentSession?.agents ?? [], id: \.id) { agent in
                AgentChip(
                    agent: agent,
                    state: engine.agentStates[agent.id]
                )
            }

            Spacer()

            // Resume a previous run
            Button(action: { showResumePicker = true }) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Resume an interrupted run")

            // Add agent button
            Button(action: { showAgentPicker = true }) {
                Image(systemName: "plus.circle")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Add another agent")

            // Settings
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
    }

    // MARK: - Actions

    private func setupDefaultAgents() {
        if engine.currentSession == nil {
            let claudeAgent = AgentLoopEngine.createClaudeAgent(role: .lead)
            engine.setup(projectPath: projectPath, agents: [claudeAgent])
        }
    }

    private func sendMessage() {
        guard !inputText.isEmpty else { return }
        let message = inputText
        inputText = ""

        Task {
            await engine.processMessage(message)
        }
    }
}

// MARK: - Agent Chip

struct AgentChip: View {
    let agent: AgentConfig
    let state: AgentState?

    var body: some View {
        HStack(spacing: 6) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(agent.name)
                .font(.system(size: 12, weight: .medium))

            // Role badge
            Text(agent.role.rawValue)
                .font(.system(size: 9))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color(hex: agent.color).opacity(0.2))
                .cornerRadius(4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(hex: agent.color).opacity(0.1))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(hex: agent.color).opacity(0.3), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        guard let state = state else { return .gray }

        switch state.status {
        case .idle: return .gray
        case .thinking: return .yellow
        case .usingTool: return .orange
        case .waitingForUser: return .blue
        case .waitingForAgent: return .purple
        case .error: return .red
        }
    }
}

// MARK: - Agent Message Bubble

struct AgentMessageBubble: View {
    let message: AgentMessage
    let agents: [AgentConfig]

    var body: some View {
        // FIXED: Updated pattern matching for new AgentMessage signatures with id and timestamp
        switch message {
        case .user(let text, _, _):
            UserMessageBubble(text: text)

        case .assistant(let agentId, let content, _, _):
            AssistantMessageBubble(agentId: agentId, content: content, agents: agents)

        case .thinking(let agentId, let content, _, _):
            ThinkingBubble(agentId: agentId, text: content, agents: agents)

        case .toolUse(let agentId, let name, let arguments, _, _):
            ToolUseBubble(agentId: agentId, toolName: name, arguments: arguments, agents: agents)

        case .toolResult(let agentId, let name, let result, _, _):
            ToolResultBubble(agentId: agentId, toolName: name, result: result, agents: agents)

        case .error(let agentId, let errorMessage, _, _):
            ErrorMessageBubble(agentId: agentId, message: errorMessage, agents: agents)

        case .agentHandoff(let from, let to, let context, _, _):
            HandoffBubble(fromAgent: from, toAgent: to, context: context, agents: agents)
        }
    }
}

// MARK: - User Message Bubble

struct UserMessageBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer()

            Text(text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(16)
                .cornerRadius(16, corners: [.topRight])
        }
    }
}

// MARK: - Assistant Message Bubble

struct AssistantMessageBubble: View {
    let agentId: String
    let content: String
    let agents: [AgentConfig]

    private var agent: AgentConfig? {
        agents.first { $0.id == agentId }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Agent avatar
            Circle()
                .fill(Color(hex: agent?.color ?? "#666666"))
                .frame(width: 28, height: 28)
                .overlay(
                    Text(String(agent?.name.prefix(1) ?? "A"))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(agent?.name ?? "Assistant")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                // Use MarkdownTextView for proper markdown rendering
                MarkdownTextView(text: content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
            }

            Spacer()
        }
    }
}

// MARK: - Thinking Bubble

struct ThinkingBubble: View {
    let agentId: String
    let text: String
    let agents: [AgentConfig]

    @State private var isExpanded = false

    private var agent: AgentConfig? {
        agents.first { $0.id == agentId }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Brain icon
            Image(systemName: "brain")
                .font(.system(size: 14))
                .foregroundColor(.purple)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(agent?.name ?? "Agent") is thinking...")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.purple)

                    Spacer()

                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if isExpanded || text.count < 200 {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(10)
                        .background(Color.purple.opacity(0.1))
                        .cornerRadius(8)
                } else {
                    Text(text.prefix(150) + "...")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(10)
                        .background(Color.purple.opacity(0.1))
                        .cornerRadius(8)
                }
            }

            Spacer()
        }
    }
}

// MARK: - Tool Use Bubble

struct ToolUseBubble: View {
    let agentId: String
    let toolName: String
    let arguments: [String: String]
    let agents: [AgentConfig]

    private var agent: AgentConfig? {
        agents.first { $0.id == agentId }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: toolIcon)
                .font(.system(size: 14))
                .foregroundColor(.orange)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(toolName)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)

                    Text("by \(agent?.name ?? "agent")")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                // Show key arguments
                ForEach(Array(arguments.prefix(3)), id: \.key) { key, value in
                    HStack {
                        Text(key + ":")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)

                        Text(value.prefix(50) + (value.count > 50 ? "..." : ""))
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                    }
                }
            }
            .padding(8)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(8)

            Spacer()
        }
    }

    private var toolIcon: String {
        switch toolName {
        case "read_file": return "doc.text"
        case "write_file": return "doc.badge.plus"
        case "edit_file": return "pencil"
        case "list_files", "glob_files": return "folder"
        case "search_code": return "magnifyingglass"
        case "run_build": return "hammer"
        case "run_command": return "terminal"
        case "get_project_structure": return "list.bullet.indent"
        default: return "wrench"
        }
    }
}

// MARK: - Tool Result Bubble

struct ToolResultBubble: View {
    let agentId: String
    let toolName: String
    let result: ToolResult
    let agents: [AgentConfig]

    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: result.success ? "checkmark.circle" : "xmark.circle")
                .font(.system(size: 14))
                .foregroundColor(result.success ? .green : .red)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(result.success ? "Success" : "Failed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(result.success ? .green : .red)

                    Spacer()

                    if result.output.count > 100 {
                        Button(action: { isExpanded.toggle() }) {
                            Text(isExpanded ? "Collapse" : "Expand")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if isExpanded || result.output.count <= 100 {
                    Text(result.output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                } else {
                    Text(result.output.prefix(100) + "...")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                }

                // Inline video if available (prefer mp4)
                let videoPath = result.metadata?["video_path_mp4"] ?? result.metadata?["video_path"]
                if let videoPath, FileManager.default.fileExists(atPath: videoPath) {
                    InlineVideoPlayer(path: videoPath)
                        .frame(height: 220)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                        .padding(.top, 4)
                }

                // Quick actions for known tools
                if toolName == "create_xcode_app", let projectPath = result.metadata?["project_path"] {
                    HStack(spacing: 12) {
                        Button {
                            let url = URL(fileURLWithPath: projectPath)
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Open in Xcode", systemImage: "hammer")
                        }
                        .buttonStyle(.borderedProminent)

                        if let appPath = result.metadata?["app_path"] {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appPath)])
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.top, 4)
                }

                // Quick actions for web capture / frames
                if toolName == "web_capture" || toolName == "extract_video_frames" {
                    HStack(spacing: 12) {
                        if let screenshot = result.metadata?["screenshot_path"], FileManager.default.fileExists(atPath: screenshot) {
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: screenshot))
                            } label: {
                                Label("Open Screenshot", systemImage: "photo")
                            }
                            .buttonStyle(.bordered)
                        }

                        if let dir = result.metadata?["frames_dir"], FileManager.default.fileExists(atPath: dir) {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
                            } label: {
                                Label("Reveal Frames", systemImage: "square.grid.2x2")
                            }
                            .buttonStyle(.bordered)
                        }

                        if let transcript = result.metadata?["transcript_path"], FileManager.default.fileExists(atPath: transcript) {
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: transcript))
                            } label: {
                                Label("Open Transcript", systemImage: "text.alignleft")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.top, 4)
                }

                // Preview images if available
                if let screenshot = result.metadata?["screenshot_path"], FileManager.default.fileExists(atPath: screenshot) {
                    ImageThumbnailRow(paths: [screenshot])
                }
                if let framesJoined = result.metadata?["frame_paths"], !framesJoined.isEmpty {
                    let paths = framesJoined.components(separatedBy: "\n").filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
                    if !paths.isEmpty {
                        ImageThumbnailRow(paths: Array(paths.prefix(4)))
                    }
                }

                if let error = result.error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }

            Spacer()
        }
    }
}

// MARK: - Error Message Bubble

struct ErrorMessageBubble: View {
    let agentId: String
    let message: String
    let agents: [AgentConfig]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14))
                .foregroundColor(.red)
                .frame(width: 28, height: 28)

            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.red)
                .padding(10)
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)

            Spacer()
        }
    }
}

// MARK: - Image Thumbnail Row

struct ImageThumbnailRow: View {
    let paths: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(paths, id: \.self) { p in
                    if let img = NSImage(contentsOfFile: p) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 120, height: 80)
                            .clipped()
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Inline Video Player

struct InlineVideoPlayer: View {
    let path: String

    var body: some View {
        Group {
            if path.lowercased().hasSuffix(".mp4") || path.lowercased().hasSuffix(".mov") {
                AVKitVideo(path: path)
            } else if path.lowercased().hasSuffix(".webm") {
                WebMVideo(path: path)
            } else {
                Text("Unsupported video format: \((path as NSString).pathExtension)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct AVKitVideo: View {
    let path: String
    @State private var player: AVPlayer? = nil

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                player = AVPlayer(url: URL(fileURLWithPath: path))
            }
    }
}

struct WebMVideo: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")

        let fileURL = URL(fileURLWithPath: path)
        let html = """
        <html><head><meta name='viewport' content='width=device-width,initial-scale=1'>
        <style>body{margin:0;background:transparent;}video{width:100%;height:100%;background:#000;border-radius:8px;}</style>
        </head><body>
        <video controls src='\(fileURL.absoluteString)'></video>
        </body></html>
        """
        web.loadHTMLString(html, baseURL: fileURL.deletingLastPathComponent())
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - Handoff Bubble

struct HandoffBubble: View {
    let fromAgent: String
    let toAgent: String
    let context: String
    let agents: [AgentConfig]

    private var fromConfig: AgentConfig? {
        agents.first { $0.id == fromAgent }
    }

    private var toConfig: AgentConfig? {
        agents.first { $0.id == toAgent }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.circle")
                .foregroundColor(.purple)

            Text("\(fromConfig?.name ?? "Agent") → \(toConfig?.name ?? "Agent")")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.purple)

            Text(context.prefix(50) + (context.count > 50 ? "..." : ""))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color.purple.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - User Input Prompt

struct UserInputPromptView: View {
    let pending: PendingUserInput
    let onSubmit: (String) -> Void

    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.blue)

                Text(pending.question)
                    .font(.system(size: 13))

                Spacer()
            }

            if let options = pending.options {
                HStack {
                    ForEach(options, id: \.self) { option in
                        Button(option) {
                            onSubmit(option)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                HStack {
                    TextField("Your response...", text: $inputText)
                        .textFieldStyle(.roundedBorder)

                    Button("Send") {
                        onSubmit(inputText)
                        inputText = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(inputText.isEmpty)
                }
            }
        }
        .padding()
        .background(Color.blue.opacity(0.1))
    }
}

// MARK: - Input Area

struct AgentInputArea: View {
    @Binding var text: String
    let isProcessing: Bool
    let activeAgents: [String]
    let onSend: () -> Void
    let onStop: () -> Void
    let onAddAgent: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Text input
            TextField("Ask the agent to help with your code...", text: $text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(20)
                .onSubmit {
                    if !text.isEmpty && !isProcessing {
                        onSend()
                    }
                }

            // Send/Stop button
            Button(action: {
                if isProcessing {
                    onStop()
                } else {
                    onSend()
                }
            }) {
                ZStack {
                    Circle()
                        .fill(buttonColor)
                        .frame(width: 36, height: 36)

                    if isProcessing {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty && !isProcessing)
        }
        .padding()
    }

    private var buttonColor: Color {
        if isProcessing {
            return .red
        } else if text.isEmpty {
            return .gray.opacity(0.5)
        } else {
            return .accentColor
        }
    }
}

// MARK: - Agent Picker Sheet

struct AgentPickerSheet: View {
    let onSelect: (AgentConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Agent")
                .font(.headline)

            VStack(spacing: 12) {
                AgentOptionRow(
                    name: "Claude",
                    description: "Best for reasoning and conversation",
                    color: "#D97706",
                    icon: "brain.head.profile"
                ) {
                    onSelect(AgentLoopEngine.createClaudeAgent())
                }

                AgentOptionRow(
                    name: "DeepSeek",
                    description: "Specialized for code generation",
                    color: "#3B82F6",
                    icon: "chevron.left.forwardslash.chevron.right"
                ) {
                    onSelect(AgentLoopEngine.createDeepSeekAgent())
                }

                AgentOptionRow(
                    name: "GPT-4",
                    description: "Great for code review",
                    color: "#10B981",
                    icon: "eye"
                ) {
                    onSelect(AgentLoopEngine.createGPTAgent())
                }

                AgentOptionRow(
                    name: "Local (Ollama)",
                    description: "Fast local model",
                    color: "#8B5CF6",
                    icon: "desktopcomputer"
                ) {
                    onSelect(AgentLoopEngine.createLocalAgent())
                }
            }

            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(width: 350)
    }
}

struct AgentOptionRow: View {
    let name: String
    let description: String
    let color: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(hex: color))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: icon)
                            .foregroundColor(.white)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 14, weight: .medium))

                    Text(description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "plus.circle")
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Corner Radius Extension

extension View {
    func cornerRadius(_ radius: CGFloat, corners: [Corner]) -> some View {
        clipShape(RoundedCornerShape(radius: radius, corners: corners))
    }
}

enum Corner {
    case topLeft, topRight, bottomLeft, bottomRight
}

struct RoundedCornerShape: Shape {
    var radius: CGFloat
    var corners: [Corner]

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let tl = corners.contains(.topLeft) ? radius : 0
        let tr = corners.contains(.topRight) ? radius : 0
        let bl = corners.contains(.bottomLeft) ? radius : 0
        let br = corners.contains(.bottomRight) ? radius : 0

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)

        return path
    }
}

// MARK: - Streaming Indicator (NEW)

/// Visual feedback when agent is processing/streaming
struct StreamingIndicator: View {
    @State private var dotIndex = 0
    let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .opacity(index == dotIndex ? 1.0 : 0.3)
            }

            Text("Thinking...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onReceive(timer) { _ in
            dotIndex = (dotIndex + 1) % 3
        }
    }
}

// MARK: - Agent Settings Sheet (NEW)

/// Settings sheet for agent configuration
struct AgentSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine = AgentLoopEngine.shared
    @State private var maxIterations: Double = 50
    @State private var temperature: Double = 0.3

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Agent Settings")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()

            // Max Iterations
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Max Iterations")
                    Spacer()
                    Text("\(Int(maxIterations))")
                        .foregroundColor(.secondary)
                }
                Slider(value: $maxIterations, in: 10...100, step: 5)
                Text("Safety limit for agent loop iterations")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Temperature
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(String(format: "%.1f", temperature))
                        .foregroundColor(.secondary)
                }
                Slider(value: $temperature, in: 0...1, step: 0.1)
                Text("Lower = more focused, Higher = more creative")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Active Agents
            VStack(alignment: .leading, spacing: 8) {
                Text("Active Agents")
                    .font(.headline)

                ForEach(engine.currentSession?.agents ?? [], id: \.id) { agent in
                    HStack {
                        Circle()
                            .fill(Color(hex: agent.color))
                            .frame(width: 12, height: 12)
                        Text(agent.name)
                        Text("(\(agent.role.rawValue))")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(agent.provider)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                    }
                    .padding(.vertical, 4)
                }
            }

            Spacer()

            HStack {
                Button("Reset to Defaults") {
                    maxIterations = 50
                    temperature = 0.3
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400, height: 500)
    }
}
