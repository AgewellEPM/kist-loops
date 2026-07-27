import Foundation

/// A token-preserving canonical JSON serializer — the honest replacement for `JSONSerialization`, which
/// the council caught producing FALSE `.equivalent` verdicts two ways: it lossily reformats numbers
/// (`1.0` → `1`, `1e2` → `100`) and it silently keeps only the LAST of duplicate keys. Either can mask a
/// real regression in a payroll/banking port. This canonicalizer instead:
///   • sorts object keys (so key ORDER stops being a diff — the legitimate noise we DO want to kill),
///   • preserves NUMBER lexemes VERBATIM (`1.0` stays distinct from `1`; a representational change is
///     surfaced as NOT-EQUIVALENT, never silently equal — the caller opts into numeric tolerance via an
///     invariant only if it is genuinely insignificant),
///   • normalizes STRING values (unambiguous JSON string semantics: `"A"` and `"A"` are equal),
///   • REJECTS objects with duplicate keys (returns nil → caller falls back to text normalization, which
///     preserves both keys so a dropped duplicate surfaces as a diff instead of being masked).
/// Returns nil for anything that is not strictly one complete JSON value, so the caller falls back to safe
/// text normalization rather than trusting a partial parse.
enum JSONCanonicalizer {
    static func canonical(_ s: String) -> String? {
        var p = Parser(Array(s))
        p.skipWhitespace()
        guard let node = p.parseValue() else { return nil }
        p.skipWhitespace()
        guard p.atEnd else { return nil }          // trailing garbage ⇒ not clean JSON ⇒ text fallback
        return node.canonical()
    }

    indirect enum Node {
        case object([(String, Node)])              // decoded keys kept in parse order for dup detection
        case array([Node])
        case number(String)                        // RAW lexeme, preserved
        case string(String)                        // decoded value, canonically re-encoded
        case literal(String)                       // true / false / null

        func canonical() -> String? {
            switch self {
            case .number(let raw): return raw
            case .literal(let l): return l
            case .string(let v): return JSONCanonicalizer.encode(v)
            case .array(let items):
                var parts: [String] = []
                for it in items { guard let c = it.canonical() else { return nil }; parts.append(c) }
                return "[" + parts.joined(separator: ",") + "]"
            case .object(let pairs):
                var seen = Set<String>()
                for (k, _) in pairs where !seen.insert(k).inserted { return nil }   // duplicate key ⇒ reject
                let parts = pairs.sorted { $0.0 < $1.0 }.compactMap { pair -> String? in
                    guard let cv = pair.1.canonical() else { return nil }
                    return JSONCanonicalizer.encode(pair.0) + ":" + cv
                }
                guard parts.count == pairs.count else { return nil }
                return "{" + parts.joined(separator: ",") + "}"
            }
        }
    }

