import Foundation

/// THE FLEET SIGNOFF LEDGER — the foreman's forge-proof attestation that a fleet subtask is REALLY
/// done, not merely claimed. The internal tier of the two-tier signoff model (the EXTERNAL Ed25519
/// promotion gate composes only downstream, at deploy — Stage 3).
///
/// WHY ForgeSeal HMAC, NOT a new Ed25519 keypair: the captain is INTERNAL to the build pipeline; it is
/// the only signer AND the verifier runs on the SAME install. That is exactly the symmetric-key (HMAC)
/// trust model, not asymmetric. So this ledger seals with ForgeSeal (per-install key, this device only).
///
/// THE NO-FORGE SEAM: `record(...)` is the SOLE admission path and it REQUIRES a `GroundedVerdict`. A
/// GroundedVerdict's init is PRIVATE, and this ledger admits only `.code` provenance: the internal
/// deterministic SymbolicCaptain referee over MEASURED evidence. Public non-code greens are useful
/// verdicts, but they cannot sign off code. There is NO string/bool overload. A bragging caller reaches
/// AT MOST `.driftFlagged`, which this ledger REJECTS (a no-op).
///
/// FORGE BOUNDARY — TWO independent guards (belt + suspenders):
///   1. SEAL (per-entry HMAC): every admitted entry is sealed with ForgeSeal.sign(canonical). On LOAD,
///      any entry whose seal fails verification is excluded from `entries` (a hand-written signoff.jsonl
///      carries no valid HMAC tag unless it has this install's protected ForgeSeal key).
///   2. CHAIN (hash-chain): every entry stores `prevHash` (prior entry's `entryHash`) and
///      `entryHash = SHA256(prevHash + canonical)`. Genesis prevHash = "". `verifyChain()` returns the
///      seq of the FIRST broken link/payload, or nil if intact. ANY break ⇒ ZERO valid signoffs.
///
/// DETERMINISM: `recordedAt`'s canonical form truncates to integer seconds so ISO-8601 encode/decode
/// skew can't break the seal. The chain hash is a pure function of the canonical bytes — no clock, no I/O.
///
/// CONCURRENCY: the Foreman is still the intended single writer, but the port also serializes every
/// public method with an internal lock. Concurrent `record` calls cannot interleave a stale seq/prevHash.
///
/// Ported from TinkySDR's Captain (Stage 1.5): SHA256 via MythosCrypto (swift-crypto); @MainActor dropped.
///
/// LABEL: PROTOTYPE

// MARK: - Entry (hash-chained + ForgeSeal-sealed)

