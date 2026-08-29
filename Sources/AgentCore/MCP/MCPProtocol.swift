import Foundation

/// Single source of truth for the MCP wire protocol version kist speaks.
///
/// Before this, the two transports pinned DIFFERENT, stale versions ("2024-11-05" stdio, "2025-03-26"
/// HTTP) and DISCARDED the version the server negotiated back — so kist never actually spoke the
/// version the server agreed to.
///
/// We OFFER the latest version kist actually IMPLEMENTS (`2025-06-18`: the stateful `initialize` +
/// `Mcp-Session-Id` handshake this client performs), then READ BACK the `protocolVersion` the server
/// returns and honor it on every subsequent request. A compliant older server answers with the version
/// it supports; we adopt it (that read-back is the real fix). Overridable via `KIST_MCP_PROTOCOL_VERSION`.
///
/// NOTE — honesty over labeling: the newer `2026-07-28` spec makes the transport STATELESS (session ids
/// dropped, per-request identity/capabilities in `_meta`, optional `server/discover`). kist does NOT yet
/// implement that shape, so we deliberately do NOT advertise `2026-07-28` — offering a version we don't
/// speak is a protocol lie a strict stateless server could reject. Implementing the stateless `_meta`
/// path is the follow-up that would let us bump the offer.
public enum MCPProtocol {
    /// Host-owned correlation metadata for tools/call. This is deliberately outside `arguments`,
    /// so model-authored fields cannot replace it.
    public static let correlationMetadataKey = "kist.correlation_id"

    static func toolCallMetadata(correlationID: String?, authorization: String? = nil) -> [String: String]? {
        var metadata: [String: String] = [:]
        if let authorization, !authorization.isEmpty { metadata["authorization"] = authorization }
        if let raw = correlationID, let missionID = PlanExecuteMissionID(rawValue: raw) {
            metadata[correlationMetadataKey] = missionID.rawValue
        }
        return metadata.isEmpty ? nil : metadata
    }

    /// The protocol version offered in `initialize` — the latest revision kist actually implements
    /// (stateful handshake). Env-overridable for pinning / forward-testing a newer server.
    public static let offeredVersion: String = {
        // Live getenv, not ProcessInfo.processInfo.environment: the latter snapshots the whole env on first
        // access process-wide, and reading it here (at static-init) could freeze that snapshot before a
        // later setenv elsewhere — a footgun for env-dependent code/tests. getenv reads just this key, live.
        if let raw = getenv("KIST_MCP_PROTOCOL_VERSION"), let v = String(validatingUTF8: raw), !v.isEmpty { return v }
        return "2025-06-18"
    }()

    /// Per-request protocol-version header (MCP HTTP transport). Carries the NEGOTIATED version and is
    /// sent only AFTER `initialize` completes — never on the initialize request itself (the negotiated
    /// value isn't known yet, and a strict server may validate it).
    public static let versionHeader = "MCP-Protocol-Version"

    public static let clientName = "kist"
    public static let clientVersion = "1.0"

    /// Standard `initialize` params, shared by both transports.
    public static func initializeParams() -> [String: Any] {
        [
            "protocolVersion": offeredVersion,
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": clientName, "version": clientVersion],
        ]
    }

    /// The version the server negotiated (its `initialize` result), or our offered version if the
    /// server didn't specify one. This is what a compliant client must use on subsequent requests.
    public static func negotiatedVersion(from initializeResult: [String: Any]) -> String {
        if let v = initializeResult["protocolVersion"] as? String, !v.isEmpty { return v }
        return offeredVersion
    }
}