    /// Canonical JSON string encoding: escape the minimal required set, emit everything else verbatim.
    static func encode(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    struct Parser {
        let chars: [Character]
        var i = 0
        var depth = 0
        /// Recursion cap — council (DeepSeek) caught an unbounded-recursion stack overflow on pathological
        /// deep nesting (`[[[[…]]]]`). Beyond this, bail to nil → safe text fallback, never a crash.
        static let maxDepth = 1000
        init(_ chars: [Character]) { self.chars = chars }
        var atEnd: Bool { i >= chars.count }
        func peek() -> Character? { i < chars.count ? chars[i] : nil }
        static func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }

        mutating func skipWhitespace() {
            while let c = peek(), c == " " || c == "\n" || c == "\r" || c == "\t" { i += 1 }
        }

        mutating func parseValue() -> Node? {
            skipWhitespace()
            guard let c = peek() else { return nil }
            switch c {
            case "{": return parseObject()
            case "[": return parseArray()
            case "\"": return parseString().map { .string($0) }
            case "t": return parseLiteral("true")
            case "f": return parseLiteral("false")
            case "n": return parseLiteral("null")
            case "-", "0"..."9": return parseNumber()
            default: return nil
            }
        }

        mutating func parseLiteral(_ lit: String) -> Node? {
            for ch in lit { guard peek() == ch else { return nil }; i += 1 }
            return .literal(lit)
        }

        /// Strict RFC 8259 number grammar (council: leading zeros like `0123` / `-01` must be REJECTED, not
        /// silently accepted then canonicalized — accepting non-JSON can mask a diff as an equivalence).
        mutating func parseNumber() -> Node? {
            let start = i
            if peek() == "-" { i += 1 }
            guard let first = peek() else { return nil }
            if first == "0" {
                i += 1                                        // a leading 0 stands alone (no 0123)
            } else if Self.isDigit(first) {                   // 1-9 then any digits
                while let c = peek(), Self.isDigit(c) { i += 1 }
            } else {
                return nil                                    // e.g. "-" with no digit, or "-x"
            }
            if peek() == "." {                                // fraction requires ≥1 digit
                i += 1
                guard let f = peek(), Self.isDigit(f) else { return nil }
                while let c = peek(), Self.isDigit(c) { i += 1 }
            }
            if let e = peek(), e == "e" || e == "E" {         // exponent requires ≥1 digit
                i += 1
                if let s = peek(), s == "+" || s == "-" { i += 1 }
                guard let x = peek(), Self.isDigit(x) else { return nil }
                while let c = peek(), Self.isDigit(c) { i += 1 }
            }
            return .number(String(chars[start..<i]))
        }

        mutating func parseString() -> String? {
            guard peek() == "\"" else { return nil }
            i += 1
            var out = ""
            while let c = peek() {
                i += 1
                if c == "\"" { return out }
                if c == "\\" {
                    guard let esc = peek() else { return nil }
                    i += 1
                    switch esc {
                    case "\"": out += "\""
                    case "\\": out += "\\"
                    case "/": out += "/"
                    case "n": out += "\n"
                    case "t": out += "\t"
                    case "r": out += "\r"
                    case "b": out += "\u{08}"
                    case "f": out += "\u{0C}"
                    case "u":
                        guard let scalar = parseUnicodeEscape() else { return nil }
                        out.unicodeScalars.append(scalar)
                    default: return nil
                    }
                } else {
                    // Reject RAW (unescaped) control characters — RFC 8259 requires them escaped. Accepting
                    // them lets an invalid string canonicalize identically to its escaped-but-valid twin,
                    // which would mask a format difference (council).
                    if let s = c.unicodeScalars.first, c.unicodeScalars.count == 1, s.value < 0x20 { return nil }
                    out.append(c)
                }
            }
            return nil                                        // unterminated string
        }

        /// A `\u` escape (the `\u` already consumed): reads 4 hex, COMBINES a valid high+low surrogate pair
        /// into one scalar, and REJECTS a lone/unpaired surrogate (council: proper surrogate handling).
        mutating func parseUnicodeEscape() -> Unicode.Scalar? {
            guard let hi = read4Hex() else { return nil }
            if (0xD800...0xDBFF).contains(hi) {               // high surrogate → needs a low surrogate
                guard peek() == "\\" else { return nil }; i += 1
                guard peek() == "u" else { return nil }; i += 1
                guard let lo = read4Hex(), (0xDC00...0xDFFF).contains(lo) else { return nil }
                return Unicode.Scalar(0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00))
            }
            if (0xDC00...0xDFFF).contains(hi) { return nil }  // lone low surrogate → invalid
            return Unicode.Scalar(hi)
        }

        mutating func read4Hex() -> UInt32? {
            guard i + 4 <= chars.count else { return nil }
            let hex = String(chars[i..<i + 4])
            guard hex.allSatisfy({ $0.isHexDigit }), let v = UInt32(hex, radix: 16) else { return nil }
            i += 4
            return v
        }

        mutating func parseArray() -> Node? {
            depth += 1; defer { depth -= 1 }
            if depth > Self.maxDepth { return nil }
            i += 1                                            // consume [
            var items: [Node] = []
            skipWhitespace()
            if peek() == "]" { i += 1; return .array(items) }
            while true {
                guard let v = parseValue() else { return nil }
                items.append(v)
                skipWhitespace()
                switch peek() {
                case ",": i += 1
                case "]": i += 1; return .array(items)
                default: return nil
                }
            }
        }

        mutating func parseObject() -> Node? {
            depth += 1; defer { depth -= 1 }
            if depth > Self.maxDepth { return nil }
            i += 1                                            // consume {
            var pairs: [(String, Node)] = []
            skipWhitespace()
            if peek() == "}" { i += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                guard let key = parseString() else { return nil }
                skipWhitespace()
                guard peek() == ":" else { return nil }
                i += 1
                guard let v = parseValue() else { return nil }
                pairs.append((key, v))
                skipWhitespace()
                switch peek() {
                case ",": i += 1
                case "}": i += 1; return .object(pairs)
                default: return nil
                }
            }
        }
    }
}
