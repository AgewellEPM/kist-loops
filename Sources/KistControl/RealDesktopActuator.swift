import Foundation
import AgentCore
#if os(macOS)
import CoreGraphics
import ApplicationServices
import ImageIO
import UniformTypeIdentifiers
#endif

/// The ONLY place the real CGEvent/CGDisplay injection primitives live — inside the `kist-control` binary,
/// never in AgentCore/kist. Each action preflights the concrete TCC grant and returns a typed failure (never
/// a silent no-op) when the permission is absent. macOS only; other platforms fail clearly.
/// The side-effecting CGEvent code is adapted from the manually-verified DesktopControlTool primitives.
struct RealDesktopActuator: DesktopActuator {
    func perform(_ r: DesktopActionRequest) -> DesktopActionResponse {
        #if os(macOS)
        // TCC preflight per kind — the broker (not kist) is the identity that must hold these grants.
        if r.kind.needsAccessibility, !AXIsProcessTrusted() {
            return .failure(id: r.id, .accessibilityNotGranted,
                            "kist-control lacks Accessibility. Grant it in System Settings ▸ Privacy & Security ▸ Accessibility.")
        }
        if r.kind.needsScreenRecording, !CGPreflightScreenCaptureAccess() {
            return .failure(id: r.id, .screenRecordingNotGranted,
                            "kist-control lacks Screen Recording. Grant it in System Settings ▸ Privacy & Security ▸ Screen Recording.")
        }
        guard let src = CGEventSource(stateID: .combinedSessionState) else {
            return .failure(id: r.id, .actuationFailed, "could not create a CGEventSource")
        }
        // Resolve the TARGET display (r.display index; fallback to main). All coordinates below are that
        // display's SCREENSHOT-PIXEL space, converted to GLOBAL CG points via DisplayGeometry — Retina- AND
        // multi-display-correct (kist-review: the actuator previously used raw coords, ignoring scale/display).
        let displays = DisplayGeometry.liveDisplays()
        let disp: DisplayInfo
        if r.display >= 0, r.display < displays.count { disp = displays[r.display] }
        else if let m = DisplayGeometry.main(displays) { disp = m }
        else { return .failure(id: r.id, .actuationFailed, "no display detected") }
        // Local pixel (x,y) on `disp` → global CG point, BOUNDS-CHECKED. nil ⇒ absent or out of bounds.
        func point(_ x: Int?, _ y: Int?) -> CGPoint? {
            guard let px = x, let py = y, disp.containsLocalPixel(x: px, y: py) else { return nil }
            let g = disp.localPixelToGlobalPoint(x: px, y: py)
            return CGPoint(x: g.x, y: g.y)
        }
        func oob(_ x: Int?, _ y: Int?) -> DesktopActionResponse {
            .failure(id: r.id, .invalidRequest,
                     "(\(x ?? -1),\(y ?? -1)) is outside display \(disp.pixelWidth)x\(disp.pixelHeight) px")
        }

        switch r.kind {
        case .screenSize:
            return .init(id: r.id, ok: true,
                         message: "display \(r.display): \(disp.pixelWidth)x\(disp.pixelHeight) px, scale \(disp.scale)",
                         width: disp.pixelWidth, height: disp.pixelHeight)
        case .mousePosition:
            guard let loc = CGEvent(source: nil)?.location else {
                return .failure(id: r.id, .actuationFailed, "could not read cursor position")
            }
            // Carry the position in the message (width/height are screenshot dimensions — don't misuse them).
            return .init(id: r.id, ok: true, message: "x=\(Int(loc.x)) y=\(Int(loc.y)) (global points)")
        case .screenshot:
            guard let image = CGDisplayCreateImage(CGDirectDisplayID(disp.id)) else {   // resolved display, not always main
                return .failure(id: r.id, .actuationFailed, "screen capture returned no image")
            }
            guard let png = Self.pngBase64(image) else {
                return .failure(id: r.id, .actuationFailed, "could not encode the captured image")
            }
            return .init(id: r.id, ok: true, message: "screenshot",
                         pngBase64: png, width: image.width, height: image.height)
        case .move:
            guard let p = point(r.x, r.y) else { return oob(r.x, r.y) }
            let ok = DesktopControlTool.post(.mouseMoved, src: src, at: p, button: .left)
            return ok ? .init(id: r.id, ok: true, message: "moved") : .failure(id: r.id, .actuationFailed, "move failed")
        case .click, .doubleClick, .rightClick:
            guard let p = point(r.x, r.y) else { return oob(r.x, r.y) }
            let right = (r.kind == .rightClick)
            let clicks = r.kind == .doubleClick ? 2 : max(1, r.clicks)
            let ok = DesktopControlTool.postClick(src: src, at: p, right: right, clicks: clicks)
            return ok ? .init(id: r.id, ok: true, message: "clicked") : .failure(id: r.id, .actuationFailed, "click failed")
        case .drag:
            guard let from = point(r.x, r.y) else { return oob(r.x, r.y) }
            guard let to = point(r.dx, r.dy) else { return oob(r.dx, r.dy) }
            let ok = DesktopControlTool.postDrag(src: src, from: from, to: to)
            return ok ? .init(id: r.id, ok: true, message: "dragged") : .failure(id: r.id, .actuationFailed, "drag failed")
        case .scroll:
            // Position the cursor at (x,y) first if provided, so the scroll targets the intended window.
            if let p = point(r.x, r.y) { _ = DesktopControlTool.post(.mouseMoved, src: src, at: p, button: .left) }
            guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(r.dy ?? 0), wheel2: Int32(r.dx ?? 0), wheel3: 0) else {
                return .failure(id: r.id, .actuationFailed, "scroll event creation failed")
            }
            e.post(tap: .cghidEventTap)
            return .init(id: r.id, ok: true, message: "scrolled")
        case .type:
            let ok = DesktopControlTool.postText(src: src, text: r.text ?? "")
            return ok ? .init(id: r.id, ok: true, message: "typed \((r.text ?? "").count) char(s)")
                      : .failure(id: r.id, .actuationFailed, "could not synthesize keyboard event")
        case .key:
            let chord = r.keys.joined(separator: "+")
            let parsed = DesktopControlTool.parseChord(chord)
            guard let code = DesktopControlTool.keyCode(for: parsed.key),
                  let flags = DesktopControlTool.modifierFlags(parsed.modifiers) else {
                return .failure(id: r.id, .invalidRequest, "unknown key/modifier in \(r.keys)")
            }
            let ok = DesktopControlTool.postKey(src: src, keyCode: code, flags: flags)
            return ok ? .init(id: r.id, ok: true, message: "key \(chord)")
                      : .failure(id: r.id, .actuationFailed, "key event failed")
        }
        #else
        return .failure(id: r.id, .unsupportedPlatform, "kist-control requires macOS (CGEvent).")
        #endif
    }

    #if os(macOS)
    /// Encode a captured frame as base64 PNG for the IPC response.
    static func pngBase64(_ image: CGImage) -> String? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data).base64EncodedString()
    }
    #endif
}
