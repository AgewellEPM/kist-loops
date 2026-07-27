import Foundation
import AppKit
import Combine

/// Service for linking/syncing to running applications
@MainActor
final class AppLinkService: ObservableObject {
    static let shared = AppLinkService()

    /// Currently linked app
    @Published var linkedApp: RunningApp?

    /// Whether we're in selection mode (waiting for user to click an app)
    @Published var isSelectingApp = false

    /// List of running apps (refreshed periodically)
    @Published var runningApps: [RunningApp] = []

    private var refreshTimer: Timer?
    private var eventMonitor: Any?

    struct RunningApp: Identifiable, Hashable {
        let id: pid_t
        let name: String
        let bundleIdentifier: String?
        let icon: NSImage?
        let isActive: Bool

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: RunningApp, rhs: RunningApp) -> Bool {
            lhs.id == rhs.id
        }
    }

    private init() {
        refreshRunningApps()
        startRefreshTimer()
    }

    deinit {
        refreshTimer?.invalidate()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Public API

    /// Start app selection mode - user will click on an app to link
    func startAppSelection() {
        isSelectingApp = true
        refreshRunningApps()

        // Add global click monitor
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            Task { @MainActor in
                self?.handleGlobalClick(event)
            }
        }
    }

    /// Cancel app selection mode
    func cancelSelection() {
        isSelectingApp = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    /// Link to a specific app
    func linkTo(_ app: RunningApp) {
        linkedApp = app
        isSelectingApp = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    /// Unlink from current app
    func unlink() {
        linkedApp = nil
    }

    /// Toggle link state
    func toggleLink() {
        if linkedApp != nil {
            unlink()
        } else {
            startAppSelection()
        }
    }

    /// Get context from linked app (file path, selected text, etc.)
    func getLinkedAppContext() -> String? {
        guard let app = linkedApp else { return nil }

        // Try to get context based on app type
        if let bundleId = app.bundleIdentifier {
            switch bundleId {
            case "com.apple.dt.Xcode":
                return getXcodeContext()
            case "com.apple.finder":
                return getFinderContext()
            case "com.apple.Terminal", "com.googlecode.iterm2":
                return getTerminalContext()
            default:
                return "Linked to: \(app.name)"
            }
        }

        return "Linked to: \(app.name)"
    }

    // MARK: - Private Methods

    private func refreshRunningApps() {
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications.filter { app in
            app.activationPolicy == .regular && app.localizedName != nil
        }

        let frontApp = workspace.frontmostApplication

        runningApps = apps.compactMap { app in
            guard let name = app.localizedName else { return nil }
            return RunningApp(
                id: app.processIdentifier,
                name: name,
                bundleIdentifier: app.bundleIdentifier,
                icon: app.icon,
                isActive: app.processIdentifier == frontApp?.processIdentifier
            )
        }.sorted { $0.name < $1.name }
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRunningApps()
            }
        }
    }

    private func handleGlobalClick(_ event: NSEvent) {
        guard isSelectingApp else { return }

        // Get the app under the mouse
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

            for windowInfo in windowList {
                guard let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                      let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t else {
                    continue
                }

                let windowRect = CGRect(
                    x: bounds["X"] ?? 0,
                    y: bounds["Y"] ?? 0,
                    width: bounds["Width"] ?? 0,
                    height: bounds["Height"] ?? 0
                )

                // Convert to screen coordinates
                let screenHeight = screen.frame.height
                let flippedY = screenHeight - mouseLocation.y
                let clickPoint = CGPoint(x: mouseLocation.x, y: flippedY)

                if windowRect.contains(clickPoint) {
                    if let app = runningApps.first(where: { $0.id == ownerPID }) {
                        linkTo(app)
                        return
                    }
                }
            }
        }

        // If we got here, cancel selection
        cancelSelection()
    }

    // MARK: - App-Specific Context

    private func getXcodeContext() -> String? {
        // Could use AppleScript to get current file path
        let script = """
        tell application "Xcode"
            if (count of documents) > 0 then
                set docPath to path of front document
                return docPath
            end if
        end tell
        """

        if let result = runAppleScript(script) {
            return "Xcode Project: \(result)"
        }
        return nil
    }

    private func getFinderContext() -> String? {
        let script = """
        tell application "Finder"
            if (count of windows) > 0 then
                set currentFolder to target of front window as text
                return POSIX path of currentFolder
            end if
        end tell
        """

        if let result = runAppleScript(script) {
            return "Finder Path: \(result)"
        }
        return nil
    }

    private func getTerminalContext() -> String? {
        // Terminal context is harder to get reliably
        return nil
    }

    private func runAppleScript(_ script: String) -> String? {
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let output = scriptObject.executeAndReturnError(&error)
            if error == nil {
                return output.stringValue
            }
        }
        return nil
    }
}
