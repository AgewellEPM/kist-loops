import Foundation

// Pure, dependency-free STRUCTURAL symbol extraction — the gap between kist's lexical
// context index and the frontier's AST knowledge-graphs. Line-anchored declaration
// patterns per language give a file's outline (types/functions/etc. with line numbers)
// and a repo-wide "where is X defined" without the model reading whole files. Regex, not
// a full parser: fast, offline, robust across languages, and good enough for navigation
// (the same approach editors use for a quick "go to symbol").
public struct CodeSymbol: Sendable, Equatable {
    public let kind: String     // func | class | struct | enum | protocol | type | interface | trait | impl | mod
    public let name: String
    public let line: Int        // 1-indexed
    public init(kind: String, name: String, line: Int) { self.kind = kind; self.name = name; self.line = line }
}

public enum SymbolExtractor {

    /// Map a file extension to a language key we have patterns for. Returns nil for unknown.
    public static func language(forPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": return "ts"
        case "py": return "python"
        case "rs": return "rust"
        case "go": return "go"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "rb": return "ruby"
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh": return "cpp"
        default: return nil
        }
    }

    /// (kind, regex). Each regex is line-anchored and captures the symbol name in group "name".
    static let patterns: [String: [(kind: String, regex: String)]] = [
        "swift": [
            ("type",     #"^\s*(?:public|internal|private|fileprivate|open|final|@\w+\s+)*\s*(?:class|struct|enum|protocol|actor|extension)\s+(?<name>[A-Za-z_]\w*)"#),
            ("func",     #"^\s*(?:public|internal|private|fileprivate|open|static|class|final|override|@\w+\s+)*\s*func\s+(?<name>[A-Za-z_]\w*)"#),
        ],
        "ts": [
            ("type",     #"^\s*(?:export\s+)?(?:default\s+)?(?:abstract\s+)?(?:class|interface|enum|type)\s+(?<name>[A-Za-z_$][\w$]*)"#),
            ("func",     #"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s+(?<name>[A-Za-z_$][\w$]*)"#),
            // Arrow assigned to a const/let/var: parenthesized OR single-param, with or without a type annotation.
            ("func",     #"^\s*(?:export\s+)?(?:const|let|var)\s+(?<name>[A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s+)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*(?::[^=]+)?=>"#),
        ],
        "python": [
            ("class",    #"^\s*class\s+(?<name>[A-Za-z_]\w*)"#),
            ("func",     #"^\s*(?:async\s+)?def\s+(?<name>[A-Za-z_]\w*)"#),
        ],
        "rust": [
            ("type",     #"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:struct|enum|trait|union|mod)\s+(?<name>[A-Za-z_]\w*)"#),
            ("impl",     #"^\s*impl(?:<[^>]*>)?\s+(?<name>[A-Za-z_]\w*)"#),
            ("func",     #"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?fn\s+(?<name>[A-Za-z_]\w*)"#),
        ],
        "go": [
            ("type",     #"^\s*type\s+(?<name>[A-Za-z_]\w*)"#),
            ("func",     #"^\s*func\s+(?:\([^)]*\)\s*)?(?<name>[A-Za-z_]\w*)"#),
        ],
        "java": [
            ("type",     #"^\s*(?:public|private|protected|abstract|final|static|\s)*\s*(?:class|interface|enum)\s+(?<name>[A-Za-z_]\w*)"#),
            // Methods: require an ACCESS MODIFIER at line start — a strong discriminator that
            // control statements (if/for/while/switch) never have, so no false positives.
            ("func",     #"^\s*(?:@\w+\s+)*(?:public|private|protected)\s+(?:static\s+|final\s+|abstract\s+|synchronized\s+|native\s+|default\s+)*[\w<>\[\].,\s]+?\s+(?<name>[A-Za-z_]\w*)\s*\([^;]*\)"#),
        ],
        "kotlin": [
            ("type",     #"^\s*(?:public|private|internal|abstract|sealed|open|data|\s)*\s*(?:class|interface|object)\s+(?<name>[A-Za-z_]\w*)"#),
            ("func",     #"^\s*(?:public|private|internal|override|suspend|\s)*\s*fun\s+(?:<[^>]*>\s+)?(?<name>[A-Za-z_]\w*)"#),
        ],
        "ruby": [
            ("type",     #"^\s*(?:class|module)\s+(?<name>[A-Za-z_]\w*)"#),
            ("func",     #"^\s*def\s+(?<name>[A-Za-z_][\w?!]*)"#),
        ],
        "cpp": [
            ("type",     #"^\s*(?:class|struct|enum|namespace)\s+(?<name>[A-Za-z_]\w*)"#),
            // Function DEFINITIONS (body brace on the same line), guarded by a negative
            // lookahead so control statements (if/for/while/switch/catch) are never matched.
            // Best-effort: member defs `Ret Class::m()` capture the last identifier.
            ("func",     #"^\s*(?!\s*(?:if|for|while|switch|catch|return|else|do|sizeof)\b)(?:[A-Za-z_][\w:<>*&,\s]*\s+[*&]?)+(?<name>[A-Za-z_]\w*)\s*\([^;]*\)\s*(?:const\s*)?(?:noexcept\s*)?\{\s*$"#),
        ],
    ]

    /// Structural outline of one file. Empty for an unknown language (caller degrades gracefully).
    public static func outline(_ source: String, language: String) -> [CodeSymbol] {
        guard let langPatterns = patterns[language] else { return [] }
        let compiled = langPatterns.compactMap { p -> (String, NSRegularExpression)? in
            (try? NSRegularExpression(pattern: p.regex)).map { (p.kind, $0) }
        }
        var out: [CodeSymbol] = []
        let lines = source.components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() {
            if line.count > 2000 { continue }               // skip pathological minified lines
            let range = NSRange(line.startIndex..., in: line)
            for (kind, re) in compiled {
                guard let m = re.firstMatch(in: line, range: range) else { continue }
                let nameRange = m.range(withName: "name")
                guard nameRange.location != NSNotFound, let r = Range(nameRange, in: line) else { continue }
                out.append(CodeSymbol(kind: kind, name: String(line[r]), line: idx + 1))
                break                                        // one symbol per line (first match wins)
            }
        }
        return out
    }
}
