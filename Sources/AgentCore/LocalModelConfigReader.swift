import Foundation

/// FLAWLESS-LOOPS SAFETY NET #3 (readers): pull the chat template + EOS from a local model on disk.
///
/// Two real-world sources, tried in order:
///   1. a HuggingFace-style `tokenizer_config.json` (next to, or passed directly as, the model) — has
///      `chat_template`, `eos_token`, `bos_token` as plain JSON.
///   2. a `.gguf` file — the template lives in binary metadata under `tokenizer.chat_template`.
///
/// Fail-soft by design: any malformed/oversized/absent input returns nil rather than throwing into the
/// onboarding path. We never invent a template — only report what we can actually read.
public enum LocalModelConfigReader {

    /// Resolve a local model path (a `.gguf`, a `tokenizer_config.json`, or a directory containing one)
    /// into a template profile. Returns nil if nothing readable is found.
    public static func read(path: String) -> LocalModelTemplate? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }

        if isDir.boolValue {
            let cfg = (path as NSString).appendingPathComponent("tokenizer_config.json")
            if fm.fileExists(atPath: cfg) { return readTokenizerConfig(path: cfg) }
            // first .gguf in the directory
            if let entries = try? fm.contentsOfDirectory(atPath: path),
               let gguf = entries.first(where: { $0.lowercased().hasSuffix(".gguf") }) {
                return readGGUF(path: (path as NSString).appendingPathComponent(gguf))
            }
            return nil
        }

        let lower = path.lowercased()
        if lower.hasSuffix(".json") { return readTokenizerConfig(path: path) }
        if lower.hasSuffix(".gguf") {
            // A GGUF may sit beside a tokenizer_config.json with a richer template — prefer the JSON.
            let sibling = (((path as NSString).deletingLastPathComponent) as NSString)
                .appendingPathComponent("tokenizer_config.json")
            if fm.fileExists(atPath: sibling), let viaJSON = readTokenizerConfig(path: sibling) { return viaJSON }
            return readGGUF(path: path)
        }
        return nil
    }

    // MARK: - tokenizer_config.json

    /// tokenizer_config.json is normally < 1 MB; cap the read so a huge/crafted UNTRUSTED file can't OOM
    /// the process (the GGUF path is already capped — this closes the same hole on the JSON path).
    private static let jsonReadCap = 16 * 1024 * 1024

    static func readTokenizerConfig(path: String) -> LocalModelTemplate? {
        // Reject oversized files BEFORE slurping them into memory.
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
           size.intValue > jsonReadCap { return nil }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // read(upToCount:) bounds the read even if the size attribute was unavailable/raced.
        let read = (try? handle.read(upToCount: jsonReadCap)) ?? nil
        guard let data = read, data.count <= jsonReadCap,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        // chat_template can be a string or (newer multi-template) an array of {name, template}.
        let template: String?
        if let s = obj["chat_template"] as? String { template = s }
        else if let arr = obj["chat_template"] as? [[String: Any]] {
            template = (arr.first { ($0["name"] as? String) == "default" }?["template"] as? String)
                ?? (arr.first?["template"] as? String)
        } else { template = nil }
        let eos = tokenString(obj["eos_token"])
        let name = (obj["model_type"] as? String) ?? (obj["_name_or_path"] as? String)
        guard template != nil || eos != nil || name != nil else { return nil }
        return LocalModelTemplate.from(chatTemplate: template, eosToken: eos, modelName: name,
                                       source: "tokenizer_config.json")
    }

    /// `eos_token` is either a plain string or an `AddedToken` object `{ "content": "</s>", ... }`.
    static func tokenString(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let o = value as? [String: Any], let c = o["content"] as? String { return c }
        return nil
    }

    // MARK: - GGUF binary metadata

    /// Read only as much of the file as the metadata needs (metadata precedes tensor data in GGUF).
    private static let ggufReadCap = 48 * 1024 * 1024   // 48 MB — covers metadata + a large vocab array

    static func readGGUF(path: String) -> LocalModelTemplate? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: ggufReadCap), data.count > 24 else { return nil }
        guard let meta = parseGGUFMetadata(data) else { return nil }
        let template = meta["tokenizer.chat_template"]
        let name = meta["general.name"] ?? meta["general.basename"] ?? meta["general.architecture"]
        guard template != nil || name != nil else { return nil }
        return LocalModelTemplate.from(chatTemplate: template, eosToken: nil, modelName: name,
                                       source: "GGUF metadata")
    }

    // GGUF value type tags.
    private enum GG: UInt32 { case uint8=0, int8=1, uint16=2, int16=3, uint32=4, int32=5, float32=6,
                                   bool=7, string=8, array=9, uint64=10, int64=11, float64=12 }

    /// Parse GGUF header + metadata KV pairs, returning the STRING-typed values keyed by name (the only
    /// ones we need: chat_template, general.name/architecture). Non-string values are correctly consumed
    /// so the cursor stays aligned, but skipped. Returns nil on a bad magic or any bounds violation.
    static func parseGGUFMetadata(_ data: Data) -> [String: String]? {
        var c = ByteCursor(data)
        guard let magic = c.readBytes(4), magic == Data([0x47, 0x47, 0x55, 0x46]) else { return nil }  // "GGUF"
        guard let version = c.readUInt32(), version >= 2 else { return nil }
        guard c.readUInt64() != nil else { return nil }              // tensor_count (skip)
        guard let kvCount = c.readUInt64(), kvCount < 1_000_000 else { return nil }

        // Only a FULLY-consumed metadata block is trustworthy: a truncated/corrupt file that happens to
        // have a valid first key must NOT be mistaken for a complete config. Any mid-parse bounds
        // violation → nil (fail-closed), never the partial dictionary read so far.
        var out: [String: String] = [:]
        for _ in 0..<kvCount {
            guard let key = c.readGGUFString() else { return nil }
            guard let typeRaw = c.readUInt32(), let type = GG(rawValue: typeRaw) else { return nil }
            guard let value = readValue(&c, type: type) else { return nil }
            if let s = value { out[key] = s }
        }
        return out
    }

    /// Consume one value of `type`, returning its String form if it's a string (else nil but still
    /// advancing the cursor past the bytes). Arrays are skipped wholesale.
    private static func readValue(_ c: inout ByteCursor, type: GG) -> String?? {
        switch type {
        case .uint8, .int8, .bool: return c.skip(1) ? .some(nil) : nil
        case .uint16, .int16:      return c.skip(2) ? .some(nil) : nil
        case .uint32, .int32, .float32: return c.skip(4) ? .some(nil) : nil
        case .uint64, .int64, .float64: return c.skip(8) ? .some(nil) : nil
        case .string:
            guard let s = c.readGGUFString() else { return nil }
            return .some(s)
        case .array:
            return skipArray(&c, depth: 0) ? .some(nil) : nil
        }
    }

    /// Max nested-array depth — a crafted GGUF with deeply nested arrays (still under the byte cap) must
    /// not blow the stack. Real metadata is never nested beyond 1–2 levels.
    private static let maxArrayDepth = 16

    /// Skip an ARRAY value: element type (uint32) + count (uint64) + the elements. String elements are
    /// skipped by reading each length and advancing (no decode) so even a 150k-token vocab is cheap.
    private static func skipArray(_ c: inout ByteCursor, depth: Int) -> Bool {
        guard depth < maxArrayDepth else { return false }   // fail-closed on pathological nesting
        guard let elemRaw = c.readUInt32(), let elem = GG(rawValue: elemRaw),
              let count = c.readUInt64(), count < 100_000_000,
              let n = Int(exactly: count) else { return false }
        // Overflow-safe byte length for fixed-size elements (n is capped <100M, but compute defensively).
        func skipFixed(_ size: Int) -> Bool {
            let (bytes, overflow) = n.multipliedReportingOverflow(by: size)
            return !overflow && c.skip(bytes)
        }
        switch elem {
        case .uint8, .int8, .bool:      return skipFixed(1)
        case .uint16, .int16:           return skipFixed(2)
        case .uint32, .int32, .float32: return skipFixed(4)
        case .uint64, .int64, .float64: return skipFixed(8)
        case .string:
            for _ in 0..<n { if c.readGGUFString() == nil { return false } }
            return true
        case .array:
            for _ in 0..<n { if !skipArray(&c, depth: depth + 1) { return false } }   // nested arrays (rare)
            return true
        }
    }
}

