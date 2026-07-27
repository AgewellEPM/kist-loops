import Foundation
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Readiness check for driving the native desktop (the hands/aim/perception tools). A live GUI run needs
/// three things that live OUTSIDE the code — two macOS permissions and a vision backend — and if any is
/// missing the run fails opaquely mid-way (a click no-ops, a capture returns nil). This turns that into an
/// up-front checklist that names exactly what to enable, so "run and hope" becomes "here's what's missing".
public enum ComputerUsePreflight {

    public struct Readiness: Sendable, Equatable {
        public let accessibility: Bool      // input injection (AXIsProcessTrusted)
        public let screenRecording: Bool    // screen capture (CGPreflightScreenCaptureAccess)
        public let moondreamConfigured: Bool // a Moondream cloud key or local server URL
        public var ready: Bool { accessibility && screenRecording && moondreamConfigured }
    }

    /// Pure evaluation from probed facts — unit-tested without touching real permissions/env.
    public static func evaluate(accessibility: Bool, screenRecording: Bool,
                                moondreamKey: String?, moondreamURL: String?) -> Readiness {
        let hasMoon = !(moondreamKey?.isEmpty ?? true) || !(moondreamURL?.isEmpty ?? true)
        return Readiness(accessibility: accessibility, screenRecording: screenRecording, moondreamConfigured: hasMoon)
    }

    /// Live check against the real OS + environment (macOS). On other platforms everything is false.
    public static func check(environment: [String: String] = ProcessInfo.processInfo.environment) -> Readiness {
        #if canImport(ApplicationServices) && canImport(CoreGraphics)
        let ax = AXIsProcessTrusted()
        let screen = CGPreflightScreenCaptureAccess()
        #else
        let ax = false, screen = false
        #endif
        return evaluate(accessibility: ax, screenRecording: screen,
                        moondreamKey: environment["MOONDREAM_API_KEY"], moondreamURL: environment["MOONDREAM_BASE_URL"])
    }

    /// The perceive→decide→act→wait loop, handed to the model on the ready path so it knows how to chain
    /// the GUI tools (they exist, but the SEQUENCE is the skill).
    public static let playbook = """
    Driving the screen — the loop:
      1. look("what's on screen?") or look("<question>")  — cheap read of current state; decide from it.
      2. tap("<target>")  — capture+locate+click a named thing in one step (preferred over screenshot→locate→click).
      3. desktop_control  — raw input when there's no click target: key ("return"/"cmd+s"/arrows), type, drag, scroll.
      4. wait_for_screen("<what should appear>")  — after any action that triggers a transition/loading, BEFORE the next step.
      Repeat. Coordinates are main-display screenshot pixels. Confirm actions landed with wait_for_screen/look, not by assuming.
    """

    /// A human/agent-readable checklist naming the exact fix for each missing item.
    public static func report(_ r: Readiness) -> String {
        if r.ready {
            return "✓ Computer use is READY — Accessibility, Screen Recording, and a Moondream backend are all set.\n\n" + playbook
        }
        func line(_ ok: Bool, _ name: String, _ fix: String) -> String {
            ok ? "  ✓ \(name)" : "  ✗ \(name) — \(fix)"
        }
        return """
        Computer use is NOT ready. Enable the missing items, then retry:
        \(line(r.accessibility, "Accessibility (mouse/keyboard)", "System Settings → Privacy & Security → Accessibility → add & enable this app"))
        \(line(r.screenRecording, "Screen Recording (capture)", "System Settings → Privacy & Security → Screen Recording → add & enable this app"))
        \(line(r.moondreamConfigured, "Moondream vision", "set MOONDREAM_API_KEY (cloud) or MOONDREAM_BASE_URL (local server)"))
        """
    }
}

/// Read-only diagnostic tool: report whether the desktop-control stack is ready to run, and what's missing.
/// Not gated (it only reads permission/env state), and cheap — the agent can call it before a GUI attempt.
public struct ComputerUseCheckTool: AgentTool {
    public let name = "computer_use_check"
    public var description: String {
        "Check whether desktop control is ready (Accessibility + Screen Recording permissions + a Moondream vision backend). Returns a checklist of what's missing and how to enable it. Call before attempting to drive the screen."
    }
    public var parameters: [ToolParameter] { [] }

    private let probe: @Sendable () -> ComputerUsePreflight.Readiness

    public init(probe: @escaping @Sendable () -> ComputerUsePreflight.Readiness = { ComputerUsePreflight.check() }) {
        self.probe = probe
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let r = probe()
        return ToolResult(success: true, output: ComputerUsePreflight.report(r),
                          metadata: ["ready": r.ready ? "true" : "false",
                                     "accessibility": "\(r.accessibility)",
                                     "screen_recording": "\(r.screenRecording)",
                                     "moondream": "\(r.moondreamConfigured)"])
    }
}
