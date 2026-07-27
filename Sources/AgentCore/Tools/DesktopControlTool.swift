import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import ApplicationServices
import UniformTypeIdentifiers
#endif

/// THE HANDS. Real input injection + screen capture so the agent can OPERATE a native GUI — not just
/// launch it (`computer_control`) or passively screenshot it (`live_screen_watch`). This is the primitive
/// that turns kist from a coding/research agent into a computer-USING one: move/click/drag the mouse,
/// type unicode text, press key chords, scroll, and capture the screen to reason over.
///
/// Coordinates are in SCREENSHOT PIXEL space (what the model reads off a `screenshot` action), converted
/// internally to the CoreGraphics point space that CGEvent expects using the display's real Retina scale,
/// and bounds-checked against the target display — so a click lands on the pixel the model saw and can
/// never be flung to a guessed off-screen point.
///
/// Multi-display aware via a 0-based `display` index. macOS only (CGEvent) — other platforms fail clearly.
/// Two permissions are checked up-front so we fail with an actionable
/// message instead of silently no-op'ing: Accessibility (`AXIsProcessTrusted`) for input, Screen Recording
/// (`CGPreflightScreenCaptureAccess`) for capture.
///
/// PROTOTYPE: the actuator is real and the pure logic (scaling, chord parsing, keycodes, modifier flags)
/// is unit-tested; the CGEvent side effects move the real cursor/keyboard and are verified manually, not
/// in CI. High blast radius — approval-gated by default; only unlocked deliberately.
public struct DesktopControlTool: AgentTool {
    public let name = "desktop_control"
    public var description: String {
        """
        Operate the native desktop: capture the screen and drive the real mouse and keyboard. Use \
        `screenshot` to see, then `click`/`type`/`key`/`move`/`drag`/`scroll` to act. Coordinates are in \
        the same pixel space as the screenshot you took. Typical loop: screenshot -> view_image(path) -> \
        decide -> click/type -> screenshot again. macOS only; pass `display` to target a non-main monitor. \
        Needs Accessibility + Screen Recording permission granted to this binary.
        """
    }

    public var parameters: [ToolParameter] {
        [
            ToolParameter(name: "action", type: "string", description: "One of: screenshot, screen_size, mouse_position, move, click, double_click, right_click, drag, type, key, scroll."),
            ToolParameter(name: "x", type: "integer", description: "Target X in screenshot pixels (move/click/drag start).", required: false),
            ToolParameter(name: "y", type: "integer", description: "Target Y in screenshot pixels.", required: false),
            ToolParameter(name: "to_x", type: "integer", description: "Drag end X in screenshot pixels.", required: false),
            ToolParameter(name: "to_y", type: "integer", description: "Drag end Y in screenshot pixels.", required: false),
            ToolParameter(name: "text", type: "string", description: "Text to type (action=type). Any unicode.", required: false),
            ToolParameter(name: "key", type: "string", description: "Key or chord (action=key), e.g. 'return', 'esc', 'up', 'cmd+s', 'shift+tab'.", required: false),
            ToolParameter(name: "button", type: "string", description: "Mouse button for click: 'left' (default) or 'right'.", required: false),
            ToolParameter(name: "dy", type: "integer", description: "Vertical scroll amount (action=scroll); positive scrolls content up, negative down.", required: false),
            ToolParameter(name: "dx", type: "integer", description: "Horizontal scroll amount (action=scroll).", required: false),
            ToolParameter(name: "out_dir", type: "string", description: "Project-relative folder for screenshots (default .kist/desktop).", required: false),
            ToolParameter(name: "display", type: "integer", description: "0-based display index to target (default the main display). Use screen_size to see how many are attached.", required: false),
        ]
    }

