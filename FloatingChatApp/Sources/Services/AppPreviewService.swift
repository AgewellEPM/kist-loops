import Foundation
import AppKit
import Combine
import SwiftUI
import os

private let logger = Logger(subsystem: "com.floatingchat.app", category: "AppPreview")

/// Service for live preview of apps being built/modified by the agent
/// Similar to Android Studio emulator view - watch the app as it's being worked on
@MainActor
final class AppPreviewService: ObservableObject {
    static let shared = AppPreviewService()

    // MARK: - Published State

    @Published var currentFrame: NSImage?
    @Published var isCapturing = false
    @Published var targetApp: TargetApp?
    @Published var lastInteraction: AppInteraction?
    @Published var captureHistory: [CapturedFrame] = []

    // MARK: - Configuration

    private var captureTimer: Timer?
    private let captureInterval: TimeInterval = 0.1 // 10 FPS
    private let maxHistoryFrames = 50

    struct TargetApp: Identifiable {
        let id: pid_t
        let name: String
        let bundleIdentifier: String?
        var windowID: CGWindowID?
    }

    struct CapturedFrame: Identifiable {
        let id = UUID()
        let image: NSImage
        let timestamp: Date
        let interaction: AppInteraction?
    }

    struct AppInteraction {
        let type: InteractionType
        let description: String
        let timestamp: Date

        enum InteractionType {
            case click
            case typing
            case toolUse(String)
            case fileWrite(String)
            case build
            case success
            case error
        }
    }

    private init() {}

    // MARK: - Public API

    /// Start capturing a specific app by name or bundle ID
    func startCapturing(appName: String? = nil, bundleID: String? = nil) {
        // Find the running app
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications

        var targetProcess: NSRunningApplication?

        if let bundleID = bundleID {
            targetProcess = apps.first { $0.bundleIdentifier == bundleID }
        } else if let appName = appName {
            targetProcess = apps.first {
                $0.localizedName?.lowercased().contains(appName.lowercased()) == true
            }
        }

        guard let app = targetProcess else {
            logger.warning("Target app not found")
            return
        }

        // Find the main window
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let appWindows = windowList.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
        }

        let mainWindow = appWindows.first {
            let layer = $0[kCGWindowLayer as String] as? Int ?? 0
            return layer == 0 // Normal window layer
        }

        let windowID = mainWindow?[kCGWindowNumber as String] as? CGWindowID

        targetApp = TargetApp(
            id: app.processIdentifier,
            name: app.localizedName ?? "Unknown",
            bundleIdentifier: app.bundleIdentifier,
            windowID: windowID
        )

        isCapturing = true
        startCaptureTimer()

        logger.info("Started capturing \(self.targetApp?.name ?? "unknown", privacy: .public)")
    }

    /// Start capturing Xcode (common use case)
    func startCapturingXcode() {
        startCapturing(bundleID: "com.apple.dt.Xcode")
    }

    /// Start capturing the most recently launched app
    func startCapturingRecentApp() {
        let workspace = NSWorkspace.shared
        if let frontApp = workspace.frontmostApplication,
           frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            startCapturing(bundleID: frontApp.bundleIdentifier)
        }
    }

    /// Stop capturing
    func stopCapturing() {
        captureTimer?.invalidate()
        captureTimer = nil
        isCapturing = false
        logger.info("Stopped capturing")
    }

    /// Record an interaction (called by AgentLoopEngine when tools are used)
    func recordInteraction(_ type: AppInteraction.InteractionType, description: String) {
        let interaction = AppInteraction(
            type: type,
            description: description,
            timestamp: Date()
        )
        lastInteraction = interaction

        // Capture a frame with this interaction
        if let frame = captureCurrentFrame() {
            let captured = CapturedFrame(
                image: frame,
                timestamp: Date(),
                interaction: interaction
            )
            captureHistory.append(captured)

            // Limit history size
            if captureHistory.count > maxHistoryFrames {
                captureHistory.removeFirst()
            }
        }
    }

    /// Take a single screenshot
    func captureCurrentFrame() -> NSImage? {
        guard let target = targetApp else { return nil }

        // Try to capture the specific window first
        if let windowID = target.windowID {
            if let cgImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                [.boundsIgnoreFraming, .nominalResolution]
            ) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }

        // Fallback: capture all windows of the app
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let appWindows = windowList.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == target.id
        }

        if let firstWindow = appWindows.first,
           let windowID = firstWindow[kCGWindowNumber as String] as? CGWindowID {
            if let cgImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                [.boundsIgnoreFraming, .nominalResolution]
            ) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }

        return nil
    }

    // MARK: - Private Methods

    private func startCaptureTimer() {
        captureTimer?.invalidate()
        captureTimer = Timer.scheduledTimer(withTimeInterval: captureInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateFrame()
            }
        }
    }

    private func updateFrame() {
        if let frame = captureCurrentFrame() {
            currentFrame = frame
        }
    }
}

