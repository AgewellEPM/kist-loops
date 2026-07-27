import Foundation
#if canImport(ApplicationServices)
import ApplicationServices
#endif

/// STRUCTURED UI GROUNDING — the biggest reliability lever for driving standard apps. Pure vision
/// (Moondream point) guesses a pixel and has ~20px error; on OSWorld/WebArena ~60-70% of computer-use
/// failures are grounding mistakes (wrong pixel, occluded/ambiguous target, layout shift). macOS already
/// exposes a deterministic, machine-readable UI graph via the Accessibility API (the permission we already
/// require), so instead of guessing, the agent reads the real interactive elements — role, label, exact
/// pixel bounds, enabled-state — and clicks a KNOWN center via the existing hands. Vision stays the
/// fallback for custom-rendered UIs (games) that expose no AX tree.
///
/// A plain, Sendable element descriptor (no AX types) is the testable currency; the AX walk that produces
/// it is macOS-only integration (like CGEvent) and injected behind `UIElementProvider` so tool logic —
/// filtering, rendering, click-center math — is unit-tested with a mock tree.
public struct UIElement: Sendable, Equatable {
    public let role: String
    public let label: String?
    public let value: String?
    public let x: Int, y: Int, width: Int, height: Int   // pixel bounds (screenshot space)
    public let enabled: Bool

    public init(role: String, label: String?, value: String?, x: Int, y: Int, width: Int, height: Int, enabled: Bool) {
        self.role = role; self.label = label; self.value = value
        self.x = x; self.y = y; self.width = width; self.height = height; self.enabled = enabled
    }

    /// The point the agent hands to desktop_control/tap — the element's center in screenshot pixels.
    public var centerX: Int { x + width / 2 }
    public var centerY: Int { y + height / 2 }
}

public protocol UIElementProvider: Sendable {
    /// Snapshot the focused app's interactive elements on the given display (nil = main), in that
    /// display's screenshot-pixel space. Empty when no AX tree is available.
    func snapshot(maxElements: Int, on display: DisplayInfo?) -> [UIElement]
}

public extension AgentTool {
    /// Resolve an optional `display` INDEX argument to a target display (nil ⇒ main). Fails loudly on a
    /// non-integer or explicit out-of-range index (never silently retargets). macOS-gated.
    func resolveDisplay(from arguments: [String: Any]) -> (display: DisplayInfo?, error: String?) {
        guard let raw = arguments["display"] else { return (nil, nil) }
        // STRICT: a fractional index (0.5, 1.9) must NOT truncate to a real display (wrong-target risk).
        guard let i = strictInt(raw) else { return (nil, "display must be a whole-number index.") }
        #if canImport(CoreGraphics)
        return DisplayGeometry.resolveTarget(index: i)
        #else
        return (nil, "multi-display requires macOS.")
        #endif
    }

    /// Parse a WHOLE-number index: a real Int, an integral Double (1.0), or an integer string — but NOT a
    /// fractional value (0.5 → nil). Used where truncation would silently target the wrong thing.
    func strictInt(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return d == d.rounded() ? Int(d) : nil }
        if let s = any as? String, let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
        return nil
    }
}

public enum AXPressResult: Sendable, Equatable {
    case pressed(role: String, label: String?)
    case ambiguous(Int)     // multiple controls match the label — refuse to guess
    case indeterminate      // the press MAY have completed (AX cannotComplete) — verify, don't blind-retry
    case notFound
    case unavailable        // no AX tree / not trusted
    case failed(String)
}

/// Direct AX actions — press an element BY IDENTITY (AXUIElementPerformAction), not by clicking a pixel.
/// The most reliable action path for AX-exposed apps: no coordinate, no occlusion, can't miss.
public protocol UIActionProvider: Sendable {
    func press(labelQuery: String, role: String?, on display: DisplayInfo?) -> AXPressResult
}

