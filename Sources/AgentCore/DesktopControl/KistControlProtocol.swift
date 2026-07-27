import Foundation

/// The IPC CONTRACT between `kist` (coding CLI, holds no TCC grants) and `kist-control` (the separately-signed
/// broker that alone holds Accessibility/Screen-Recording and performs desktop actions). See
/// docs/kist/KIST_CONTROL_SPLIT_IDENTITY_PLAN.md for the full architecture (council 2026-07-03).
///
/// This file is the STABLE, transport-agnostic message schema — pure Codable, fully unit-tested, and shared by
/// both binaries. The transport (Unix-domain socket / XPC), the broker's OS primitives, and peer
/// authentication are the signing+hardware-gated pieces built on top; this contract is what they carry.
///
/// SECURITY NOTE: receiving this message NEVER implies authorization. The broker authenticates the connecting
/// peer's code signature (audit token) BEFORE dispatching any action; this schema only frames intent.
public enum KistControlProtocol {
    /// Bump when the wire schema changes incompatibly; the broker refuses a mismatched major.
    public static let version = 1
}

/// A desktop action the broker can perform. Mirrors DesktopControlTool's supported actions, but as a typed,
/// validated value — the coding side constructs it; only the broker (with TCC) executes it.
public enum DesktopActionKind: String, Codable, Sendable, CaseIterable {
    case move, click, doubleClick = "double_click", rightClick = "right_click"
    case drag, scroll, type, key
    case screenshot, screenSize = "screen_size", mousePosition = "mouse_position"

    /// Actions that inject real input (need Accessibility). Screenshot needs Screen-Recording; the reads
    /// (screen_size / mouse_position) need neither. The broker preflights the matching TCC grant per kind.
    public var needsAccessibility: Bool {
        switch self {
        case .move, .click, .doubleClick, .rightClick, .drag, .scroll, .type, .key: return true
        case .screenshot, .screenSize, .mousePosition: return false
        }
    }
    public var needsScreenRecording: Bool { self == .screenshot }
}

/// A single brokered request. `id` correlates the reply; `version` lets the broker reject an incompatible client.
public struct DesktopActionRequest: Codable, Sendable, Equatable {
    public var version: Int
    public var id: String
    public var kind: DesktopActionKind
    public var display: Int          // 0-based display index (multi-display)
    public var x: Int?
    public var y: Int?
    public var dx: Int?
    public var dy: Int?
    public var text: String?         // for `type`
    public var keys: [String]        // for `key` (e.g. ["cmd","c"])
    public var clicks: Int           // click count (1 or 2)

    public init(version: Int = KistControlProtocol.version, id: String, kind: DesktopActionKind,
                display: Int = 0, x: Int? = nil, y: Int? = nil, dx: Int? = nil, dy: Int? = nil,
                text: String? = nil, keys: [String] = [], clicks: Int = 1) {
        self.version = version; self.id = id; self.kind = kind; self.display = display
        self.x = x; self.y = y; self.dx = dx; self.dy = dy; self.text = text; self.keys = keys; self.clicks = clicks
    }
}

/// The broker's reply. `ok=false` carries a machine code + human reason (e.g. permission not granted).
public struct DesktopActionResponse: Codable, Sendable, Equatable {
    public var version: Int
    public var id: String
    public var ok: Bool
    public var code: DesktopActionErrorCode?
    public var message: String
    public var pngBase64: String?    // screenshot payload
    public var width: Int?
    public var height: Int?

    public init(version: Int = KistControlProtocol.version, id: String, ok: Bool,
                code: DesktopActionErrorCode? = nil, message: String = "",
                pngBase64: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.version = version; self.id = id; self.ok = ok; self.code = code
        self.message = message; self.pngBase64 = pngBase64; self.width = width; self.height = height
    }

    public static func failure(id: String, _ code: DesktopActionErrorCode, _ message: String) -> DesktopActionResponse {
        DesktopActionResponse(id: id, ok: false, code: code, message: message)
    }
}

public enum DesktopActionErrorCode: String, Codable, Sendable {
    case accessibilityNotGranted   // broker lacks Accessibility TCC
    case screenRecordingNotGranted // broker lacks Screen-Recording TCC
    case unauthorizedPeer          // the connecting process failed code-signature auth
    case versionMismatch           // client wire version incompatible with the broker
    case invalidRequest            // missing/contradictory params
    case unsupportedPlatform       // non-macOS broker
    case actuationFailed           // the OS primitive returned failure
}

/// Length-prefixed framing for a stream transport (Unix-domain socket): a 4-byte big-endian UInt32 length
/// followed by that many JSON bytes. Pure + testable; the socket layer just does read/write of these frames.
public enum KistControlFraming {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try JSONEncoder().encode(value)
        var length = UInt32(body.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(body)
        return out
    }

    /// Decode one frame from `buffer`. Returns the value + bytes consumed, or nil if a full frame isn't buffered
    /// yet. Throws on a corrupt/oversized frame (fail-closed).
    public static func decode<T: Decodable>(_ type: T.Type, from buffer: Data,
                                            maxBytes: Int = 64 * 1024 * 1024) throws -> (value: T, consumed: Int)? {
        guard buffer.count >= 4 else { return nil }
        let len = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if Int(len) > maxBytes { throw KistControlFramingError.frameTooLarge(Int(len)) }
        let total = 4 + Int(len)
        guard buffer.count >= total else { return nil }
        let body = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + total))
        let value = try JSONDecoder().decode(T.self, from: body)
        return (value, total)
    }
}

public enum KistControlFramingError: Error, Equatable { case frameTooLarge(Int) }