// MARK: - Preview Window View

struct AppPreviewView: View {
    @ObservedObject var previewService: AppPreviewService
    @ObservedObject var agentEngine: AgentLoopEngine

    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Circle()
                    .fill(previewService.isCapturing ? Color.green : Color.red)
                    .frame(width: 8, height: 8)

                if let app = previewService.targetApp {
                    Text(app.name)
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Text("No app selected")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Controls
                if previewService.isCapturing {
                    Button(action: { previewService.stopCapturing() }) {
                        Image(systemName: "stop.circle.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                } else {
                    Menu {
                        Button("Capture Xcode") {
                            previewService.startCapturingXcode()
                        }
                        Button("Capture Front App") {
                            previewService.startCapturingRecentApp()
                        }
                    } label: {
                        Image(systemName: "record.circle")
                            .foregroundColor(.neonCyan)
                    }
                    .menuStyle(.borderlessButton)
                }

                Button(action: { showHistory.toggle() }) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(showHistory ? .neonPink : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.3))

            // Preview content
            if showHistory {
                historyView
            } else {
                livePreviewView
            }
        }
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.neonCyan.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var livePreviewView: some View {
        ZStack {
            // Screen capture
            if let frame = previewService.currentFrame {
                Image(nsImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                // Placeholder - compact and centered
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.2))
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "tv")
                                .font(.system(size: 24))
                                .foregroundColor(.secondary.opacity(0.6))
                            Text("No preview available")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                    )
            }

            // Interaction overlay
            if let interaction = previewService.lastInteraction {
                VStack {
                    Spacer()
                    interactionBanner(interaction)
                }
            }
        }
        .padding(6)
    }

    @ViewBuilder
    private var historyView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(previewService.captureHistory.reversed()) { frame in
                    VStack(spacing: 4) {
                        Image(nsImage: frame.image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.neonCyan.opacity(0.3), lineWidth: 1)
                            )

                        if let interaction = frame.interaction {
                            Text(interaction.description)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(8)
        }
        .frame(height: 160)
    }

    @ViewBuilder
    private func interactionBanner(_ interaction: AppPreviewService.AppInteraction) -> some View {
        HStack(spacing: 8) {
            interactionIcon(interaction.type)
                .font(.system(size: 12))
                .foregroundColor(interactionColor(interaction.type))

            Text(interaction.description)
                .font(.system(size: 11))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer()

            Text(interaction.timestamp, style: .time)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(interactionColor(interaction.type).opacity(0.5), lineWidth: 1)
                )
        )
        .padding(8)
    }

    private func interactionIcon(_ type: AppPreviewService.AppInteraction.InteractionType) -> Image {
        switch type {
        case .click: return Image(systemName: "hand.tap")
        case .typing: return Image(systemName: "keyboard")
        case .toolUse: return Image(systemName: "wrench.and.screwdriver")
        case .fileWrite: return Image(systemName: "doc.badge.plus")
        case .build: return Image(systemName: "hammer")
        case .success: return Image(systemName: "checkmark.circle")
        case .error: return Image(systemName: "exclamationmark.triangle")
        }
    }

    private func interactionColor(_ type: AppPreviewService.AppInteraction.InteractionType) -> Color {
        switch type {
        case .click: return .neonPink
        case .typing: return .neonCyan
        case .toolUse: return .neonPurple
        case .fileWrite: return .neonGreen
        case .build: return .neonOrange
        case .success: return .green
        case .error: return .red
        }
    }
}
