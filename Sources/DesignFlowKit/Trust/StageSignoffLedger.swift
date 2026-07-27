import Foundation
import AgentCore

/// A tamper-evident, ForgeSeal-sealed signoff chain for DesignFlow stages.
///
/// WHY NOT FleetSignoffLedger.record: that ledger is the fleet's CODE-signoff
/// currency — it admits only a `GroundedVerdict` of `.code` provenance, which is
/// internal to AgentCore and computed by the SymbolicCaptain over code + a real
/// test runner. DesignFlow stages produce design/spec artifacts, not code-with-
/// tests, and cannot (must not) mint that verdict from outside AgentCore. So this
/// is a SEPARATE, honest ledger built on the SAME public crypto primitives
/// (`ForgeSeal.sign/verify`, `FleetSignoffEntry.computeHash`) with the SAME two
/// guards: a per-entry HMAC seal AND a hash chain. It records MEASURED facts
/// (which artifact committed as which SHA, what merged) — never a verdict.
///
/// FORGE BOUNDARY (belt + suspenders, mirrors the fleet ledger):
///   1. SEAL — each entry carries `ForgeSeal.sign(canonical)`; on load any entry
///      whose seal fails verification is excluded (a hand-written line has no valid
///      HMAC unless it holds this install's protected key).
///   2. CHAIN — `entryHash = SHA256(prevHash + canonical)`, genesis prevHash "".
///      Any break drops that entry and everything after it (fail-closed).
public struct StageSignoff: Codable, Equatable, Sendable {
    public var seq: Int
    public var prevHash: String
    public var projectID: String
    public var stageRaw: String
    public var artifactPath: String
    public var commitSHA: String
    public var artifactHash: String
    public var committedPaths: [String]
    public var recordedAtEpoch: Int64
    public var entryHash: String
    public var seal: String?

    public var stage: AgentKind? { AgentKind(rawValue: stageRaw) }

    /// Injective canonical string over every identity-critical field. Free text is
    /// ForgeSeal.field-escaped so `|`/`=` inside a value can't shift boundaries.
    /// `artifactHash` binds the seal to the artifact's actual bytes, not just its path.
    public var canonical: String {
        [
            "seq=\(seq)",
            "prev=\(ForgeSeal.field(prevHash))",
            "project=\(ForgeSeal.field(projectID))",
            "stage=\(ForgeSeal.field(stageRaw))",
            "artifact=\(ForgeSeal.field(artifactPath))",
            "commit=\(ForgeSeal.field(commitSHA))",
            "ahash=\(ForgeSeal.field(artifactHash))",
            "paths=\(ForgeSeal.field(committedPaths.joined(separator: ",")))",
            "at=\(recordedAtEpoch)",
        ].joined(separator: "|")
    }

    public var sealValid: Bool {
        guard let s = seal, !s.isEmpty else { return false }
        return ForgeSeal.verify(canonical, seal: s)
    }

    /// True iff this entry's stored hash matches the recomputed chain link.
    public func chainValid(prev: String) -> Bool {
        entryHash == FleetSignoffEntry.computeHash(prevHash: prev, canonical: canonical)
    }
}

public struct StageSignoffLedger: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public enum LedgerError: Error, CustomStringConvertible {
        case writeFailed(String)
        case unsealed
        case chainBrokeOnAppend
        public var description: String {
            switch self {
            case let .writeFailed(m): return "signoff write failed: \(m)"
            case .unsealed: return "signoff seal is empty — no ForgeSeal key; refusing to record an unsealed signoff"
            case .chainBrokeOnAppend: return "appended signoff did not verify as the new chain tail"
            }
        }
    }

    /// Every VALID entry: the longest prefix that is seal-valid, chain-intact, and
    /// monotone in seq/prevHash. Any break truncates the tail (fail-closed).
    public func entries() -> [StageSignoff] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var result: [StageSignoff] = []
        var prev = ""
        var expectedSeq = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let e = try? decoder.decode(StageSignoff.self, from: Data(line.utf8)) else { break }
            guard e.seq == expectedSeq, e.prevHash == prev, e.sealValid, e.chainValid(prev: prev) else { break }
            result.append(e)
            prev = e.entryHash
            expectedSeq += 1
        }
        return result
    }

    /// The seq of the first broken link (seal or chain), or nil if the whole file is intact.
    public func verifyChain() -> Int? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        var prev = ""
        var expectedSeq = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let e = try? decoder.decode(StageSignoff.self, from: Data(line.utf8)) else { return expectedSeq }
            guard e.seq == expectedSeq, e.prevHash == prev, e.sealValid, e.chainValid(prev: prev) else { return expectedSeq }
            prev = e.entryHash
            expectedSeq += 1
        }
        return nil
    }

    /// Append a sealed signoff for a completed stage. seq/prevHash are derived from
    /// the current VALID tail so a tampered middle entry can't be silently extended.
    ///
    /// SINGLE-WRITER INVARIANT (DeepSeek review Finding 3): this read-modify-append is
    /// NOT safe under concurrent writers to the SAME file. The architecture guarantees
    /// a single sequential writer per ledger — the inner pipeline runs stages serially
    /// and each run owns a distinct per-project ledger file, so two appends never race
    /// the same file. If that ever changes, wrap this in an actor or flock the fd.
    @discardableResult
    public func append(projectID: String, stage: AgentKind, artifactPath: String,
                       commitSHA: String, artifactHash: String, committedPaths: [String],
                       atEpoch: Double) throws -> StageSignoff {
        let existing = entries()
        let prev = existing.last?.entryHash ?? ""
        var entry = StageSignoff(
            seq: existing.count, prevHash: prev, projectID: projectID, stageRaw: stage.rawValue,
            artifactPath: artifactPath, commitSHA: commitSHA, artifactHash: artifactHash,
            committedPaths: committedPaths.sorted(),
            recordedAtEpoch: Int64(atEpoch), entryHash: "", seal: nil)
        let canonical = entry.canonical
        entry.entryHash = FleetSignoffEntry.computeHash(prevHash: prev, canonical: canonical)
        let seal = ForgeSeal.sign(canonical)
        // Fail-closed: no ForgeSeal key ⇒ empty seal ⇒ REFUSE (Codex BLOCKER-2). An
        // unsealed signoff must never be written and never let a stage advance.
        guard !seal.isEmpty else { throw LedgerError.unsealed }
        entry.seal = seal

        let data = try JSONEncoder().encode(entry)
        guard var line = String(data: data, encoding: .utf8) else {
            throw LedgerError.writeFailed("encode")
        }
        line += "\n"
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
        } else {
            let prior = (try? Data(contentsOf: fileURL)) ?? Data()
            try (prior + Data(line.utf8)).write(to: fileURL)
        }
        // Verify the appended entry is now the valid tail (seal + chain), else the
        // write did not take — fail-closed rather than return a phantom signoff.
        guard entries().count == existing.count + 1 else { throw LedgerError.chainBrokeOnAppend }
        return entry
    }
}
