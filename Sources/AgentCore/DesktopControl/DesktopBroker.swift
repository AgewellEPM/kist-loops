import Foundation

/// The desktop-actuation abstraction. `RealDesktopActuator` (CGEvent/AXUIElement/CGDisplayCreateImage) lives
/// in the `kist-control` executable target. NOTE (honest, current state): the legacy in-process
/// `DesktopControlTool` in AgentCore STILL holds equivalent primitives for the not-yet-cut-over armed path;
/// the END-STATE removes those from AgentCore so the coding `kist` binary contains no injection primitives —
/// tracked as the client-cutover step in docs/kist/KIST_CONTROL_SPLIT_IDENTITY_PLAN.md. Mocks live here for tests.
public protocol DesktopActuator: Sendable {
    /// Execute one already-authorized action. Implementations preflight the matching TCC grant and return a
    /// typed failure (never crash / never silently no-op) when the permission is absent.
    func perform(_ request: DesktopActionRequest) -> DesktopActionResponse
}

/// The connecting peer's identity, as the transport resolves it (audit token → SecCode on macOS). Kept
/// transport-agnostic so BrokerCore's auth decision is pure + unit-testable.
public struct DesktopPeer: Sendable, Equatable {
    public var uid: uid_t
    public var authenticated: Bool     // did the peer satisfy the pinned code-signing requirement?
    public var describedBy: String     // for logging: signing id / path / "unsigned-dev"
    public init(uid: uid_t, authenticated: Bool, describedBy: String) {
        self.uid = uid; self.authenticated = authenticated; self.describedBy = describedBy
    }
}

/// The SECURITY-CRITICAL heart of the broker, kept PURE so every gate is unit-tested:
///   authenticate peer  →  same uid  →  wire-version compatible  →  ONLY THEN actuate.
/// Any failing gate returns a typed failure and NEVER reaches the actuator. Fail-closed throughout.
public struct BrokerCore: Sendable {
    private let actuator: DesktopActuator
    private let expectedUID: uid_t

    public init(actuator: DesktopActuator, expectedUID: uid_t) {
        self.actuator = actuator
        self.expectedUID = expectedUID
    }

    public func handle(_ request: DesktopActionRequest, from peer: DesktopPeer) -> DesktopActionResponse {
        // GATE 1: the peer must have satisfied the pinned code-signing requirement (confused-deputy defense).
        guard peer.authenticated else {
            return .failure(id: request.id, .unauthorizedPeer,
                            "connecting process failed code-signature authentication (\(peer.describedBy))")
        }
        // GATE 2: same console user only — never actuate on behalf of another uid.
        guard peer.uid == expectedUID else {
            return .failure(id: request.id, .unauthorizedPeer,
                            "peer uid \(peer.uid) != broker uid \(expectedUID)")
        }
        // GATE 3: refuse an incompatible wire major (fail-closed rather than misinterpret).
        guard request.version == KistControlProtocol.version else {
            return .failure(id: request.id, .versionMismatch,
                            "client wire version \(request.version) != broker \(KistControlProtocol.version)")
        }
        // GATE 4: basic structural validity for coordinate-bearing actions.
        if let reason = Self.structuralRefusal(request) {
            return .failure(id: request.id, .invalidRequest, reason)
        }
        // Authorized + valid ⇒ actuate (the actuator still preflights the concrete TCC grant per kind).
        return actuator.perform(request)
    }

    /// Pure request validation — missing/contradictory params fail BEFORE any OS call.
    static func structuralRefusal(_ r: DesktopActionRequest) -> String? {
        switch r.kind {
        case .move, .click, .doubleClick, .rightClick:
            if r.x == nil || r.y == nil { return "\(r.kind.rawValue) requires x and y" }
        case .drag:
            if r.x == nil || r.y == nil || r.dx == nil || r.dy == nil { return "drag requires x,y,dx,dy" }
        case .scroll:
            if r.dx == nil && r.dy == nil { return "scroll requires dx and/or dy" }
        case .type:
            if (r.text ?? "").isEmpty { return "type requires non-empty text" }
        case .key:
            if r.keys.isEmpty { return "key requires at least one key" }
        case .screenshot, .screenSize, .mousePosition:
            break
        }
        if r.display < 0 { return "display index must be >= 0" }
        return nil
    }
}

/// Records requests + returns scripted responses. For unit tests only.
public final class MockDesktopActuator: DesktopActuator, @unchecked Sendable {
    public private(set) var performed: [DesktopActionRequest] = []
    private let responder: (DesktopActionRequest) -> DesktopActionResponse
    public init(responder: @escaping (DesktopActionRequest) -> DesktopActionResponse = { .init(id: $0.id, ok: true, message: "mock") }) {
        self.responder = responder
    }
    public func perform(_ request: DesktopActionRequest) -> DesktopActionResponse {
        performed.append(request)
        return responder(request)
    }
}
