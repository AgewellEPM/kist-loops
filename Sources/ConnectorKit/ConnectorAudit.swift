import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Tamper-evident "doing history": every connector invocation is recorded, sealed
/// (ForgeSeal HMAC), and hash-chained — the same forge-proof discipline as the fleet
/// signoff ledger. Secrets are NEVER stored: the input is recorded as a SHA-256 hash,
/// not raw bytes, so tokens/PII can't leak into the audit file.
public struct ConnectorAuditEntry: Codable, Sendable, Equatable {
    public var seq: Int
    public var prevHash: String
    public var connector: String
    public var action: String
    public var inputHash: String      // SHA-256 of the input, not the input itself
    public var statusCode: Int
    public var ok: Bool
    public var atEpoch: Int64
    public var entryHash: String
    public var seal: String?
    public var phase: String? = nil
    public var invocationID: String? = nil

    public var canonical: String {
        var fields = [
            "seq=\(seq)",
            "prev=\(ForgeSeal.field(prevHash))",
            "connector=\(ForgeSeal.field(connector))",
            "action=\(ForgeSeal.field(action))",
            "input=\(ForgeSeal.field(inputHash))",
            "status=\(statusCode)",
            "ok=\(ok ? 1 : 0)",
            "at=\(atEpoch)",
        ]
        if let phase { fields.append("phase=\(ForgeSeal.field(phase))") }
        if let invocationID { fields.append("invocation=\(ForgeSeal.field(invocationID))") }
        return fields.joined(separator: "|")
    }

    public var sealValid: Bool {
        guard let s = seal, !s.isEmpty else { return false }
        return ForgeSeal.verify(canonical, seal: s)
    }
    public func chainValid(prev: String) -> Bool {
        entryHash == FleetSignoffEntry.computeHash(prevHash: prev, canonical: canonical)
    }
}

public struct ConnectorAudit: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public enum AuditError: Error, CustomStringConvertible {
        case unsealed
        case invalidHistory
        case io(Int32)
        public var description: String {
            switch self {
            case .unsealed: return "audit seal empty (no ForgeSeal key) — refusing to record"
            case .invalidHistory: return "connector audit history is incomplete or invalid"
            case .io(let code): return "connector audit could not be persisted (errno \(code))"
            }
        }
    }

    /// SHA-256 (base64) of the input map — stable, secret-free.
    public static func hashInput(_ input: [String: String]) -> String {
        // Length prefixes make boundaries unambiguous even when values contain delimiters.
        let canonical = input.keys.sorted().map { key in
            let value = input[key] ?? ""
            return "\(key.utf8.count):\(key)\(value.utf8.count):\(value)"
        }.joined()
        return FleetSignoffEntry.computeHash(prevHash: "", canonical: canonical)
    }

    /// The longest valid (seal + chain intact) prefix. Any break truncates the tail.
    public func entries() -> [ConnectorAuditEntry] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        var out: [ConnectorAuditEntry] = []
        var prev = ""
        var seq = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let e = try? dec.decode(ConnectorAuditEntry.self, from: Data(line.utf8)) else { break }
            guard e.seq == seq, e.prevHash == prev, e.sealValid, e.chainValid(prev: prev) else { break }
            out.append(e); prev = e.entryHash; seq += 1
        }
        return out
    }

    public func verifyChain() -> Int? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let dec = JSONDecoder()
        var prev = ""
        var seq = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let e = try? dec.decode(ConnectorAuditEntry.self, from: Data(line.utf8)) else { return seq }
            guard e.seq == seq, e.prevHash == prev, e.sealValid, e.chainValid(prev: prev) else { return seq }
            prev = e.entryHash; seq += 1
        }
        return nil
    }

    @discardableResult
    public func record(connector: String, action: String, input: [String: String],
                       statusCode: Int, ok: Bool, atEpoch: Double,
                       phase: String? = nil, invocationID: String? = nil) throws -> ConnectorAuditEntry {
        let lockFD = open(fileURL.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard lockFD >= 0 else { throw AuditError.io(errno) }
        defer { _ = close(lockFD) }
        var locked: Int32
        repeat { locked = flock(lockFD, LOCK_EX) } while locked < 0 && errno == EINTR
        guard locked == 0 else { throw AuditError.io(errno) }
        defer { _ = flock(lockFD, LOCK_UN) }
        let existing = try validatedEntries()
        let prev = existing.last?.entryHash ?? ""
        var e = ConnectorAuditEntry(
            seq: existing.count, prevHash: prev, connector: connector, action: action,
            inputHash: Self.hashInput(input), statusCode: statusCode, ok: ok,
            atEpoch: Int64(atEpoch), entryHash: "", seal: nil)
        e.phase = phase
        e.invocationID = invocationID
        let canonical = e.canonical
        e.entryHash = FleetSignoffEntry.computeHash(prevHash: prev, canonical: canonical)
        let seal = ForgeSeal.sign(canonical)
        guard !seal.isEmpty else { throw AuditError.unsealed }
        e.seal = seal
        let line = (try JSONEncoder().encode(e))
        var text = String(data: line, encoding: .utf8) ?? ""
        text += "\n"
        let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw AuditError.io(errno) }
        defer { _ = close(fd) }
        try Data(text.utf8).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AuditError.io(errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw AuditError.io(errno) }
        let parent = open(fileURL.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw AuditError.io(errno) }
        defer { _ = close(parent) }
        guard fsync(parent) == 0 else { throw AuditError.io(errno) }
        return e
    }

    private func validatedEntries() throws -> [ConnectorAuditEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        guard text.isEmpty || text.hasSuffix("\n") else { throw AuditError.invalidHistory }
        var result: [ConnectorAuditEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let entry = try JSONDecoder().decode(ConnectorAuditEntry.self, from: Data(line.utf8))
            let previous = result.last?.entryHash ?? ""
            guard entry.seq == result.count, entry.prevHash == previous,
                  entry.sealValid, entry.chainValid(prev: previous) else { throw AuditError.invalidHistory }
            result.append(entry)
        }
        return result
    }
}