/// A bounds-checked little-endian cursor over a Data buffer. Every read returns nil on overflow — the
/// parser fails soft rather than crashing on a truncated/corrupt file.
struct ByteCursor {
    private let data: Data
    private var i: Int
    init(_ data: Data) { self.data = data; self.i = data.startIndex }

    private mutating func take(_ n: Int) -> Data? {
        guard n >= 0 else { return nil }
        let (end, overflow) = i.addingReportingOverflow(n)
        guard !overflow, end <= data.endIndex else { return nil }
        let r = data.subdata(in: i..<end); i = end; return r
    }
    mutating func skip(_ n: Int) -> Bool {
        guard n >= 0 else { return false }
        let (end, overflow) = i.addingReportingOverflow(n)
        guard !overflow, end <= data.endIndex else { return false }
        i = end; return true
    }
    mutating func readBytes(_ n: Int) -> Data? { take(n) }

    mutating func readUInt32() -> UInt32? {
        guard let d = take(4) else { return nil }
        return le32(d)
    }
    mutating func readUInt64() -> UInt64? { guard let d = take(8) else { return nil }; return le64(d) }

    /// GGUF string = uint64 length + UTF-8 bytes. Capped to avoid a corrupt length allocating wildly.
    mutating func readGGUFString() -> String? {
        guard let len = readUInt64(), len < 64 * 1024 * 1024, let n = Int(exactly: len) else { return nil }
        guard let bytes = take(n) else { return nil }
        return String(data: bytes, encoding: .utf8) ?? ""   // non-UTF8 → empty (still consumed)
    }

    private func le32(_ d: Data) -> UInt32 {
        let b = [UInt8](d)
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }
    private func le64(_ d: Data) -> UInt64 {
        let b = [UInt8](d)
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(b[k]) << (8 * k) }
        return v
    }
}