/// One forge-proof signoff in a fleet's chain. Codable for JSONL persistence. `.green` verdict is an
/// invariant of admission (enforced by `record`), but the field is persisted so the chain hash covers
/// it and a flip-to-green tamper is caught by BOTH the seal and the chain.
public struct FleetSignoffEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: Int { seq }
    public let seq: Int                       // monotone position in the chain
    public let prevHash: String               // prior entry's entryHash; "" at genesis
    public let goalID: String                 // the fleet's goal / baton identity
    public let agentID: UUID                   // the agent this signoff certifies
    public let branch: String                 // wt.branch — the merge target
    public let buildID: String                 // canonical build identity
    public let verdict: CaptainJudgment.Verdict   // MUST be .green to have been admitted
    public let testExitCode: Int32            // MEASURED evidence (not a bool)
    public let changedLines: Int
    public let maxFileLines: Int
    public let outOfScopeCount: Int
    public let summary: String                 // foreman's measured note
    public let recordedAt: Date                // caller-supplied wall clock of the write
    public let entryHash: String               // SHA256(prevHash + canonical) — tamper-evident
    public var seal: String?                   // ForgeSeal.sign(canonical) — the SIGNATURE

    enum CodingKeys: String, CodingKey {
        case seq, prevHash, goalID, agentID, branch, buildID, verdict
        case testExitCode, changedLines, maxFileLines, outOfScopeCount
        case summary, recordedAt, entryHash, seal
    }

    public init(seq: Int, prevHash: String, goalID: String, agentID: UUID, branch: String,
                buildID: String, verdict: CaptainJudgment.Verdict, testExitCode: Int32,
                changedLines: Int, maxFileLines: Int, outOfScopeCount: Int, summary: String,
                recordedAt: Date, entryHash: String, seal: String?) {
        self.seq = seq
        self.prevHash = prevHash
        self.goalID = goalID
        self.agentID = agentID
        self.branch = branch
        self.buildID = buildID
        self.verdict = verdict
        self.testExitCode = testExitCode
        self.changedLines = changedLines
        self.maxFileLines = maxFileLines
        self.outOfScopeCount = outOfScopeCount
        self.summary = summary
        self.recordedAt = recordedAt
        self.entryHash = entryHash
        self.seal = seal
    }

    /// Additive decode: every newer field is `decodeIfPresent` with a safe default so an older on-disk
    /// schema still loads (then fails the seal/chain if its shape no longer matches). The
    /// identity-critical genesis fields (seq/prevHash/entryHash) are required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        prevHash = try c.decode(String.self, forKey: .prevHash)
        entryHash = try c.decode(String.self, forKey: .entryHash)
        goalID = try c.decodeIfPresent(String.self, forKey: .goalID) ?? ""
        agentID = try c.decodeIfPresent(UUID.self, forKey: .agentID) ?? UUID()
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        buildID = try c.decodeIfPresent(String.self, forKey: .buildID) ?? ""
        verdict = try c.decodeIfPresent(CaptainJudgment.Verdict.self, forKey: .verdict) ?? .blocked
        testExitCode = try c.decodeIfPresent(Int32.self, forKey: .testExitCode) ?? -1
        changedLines = try c.decodeIfPresent(Int.self, forKey: .changedLines) ?? 0
        maxFileLines = try c.decodeIfPresent(Int.self, forKey: .maxFileLines) ?? 0
        outOfScopeCount = try c.decodeIfPresent(Int.self, forKey: .outOfScopeCount) ?? 0
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        recordedAt = try c.decodeIfPresent(Date.self, forKey: .recordedAt) ?? Date(timeIntervalSince1970: 0)
        seal = try c.decodeIfPresent(String.self, forKey: .seal)
    }

    // MARK: Canonical / seal / hash

    /// The injective canonical string covering every identity-critical field. Free text is
    /// ForgeSeal.field-escaped so a `|` or `=` inside a value cannot shift field boundaries. Integer
    /// seconds for recordedAt (ISO-8601 precision safety).
    public var canonical: String {
        let secs = Int64(recordedAt.timeIntervalSince1970)
        return [
            "seq=\(seq)",
            "prev=\(ForgeSeal.field(prevHash))",
            "goal=\(ForgeSeal.field(goalID))",
            "agent=\(agentID.uuidString)",
            "branch=\(ForgeSeal.field(branch))",
            "build=\(ForgeSeal.field(buildID))",
            "verdict=\(verdict.rawValue)",
            "exit=\(testExitCode)",
            "changed=\(changedLines)",
            "maxfile=\(maxFileLines)",
            "oos=\(outOfScopeCount)",
            "summary=\(ForgeSeal.field(summary))",
            "at=\(secs)",
        ].joined(separator: "|")
    }

    /// True iff the entry carries a valid ForgeSeal over its own canonical bytes.
    public var sealValid: Bool {
        guard let s = seal, !s.isEmpty else { return false }
        return ForgeSeal.verify(canonical, seal: s)
    }

    /// Pure hash of `prevHash + canonical` — the chain link. Used by both the writer (to stamp) and
    /// `verifyChain` (to detect tampering). No clock, no I/O.
    public static func computeHash(prevHash: String, canonical: String) -> String {
        var input = Data(prevHash.utf8)
        input.append(Data(canonical.utf8))
        return MythosCrypto.sha256(input).base64EncodedString()
    }
}