public enum UIElementRenderer {
    /// Roles worth clicking — filters the AX tree down to actionable controls (not every static label).
    public static let interactiveRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXTextField", "AXTextArea", "AXComboBox", "AXLink", "AXSlider", "AXTab",
        "AXCell", "AXRow", "AXDisclosureTriangle", "AXStepper", "AXSegmentedControl", "AXToolbarButton",
    ]

    /// Keep only elements matching the query (role or label substring, case-insensitive) and, when
    /// `interactiveOnly`, only actionable roles. Degenerate zero-size elements are dropped (nothing to click).
    public static func filter(_ els: [UIElement], query: String?, interactiveOnly: Bool) -> [UIElement] {
        let q = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return els.filter { e in
            guard e.width > 0, e.height > 0 else { return false }
            if interactiveOnly, !interactiveRoles.contains(e.role) { return false }
            guard let q, !q.isEmpty else { return true }
            return e.role.lowercased().contains(q) || (e.label?.lowercased().contains(q) ?? false)
        }
    }

    /// One line per element: role "label" [state] @ center — the model clicks the center directly.
    public static func render(_ els: [UIElement]) -> String {
        els.map { e in
            let role = clean(short(e.role), maxLength: 40) ?? "unknown"
            let name = e.label.flatMap { clean($0, maxLength: 80) }.map { " \"\($0)\"" } ?? ""
            let state = e.enabled ? "" : " [disabled]"
            let val = e.value.flatMap { clean($0, maxLength: 40) }.map { " =\($0)" } ?? ""
            return "\(role)\(name)\(val)\(state) @ (\(e.centerX),\(e.centerY))"
        }.joined(separator: "\n")
    }

    /// Strip the "AX" prefix for readability (AXButton → button).
    static func short(_ role: String) -> String {
        role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role.lowercased()
    }

    /// Roles that support a simple AXPress (a subset of interactiveRoles). Text fields, sliders, rows,
    /// cells, steppers, segmented controls are excluded — they don't press cleanly (Codex).
    public static let pressableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXTab", "AXDisclosureTriangle", "AXLink", "AXToolbarButton",
    ]

    public enum PressMatch: Equatable {
        case unique(Int)
        case ambiguous(Int)   // N controls match the label — refuse to guess
        case none
    }

    /// Pick the element to press for a label query: pressable, enabled, sized, matching the optional role.
    /// Exact (case-insensitive) label match preferred over substring. If MORE THAN ONE control matches
    /// (e.g. two "OK" buttons), returns `.ambiguous` rather than pressing a tree-order guess (Codex HIGH).
    /// Pure, so target selection is unit-tested without AX.
    public static func bestMatch(_ els: [UIElement], labelQuery: String, role: String?,
                                 supportsPressAction: (Int) -> Bool = { _ in true }) -> PressMatch {
        let q = labelQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return .none }
        let r = role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = els.indices.filter { i in
            let e = els[i]
            guard e.width > 0, e.height > 0, e.enabled, pressableRoles.contains(e.role), e.label != nil else { return false }
            if let r, !r.isEmpty, !e.role.lowercased().contains(r) { return false }
            guard supportsPressAction(i) else { return false }
            return true
        }
        let exact = candidates.filter { els[$0].label?.lowercased() == q }
        if exact.count == 1 { return .unique(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact.count) }
        let sub = candidates.filter { els[$0].label?.lowercased().contains(q) ?? false }
        if sub.count == 1 { return .unique(sub[0]) }
        if sub.count > 1 { return .ambiguous(sub.count) }
        return .none
    }

    /// AX strings are untrusted app-controlled text. Keep each element on one bounded line so labels cannot
    /// spoof extra results or flood the model context.
    static func clean(_ raw: String, maxLength: Int) -> String? {
        let scalarText = raw.unicodeScalars.map { scalar -> String in
            if CharacterSet.newlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                return " "
            }
            if scalar == "\"" { return "\\\"" }
            return String(scalar)
        }.joined()
        let collapsed = scalarText.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > maxLength ? String(trimmed.prefix(maxLength)) + "..." : trimmed
    }
}

#if canImport(ApplicationServices) && canImport(CoreGraphics)
import CoreGraphics

/// Production provider: walks the FOCUSED application's Accessibility tree. macOS-only, needs the
/// Accessibility permission (same one desktop_control requires). Integration code — not unit-tested.
public struct AXUIElementProvider: UIElementProvider, UIActionProvider {
    private let maxDepth: Int
    private let maxVisits: Int

    public init(maxDepth: Int = 40, maxVisits: Int = 8000) {
        self.maxDepth = maxDepth
        self.maxVisits = maxVisits
    }

    public func snapshot(maxElements: Int, on display: DisplayInfo?) -> [UIElement] {
        guard AXIsProcessTrusted() else { return [] }
        guard let target = display ?? DisplayGeometry.main(DisplayGeometry.liveDisplays()) else { return [] }
        let system = AXUIElementCreateSystemWide()
        // HARD timeout on the SYSTEM-WIDE object = process default, so it bounds every child read too
        // (an object-local timeout on the app element would not propagate — council HIGH).
        AXUIElementSetMessagingTimeout(system, 2.0)
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let app = appRef, CFGetTypeID(app) == AXUIElementGetTypeID() else { return [] }
        let appEl = app as! AXUIElement
        // Keep only elements whose center is within the TARGET display; each is emitted in that display's
        // screenshot-pixel space (per-display origin + scale via DisplayGeometry), so a click lands right.
        var out: [UIElement] = []
        var visited = 0
        walk(appEl, depth: 0, into: &out, max: maxElements, visited: &visited, target: target)
        return out
    }

    // MARK: - Direct AX press (by identity, not pixel)

