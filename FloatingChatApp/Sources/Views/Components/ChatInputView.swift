import SwiftUI

struct ChatInputView: View {
    @Binding var text: String
    let isLoading: Bool
    let selectedProvider: any AIProvider
    var hasAttachedImage: Bool = false
    var hasRecentWebCapture: Bool = false
    let onSend: () -> Void
    let onStop: () -> Void
    let onProviderTap: () -> Void
    let onSettingsTap: () -> Void
    var onImageAttach: (() -> Void)? = nil
    var onContextCapture: (() -> Void)? = nil
    var onScreenCapture: (() -> Void)? = nil
    var onAttachLastWebCapture: (() -> Void)? = nil
    var onAttachLastWebFrames: (() -> Void)? = nil
    var onAttachLastWebFramesGrid: (() -> Void)? = nil
    var hasRecentWebFrames: Bool = false
    var onTranscribeLastVideo: (() -> Void)? = nil
    var hasRecentVideo: Bool = false

    @StateObject private var voiceManager = VoiceInputManager.shared
    @StateObject private var appLinkService = AppLinkService.shared
    @State private var showAppPicker = false
    // Drive UI state from the VoiceInputManager to avoid dead buttons
    private var isRecording: Bool { voiceManager.isRecording }
    @State private var voiceBaseText = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Linked app indicator
            if appLinkService.linkedApp != nil || appLinkService.isSelectingApp {
                LinkedAppIndicator(
                    linkedApp: appLinkService.linkedApp,
                    isSelecting: appLinkService.isSelectingApp,
                    onUnlink: { appLinkService.unlink() },
                    onCancel: { appLinkService.cancelSelection() }
                )
            }

            Divider()
                .opacity(0.3)

            // Text input area
            HStack(alignment: .bottom, spacing: 0) {
                // Multi-line text editor
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Message...")
                            .foregroundColor(.secondary.opacity(0.5))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                    }

