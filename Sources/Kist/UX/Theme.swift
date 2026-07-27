import Foundation

/// `/theme` — a semantic color palette for kist's output. Instead of hardcoding ANSI codes, surfaces ask
/// the theme for a *role* (accent, success, warning, error, dim, prompt) and the theme maps it to codes.
/// This makes accessibility real: `high-contrast` maximizes brightness for low vision, `daltonized` avoids
/// the red/green confusion of color-vision deficiency, and `mono` emits NO ANSI at all — the correct
/// choice for screen readers, which otherwise read escape sequences aloud.
///
/// A `Theme` is an immutable value passed explicitly to renderers (no mutable global → Sendable-safe). The
/// active theme is resolved from settings via `Theme.resolve(_:)`.
public struct Theme: Equatable, Sendable {
    public let name: String
    let accentCode: String     // headers / primary emphasis
    let successCode: String    // ✓ good outcomes
    let warningCode: String    // caution
    let errorCode: String      // ✗ failures
    let dimCode: String        // secondary / hints
    let promptCode: String     // the input prompt glyph

    /// Wrap `s` in an ANSI role, or return it untouched when the code is empty (mono / NO_COLOR).
    func wrap(_ code: String, _ s: String) -> String {
        code.isEmpty ? s : "\u{001B}[\(code)m\(s)\u{001B}[0m"
    }
    public func accent(_ s: String) -> String { wrap(accentCode, s) }
    public func success(_ s: String) -> String { wrap(successCode, s) }
    public func warning(_ s: String) -> String { wrap(warningCode, s) }
    public func error(_ s: String) -> String { wrap(errorCode, s) }
    public func dim(_ s: String) -> String { wrap(dimCode, s) }
    public func prompt(_ s: String) -> String { wrap(promptCode, s) }

    // MARK: - Palettes

    /// kist's original look — cyan accent, green/red status, faint dim.
    public static let standard = Theme(name: "default", accentCode: "36;1", successCode: "32",
                                       warningCode: "33", errorCode: "31", dimCode: "2", promptCode: "36;1")
    public static let dark = Theme(name: "dark", accentCode: "36;1", successCode: "32;1",
                                   warningCode: "33;1", errorCode: "31;1", dimCode: "90", promptCode: "36;1")
    public static let light = Theme(name: "light", accentCode: "34", successCode: "32",
                                    warningCode: "33", errorCode: "31", dimCode: "90", promptCode: "34;1")

    /// Color-vision-deficiency safe (deuteranopia/protanopia): red↔green are unreliable, so status leans on
    /// blue vs. yellow/magenta — hues separable for the common CVD types. No green-for-good/red-for-bad.
    public static let daltonized = Theme(name: "daltonized", accentCode: "36;1", successCode: "34;1",
                                         warningCode: "33;1", errorCode: "35;1", dimCode: "90", promptCode: "36;1")

    /// Low-vision: bold bright everything, and `dim` is a plain readable white — NOT the faint `2` that
    /// low-vision users can't see. Maximize contrast, never sacrifice legibility for subtlety.
    public static let highContrast = Theme(name: "high-contrast", accentCode: "97;1", successCode: "92;1",
                                           warningCode: "93;1", errorCode: "91;1", dimCode: "37", promptCode: "97;1")

    /// No color at all — every role returns plain text. The right choice for screen readers (ANSI escapes
    /// get read aloud) and for `NO_COLOR`. Meaning must survive without color, so surfaces still use glyphs.
    public static let mono = Theme(name: "mono", accentCode: "", successCode: "", warningCode: "",
                                   errorCode: "", dimCode: "", promptCode: "")

    public static let all: [Theme] = [standard, dark, light, daltonized, highContrast, mono]

    /// Resolve a theme name (as stored in settings) to a palette. `auto`/nil/unknown ⇒ default; honors the
    /// `NO_COLOR` convention by forcing mono.
    public static func resolve(_ name: String?, noColorEnv: Bool = ProcessInfo.processInfo.environment["NO_COLOR"] != nil) -> Theme {
        if noColorEnv { return mono }
        switch (name ?? "auto").lowercased() {
        case "dark": return dark
        case "light": return light
        case "daltonized", "colorblind", "cvd": return daltonized
        case "high-contrast", "highcontrast", "hc": return highContrast
        case "mono", "none", "no-color": return mono
        default: return standard   // "auto" / unknown
        }
    }

    /// A one-line swatch showing each role, so `/theme` previews what the palette looks like immediately.
    /// `colorized: false` emits the same words with NO ANSI — used when the ACTIVE theme is mono/NO_COLOR so
    /// listing the palettes doesn't spray escapes a screen reader would read aloud.
    public func swatch(colorized: Bool = true) -> String {
        let paint: (String, String) -> String = colorized ? wrap : { _, s in s }
        return "\(paint(accentCode, "accent"))  \(paint(successCode, "✓ success"))  " +
               "\(paint(warningCode, "caution"))  \(paint(errorCode, "✗ error"))  \(paint(dimCode, "dim"))"
    }
}