// MARK: - Signoff (the proof stamped into a cell / baton contribution)

/// The compact proof the captain stamps onto an agent cell / baton contribution. "Really done" = this
/// present AND `ledger.verifyChain() == nil` AND `entries[ledgerSeq].entryHash == ledgerEntryHash` AND
/// that entry's `sealValid`. The forge-proof link back to the chain is `ledgerEntryHash` (tamper-evident
/// — editing the ledger row changes it).
public struct Signoff: Codable, Equatable, Sendable {
    public let ledgerSeq: Int                 // FleetSignoffEntry.seq the foreman appended
    public let ledgerEntryHash: String        // == FleetSignoffEntry.entryHash; tamper link
    public let verdict: CaptainJudgment.Verdict
    public let testExitCode: Int32
    public let signedAtEpoch: Double

    enum CodingKeys: String, CodingKey {
        case ledgerSeq, ledgerEntryHash, verdict, testExitCode, signedAtEpoch
    }

    public init(ledgerSeq: Int, ledgerEntryHash: String, verdict: CaptainJudgment.Verdict,
                testExitCode: Int32, signedAtEpoch: Double) {
        self.ledgerSeq = ledgerSeq
        self.ledgerEntryHash = ledgerEntryHash
        self.verdict = verdict
        self.testExitCode = testExitCode
        self.signedAtEpoch = signedAtEpoch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ledgerSeq = try c.decode(Int.self, forKey: .ledgerSeq)
        ledgerEntryHash = try c.decode(String.self, forKey: .ledgerEntryHash)
        verdict = try c.decodeIfPresent(CaptainJudgment.Verdict.self, forKey: .verdict) ?? .blocked
        testExitCode = try c.decodeIfPresent(Int32.self, forKey: .testExitCode) ?? -1
        signedAtEpoch = try c.decodeIfPresent(Double.self, forKey: .signedAtEpoch) ?? 0
    }
}

// MARK: - The measured evidence the foreman supplies alongside the verdict

/// The MEASURED facts a signoff records. Separate from the `GroundedVerdict` so the ledger persists the
/// numbers the foreman observed (exit code, diff size, scope escapes) for audit, while the GREEN
/// decision itself can only come from the referee. These are descriptive evidence, NOT the admission gate.
public struct FleetSignoffEvidence: Equatable, Sendable {
    public let buildID: String
    public let testExitCode: Int32
    public let changedLines: Int
    public let maxFileLines: Int
    public let outOfScopeCount: Int
    public let summary: String

    public init(buildID: String, testExitCode: Int32, changedLines: Int = 0,
                maxFileLines: Int = 0, outOfScopeCount: Int = 0, summary: String = "") {
        self.buildID = buildID
        self.testExitCode = testExitCode
        self.changedLines = changedLines
        self.maxFileLines = maxFileLines
        self.outOfScopeCount = outOfScopeCount
        self.summary = summary
    }
}

// MARK: - Ledger

/// The fleet's forge-proof signoff chain. The Foreman is the intended single writer, but every public
/// method is serialized by an internal recursive lock (Codex MED — faithfully replacing the original's
/// `@MainActor` serialization that the cross-platform port dropped), so concurrent `record(...)` calls
/// can never interleave a stale `prevHash`/`seq` and corrupt the chain. Persists JSONL to its own
/// per-fleet directory. The only mutator is `record(...)`; there is intentionally no setter, delete, or
/// string overload. `@unchecked Sendable` is justified BY the lock guarding all mutable state.
public final class FleetSignoffLedger: @unchecked Sendable {

    private let fileURL: URL
    /// Serializes all chain reads/writes. Recursive because read accessors compose (entries → verifyChain).
    private let lock = NSRecursiveLock()
    /// In-memory mirror of the on-disk chain (the on-disk file is authoritative on load; thereafter
    /// memory leads and is rewritten on every append).
    private var chain: [FleetSignoffEntry] = []