    public var supportedActions: [String] {
        ["screenshot", "screen_size", "mouse_position", "move", "click", "double_click", "right_click", "drag", "type", "key", "scroll"]
    }
    public var unsupportedActions: [String] { ["open_app", "launch", "run", "keypress_sequence", "record"] }
    public var capabilityNote: String? {
        "Does NOT launch apps (use computer_control) or run shell (use run_command). Coordinates are screenshot pixels on the target display; take a screenshot first and pass the same display index when acting."
    }
    public var usageExamples: [String] {
        ["{\"action\":\"screenshot\"}", "{\"action\":\"click\",\"x\":640,\"y\":400}", "{\"action\":\"type\",\"text\":\"hello\"}", "{\"action\":\"key\",\"key\":\"cmd+s\"}"]
    }

    public init() {}

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let action = (try requireString("action", from: arguments)).lowercased()
        guard supportedActions.contains(action) else {
            return .failure("unknown desktop_control action '\(action)'. Valid: \(supportedActions.joined(separator: ", "))")
        }
        #if canImport(CoreGraphics)
        return try runMacOS(action: action, arguments: arguments, context: context)
        #else
        return .failure("desktop_control requires macOS (CGEvent). This platform is unsupported.")
        #endif
    }

    // MARK: - Pure, testable helpers (no side effects)

    /// Convert a screenshot-pixel coordinate to a CoreGraphics point coordinate for a display whose
    /// origin is `origin` (points) and whose Retina scale is `scale` (pixels per point).
    static func pointFromPixel(px: Double, py: Double, origin: (x: Double, y: Double), scale: Double) -> (x: Double, y: Double) {
        let s = scale > 0 ? scale : 1
        return (origin.x + px / s, origin.y + py / s)
    }

    /// Parse a chord like "cmd+shift+s" into (modifier names, base key name). The last segment is the key.
    public static func parseChord(_ raw: String) -> (modifiers: [String], key: String) {
        let parts = raw.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let key = parts.last else { return ([], raw.lowercased()) }
        return (Array(parts.dropLast()), key)
    }

    /// Map a key name to a macOS virtual keycode. Returns nil for unknown names (caller fails clearly).
    public static func keyCode(for name: String) -> UInt16? { keyCodeTable[name.lowercased()] }

    /// Named keys + a-z/0-9. Modifiers are handled separately as event flags, not here.
    static let keyCodeTable: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "spacebar": 49,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    /// Raw CGEventFlags bitmask for a set of modifier names, or nil if ANY name is unknown — so a
    /// typo'd chord (`cmd+bogus+s`) fails loudly instead of silently firing the wrong command.
    public static func modifierFlags(_ mods: [String]) -> UInt64? {
        var raw: UInt64 = 0
        for m in mods {
            switch m {
            case "cmd", "command", "meta", "super": raw |= 0x100000   // maskCommand
            case "shift": raw |= 0x20000                              // maskShift
            case "opt", "option", "alt": raw |= 0x80000              // maskAlternate
            case "ctrl", "control": raw |= 0x40000                   // maskControl
            case "fn", "function": raw |= 0x800000                    // maskSecondaryFn
            default: return nil
            }
        }
        return raw
    }

    static let maxTypeLength = 5000

    /// Result of a one-shot pixel click on the main display (used by the combined `tap` primitive).
    /// Plain enum (no CoreGraphics) so cross-platform callers can pattern-match it.
    public enum ClickOutcome: Equatable, Sendable {
        case clicked(x: Int, y: Int)
        case outOfBounds(String)
        case notTrusted
        case failed(String)
    }
}

#if canImport(CoreGraphics)
extension DesktopControlTool {

    private static let inputActions: Set<String> = ["move", "click", "double_click", "right_click", "drag", "type", "key", "scroll"]

