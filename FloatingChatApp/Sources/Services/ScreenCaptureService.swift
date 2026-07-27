import Foundation
import AppKit
import ScreenCaptureKit

/// Service for capturing screen content and detecting active context
@MainActor
final class ScreenCaptureService: ObservableObject {
    static let shared = ScreenCaptureService()

    @Published var isCapturing = false
    @Published var lastCapturedImage: NSImage?
    @Published var currentActiveApp: ActiveContext?

    private init() {}

    // MARK: - Screen Capture

    /// Capture the entire screen
    func captureScreen() async -> Data? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }

        // Use CGWindowListCreateImage for full screen capture
        guard let displayID = CGMainDisplayID() as CGDirectDisplayID?,
              let image = CGDisplayCreateImage(displayID) else {
            return nil
        }

        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        lastCapturedImage = nsImage

        return nsImage.pngData()
    }

    /// Capture a specific window
    func captureWindow(windowNumber: CGWindowID) async -> Data? {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowNumber,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            return nil
        }

        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        lastCapturedImage = nsImage

        return nsImage.pngData()
    }

    /// Capture area under mouse cursor
    func captureAreaAroundCursor(size: CGFloat = 400) async -> Data? {
        let mouseLocation = NSEvent.mouseLocation
        let screens = NSScreen.screens

        guard let screen = screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) else {
            return nil
        }

        // Convert to screen coordinates (flip Y)
        let screenHeight = screen.frame.height
        let flippedY = screenHeight - mouseLocation.y

        let captureRect = CGRect(
            x: mouseLocation.x - size/2,
            y: flippedY - size/2,
            width: size,
            height: size
        )

        guard let image = CGWindowListCreateImage(
            captureRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            return nil
        }

        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        lastCapturedImage = nsImage

        return nsImage.pngData()
    }

    // MARK: - Active Context Detection

    /// Get info about the currently active application
    func getCurrentApplication() -> ActiveContext? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let bundleID = frontmostApp.bundleIdentifier ?? "unknown"
        let appName = frontmostApp.localizedName ?? "Unknown App"

        var metadata: [String: String] = [:]

        // Try to get window title
        if let windowInfo = getActiveWindowInfo(for: frontmostApp) {
            metadata["windowTitle"] = windowInfo.title
            if let path = windowInfo.documentPath {
                metadata["documentPath"] = path
            }
        }

        let context = ActiveContext(
            type: .application,
            name: appName,
            identifier: bundleID,
            metadata: metadata
        )

        currentActiveApp = context
        return context
    }

    /// Get information about the window at a specific point
    func getWindowAtPoint(_ point: NSPoint) -> (app: NSRunningApplication?, windowInfo: WindowInfo?)? {
        // Get all windows
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Convert point (AppKit origin bottom-left to CG origin top-left)
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let cgPoint = CGPoint(x: point.x, y: screenHeight - point.y)

        for window in windowList {
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let width = boundsDict["Width"] as? CGFloat,
                  let height = boundsDict["Height"] as? CGFloat else {
                continue
            }

            let bounds = CGRect(x: x, y: y, width: width, height: height)

            if bounds.contains(cgPoint) {
                let pid = window[kCGWindowOwnerPID as String] as? Int32 ?? 0
                let app = NSRunningApplication(processIdentifier: pid)

                var info = WindowInfo(
                    windowNumber: window[kCGWindowNumber as String] as? Int ?? 0,
                    title: window[kCGWindowName as String] as? String ?? "",
                    ownerName: window[kCGWindowOwnerName as String] as? String ?? "",
                    bounds: bounds,
                    documentPath: nil
                )

                // For certain apps, try to extract document path from title
                if let title = window[kCGWindowName as String] as? String {
                    info.documentPath = extractDocumentPath(from: title, appName: info.ownerName)
                }

                return (app, info)
            }
        }

        return nil
    }

    /// Let user click to select a context target
    func startContextSelection(completion: @escaping (ActiveContext?) -> Void) {
        // Create a full-screen overlay window for selection
        let selectionWindow = ContextSelectionWindow { [weak self] point in
            guard let self = self else {
                completion(nil)
                return
            }

            Task { @MainActor in
                let context = await self.captureContextAtPoint(point)
                completion(context)
            }
        }

        selectionWindow.show()
    }

    /// Capture context at a specific screen point
    func captureContextAtPoint(_ point: NSPoint) async -> ActiveContext? {
        guard let (app, windowInfo) = getWindowAtPoint(point) else {
            return nil
        }

        var contextType: ActiveContext.ContextType = .application
        var name = app?.localizedName ?? windowInfo?.ownerName ?? "Unknown"
        var identifier = app?.bundleIdentifier ?? ""
        var metadata: [String: String] = [:]

        if let windowInfo = windowInfo {
            metadata["windowTitle"] = windowInfo.title

            if let docPath = windowInfo.documentPath {
                metadata["documentPath"] = docPath
                contextType = .document
                name = (docPath as NSString).lastPathComponent
                identifier = docPath
            }

            // Capture the specific window
            if let screenData = await captureWindow(windowNumber: CGWindowID(windowInfo.windowNumber)) {
                return ActiveContext(
                    type: contextType,
                    name: name,
                    identifier: identifier,
                    metadata: metadata,
                    screenData: screenData
                )
            }
        }

        return ActiveContext(
            type: contextType,
            name: name,
            identifier: identifier,
            metadata: metadata
        )
    }

    // MARK: - Helpers

    private func getActiveWindowInfo(for app: NSRunningApplication) -> WindowInfo? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == app.processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0 else {  // Normal window layer
                continue
            }

            return WindowInfo(
                windowNumber: window[kCGWindowNumber as String] as? Int ?? 0,
                title: window[kCGWindowName as String] as? String ?? "",
                ownerName: window[kCGWindowOwnerName as String] as? String ?? "",
                bounds: .zero,
                documentPath: extractDocumentPath(
                    from: window[kCGWindowName as String] as? String ?? "",
                    appName: app.localizedName ?? ""
                )
            )
        }

        return nil
    }

    private func extractDocumentPath(from title: String, appName: String) -> String? {
        // Many apps show document path in title
        // Try to extract it

        // Check if title looks like a file path
        if title.hasPrefix("/") || title.hasPrefix("~") {
            return title
        }

        // Check for common patterns like "filename - AppName"
        let patterns = [
            " - \(appName)",
            " — \(appName)",
            " | \(appName)"
        ]

        for pattern in patterns {
            if title.range(of: pattern) != nil {
                // Found pattern but we only have filename, not full path
                return nil
            }
        }

        return nil
    }

    struct WindowInfo {
        let windowNumber: Int
        let title: String
        let ownerName: String
        let bounds: CGRect
        var documentPath: String?
    }
}