    /// `baseDir` is the test seam. Production default is a per-fleet directory, separate custody from
    /// the blackboard so a torn blackboard write can't corrupt the proof chain.
    public init(baseDir: URL) {
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        fileURL = baseDir.appendingPathComponent("signoff.jsonl")
        load()
    }

    // MARK: The ONLY admission path (the no-forge seam)

    /// Append a signoff — but ONLY if `grounded` is a code-refereed `.green`. Anything else
    /// (`.driftFlagged` / `.blocked` / a public non-code green) is a NO-OP returning nil: a
    /// claimed-but-unverified subtask cannot enter shared memory or unlock a merge.
    ///
    /// HONESTY: there is no overload that takes a bare verdict, a bool, or a string. To call this you
    /// must HOLD a `GroundedVerdict`, and to hold a `.green` one you must have gone through
    /// `GroundedVerdict.fromCode(facts)` — the referee over measured evidence.
    ///
    /// On admission the entry is hash-chained onto the prior entry and sealed with ForgeSeal. Returns
    /// the persisted entry, or nil if the verdict wasn't a code green, the seal could not be minted, or
    /// the ledger write failed.
    @discardableResult
    public func record(goalID: String, agentID: UUID, branch: String,
                       grounded: GroundedVerdict, evidence: FleetSignoffEvidence,
                       atEpoch: Double) -> FleetSignoffEntry? {
        lock.lock(); defer { lock.unlock() }
        // GATE: only a code-refereed .green is admissible. Public game/text verdicts cannot sign off
        // code work even when they are green.
        guard grounded.isAdmissibleCodeGreen else { return nil }

        let seq = chain.count
        let prevHash = chain.last?.entryHash ?? ""   // genesis link is "" per contract
        let recordedAt = Date(timeIntervalSince1970: atEpoch)

        // Build the entry with a placeholder hash so we can derive the canonical, then stamp the real
        // hash + seal. (canonical does NOT include entryHash.)
        let base = FleetSignoffEntry(
            seq: seq, prevHash: prevHash, goalID: goalID, agentID: agentID,
            branch: branch, buildID: evidence.buildID, verdict: .green,
            testExitCode: evidence.testExitCode, changedLines: evidence.changedLines,
            maxFileLines: evidence.maxFileLines, outOfScopeCount: evidence.outOfScopeCount,
            summary: evidence.summary, recordedAt: recordedAt, entryHash: "", seal: nil)

        let canonical = base.canonical
        let entryHash = FleetSignoffEntry.computeHash(prevHash: prevHash, canonical: canonical)
        let seal = ForgeSeal.sign(canonical)
        guard !seal.isEmpty else { return nil }

        let entry = FleetSignoffEntry(
            seq: seq, prevHash: prevHash, goalID: goalID, agentID: agentID,
            branch: branch, buildID: evidence.buildID, verdict: .green,
            testExitCode: evidence.testExitCode, changedLines: evidence.changedLines,
            maxFileLines: evidence.maxFileLines, outOfScopeCount: evidence.outOfScopeCount,
            summary: evidence.summary, recordedAt: recordedAt, entryHash: entryHash,
            seal: seal)
        guard entry.sealValid else { return nil }

        let next = chain + [entry]
        do {
            try persist(next)
        } catch {
            return nil
        }
        chain = next
        return entry
    }

    /// Mint the compact `Signoff` proof for a freshly recorded entry — the value stamped onto an agent
    /// cell / baton contribution. Pure projection.
    public func signoff(for entry: FleetSignoffEntry, atEpoch: Double) -> Signoff {
        Signoff(ledgerSeq: entry.seq, ledgerEntryHash: entry.entryHash,
                verdict: entry.verdict, testExitCode: entry.testExitCode,
                signedAtEpoch: atEpoch)
    }

    // MARK: Reads

    /// The full chain in append order (raw; callers wanting only trustworthy rows use `entries` or
    /// check `verifyChain()` first).
    public func all() -> [FleetSignoffEntry] { lock.lock(); defer { lock.unlock() }; return chain }

