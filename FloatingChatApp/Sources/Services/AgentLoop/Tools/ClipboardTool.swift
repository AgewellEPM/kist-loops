import Foundation
import Cocoa

/// Tool to read, write, and manage clipboard content
final class ClipboardTool: AgentTool {
    let name = "clipboard"
    let description = "Read, write, and manage clipboard content. Use for copying text, reading what's on the clipboard, or clearing it."
    let parameters = [
        ToolParameter(name: "action", type: "string", description: "Action to perform: 'read' (get clipboard content), 'write' (set clipboard content), 'clear' (clear clipboard)", required: true),
        ToolParameter(name: "text", type: "string", description: "Text to copy to clipboard (required for 'write' action)", required: false)
    ]

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult(success: false, output: "", error: "Missing required parameter: action")
        }

        switch action.lowercased() {
        case "read":
            return readClipboard()

        case "write":
            guard let text = arguments["text"] as? String else {
                return ToolResult(success: false, output: "", error: "Missing required parameter 'text' for write action")
            }
            return writeClipboard(text)

        case "clear":
            return clearClipboard()

        default:
            return ToolResult(success: false, output: "", error: "Unknown action: \(action). Use 'read', 'write', or 'clear'")
        }
    }

    // MARK: - Private Methods

    private func readClipboard() -> ToolResult {
        let pasteboard = NSPasteboard.general

        // Try to get string content
        if let content = pasteboard.string(forType: .string) {
            let preview = content.count > 500 ? String(content.prefix(500)) + "... (truncated)" : content
            return ToolResult(
                success: true,
                output: preview,
                metadata: [
                    "type": "text",
                    "length": String(content.count)
                ]
            )
        }

        // Check for other content types
        let types = pasteboard.types ?? []

        if types.contains(.fileURL) {
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
                let paths = urls.map { $0.path }.joined(separator: "\n")
                return ToolResult(
                    success: true,
                    output: "File URLs on clipboard:\n\(paths)",
                    metadata: [
                        "type": "files",
                        "count": String(urls.count)
                    ]
                )
            }
        }

        if types.contains(.tiff) || types.contains(.png) {
            return ToolResult(
                success: true,
                output: "Image data on clipboard",
                metadata: ["type": "image"]
            )
        }

        if types.isEmpty {
            return ToolResult(
                success: true,
                output: "Clipboard is empty",
                metadata: ["type": "empty"]
            )
        }

        return ToolResult(
            success: true,
            output: "Clipboard contains non-text data. Types: \(types.map { $0.rawValue }.joined(separator: ", "))",
            metadata: ["type": "other"]
        )
    }

    private func writeClipboard(_ text: String) -> ToolResult {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let success = pasteboard.setString(text, forType: .string)

        if success {
            return ToolResult(
                success: true,
                output: "Copied to clipboard: \(text.prefix(100))\(text.count > 100 ? "..." : "")",
                metadata: ["length": String(text.count)]
            )
        } else {
            return ToolResult(success: false, output: "", error: "Failed to write to clipboard")
        }
    }

    private func clearClipboard() -> ToolResult {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        return ToolResult(
            success: true,
            output: "Clipboard cleared",
            metadata: nil
        )
    }
}