    func runMacOS(action: String, arguments: [String: Any], context: ToolContext) throws -> ToolResult {
        // Input injection needs Accessibility; fail with an actionable message instead of a silent no-op.
        if Self.inputActions.contains(action), !AXIsProcessTrusted() {
            return .failure("Accessibility permission not granted to this process. Grant it in System Settings → Privacy & Security → Accessibility, then retry.")
        }
        // Resolve the TARGET display (default main). `display` is a 0-based index into the attached
        // displays (see the screen_size action). Every coordinate below is that display's screenshot-pixel
        // space, converted to global points via DisplayGeometry — so this works on ANY monitor, not just main.
        let displays = DisplayGeometry.liveDisplays()
        let disp: DisplayInfo
        if let displayRaw = arguments["display"] {
            // An EXPLICIT display must be a valid WHOLE-number index — never silently retarget the main
            // monitor for a hardened input actuator (wrong-target risk; a fractional 0.5 must not truncate).
            guard let i = strictInt(displayRaw) else { return .failure("display must be a whole-number index.") }
            guard i >= 0, i < displays.count else { return .failure("display index \(i) is out of range — \(displays.count) display(s) attached (indices 0..\(max(0, displays.count - 1))).") }
            disp = displays[i]
        } else {
            guard let main = DisplayGeometry.main(displays) else { return .failure("no display detected.") }
            disp = main
        }
        let displayID = CGDirectDisplayID(disp.id)
        let pixelW = disp.pixelWidth, pixelH = disp.pixelHeight

        // The event source is only needed for INPUT actions — screenshot/geometry must not fail if it's nil.
        let src = CGEventSource(stateID: .combinedSessionState)

        enum Resolved { case ok(CGPoint), absent, outOfBounds(String) }
        func resolve(_ xKey: String, _ yKey: String) -> Resolved {
            guard let px = optionalInt(xKey, from: arguments), let py = optionalInt(yKey, from: arguments) else { return .absent }
            guard disp.containsLocalPixel(x: px, y: py) else {
                return .outOfBounds("(\(px),\(py)) is outside display \(disp.pixelWidth)x\(disp.pixelHeight) px. Take a screenshot of this display and use coordinates within it.")
            }
            let g = disp.localPixelToGlobalPoint(x: px, y: py)
            return .ok(CGPoint(x: g.x, y: g.y))
        }
        func ai(_ k: String) -> Int { optionalInt(k, from: arguments) ?? 0 }

        switch action {
        case "screen_size":
            let others = displays.count > 1 ? " \(displays.count) displays attached (use the 'display' index to target another)." : ""
            return ToolResult(success: true,
                              output: "display \(disp.id): \(pixelW)x\(pixelH) px (\(Int(disp.widthPt))x\(Int(disp.heightPt)) pt, scale \(disp.scale))\(disp.isMain ? " [main]" : "").\(others) Screenshot coordinates are in the pixel space.",
                              metadata: ["pixel_width": "\(pixelW)", "pixel_height": "\(pixelH)", "point_width": "\(Int(disp.widthPt))", "point_height": "\(Int(disp.heightPt))", "scale": "\(disp.scale)", "displays": "\(displays.count)", "is_main": "\(disp.isMain)"])

        case "mouse_position":
            guard let loc = CGEvent(source: nil)?.location else { return .failure("could not read the current cursor position") }
            // If the cursor isn't on the TARGET display, say so (its local pixels would be off-bounds).
            if !disp.containsGlobalPoint(x: Double(loc.x), y: Double(loc.y)) {
                let actual = DisplayGeometry.display(forGlobalPoint: Double(loc.x), y: Double(loc.y), in: displays)
                let where_ = actual.map { "display \($0.id)" } ?? "no display (dead space)"
                return ToolResult(success: true,
                                  output: "cursor is on \(where_), not target display \(disp.id) (global \(Int(loc.x)),\(Int(loc.y)) pt). Query that display's index for local coordinates.",
                                  metadata: ["on_target": "false"])
            }
            let (px, py) = disp.globalPointToLocalPixel(x: Double(loc.x), y: Double(loc.y))
            return ToolResult(success: true, output: "cursor at \(px),\(py) px on display \(disp.id) (\(Int(loc.x)),\(Int(loc.y)) global pt)",
                              metadata: ["x": "\(px)", "y": "\(py)", "on_target": "true"])

        case "screenshot":
            if !CGPreflightScreenCaptureAccess() {
                return .failure("Screen Recording permission not granted to this process. Grant it in System Settings → Privacy & Security → Screen Recording, then retry.")
            }
            guard let image = CGDisplayCreateImage(displayID) else {
                return .failure("screen capture returned nothing even though permission looks granted — retry, and confirm Screen Recording is enabled for this process.")
            }
            let outDirArg = (arguments["out_dir"] as? String) ?? ".kist/desktop"
            let outDir = try context.resolvedPath(outDirArg, mustExist: false)
            try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            // UUID suffix: distinct even for two captures in the same second (Codex: second-resolution clobber).
            let filename = "shot-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))-\(image.width)x\(image.height).png"
            let url = URL(fileURLWithPath: outDir).appendingPathComponent(filename)
            guard Self.writePNG(image, to: url) else {
                return .failure("failed to encode screenshot PNG at \(url.path)")
            }
            return ToolResult(success: true,
                              output: "screenshot saved: \(url.path) (\(image.width)x\(image.height) px). View it with view_image(path=\"\(url.path)\"), then act with click/type using pixel coordinates.",
                              metadata: ["path": url.path, "width": "\(image.width)", "height": "\(image.height)", "scale": "\(disp.scale)"])

        case "move":
            switch resolve("x", "y") {
            case .absent: return .failure("move needs x and y (screenshot pixels)")
            case .outOfBounds(let m): return .failure(m)
            case .ok(let p):
                guard let src, Self.post(.mouseMoved, src: src, at: p, button: .left) else { return .failure("could not synthesize move event") }
                return ToolResult(success: true, output: "moved cursor to \(ai("x")),\(ai("y")) px")
            }

        case "click", "double_click", "right_click":
            switch resolve("x", "y") {
            case .absent: return .failure("\(action) needs x and y (screenshot pixels) — take a screenshot first to find them")
            case .outOfBounds(let m): return .failure(m)
            case .ok(let p):
                guard let src else { return .failure("no event source for click") }
                let right: Bool
                if action == "right_click" {
                    right = true
                } else {
                    switch (arguments["button"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces) {
                    case nil, "", "left": right = false
                    case "right": right = true
                    case let other?: return .failure("unknown button '\(other)' — use 'left' or 'right'")
                    }
                }
                let clicks = action == "double_click" ? 2 : 1
                guard Self.postClick(src: src, at: p, right: right, clicks: clicks) else { return .failure("could not synthesize click event") }
                return ToolResult(success: true, output: "\(right ? "right-" : "")clicked \(ai("x")),\(ai("y")) px\(clicks == 2 ? " (double)" : "")")
            }

        case "drag":
            let a = resolve("x", "y"), b = resolve("to_x", "to_y")
            if case .outOfBounds(let m) = a { return .failure(m) }
            if case .outOfBounds(let m) = b { return .failure(m) }
            guard case .ok(let from) = a, case .ok(let to) = b else { return .failure("drag needs x,y and to_x,to_y (screenshot pixels)") }
            guard let src, Self.postDrag(src: src, from: from, to: to) else { return .failure("could not synthesize drag event") }
            return ToolResult(success: true, output: "dragged \(ai("x")),\(ai("y")) → \(ai("to_x")),\(ai("to_y")) px")

        case "scroll":
            let dy = optionalInt("dy", from: arguments) ?? 0
            let dx = optionalInt("dx", from: arguments) ?? 0
            guard dy != 0 || dx != 0 else { return .failure("scroll needs a nonzero dy and/or dx") }
            guard let src, let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
                return .failure("could not synthesize scroll event")
            }
            e.post(tap: .cghidEventTap)
            return ToolResult(success: true, output: "scrolled dy=\(dy) dx=\(dx)")

        case "type":
            let text = (arguments["text"] as? String) ?? ""
            guard !text.isEmpty else { return .failure("type needs non-empty text") }
            guard text.count <= Self.maxTypeLength else { return .failure("text too long (\(text.count) > \(Self.maxTypeLength)); split it across calls") }
            guard let src, Self.postText(src: src, text: text) else { return .failure("could not synthesize keyboard event while typing") }
            return ToolResult(success: true, output: "typed \(text.count) characters")

        case "key":
            guard let chord = arguments["key"] as? String, !chord.isEmpty else {
                return .failure("key needs a key or chord, e.g. 'return' or 'cmd+s'")
            }
            let parsed = Self.parseChord(chord)
            guard let code = Self.keyCode(for: parsed.key) else {
                return .failure("unknown key '\(parsed.key)'. Known keys include letters, digits, return, tab, esc, arrows, f1-f12.")
            }
            guard let flags = Self.modifierFlags(parsed.modifiers) else {
                return .failure("unknown modifier in '\(chord)'. Valid modifiers: cmd, shift, opt, ctrl, fn.")
            }
            guard let src, Self.postKey(src: src, keyCode: code, flags: flags) else { return .failure("could not synthesize key event") }
            return ToolResult(success: true, output: "pressed \(chord)")

        default:
            return .failure("unhandled action '\(action)'")
        }
    }

