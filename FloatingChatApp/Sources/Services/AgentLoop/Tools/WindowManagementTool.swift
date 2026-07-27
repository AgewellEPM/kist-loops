import Foundation
import Cocoa
import ApplicationServices
import os

private let logger = Logger(subsystem: "com.floatingchat.app", category: "WindowManagement")

/// Tool to manage windows: move, resize, tile, minimize, maximize
/// Requires Accessibility permission in System Settings
final class WindowManagementTool: AgentTool {
    let name = "window_management"
    let description = """
        Manage application windows: move, resize, tile, minimize, maximize.
        Can tile windows to left/right half, maximize, or move to specific positions.
        Requires Accessibility permission in System Settings > Privacy & Security > Accessibility.
        """
    let parameters = [
        ToolParameter(name: "action", type: "string", description: "Action: 'tile_left', 'tile_right', 'maximize', 'minimize', 'restore', 'move', 'resize', 'list', 'focus'", required: true),
        ToolParameter(name: "app", type: "string", description: "Application name (e.g., 'Safari', 'Terminal'). Required for most actions.", required: false),
        ToolParameter(name: "x", type: "number", description: "X position for move action", required: false),
        ToolParameter(name: "y", type: "number", description: "Y position for move action", required: false),
        ToolParameter(name: "width", type: "number", description: "Width for resize action", required: false),
        ToolParameter(name: "height", type: "number", description: "Height for resize action", required: false)
    ]

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        // Check accessibility permission
        guard AXIsProcessTrusted() else {
            return ToolResult(
                success: false,
                output: "",
                error: "Accessibility permission required. Please enable in System Settings > Privacy & Security > Accessibility"
            )
        }

        guard let action = arguments["action"] as? String else {
            return ToolResult(success: false, output: "", error: "Missing required parameter: action")
        }

        let appName = arguments["app"] as? String

