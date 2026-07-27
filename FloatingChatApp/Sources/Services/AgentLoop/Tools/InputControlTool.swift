import Foundation
import CoreGraphics
import ApplicationServices
import os

private let logger = Logger(subsystem: "com.floatingchat.app", category: "InputControl")

/// Tool to control mouse and keyboard input
/// Requires Accessibility permission in System Settings
final class InputControlTool: AgentTool {
    let name = "input_control"
    let description = """
        Control mouse and keyboard input. Can click, move mouse, type text, and press keys.
        Requires Accessibility permission in System Settings > Privacy & Security > Accessibility.
        Use with caution - this directly controls input devices.
        """
    let parameters = [
        ToolParameter(name: "action", type: "string", description: "Action: 'click', 'double_click', 'right_click', 'move', 'drag', 'type', 'key', 'scroll'", required: true),
        ToolParameter(name: "x", type: "number", description: "X coordinate for mouse actions", required: false),
        ToolParameter(name: "y", type: "number", description: "Y coordinate for mouse actions", required: false),
        ToolParameter(name: "text", type: "string", description: "Text to type (for 'type' action)", required: false),
        ToolParameter(name: "key", type: "string", description: "Key to press (for 'key' action): 'return', 'tab', 'escape', 'space', 'delete', 'up', 'down', 'left', 'right', or single character", required: false),
        ToolParameter(name: "modifiers", type: "string", description: "Modifier keys (comma-separated): 'cmd', 'shift', 'alt', 'ctrl'. E.g., 'cmd,shift'", required: false),
        ToolParameter(name: "to_x", type: "number", description: "Target X coordinate for drag action", required: false),
        ToolParameter(name: "to_y", type: "number", description: "Target Y coordinate for drag action", required: false),
        ToolParameter(name: "scroll_amount", type: "number", description: "Scroll amount (positive = down, negative = up)", required: false)
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

        switch action.lowercased() {
        case "click":
            return performClick(arguments: arguments, button: .left, clickCount: 1)

        case "double_click":
            return performClick(arguments: arguments, button: .left, clickCount: 2)

        case "right_click":
            return performClick(arguments: arguments, button: .right, clickCount: 1)

        case "move":
            return moveMouse(arguments: arguments)

        case "drag":
            return performDrag(arguments: arguments)

        case "type":
            return typeText(arguments: arguments)

        case "key":
            return pressKey(arguments: arguments)

        case "scroll":
            return performScroll(arguments: arguments)

        case "get_position":
            let point = CGEvent(source: nil)?.location ?? .zero
            return ToolResult(
                success: true,
                output: "Mouse position: (\(Int(point.x)), \(Int(point.y)))",
                metadata: ["x": String(Int(point.x)), "y": String(Int(point.y))]
            )

        default:
            return ToolResult(success: false, output: "", error: "Unknown action: \(action)")
        }
    }

    // MARK: - Helpers

    /// Parse a CGFloat value from arguments - handles both CGFloat and Double
    private func parseCGFloat(_ value: Any?) -> CGFloat? {
        if let cgFloat = value as? CGFloat {
            return cgFloat
        }
        if let double = value as? Double {
            return CGFloat(double)
        }
        if let int = value as? Int {
            return CGFloat(int)
        }
        return nil
    }

    // MARK: - Mouse Actions

    private func performClick(arguments: [String: Any], button: CGMouseButton, clickCount: Int) -> ToolResult {
        guard let x = parseCGFloat(arguments["x"]),
              let y = parseCGFloat(arguments["y"]) else {
            return ToolResult(success: false, output: "", error: "Missing 'x' and 'y' parameters for click")
        }

        let point = CGPoint(x: x, y: y)

        let mouseDownType: CGEventType
        let mouseUpType: CGEventType

        switch button {
        case .left:
            mouseDownType = .leftMouseDown
            mouseUpType = .leftMouseUp
        case .right:
            mouseDownType = .rightMouseDown
            mouseUpType = .rightMouseUp
        default:
            mouseDownType = .leftMouseDown
            mouseUpType = .leftMouseUp
        }

        for _ in 0..<clickCount {
            let mouseDown = CGEvent(mouseEventSource: nil, mouseType: mouseDownType, mouseCursorPosition: point, mouseButton: button)
            let mouseUp = CGEvent(mouseEventSource: nil, mouseType: mouseUpType, mouseCursorPosition: point, mouseButton: button)

            mouseDown?.post(tap: CGEventTapLocation.cghidEventTap)
            usleep(50000) // Small delay between down and up
            mouseUp?.post(tap: CGEventTapLocation.cghidEventTap)

            if clickCount > 1 {
                usleep(100000) // Delay between clicks for double-click
            }
        }

        let clickType = clickCount > 1 ? "Double-clicked" : (button == .right ? "Right-clicked" : "Clicked")
        logger.info("\(clickType) at (\(Int(x)), \(Int(y)))")

        return ToolResult(
            success: true,
            output: "\(clickType) at (\(Int(x)), \(Int(y)))",
            metadata: ["x": String(Int(x)), "y": String(Int(y))]
        )
    }

    private func moveMouse(arguments: [String: Any]) -> ToolResult {
        guard let x = parseCGFloat(arguments["x"]),
              let y = parseCGFloat(arguments["y"]) else {
            return ToolResult(success: false, output: "", error: "Missing 'x' and 'y' parameters")
        }

        let point = CGPoint(x: x, y: y)
        let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        moveEvent?.post(tap: CGEventTapLocation.cghidEventTap)

        return ToolResult(
            success: true,
            output: "Moved mouse to (\(Int(x)), \(Int(y)))",
            metadata: nil
        )
    }

