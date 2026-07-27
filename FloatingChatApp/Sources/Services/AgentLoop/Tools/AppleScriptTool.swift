import Foundation
import os

private let logger = Logger(subsystem: "com.floatingchat.app", category: "AppleScript")

/// Tool to execute AppleScript for controlling any Mac application
/// Enables automation of Music, Mail, Calendar, Finder, Safari, and more
final class AppleScriptTool: AgentTool {
    let name = "applescript"
    let description = """
        Execute AppleScript to control any Mac application. Can automate:
        - Music: play/pause, skip tracks, get now playing
        - Mail: send emails, read inbox
        - Calendar: create events, check schedule
        - Finder: open folders, get selected files
        - Safari/Chrome: open URLs, get current page
        - System: notifications, dialogs, volume control
        Use 'script' parameter for raw AppleScript, or use 'command' for common presets.
        """
    let parameters = [
        ToolParameter(name: "script", type: "string", description: "Raw AppleScript code to execute. Use this for custom automation.", required: false),
        ToolParameter(name: "command", type: "string", description: "Preset command: 'music_play', 'music_pause', 'music_next', 'music_previous', 'music_now_playing', 'volume_get', 'volume_set', 'open_url', 'notification'", required: false),
        ToolParameter(name: "value", type: "string", description: "Value for commands that need it (e.g., volume level 0-100, URL to open, notification message)", required: false),
        ToolParameter(name: "title", type: "string", description: "Title for notifications", required: false)
    ]

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        // If raw script provided, execute it
        if let script = arguments["script"] as? String {
            return executeScript(script)
        }

        // Otherwise use preset commands
        guard let command = arguments["command"] as? String else {
            return ToolResult(success: false, output: "", error: "Either 'script' or 'command' parameter is required")
        }

        let value = arguments["value"] as? String
        let title = arguments["title"] as? String

        let script = buildScript(for: command, value: value, title: title)

        guard !script.isEmpty else {
            return ToolResult(success: false, output: "", error: "Unknown command: \(command)")
        }

        return executeScript(script)
    }

    // MARK: - Script Execution

    private func executeScript(_ source: String) -> ToolResult {
        var error: NSDictionary?

        guard let appleScript = NSAppleScript(source: source) else {
            logger.error("Failed to create AppleScript from source")
            return ToolResult(success: false, output: "", error: "Failed to create AppleScript")
        }

        let result = appleScript.executeAndReturnError(&error)

        if let error = error {
            let errorMessage = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            let errorNumber = error[NSAppleScript.errorNumber] as? Int ?? -1
            logger.error("AppleScript error: \(errorMessage) (\(errorNumber))")
            return ToolResult(success: false, output: "", error: "AppleScript error: \(errorMessage)")
        }

        let output = result.stringValue ?? "Script executed successfully"
        logger.info("AppleScript executed: \(output.prefix(100))")

        return ToolResult(success: true, output: output, metadata: nil)
    }

    // MARK: - Preset Commands

    private func buildScript(for command: String, value: String?, title: String?) -> String {
        switch command.lowercased() {

        // MARK: Music Control
        case "music_play":
            return "tell application \"Music\" to play"

        case "music_pause":
            return "tell application \"Music\" to pause"

        case "music_playpause", "music_toggle":
            return "tell application \"Music\" to playpause"

        case "music_next":
            return "tell application \"Music\" to next track"

        case "music_previous":
            return "tell application \"Music\" to previous track"

        case "music_now_playing":
            return """
            tell application "Music"
                if player state is playing then
                    set trackName to name of current track
                    set artistName to artist of current track
                    set albumName to album of current track
                    return "Now Playing: " & trackName & " by " & artistName & " from " & albumName
                else
                    return "Music is not playing"
                end if
            end tell
            """

        case "music_search":
            guard let query = value else { return "" }
            return """
            tell application "Music"
                set searchResults to search playlist "Library" for "\(query)"
                if (count of searchResults) > 0 then
                    play item 1 of searchResults
                    return "Playing: " & name of item 1 of searchResults
                else
                    return "No results found for: \(query)"
                end if
            end tell
            """

        // MARK: Volume Control
        case "volume_get":
            return "return output volume of (get volume settings)"

        case "volume_set":
            guard let level = value, let volume = Int(level) else { return "" }
            let clampedVolume = max(0, min(100, volume))
            return "set volume output volume \(clampedVolume)"

        case "volume_mute":
            return "set volume with output muted"

        case "volume_unmute":
            return "set volume without output muted"

        // MARK: Browser Control
        case "open_url":
            guard let url = value else { return "" }
            return """
            tell application "Safari"
                activate
                open location "\(url)"
            end tell
            return "Opened \(url) in Safari"
            """

        case "safari_current_url":
            return """
            tell application "Safari"
                return URL of front document
            end tell
            """

        case "safari_current_title":
            return """
            tell application "Safari"
                return name of front document
            end tell
            """

        // MARK: System
        case "notification":
            let message = value ?? "Notification"
            let notifTitle = title ?? "FloatingChat"
            return """
            display notification "\(message)" with title "\(notifTitle)"
            return "Notification sent"
            """

        case "dialog":
            guard let message = value else { return "" }
            let dialogTitle = title ?? "FloatingChat"
            return """
            display dialog "\(message)" with title "\(dialogTitle)"
            return "Dialog shown"
            """

        case "frontmost_app":
            return """
            tell application "System Events"
                return name of first application process whose frontmost is true
            end tell
            """

        // MARK: Finder
        case "finder_selection":
            return """
            tell application "Finder"
                set selectedItems to selection
                if (count of selectedItems) = 0 then
                    return "No items selected in Finder"
                else
                    set itemPaths to {}
                    repeat with i in selectedItems
                        set end of itemPaths to POSIX path of (i as alias)
                    end repeat
                    return itemPaths as string
                end if
            end tell
            """

        case "finder_open":
            guard let path = value else { return "" }
            return """
            tell application "Finder"
                activate
                open POSIX file "\(path)"
            end tell
            return "Opened \(path)"
            """

        // MARK: Calendar
        case "calendar_today":
            return """
            tell application "Calendar"
                set todayStart to current date
                set time of todayStart to 0
                set todayEnd to todayStart + (1 * days)
                set todayEvents to {}

                repeat with cal in calendars
                    set evts to (every event of cal whose start date ≥ todayStart and start date < todayEnd)
                    repeat with e in evts
                        set end of todayEvents to summary of e & " at " & time string of start date of e
                    end repeat
                end repeat

                if (count of todayEvents) = 0 then
                    return "No events today"
                else
                    return todayEvents as string
                end if
            end tell
            """

        case "calendar_create":
            guard let eventTitle = value else { return "" }
            return """
            tell application "Calendar"
                tell calendar "Home"
                    set newEvent to make new event with properties {summary:"\(eventTitle)", start date:current date, end date:(current date) + (1 * hours)}
                end tell
            end tell
            return "Created event: \(eventTitle)"
            """

        default:
            return ""
        }
    }
}