// MARK: - Context Selection Window

class ContextSelectionWindow: NSPanel {
    private var onSelection: ((NSPoint) -> Void)?
    private var trackingArea: NSTrackingArea?

    init(onSelection: @escaping (NSPoint) -> Void) {
        self.onSelection = onSelection

        super.init(
            contentRect: NSScreen.main?.frame ?? .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = NSColor.black.withAlphaComponent(0.3)
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let contentView = SelectionContentView(onSelection: { [weak self] point in
            self?.onSelection?(point)
            self?.close()
        })

        self.contentView = contentView
    }

    func show() {
        // Cover all screens
        if let screen = NSScreen.main {
            self.setFrame(screen.frame, display: true)
        }
        self.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.push()
    }

    override func close() {
        NSCursor.pop()
        super.close()
    }
}

class SelectionContentView: NSView {
    private var onSelection: ((NSPoint) -> Void)?
    private var currentHoverWindow: CGRect?

    init(onSelection: @escaping (NSPoint) -> Void) {
        self.onSelection = onSelection
        super.init(frame: .zero)

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw semi-transparent overlay
        NSColor.black.withAlphaComponent(0.2).setFill()
        dirtyRect.fill()

        // Highlight hovered window
        if let windowRect = currentHoverWindow {
            NSColor.systemBlue.withAlphaComponent(0.3).setFill()
            NSBezierPath(rect: windowRect).fill()

            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: windowRect)
            path.lineWidth = 3
            path.stroke()
        }

        // Draw instruction text
        let text = "Click on any window or object to connect it as context"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor.white
        ]

        let size = text.size(withAttributes: attrs)
        let point = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: bounds.height - 60
        )
        text.draw(at: point, withAttributes: attrs)

        // Draw cancel hint
        let cancelText = "Press Escape to cancel"
        let cancelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7)
        ]
        let cancelSize = cancelText.size(withAttributes: cancelAttrs)
        let cancelPoint = NSPoint(
            x: (bounds.width - cancelSize.width) / 2,
            y: bounds.height - 90
        )
        cancelText.draw(at: cancelPoint, withAttributes: cancelAttrs)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = event.locationInWindow

        // Find window under cursor and highlight it
        Task { @MainActor in
            if let result = ScreenCaptureService.shared.getWindowAtPoint(point),
               let windowInfo = result.windowInfo {
                // Convert window bounds to our coordinate system
                let screenHeight = NSScreen.main?.frame.height ?? 0
                var rect = windowInfo.bounds
                rect.origin.y = screenHeight - rect.origin.y - rect.height
                self.currentHoverWindow = rect
            } else {
                self.currentHoverWindow = nil
            }
            self.needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = event.locationInWindow
        onSelection?(point)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Escape key
            window?.close()
        }
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - NSImage Extension

extension NSImage {
    func pngData() -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    func jpegData(compressionQuality: CGFloat = 0.8) -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
