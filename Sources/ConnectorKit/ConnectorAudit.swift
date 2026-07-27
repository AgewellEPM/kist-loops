import Foundation
import AgentCore

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

    public var canonical: String {
        [
            "seq=\(seq)",
            "prev=\(ForgeSeal.field(prevHash))",
            "connector=\(ForgeSeal.field(connector))",
            "action=\(ForgeSeal.field(action))",
            "input=\(ForgeSeal.field(inputHash))",
            "status=\(statusCode)",
            "ok=\(ok ? 1 : 0)",
            "at=\(atEpoch)",
        ].joined(separator: "|")
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
        public var description: String {
            switch self { case .unsealed: return "audit seal empty (no ForgeSeal key) — refusing to record" }
        }
    }

    /// SHA-256 (base64) of the input map — stable, secret-free.
    public static func hashInput(_ input: [String: String]) -> String {
        let canonical = input.keys.sorted().map { "\($0)=\(input[$0] ?? "")" }.joined(separator: "&")
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
                       statusCode: Int, ok: Bool, atEpoch: Double) throws -> ConnectorAuditEntry {
        let existing = entries()
        let prev = existing.last?.entryHash ?? ""
        var e = ConnectorAuditEntry(
            seq: existing.count, prevHash: prev, connector: connector, action: action,
            inputHash: Self.hashInput(input), statusCode: statusCode, ok: ok,
            atEpoch: Int64(atEpoch), entryHash: "", seal: nil)
        let canonical = e.canonical
        e.entryHash = FleetSignoffEntry.computeHash(prevHash: prev, canonical: canonical)
        let seal = ForgeSeal.sign(canonical)
        guard !seal.isEmpty else { throw AuditError.unsealed }
        e.seal = seal
        let line = (try JSONEncoder().encode(e))
        var text = String(data: line, encoding: .utf8) ?? ""
        text += "\n"
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
        } else {
            let prior = (try? Data(contentsOf: fileURL)) ?? Data()
            try (prior + Data(text.utf8)).write(to: fileURL)
        }
        return e
    }
}