    // MARK: - Side-effecting CGEvent primitives (verified manually, not in CI).
    // Each returns false if the OS refused to create an event, so the actuator never reports a state
    // change that didn't happen.

    static func displayScale(_ id: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return 1 }
        let ptW = Double(mode.width)
        return ptW > 0 ? Double(mode.pixelWidth) / ptW : 1
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    @discardableResult
    public static func post(_ type: CGEventType, src: CGEventSource, at p: CGPoint, button: CGMouseButton) -> Bool {
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return false }
        e.post(tap: .cghidEventTap)
        return true
    }

    public static func postClick(src: CGEventSource, at p: CGPoint, right: Bool, clicks: Int) -> Bool {
        let downType: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = right ? .rightMouseUp : .leftMouseUp
        let button: CGMouseButton = right ? .right : .left
        for click in 1...max(1, clicks) {
            // Create BOTH events before posting either, so we never post a mouse-down we can't release.
            guard let down = CGEvent(mouseEventSource: src, mouseType: downType, mouseCursorPosition: p, mouseButton: button),
                  let up = CGEvent(mouseEventSource: src, mouseType: upType, mouseCursorPosition: p, mouseButton: button) else { return false }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Press, briefly hold, interpolate several dragged steps, then release — many controls ignore a
    /// single-jump drag. Uses short blocking sleeps; acceptable for a discrete tool call. Once the button
    /// is down we ALWAYS attempt the release (even if an interpolated step fails) so it never sticks.
    public static func postDrag(src: CGEventSource, from: CGPoint, to: CGPoint, steps: Int = 8) -> Bool {
        guard let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left),
              let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left) else { return false }
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        var allStepsOK = true
        for i in 1...max(1, steps) {
            let t = Double(i) / Double(max(1, steps))
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            if let d = CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left) {
                d.post(tap: .cghidEventTap)
                usleep(8_000)
            } else {
                allStepsOK = false; break
            }
        }
        up.post(tap: .cghidEventTap)   // always release the pre-built up event
        return allStepsOK
    }

    /// Type per-character (down+up each) so long/mixed unicode is delivered reliably, not as one blob.
    /// Both events for a character are built before posting so a key is never left held down.
    public static func postText(src: CGEventSource, text: String) -> Bool {
        for ch in text {
            var u = Array(String(ch).utf16)
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return false }
            down.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
            up.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    public static func postKey(src: CGEventSource, keyCode: UInt16, flags: UInt64) -> Bool {
        // Build both before posting so a modifier/key is never left held down on failure.
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = CGEventFlags(rawValue: flags)
        up.flags = CGEventFlags(rawValue: flags)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Reusable primitives for the combined `tap` loop (capture + click of the MAIN display)

    /// Capture the main display to PNG bytes in memory (no file). nil if Screen Recording is denied or
    /// encoding fails. Returns pixel dimensions so the caller can map normalized points → pixels.
    public static func captureMainDisplayPNG() -> (data: Data, width: Int, height: Int)? {
        guard CGPreflightScreenCaptureAccess(), let image = CGDisplayCreateImage(CGMainDisplayID()) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, image.width, image.height)
    }

    /// PROVE input injection actually works: read the cursor, nudge it, read again to confirm it MOVED,
    /// then restore AND confirm the restore. This is the one thing no unit test can check — whether CGEvent
    /// posts really land. Pass = it moved (input works); the detail also reports whether restore confirmed.
    public static func verifyCursorInjection() -> (moved: Bool, detail: String) {
        guard AXIsProcessTrusted() else { return (false, "Accessibility permission not granted") }
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return (false, "no event source") }
        guard let start = CGEvent(source: nil)?.location else { return (false, "cannot read cursor position") }
        // Nudge toward the display center so the move isn't clamped at a screen edge.
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let dx: CGFloat = start.x < bounds.midX ? 15 : -15
        let dy: CGFloat = start.y < bounds.midY ? 15 : -15
        _ = post(.mouseMoved, src: src, at: CGPoint(x: start.x + dx, y: start.y + dy), button: .left)
        usleep(50_000)
        let after = CGEvent(source: nil)?.location ?? start
        _ = post(.mouseMoved, src: src, at: start, button: .left)   // restore where it was
        usleep(50_000)
        let restored = CGEvent(source: nil)?.location ?? start
        let moved = abs(after.x - start.x) > 1 || abs(after.y - start.y) > 1
        let backOK = abs(restored.x - start.x) <= 2 && abs(restored.y - start.y) <= 2
        if !moved { return (false, "cursor did NOT move — input injection is not landing (grant/re-grant Accessibility)") }
        return (true, backOK ? "cursor moved on command and was restored — input injection works"
                             : "cursor moved (input works) but could not confirm it was restored to \(Int(start.x)),\(Int(start.y))")
    }

    /// PROVE capture returns a LIVE frame, not a black/blank one: capture, then sample raw pixel bytes for
    /// non-uniformity. A uniform frame (all bytes equal) means capture isn't really working even though the
    /// call "succeeded" (Codex: non-nil ≠ real pixels).
    public static func verifyCaptureIsLive() -> (ok: Bool, detail: String) {
        guard CGPreflightScreenCaptureAccess() else { return (false, "Screen Recording permission not granted") }
        guard let img = CGDisplayCreateImage(CGMainDisplayID()) else { return (false, "capture returned nothing") }
        let dims = "\(img.width)x\(img.height) px"
        guard let data = img.dataProvider?.data else { return (true, "captured \(dims) (content not sampled)") }
        let len = CFDataGetLength(data)
        guard let ptr = CFDataGetBytePtr(data), len > 0 else { return (true, "captured \(dims) (content not sampled)") }
        var first: UInt8? = nil, varied = false
        let samples = 128
        for k in 0..<samples {
            let idx = Int(Double(k) / Double(samples) * Double(len - 1))
            let b = ptr[idx]
            if let f = first { if b != f { varied = true; break } } else { first = b }
        }
        return varied ? (true, "captured \(dims), pixels vary (live frame)")
                      : (false, "captured \(dims) but the frame is UNIFORM (black/blank) — capture isn't really working")
    }

    /// Click a screenshot-PIXEL coordinate on the main display — same permission/bounds/scale contract as
    /// the `click` action, packaged for one-shot use by `tap`.
    public static func clickMainDisplayPixel(x: Int, y: Int, right: Bool, clicks: Int) -> ClickOutcome {
        guard AXIsProcessTrusted() else { return .notTrusted }
        let display = CGMainDisplayID()
        let bounds = CGDisplayBounds(display)
        let scale = displayScale(display)
        let pixelW = Int((Double(bounds.width) * scale).rounded())
        let pixelH = Int((Double(bounds.height) * scale).rounded())
        guard x >= 0, y >= 0, x < pixelW, y < pixelH else {
            return .outOfBounds("(\(x),\(y)) is outside the main display (\(pixelW)x\(pixelH) px)")
        }
        let p = pointFromPixel(px: Double(x), py: Double(y),
                               origin: (Double(bounds.origin.x), Double(bounds.origin.y)), scale: scale)
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return .failed("no event source") }
        guard postClick(src: src, at: CGPoint(x: p.x, y: p.y), right: right, clicks: clicks) else {
            return .failed("could not synthesize click event")
        }
        return .clicked(x: x, y: y)
    }
}
#endif