    private func performDrag(arguments: [String: Any]) -> ToolResult {
        guard let x = parseCGFloat(arguments["x"]),
              let y = parseCGFloat(arguments["y"]),
              let toX = parseCGFloat(arguments["to_x"]),
              let toY = parseCGFloat(arguments["to_y"]) else {
            return ToolResult(success: false, output: "", error: "Missing 'x', 'y', 'to_x', and 'to_y' parameters for drag")
        }

        let startPoint = CGPoint(x: x, y: y)
        let endPoint = CGPoint(x: toX, y: toY)

        // Mouse down at start
        let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: startPoint, mouseButton: .left)
        mouseDown?.post(tap: CGEventTapLocation.cghidEventTap)

        // Drag to end
        usleep(100000)
        let mouseDrag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: endPoint, mouseButton: .left)
        mouseDrag?.post(tap: CGEventTapLocation.cghidEventTap)

        // Mouse up at end
        usleep(100000)
        let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: endPoint, mouseButton: .left)
        mouseUp?.post(tap: CGEventTapLocation.cghidEventTap)

        return ToolResult(
            success: true,
            output: "Dragged from (\(Int(x)), \(Int(y))) to (\(Int(toX)), \(Int(toY)))",
            metadata: nil
        )
    }

    private func performScroll(arguments: [String: Any]) -> ToolResult {
        let amount = arguments["scroll_amount"] as? Int32 ?? 3

        let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)
        scrollEvent?.post(tap: CGEventTapLocation.cghidEventTap)

        let direction = amount > 0 ? "down" : "up"
        return ToolResult(
            success: true,
            output: "Scrolled \(direction) by \(abs(amount)) pixels",
            metadata: nil
        )
    }

    // MARK: - Keyboard Actions

    private func typeText(arguments: [String: Any]) -> ToolResult {
        guard let text = arguments["text"] as? String else {
            return ToolResult(success: false, output: "", error: "Missing 'text' parameter")
        }

        let source = CGEventSource(stateID: .hidSystemState)

        for char in text {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            var unicodeChar = Array(String(char).utf16)
            keyDown?.keyboardSetUnicodeString(stringLength: unicodeChar.count, unicodeString: &unicodeChar)
            keyDown?.post(tap: CGEventTapLocation.cghidEventTap)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            keyUp?.keyboardSetUnicodeString(stringLength: unicodeChar.count, unicodeString: &unicodeChar)
            keyUp?.post(tap: CGEventTapLocation.cghidEventTap)

            usleep(20000) // Small delay between keystrokes
        }

        logger.info("Typed \(text.count) characters")
        return ToolResult(
            success: true,
            output: "Typed: \(text.prefix(50))\(text.count > 50 ? "..." : "")",
            metadata: ["length": String(text.count)]
        )
    }

    private func pressKey(arguments: [String: Any]) -> ToolResult {
        guard let keyName = arguments["key"] as? String else {
            return ToolResult(success: false, output: "", error: "Missing 'key' parameter")
        }

        let modifiersStr = arguments["modifiers"] as? String ?? ""
        let modifiers = parseModifiers(modifiersStr)

        guard let keyCode = keyCodeForName(keyName) else {
            return ToolResult(success: false, output: "", error: "Unknown key: \(keyName)")
        }

        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = modifiers
        keyDown?.post(tap: CGEventTapLocation.cghidEventTap)

        usleep(50000)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = modifiers
        keyUp?.post(tap: CGEventTapLocation.cghidEventTap)

        var description = keyName
        if !modifiersStr.isEmpty {
            description = "\(modifiersStr)+\(keyName)"
        }

        return ToolResult(
            success: true,
            output: "Pressed key: \(description)",
            metadata: nil
        )
    }

    // MARK: - Modifier Parsing

    private func parseModifiers(_ str: String) -> CGEventFlags {
        var flags = CGEventFlags()

        let parts = str.lowercased().split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }

        for part in parts {
            switch part {
            case "cmd", "command":
                flags.insert(.maskCommand)
            case "shift":
                flags.insert(.maskShift)
            case "alt", "option":
                flags.insert(.maskAlternate)
            case "ctrl", "control":
                flags.insert(.maskControl)
            default:
                break
            }
        }

        return flags
    }

    private func keyCodeForName(_ name: String) -> CGKeyCode? {
        let lowerName = name.lowercased()

        // Special keys
        let specialKeys: [String: CGKeyCode] = [
            "return": 0x24, "enter": 0x24,
            "tab": 0x30,
            "space": 0x31,
            "delete": 0x33, "backspace": 0x33,
            "escape": 0x35, "esc": 0x35,
            "up": 0x7E,
            "down": 0x7D,
            "left": 0x7B,
            "right": 0x7C,
            "home": 0x73,
            "end": 0x77,
            "pageup": 0x74,
            "pagedown": 0x79,
            "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
            "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
            "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F
        ]

        if let code = specialKeys[lowerName] {
            return code
        }

        // Single character - use generic approach
        if name.count == 1 {
            // For simple letters/numbers, we use a basic mapping
            let charKeyCodes: [Character: CGKeyCode] = [
                "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
                "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
                "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
                "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
                "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E,
                "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25,
                "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2A, ",": 0x2B,
                "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32
            ]

            if let code = charKeyCodes[Character(lowerName)] {
                return code
            }
        }

        return nil
    }
}
