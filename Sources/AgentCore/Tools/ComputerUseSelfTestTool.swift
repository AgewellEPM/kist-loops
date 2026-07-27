import Foundation

struct SelfTestTimeout: Error {}

/// Run the computer-use SMOKE TEST — actually exercise capture, input injection, AX grounding, and (if
/// configured) Moondream, and report per-step pass/fail. Use it before a live agent run to prove the
/// hands and eyes really work on this machine, not just that permissions are granted (`computer_use_check`
/// covers permissions; this proves the capabilities). The steps are injected, so the orchestration is
/// unit-tested; production wires the real screen/mouse/model steps.
public struct ComputerUseSelfTestTool: AgentTool {
    public let name = "computer_use_selftest"
    public var description: String {
        """
        Prove the computer-use stack actually works on this machine: it captures the screen, MOVES the \
        cursor and confirms it moved (real input test — briefly nudges your pointer and restores it), reads \
        the Accessibility tree, and checks Moondream if configured. Reports each step ✓/✗. Run before a \
        live run. macOS.
        """
    }
    public var parameters: [ToolParameter] { [] }
    public var capabilityNote: String? {
        "A one-shot end-to-end check that briefly moves the real cursor to verify input works, then restores it. Read-mostly; it does not click anything."
    }

    private let steps: [ComputerUseSelfTest.Step]

    public init(steps: [ComputerUseSelfTest.Step]) { self.steps = steps }

    /// Production wiring: real capture + input-injection + AX-grounding + optional Moondream steps.
    public static func wired(client: MoondreamClient = MoondreamClient(),
                             moondreamConfigured: Bool = ProcessInfo.processInfo.environment["MOONDREAM_API_KEY"] != nil
                                 || ProcessInfo.processInfo.environment["MOONDREAM_BASE_URL"] != nil) -> ComputerUseSelfTestTool {
        var steps: [ComputerUseSelfTest.Step] = []

        // 1) Screen capture returns a LIVE (non-uniform) frame — not just a non-nil black one.
        steps.append {
            #if canImport(CoreGraphics)
            let r = DesktopControlTool.verifyCaptureIsLive()
            return .init(name: "screen capture", passed: r.ok, detail: r.detail)
            #else
            return .init(name: "screen capture", passed: false, detail: "requires macOS")
            #endif
        }

        // 2) Input injection actually moves the cursor.
        steps.append {
            #if canImport(CoreGraphics)
            let r = DesktopControlTool.verifyCursorInjection()
            return .init(name: "input injection", passed: r.moved, detail: r.detail)
            #else
            return .init(name: "input injection", passed: false, detail: "requires macOS")
            #endif
        }

        // 3) Accessibility grounding tree is available (informational — absent for custom-rendered apps).
        steps.append {
            #if canImport(ApplicationServices) && canImport(CoreGraphics)
            let count = AXUIElementProvider().snapshot(maxElements: 200, on: nil).count
            return .init(name: "AX grounding", passed: true,
                         detail: count > 0 ? "\(count) element(s) in the focused app"
                                           : "no AX tree in the focused app (fine — use vision for it)")
            #else
            return .init(name: "AX grounding", passed: false, detail: "requires macOS")
            #endif
        }

        // 4) Moondream perception responds (only if configured).
        steps.append {
            guard moondreamConfigured else {
                return .init(name: "Moondream vision", passed: true, detail: "not configured — vision tools disabled (set MOONDREAM_API_KEY to enable)")
            }
            #if canImport(CoreGraphics)
            guard let shot = DesktopControlTool.captureMainDisplayPNG() else {
                return .init(name: "Moondream vision", passed: false, detail: "no frame to send (capture failed)")
            }
            do {
                // Bound the probe so a stalled local server can't make the diagnostic hang (council).
                let caption = try await Self.withTimeout(seconds: 15) {
                    try await client.caption(imageData: shot.data, mime: "image/png")
                }
                let ok = !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                return .init(name: "Moondream vision", passed: ok, detail: ok ? "responded: \(caption.prefix(60))" : "empty response")
            } catch is SelfTestTimeout {
                return .init(name: "Moondream vision", passed: false, detail: "timed out after 15s — check the Moondream endpoint")
            } catch {
                return .init(name: "Moondream vision", passed: false, detail: "error: \(error)")
            }
            #else
            return .init(name: "Moondream vision", passed: false, detail: "requires macOS")
            #endif
        }

        return ComputerUseSelfTestTool(steps: steps)
    }

    /// Race an async op against a timeout so one stalled step can't hang the diagnostic.
    static func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); throw SelfTestTimeout() }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let (results, allPassed) = await ComputerUseSelfTest.run(steps)
        return ToolResult(success: true,
                          output: ComputerUseSelfTest.report(results, allPassed: allPassed),
                          metadata: ["all_passed": "\(allPassed)", "steps": "\(results.count)",
                                     "failed": "\(results.filter { !$0.passed }.count)"])
    }
}