                    TextEditor(text: $text)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .background(.clear)
                        .frame(minHeight: 36, maxHeight: 120)
                        .fixedSize(horizontal: false, vertical: true)
                        .focused($isTextFieldFocused)
                        .onKeyPress(keys: [.return]) { press in
                            // Shift+Enter = new line, Enter alone = send
                            if press.modifiers.contains(.shift) {
                                return .ignored // Let TextEditor handle it (new line)
                            }
                            if !text.isEmpty && !isLoading {
                                onSend()
                            }
                            return .handled
                        }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .background(Color.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // Bottom toolbar
            HStack(spacing: 12) {
                // Left side buttons
                HStack(spacing: 8) {
                    // Image attach button
                    ToolbarButton(
                        icon: hasAttachedImage ? "photo.fill" : "photo",
                        tooltip: "Attach image",
                        tint: hasAttachedImage ? .accentColor : .secondary
                    ) {
                        onImageAttach?()
                    }

                    // Attach last web capture (only show when available)
                    if hasRecentWebCapture {
                        ToolbarButton(
                            icon: "photo.badge.plus",
                            tooltip: "Attach last web capture",
                            tint: .accentColor
                        ) {
                            onAttachLastWebCapture?()
                        }
                    }

                    // Attach last extracted frame (only show when available)
                    if hasRecentWebFrames {
                        ToolbarButton(
                            icon: "square.grid.2x2",
                            tooltip: "Attach last key frame",
                            tint: .accentColor
                        ) {
                            onAttachLastWebFrames?()
                        }

                        // Attach frames grid
                        ToolbarButton(
                            icon: "square.grid.3x2",
                            tooltip: "Attach frames as grid",
                            tint: .accentColor
                        ) {
                            onAttachLastWebFramesGrid?()
                        }
                    }

                    // Transcribe last video (only show when available)
                    if hasRecentVideo {
                        ToolbarButton(
                            icon: "text.badge.plus",
                            tooltip: "Transcribe last video",
                            tint: .accentColor
                        ) {
                            onTranscribeLastVideo?()
                        }
                    }

                    // Link chain button - link to an app
                    ToolbarButton(
                        icon: appLinkService.linkedApp != nil ? "link.circle.fill" : "link",
                        tooltip: appLinkService.linkedApp != nil ? "Linked to \(appLinkService.linkedApp!.name)" : "Link to app",
                        tint: appLinkService.linkedApp != nil ? .neonCyan : (appLinkService.isSelectingApp ? .neonPink : .secondary)
                    ) {
                        if appLinkService.isSelectingApp {
                            appLinkService.cancelSelection()
                        } else {
                            showAppPicker = true
                        }
                    }
                    .popover(isPresented: $showAppPicker) {
                        AppPickerPopover(
                            apps: appLinkService.runningApps,
                            onSelect: { app in
                                appLinkService.linkTo(app)
                                showAppPicker = false
                            },
                            onStartSelection: {
                                showAppPicker = false
                                appLinkService.startAppSelection()
                            }
                        )
                    }

                    // Context capture button (click any window/app)
                    ToolbarButton(
                        icon: "viewfinder",
                        tooltip: "Connect context (click any window)"
                    ) {
                        onContextCapture?()
                    }

                    // Screen capture button
                    ToolbarButton(
                        icon: "camera.viewfinder",
                        tooltip: "Capture screen"
                    ) {
                        onScreenCapture?()
                    }

                    // Provider selector button
                    Button(action: onProviderTap) {
                        HStack(spacing: 4) {
                            Image(systemName: selectedProvider.iconName)
                                .font(.system(size: 11))
                            Text(shortProviderName(selectedProvider.name))
                                .font(.system(size: 11))

                            // Show vision indicator if model supports it
                            if selectedProvider.supportsVision {
                                Image(systemName: "eye")
                                    .font(.system(size: 8))
                            }
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Select AI model")

                    ToolbarButton(icon: "gearshape", tooltip: "Settings") {
                        onSettingsTap()
                    }

                    // Agent mode indicator (always on)
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(.system(size: 11))
                        Text("Agent")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .help("Agent mode active - AI can read, write, build, and search")
                }

                Spacer()

                // Right side buttons
                HStack(spacing: 8) {
                    // Voice input button with recording state
                    ToolbarButton(
                        icon: isRecording ? "mic.fill" : "mic",
                        tooltip: isRecording ? "Stop voice input" : "Voice input",
                        tint: isRecording ? .red : .secondary
                    ) {
                        if voiceManager.isRecording {
                            voiceManager.stop()
                        } else {
                            Task { @MainActor in
                                let ok = await voiceManager.requestAuthorization()
                                if ok {
                                    voiceBaseText = text
                                    do { try await voiceManager.start() } catch { }
                                }
                            }
                        }
                    }

                    // Send/Stop button
                    Button(action: {
                        if isLoading {
                            onStop()
                        } else if !text.isEmpty {
                            onSend()
                        }
                    }) {
                        ZStack {
                            Circle()
                                .fill(sendButtonColor)
                                .frame(width: 28, height: 28)

                            if isLoading {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(isLoading ? "Stop generation" : "Send message")
                    .disabled(text.isEmpty && !isLoading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.inputAreaBackground)
        .onReceive(voiceManager.$partialText) { partial in
            if voiceManager.isRecording {
                if voiceBaseText.isEmpty {
                    text = partial
                } else {
                    let sep = voiceBaseText.hasSuffix(" ") || partial.isEmpty ? "" : " "
                    text = voiceBaseText + sep + partial
                }
            }
        }
    }

    private var sendButtonColor: Color {
        if isLoading {
            return .red
        } else if text.isEmpty {
            return .secondary.opacity(0.3)
        } else {
            return .orange
        }
    }

    private func shortProviderName(_ name: String) -> String {
        switch name {
        case "Claude": return "Claude"
        case "GPT": return "GPT"
        case "Ollama": return "Local"
        case "MLX Local": return "MLX"
        default: return name
        }
    }
}

struct ToolbarButton: View {
    let icon: String
    let tooltip: String
    var tint: Color = .secondary
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(isHovering ? .primary : tint)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Linked App Indicator

struct LinkedAppIndicator: View {
    let linkedApp: AppLinkService.RunningApp?
    let isSelecting: Bool
    let onUnlink: () -> Void
    let onCancel: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Link icon with neon glow
            Image(systemName: isSelecting ? "link.badge.plus" : "link.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(isSelecting ? .neonPink : .neonCyan)
                .shadow(color: (isSelecting ? Color.neonPink : Color.neonCyan).opacity(0.6), radius: 4)

            if isSelecting {
                Text("Click any app to link...")
                    .font(.system(size: 11))
                    .foregroundColor(.neonPink)

                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            } else if let app = linkedApp {
                Text("Connected to:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                // App icon
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }

                Text(app.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.neonCyan)

                Spacer()

                Button(action: onUnlink) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(isHovering ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHovering = hovering
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    (isSelecting ? Color.neonPink : Color.neonCyan).opacity(0.5),
                                    (isSelecting ? Color.neonPink : Color.neonCyan).opacity(0.2)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 1
                        )
                )
        )
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

// MARK: - App Picker Popover

struct AppPickerPopover: View {
    let apps: [AppLinkService.RunningApp]
    let onSelect: (AppLinkService.RunningApp) -> Void
    let onStartSelection: () -> Void

    @State private var searchText = ""

    private var filteredApps: [AppLinkService.RunningApp] {
        if searchText.isEmpty {
            return apps
        }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "link")
                    .foregroundColor(.neonCyan)
                Text("Link to App")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search apps...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Click to select option
            Button(action: onStartSelection) {
                HStack {
                    Image(systemName: "cursorarrow.click.2")
                        .foregroundColor(.neonPink)
                    Text("Click to select window...")
                        .font(.system(size: 12))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.05))
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.vertical, 4)

            // App list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredApps) { app in
                        AppRowButton(app: app, onSelect: onSelect)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: 250)
        }
        .frame(width: 280)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct AppRowButton: View {
    let app: AppLinkService.RunningApp
    let onSelect: (AppLinkService.RunningApp) -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: { onSelect(app) }) {
            HStack(spacing: 10) {
                // App icon
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "app")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)

                    if let bundleId = app.bundleIdentifier {
                        Text(bundleId)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if app.isActive {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.neonCyan.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
