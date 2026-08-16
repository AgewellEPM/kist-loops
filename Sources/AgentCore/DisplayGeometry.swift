import Foundation

/// Shared display geometry for computer use — the single source of truth for converting between the
/// global CoreGraphics POINT space (where AX frames and CGEvent live) and per-display screenshot PIXEL
/// space (what the model reads and hands back). Extracting this is what makes MULTI-DISPLAY correct: each
/// display has its own origin (points) and its own Retina scale (pixels/point), so a single main-display
/// scale — the old assumption — is wrong for a secondary/differently-scaled monitor.
///
/// Pure value type + pure math, so the coordinate logic every actuator depends on is unit-tested without
/// any real display. The live `CGDisplay*` enumeration lives in a thin macOS shim.
public struct DisplayInfo: Sendable, Equatable {
    public let id: Int                 // CGDirectDisplayID (opaque; 0 in tests is fine)
    public let originX: Double         // display origin in GLOBAL points (top-left)
    public let originY: Double
    public let widthPt: Double         // size in points
    public let heightPt: Double
    public let scale: Double           // pixels per point (Retina factor)
    public let isMain: Bool

    public init(id: Int, originX: Double, originY: Double, widthPt: Double, heightPt: Double, scale: Double, isMain: Bool) {
        self.id = id; self.originX = originX; self.originY = originY
        self.widthPt = widthPt; self.heightPt = heightPt; self.scale = max(scale, 0.0001); self.isMain = isMain
    }

    public var pixelWidth: Int { Int((widthPt * scale).rounded()) }
    public var pixelHeight: Int { Int((heightPt * scale).rounded()) }

    /// Does a GLOBAL point (points) fall within this display?
    public func containsGlobalPoint(x: Double, y: Double) -> Bool {
        x >= originX && x < originX + widthPt && y >= originY && y < originY + heightPt
    }

    /// GLOBAL point (points) → this display's screenshot PIXEL coordinate.
    public func globalPointToLocalPixel(x: Double, y: Double) -> (x: Int, y: Int) {
        (Int(((x - originX) * scale).rounded()), Int(((y - originY) * scale).rounded()))
    }

    /// This display's screenshot PIXEL coordinate → GLOBAL point (for CGEvent).
    public func localPixelToGlobalPoint(x: Int, y: Int) -> (x: Double, y: Double) {
        (originX + Double(x) / scale, originY + Double(y) / scale)
    }

    /// Is a pixel coordinate inside this display's pixel bounds?
    public func containsLocalPixel(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < pixelWidth && y < pixelHeight
    }
}

public enum DisplayGeometry {
    /// The display a GLOBAL point lands on (nil if the point is in dead space between displays).
    public static func display(forGlobalPoint x: Double, y: Double, in displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first { $0.containsGlobalPoint(x: x, y: y) }
    }

    /// Resolve a display by index: nil ⇒ main; otherwise the display with that id, else nil.
    public static func display(id: Int?, in displays: [DisplayInfo]) -> DisplayInfo? {
        guard let id else { return displays.first(where: \.isMain) ?? displays.first }
        return displays.first { $0.id == id }
    }

    public static func main(_ displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first(where: \.isMain) ?? displays.first
    }
}

#if canImport(CoreGraphics)
import CoreGraphics

public extension DisplayGeometry {
    /// Resolve a tool's optional display INDEX to a target `DisplayInfo`. nil ⇒ nil (let the provider use
    /// main). An EXPLICIT out-of-range index yields an error message (never silently retargets — the
    /// wrong-target risk desktop_control also guards). macOS only.
    static func resolveTarget(index: Int?) -> (display: DisplayInfo?, error: String?) {
        guard let index else { return (nil, nil) }
        let displays = liveDisplays()
        guard index >= 0, index < displays.count else {
            return (nil, "display index \(index) is out of range — \(displays.count) display(s) attached.")
        }
        return (displays[index], nil)
    }

    /// Live enumeration of the attached displays (macOS). Integration — not unit-tested.
    static func liveDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let mainID = CGMainDisplayID()
        return ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            let scale: Double = {
                guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return 1 }
                return Double(mode.pixelWidth) / Double(mode.width)
            }()
            return DisplayInfo(id: Int(id), originX: Double(bounds.origin.x), originY: Double(bounds.origin.y),
                               widthPt: Double(bounds.width), heightPt: Double(bounds.height),
                               scale: scale, isMain: id == mainID)
        }
    }
}
#endif