    /// Sealed-AND-chain-intact entries only. If the chain is broken ANYWHERE this returns EMPTY — a
    /// tamper makes the ledger stricter, never looser.
    public var entries: [FleetSignoffEntry] {
        lock.lock(); defer { lock.unlock() }
        guard verifyChain() == nil else { return [] }
        return chain.filter { $0.sealValid }
    }

    /// Convenience alias mirroring the spec's `entries` accessor name.
    public func validEntries() -> [FleetSignoffEntry] { entries }

    /// True iff `agentID` has a trustworthy `.green` signoff: a sealed entry, the whole chain intact,
    /// and the verdict green. A broken chain ⇒ false for every agent (zero valid signoffs).
    public func signedOff(agentID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard verifyChain() == nil else { return false }
        return chain.contains { $0.agentID == agentID && $0.verdict == .green && $0.sealValid }
    }

    /// Same gate scoped to a specific goal — guards against a stale cross-fleet row (defense-in-depth).
    public func signedOff(goalID: String, agentID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard verifyChain() == nil else { return false }
        return chain.contains {
            $0.goalID == goalID && $0.agentID == agentID && $0.verdict == .green && $0.sealValid
        }
    }

    // MARK: Audit

    /// Recompute the chain from genesis. Returns the seq of the FIRST entry that fails its check, or nil
    /// if intact. An entry is broken if EITHER its `prevHash` no longer equals the running hash (link
    /// cut) OR its stored `entryHash` no longer equals the recomputed hash of its own canonical bytes
    /// (payload edited) OR its SEAL is invalid. The FIRST such seq is the tamper point.
    public func verifyChain() -> Int? {
        lock.lock(); defer { lock.unlock() }
        var running = ""   // expected prevHash for the next entry; "" at genesis
        for entry in chain {
            if entry.prevHash != running { return entry.seq }
            let recomputed = FleetSignoffEntry.computeHash(prevHash: entry.prevHash,
                                                           canonical: entry.canonical)
            if recomputed != entry.entryHash { return entry.seq }
            if !entry.sealValid { return entry.seq }
            running = entry.entryHash
        }
        return nil
    }

    // MARK: Persistence (JSONL — one entry per line)

    /// Load the chain from disk. We do NOT silently repair a tampered file — `verifyChain()` is the
    /// auditor, and hiding tamper at load would defeat a tamper-evident ledger. Valid-but-tampered rows
    /// (parse fine, fail the seal/chain) are loaded AS-IS so the audit catches them.
    ///
    /// FAIL-CLOSED on a structurally-broken file (Codex MED): an unparseable line is tolerated ONLY when
    /// it is the LAST line (a torn final write from a crash mid-persist). An unparseable line with valid
    /// lines AFTER it is a corruption/injection signal → the WHOLE file is rejected (chain stays empty,
    /// every signoff untrusted). Junk can never mint a green either way, but this denies any attempt to
    /// use a malformed row to shuffle what loads.
    private func load() {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        var loaded: [FleetSignoffEntry] = []
        for (i, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let entry = try? dec.decode(FleetSignoffEntry.self, from: data) else {
                if i == lines.count - 1 { break }   // tolerate a single torn final line (crash recovery)
                chain = []                          // mid-file garbage → fail closed, trust nothing
                return
            }
            loaded.append(entry)
        }
        chain = loaded
    }

    /// Rewrite the whole file (disk == memory exactly at fleet-event volume). Throws before memory is
    /// mutated, so a failed write never leaves an in-process signoff that disk cannot prove.
    private func persist(_ entries: [FleetSignoffEntry]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        var out = ""
        for entry in entries {
            guard let data = try? enc.encode(entry),
                  let line = String(data: data, encoding: .utf8) else {
                fatalError("FleetSignoffEntry encode must not fail")
            }
            out += line + "\n"
        }
        try out.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