    public func press(labelQuery: String, role: String?, on display: DisplayInfo?) -> AXPressResult {
        guard AXIsProcessTrusted() else { return .unavailable }
        guard let target = display ?? DisplayGeometry.main(DisplayGeometry.liveDisplays()) else { return .unavailable }
        let system = AXUIElementCreateSystemWide()
        // Timeout on the SYSTEM-WIDE object = process default, so it applies to every child read AND the
        // PerformAction (an object-local timeout on the app element would not — Codex HIGH).
        AXUIElementSetMessagingTimeout(system, 2.0)
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let app = appRef, CFGetTypeID(app) == AXUIElementGetTypeID() else { return .unavailable }
        let appEl = app as! AXUIElement
        // Re-resolve the target FRESH at press time (AXUIElement refs are opaque and can go stale).
        var pairs: [(UIElement, AXUIElement)] = []
        var visited = 0
        walkPairs(appEl, depth: 0, into: &pairs, max: 2500, visited: &visited, target: target)
        let descriptors = pairs.map(\.0)
        switch UIElementRenderer.bestMatch(descriptors, labelQuery: labelQuery, role: role,
                                           supportsPressAction: { supportsPressAction(pairs[$0].1) }) {
        case .none:
            return .notFound
        case .ambiguous(let n):
            return .ambiguous(n)
        case .unique(let idx):
            let (desc, ref) = pairs[idx]
            let code = AXUIElementPerformAction(ref, kAXPressAction as CFString)
            switch code {
            case .success: return .pressed(role: desc.role, label: desc.label)
            case .cannotComplete: return .indeterminate   // Apple: may still be processed — verify, don't blind-retry
            default: return .failed("AX press returned \(code.rawValue)")
            }
        }
    }

    private func walkPairs(_ el: AXUIElement, depth: Int, into out: inout [(UIElement, AXUIElement)],
                           max: Int, visited: inout Int, target: DisplayInfo) {
        guard visited < maxVisits, out.count < max, depth <= maxDepth else { return }
        visited += 1
        if let e = describe(el, target: target) { out.append((e, el)) }
        guard visited < maxVisits, out.count < max, let children = axArray(el, kAXChildrenAttribute) else { return }
        for child in children {
            if visited >= maxVisits || out.count >= max { break }
            walkPairs(child, depth: depth + 1, into: &out, max: max, visited: &visited, target: target)
        }
    }

    private func walk(_ el: AXUIElement, depth: Int, into out: inout [UIElement], max: Int,
                      visited: inout Int, target: DisplayInfo) {
        // Bound total NODES VISITED, not just describable output (council: a wide tree of geometry-less
        // container nodes doesn't grow `out` but would otherwise be walked exhaustively).
        guard visited < maxVisits, out.count < max, depth <= maxDepth else { return }
        visited += 1
        if let e = describe(el, target: target) { out.append(e) }
        guard visited < maxVisits, out.count < max, let children = axArray(el, kAXChildrenAttribute) else { return }
        for child in children {
            if visited >= maxVisits || out.count >= max { break }
            walk(child, depth: depth + 1, into: &out, max: max, visited: &visited, target: target)
        }
    }

    private func supportsPressAction(_ el: AXUIElement) -> Bool {
        var namesRef: CFArray?
        guard AXUIElementCopyActionNames(el, &namesRef) == .success,
              let names = namesRef as? [String] else { return false }
        return names.contains(kAXPressAction as String)
    }

    private func describe(_ el: AXUIElement, target: DisplayInfo) -> UIElement? {
        guard let (pos, size) = axFrame(el) else { return nil }   // no geometry ⇒ not clickable
        // Keep only elements whose CENTER lies on the TARGET display, then emit in that display's
        // screenshot-pixel space (its own origin + scale) so a click there lands on the element.
        let cx = Double(pos.x) + Double(size.width) / 2, cy = Double(pos.y) + Double(size.height) / 2
        guard target.containsGlobalPoint(x: cx, y: cy) else { return nil }
        let role = axString(el, kAXRoleAttribute) ?? "AXUnknown"
        let label = axString(el, kAXTitleAttribute) ?? axString(el, kAXDescriptionAttribute)
        let value = axString(el, kAXValueAttribute)
        let enabled = axBool(el, kAXEnabledAttribute) ?? true
        let (lx, ly) = target.globalPointToLocalPixel(x: Double(pos.x), y: Double(pos.y))
        return UIElement(role: role, label: label, value: value,
                         x: lx, y: ly,
                         width: Int((Double(size.width) * target.scale).rounded()),
                         height: Int((Double(size.height) * target.scale).rounded()),
                         enabled: enabled)
    }

    // MARK: - AX attribute readers

    private func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
        if CFGetTypeID(v) == CFStringGetTypeID() { let s = v as! String; return s.isEmpty ? nil : s }
        return nil
    }

    private func axBool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
        return (v as! CFBoolean) == kCFBooleanTrue
    }

    private func axArray(_ el: AXUIElement, _ attr: String) -> [AXUIElement]? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == CFArrayGetTypeID() else { return nil }
        // Defensive: a malformed app could put non-AXUIElement refs in the array — `as?` yields nil (drop)
        // instead of trapping on a forced cast.
        return v as? [AXUIElement]
    }

    private func axFrame(_ el: AXUIElement) -> (pos: CGPoint, size: CGSize)? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        let posVal = posRef as! AXValue, sizeVal = sizeRef as! AXValue
        guard AXValueGetType(posVal) == .cgPoint, AXValueGetType(sizeVal) == .cgSize else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posVal, .cgPoint, &pos), AXValueGetValue(sizeVal, .cgSize, &size) else { return nil }
        return (pos, size)
    }
}
#endif
