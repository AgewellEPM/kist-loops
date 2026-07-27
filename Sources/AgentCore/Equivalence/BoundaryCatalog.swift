import Foundation

/// The kind of a legacy field, used to pick the right edge-value set. (Later, the SystemArchaeologist
/// infers these per column/parameter; for L0 the caller declares them.)
public enum FieldType: String, Sendable, Equatable, Codable {
    case integer, decimal, currency, date, text, identifier, boolean
}

/// The boundary/edge values captured happy-path traffic almost never contains but that historically break
/// ports — the concrete answer to the council's #1 failure mode ("golden master only covers the easy
/// traffic → the port passes every test and is still wrong"). Each list is the equivalence-partition +
/// boundary-value catalog for one type: min/max/overflow, sign/zero edges, currency half-cent rounding,
/// leap-day / month-end / invalid dates, null/empty/whitespace, delimiter/quote/injection, unicode.
/// Pure and deterministic (no RNG) so a synthesized corpus is reproducible.
public enum BoundaryCatalog {
    public static func values(for type: FieldType) -> [String] {
        switch type {
        case .integer:
            return ["0", "1", "-1", "007",
                    "2147483647", "2147483648", "-2147483648", "-2147483649",           // int32 edges
                    "9223372036854775807", "9223372036854775808", "-9223372036854775808", // int64 edges
                    "99999999999999999999999999", "+1", " 1 ", "1.0", "1e3",
                    "NaN", "Infinity", "-Infinity", "1.2.3", "abc", " 123", "123 ", ""]   // malformed-numeric + ws (council)
        case .decimal:
            return ["0", "0.0", "0.00", "-0.0", "0.1", "-0.1", "3.141592653589793",
                    "1e10", "1e-10", "1e-300", "0.30000000000000004", "1", ".5", "5.", "-0",
                    "NaN", "Infinity", "1.2.3", ""]
        case .currency:
            return ["0.00", "0.01", "-0.01", "0.005", "0.004", "0.006",                 // half-cent rounding
                    "-0.005", "-1.005", "0.001", "0.999", "1.005", "1.115", "2.675",      // signed half-cent + banker's-rounding traps
                    "$1.00", "1,000.00", "(1.00)",                                        // symbol / thousands-sep / accounting-negative (council)
                    "999999999.99", "1000000.00", "-0.00", ".99", "1.", ""]
        case .date:
            return ["2024-02-29", "2000-02-29",                                          // valid leap (incl. /400)
                    "2023-02-29", "1900-02-29", "2100-02-29",                            // invalid leap (non-/400 century, incl. future)
                    "2024-01-31", "2024-04-30", "2024-04-31", "2024-02-30",              // month-end + invalid overflow
                    "2024-12-31", "2025-01-01", "2024-00-01", "2024-13-01", "2024-12-32",
                    "2024/01/01", "01/01/2024", "2024-01-01 12:30:00", "24-01-01",       // separators / order / datetime / 2-digit-yr (council)
                    "0000-01-01", "9999-12-31", ""]
        case .text:
            return ["", " ", "  padded  ", "a", "café", "😀", "naïve",
                    "a,b", "a;b", "line1\nline2", "tab\tsep", "\"quoted\"", "back\\slash",
                    "\t", "\n", "\u{0}", "\u{FEFF}bom", "\"\"", ",,",                     // pure-control / BOM / quote-escape (council)
                    "null", "NULL", "None", "undefined", "true", "0", "-1",
                    "'; DROP TABLE users;--", "<script>", String(repeating: "x", count: 10_000)]
        case .identifier:
            return ["", "a", "a b", "UPPER", "lower", "with-dash", "with.dot",
                    "'; DROP TABLE--", "../../etc/passwd", "🔑", String(repeating: "k", count: 1024)]
        case .boolean:
            return ["true", "false", "TRUE", "FALSE", "True", "1", "0", "yes", "no", "on", "off", "", "null"]
        }
    }
}