        switch action.lowercased() {
        case "list":
            return listWindows()

        case "focus":
            guard let app = appName else {
                return ToolResult(success: false, output: "", error: "Missing 'app' parameter")
            }
            return focusApp(name: app)

        case "tile_left":
            guard let app = appName else {
                return ToolResult(success: false, output: "", error: "Missing 'app' parameter")
            }
            return tileWindow(appName: app, position: .left)

        case "tile_right":
            guard let app = appName else {
                return ToolResult(success: false, output: "", error: "Missing 'app' parameter")
            }
            return tileWindow(appName: app, position: .right)

        case "maximize":
            guard let app = appName else {
                return ToolResult(success: false, output: "", error: "Missing 'app' parameter")
            }
            return maximizeWindow(appName: app)

        case "minimize":
            guard let app = appName else {
                return ToolResult(success: false, output: "", error: "Missing 'app' parameter")
            }
            return minimizeWindow(appName: app)

        case "move":
            guard let app = appName else {
                return ToolResult(success: false, output: "", error: "Missing 'app' parameter")
            }
            let x = arguments["x"] as? CGFloat ?? 0
            let y = arguments["y"] as? CGFloat ?? 0
            return moveWindow(appName: app, to: CGPoint(x: x, y: y))

        case "resize":
            guard let app = appName else {
                return ToolResult(success: false, output: "", error: "Missing 'app' parameter")
            }
            guard let width = arguments["width"] as? CGFloat,
                  let height = arguments["height"] as? CGFloat else {
                return ToolResult(success: false, output: "", error: "Missing 'width' and 'height' parameters")
            }
            return resizeWindow(appName: app, to: CGSize(width: width, height: height))

        default:
            return ToolResult(success: false, output: "", error: "Unknown action: \(action)")
        }
    }

    // MARK: - Window Operations

    private enum TilePosition {
        case left, right
    }

    private func listWindows() -> ToolResult {
        var windowInfo: [String] = []

        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }

        for app in apps {
            guard let appName = app.localizedName else { continue }
            let pid = app.processIdentifier

            if let appElement = AXUIElementCreateApplication(pid) as AXUIElement? {
                var windowsRef: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

                if result == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty {
                    for (index, window) in windows.enumerated() {
                        var titleRef: CFTypeRef?
                        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                        let title = (titleRef as? String) ?? "Untitled"

                        var posRef: CFTypeRef?
                        var sizeRef: CFTypeRef?
                        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
                        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)

                        var pos = CGPoint.zero
                        var size = CGSize.zero
                        if let posValue = posRef {
                            AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
                        }
                        if let sizeValue = sizeRef {
                            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                        }

                        windowInfo.append("• \(appName) - \(title) (\(Int(size.width))x\(Int(size.height)) at \(Int(pos.x)),\(Int(pos.y)))")
                    }
                }
            }
        }

        if windowInfo.isEmpty {
            return ToolResult(success: true, output: "No visible windows found", metadata: nil)
        }

        return ToolResult(
            success: true,
            output: "Open windows:\n" + windowInfo.joined(separator: "\n"),
            metadata: ["count": String(windowInfo.count)]
        )
    }

    private func focusApp(name: String) -> ToolResult {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName?.lowercased().contains(name.lowercased()) == true
        }

        guard let app = apps.first else {
            return ToolResult(success: false, output: "", error: "Application '\(name)' not found or not running")
        }

        app.activate(options: [.activateIgnoringOtherApps])
        return ToolResult(success: true, output: "Focused \(app.localizedName ?? name)", metadata: nil)
    }

    private func tileWindow(appName: String, position: TilePosition) -> ToolResult {
        guard let screen = NSScreen.main else {
            return ToolResult(success: false, output: "", error: "Could not get screen information")
        }

        let frame = screen.visibleFrame
        let halfWidth = frame.width / 2

        let targetFrame: CGRect
        switch position {
        case .left:
            targetFrame = CGRect(x: frame.origin.x, y: frame.origin.y, width: halfWidth, height: frame.height)
        case .right:
            targetFrame = CGRect(x: frame.origin.x + halfWidth, y: frame.origin.y, width: halfWidth, height: frame.height)
        }

        return setWindowFrame(appName: appName, frame: targetFrame, action: "Tiled \(position == .left ? "left" : "right")")
    }

    private func maximizeWindow(appName: String) -> ToolResult {
        guard let screen = NSScreen.main else {
            return ToolResult(success: false, output: "", error: "Could not get screen information")
        }

        return setWindowFrame(appName: appName, frame: screen.visibleFrame, action: "Maximized")
    }

    private func minimizeWindow(appName: String) -> ToolResult {
        guard let window = getFrontWindow(appName: appName) else {
            return ToolResult(success: false, output: "", error: "Could not find window for \(appName)")
        }

        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
        return ToolResult(success: true, output: "Minimized \(appName)", metadata: nil)
    }

    private func moveWindow(appName: String, to point: CGPoint) -> ToolResult {
        guard let window = getFrontWindow(appName: appName) else {
            return ToolResult(success: false, output: "", error: "Could not find window for \(appName)")
        }

        var position = point
        let positionValue = AXValueCreate(.cgPoint, &position)!
        let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)

        if result == .success {
            return ToolResult(success: true, output: "Moved \(appName) to (\(Int(point.x)), \(Int(point.y)))", metadata: nil)
        } else {
            return ToolResult(success: false, output: "", error: "Failed to move window")
        }
    }

    private func resizeWindow(appName: String, to size: CGSize) -> ToolResult {
        guard let window = getFrontWindow(appName: appName) else {
            return ToolResult(success: false, output: "", error: "Could not find window for \(appName)")
        }

        var newSize = size
        let sizeValue = AXValueCreate(.cgSize, &newSize)!
        let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)

        if result == .success {
            return ToolResult(success: true, output: "Resized \(appName) to \(Int(size.width))x\(Int(size.height))", metadata: nil)
        } else {
            return ToolResult(success: false, output: "", error: "Failed to resize window")
        }
    }

    private func setWindowFrame(appName: String, frame: CGRect, action: String) -> ToolResult {
        guard let window = getFrontWindow(appName: appName) else {
            return ToolResult(success: false, output: "", error: "Could not find window for \(appName)")
        }

        // Set position
        var position = frame.origin
        let positionValue = AXValueCreate(.cgPoint, &position)!
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)

        // Set size
        var size = frame.size
        let sizeValue = AXValueCreate(.cgSize, &size)!
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)

        return ToolResult(success: true, output: "\(action) \(appName)", metadata: nil)
    }

    private func getFrontWindow(appName: String) -> AXUIElement? {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName?.lowercased().contains(appName.lowercased()) == true
        }

        guard let app = apps.first else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var windowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)

        if result == .success, let window = windowRef {
            return (window as! AXUIElement)
        }

        // Fallback to first window
        var windowsRef: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        if windowsResult == .success, let windows = windowsRef as? [AXUIElement], let firstWindow = windows.first {
            return firstWindow
        }

        return nil
    }
}
