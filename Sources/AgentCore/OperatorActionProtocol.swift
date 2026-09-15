import Foundation

/// One operator-authorized host action. Model output supplies only the operation arguments;
/// the worker binds and reserves the request before publishing an out-of-workspace permit.
public enum OperatorActionDisposition: String, Codable, Sendable {
    case observed, denied, unknown
}

public struct OperatorActionDirectoryEntry: Codable, Sendable, Equatable {
    public let name: String
    public let kind: String
}

public struct OperatorActionResponse: Codable, Sendable {
    public let schema_version: Int
    public let disposition: OperatorActionDisposition
    public let code: String
    public let message: String
    public let accepted: Bool
    public let action_id: String?
    public let claim_id: String?
    public let mission_id: String?
    public let project_root: String?
    public let workspace_root: String?
    public let policy_sha256: String?
    public let request_sha256: String?
    public let operation: String?
    public let root_scope: String?
    public let observed_at: String
    public let evidence: [String: String]
    public let content: String?
    public let entries: [OperatorActionDirectoryEntry]?

    public var exitCode: Int32 {
        switch disposition { case .observed: return 0; case .denied: return 2; case .unknown: return 3 }
    }

    public static func denied(code: String, message: String) -> Self {
        Self.make(.denied, code: code, message: message, now: Date())
    }

    static func make(_ disposition: OperatorActionDisposition, code: String, message: String,
                     request: OperatorActionRequest? = nil, digest: String? = nil, now: Date,
                     evidence: [String: String] = [:], content: String? = nil,
                     entries: [OperatorActionDirectoryEntry]? = nil) -> Self {
        Self(schema_version: 1, disposition: disposition, code: code, message: message,
             accepted: false, action_id: request?.action_id, claim_id: request?.claim_id,
             mission_id: request?.mission_id, project_root: request?.project_root,
             workspace_root: request?.workspace_root, policy_sha256: request?.policy_sha256,
             request_sha256: digest, operation: request?.operation,
             root_scope: request?.root_scope,
             observed_at: ISO8601DateFormatter().string(from: now), evidence: evidence,
             content: content, entries: entries)
    }
}

struct OperatorActionRequest: Decodable, Sendable {
    let schema_version: Int
    let action_id: String
    let claim_id: String
    let mission_id: String
    let project_root: String
    let workspace_root: String
    let policy_sha256: String
    let operation: String
    let root_scope: String
    let arguments: [String: SMLValue]

    static let keys: Set<String> = ["schema_version", "action_id", "claim_id", "mission_id",
        "project_root", "workspace_root", "policy_sha256", "operation", "root_scope", "arguments"]
}

/// Permit bytes are read only from the host-selected private directory. They are never
/// accepted from the request, workspace, environment, stdout, or a model's claimed approval.
struct OperatorActionPermit: Decodable, Sendable {
    let schema_version: Int
    let issuer: String
    let operator_request_id: String
    let action_id: String
    let claim_id: String
    let mission_id: String
    let project_root: String
    let project_device: String
    let project_inode: String
    let workspace_root: String
    let workspace_device: String
    let workspace_inode: String
    let root_scope: String
    let allowed_root: String
    let allowed_root_device: String
    let allowed_root_inode: String
    let access: String
    let policy_sha256: String
    let request_sha256: String
    let issued_at: String
    let expires_at: String

    static let keys: Set<String> = ["schema_version", "issuer", "operator_request_id", "action_id",
        "claim_id", "mission_id", "project_root", "project_device", "project_inode", "workspace_root",
        "workspace_device", "workspace_inode", "root_scope", "allowed_root", "allowed_root_device",
        "allowed_root_inode", "access", "policy_sha256", "request_sha256", "issued_at", "expires_at"]
}

enum OperatorActionValidation {
    static func decode<T: Decodable>(_ type: T.Type, data: Data, keys: Set<String>, maximumBytes: Int) throws -> T {
        let object = try SMLWireCodec.decodeArbitraryJSONObject(from: data,
            limits: .init(maximumBytes: maximumBytes, maximumDepth: 4, maximumNodes: 512))
        guard Set(object.keys) == keys else { throw Failure.invalid }
        return try JSONDecoder().decode(type, from: data)
    }

    enum Failure: Error { case invalid, unsafe, stale, replayed, io, unsupported }

    static func uuid(_ text: String) -> UUID? {
        guard text.utf8.count == 36, let value = UUID(uuidString: text),
              value.uuidString.caseInsensitiveCompare(text) == .orderedSame else { return nil }
        return value
    }

    static func identifier(_ text: String) -> Bool {
        (1...100).contains(text.utf8.count) && text.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func digest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func date(_ text: String) -> Date? {
        guard text.utf8.count <= 40 else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func argument(_ args: [String: SMLValue], _ key: String) throws -> String {
        guard case .string(let value) = args[key] else { throw Failure.invalid }
        return value
    }

    static func relativePath(_ path: String, allowRoot: Bool = false) throws {
        if allowRoot && path == "." { return }
        guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"),
              path == path.precomposedStringWithCanonicalMapping,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.invalid }
        let protected: Set<String> = [".git", ".kist", ".claude", ".codex", ".ssh", ".aws", ".gnupg",
            ".operator-action", "authorities"]
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= 24, components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !protected.contains($0.lowercased())
                && !$0.lowercased().hasPrefix(".env")
        }) else { throw Failure.invalid }
    }

    static func mutationPath(_ path: String) throws {
        try relativePath(path)
        let controls: Set<String> = ["agents.md", "claude.md", "mission_lock.md", "blueprint.json",
            "director_state.json", "director_heartbeat.json", "stage_state.json", "worker_heartbeat.json",
            "test_evidence.md", "stage_reports"]
        guard !path.split(separator: "/").contains(where: { controls.contains($0.lowercased()) }) else {
            throw Failure.unsafe
        }
    }
}
