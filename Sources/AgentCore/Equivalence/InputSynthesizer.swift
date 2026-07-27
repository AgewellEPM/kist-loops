import Foundation

/// Synthesizes a boundary-hunting input corpus for a record-shaped legacy transform — the mechanism that
/// defeats the happy-path trap (council's #1 failure mode). Given the record's field types + a nominal
/// (known-good) value per field, it emits:
///   • one-factor-at-a-time (OFAT) cases: hold every field at nominal, vary ONE field across its full
///     boundary catalog — so a divergence localizes to a single field × single edge value,
///   • structural cases: empty input, a single nominal row, many rows, and duplicate rows.
/// Deterministic (no RNG) so the corpus is reproducible; every case carries a descriptive id so a
/// regression names the exact field+edge that broke the port. This is the "seed the corpus with the
/// inputs traffic never sent" half; coverage-guided fuzzing (later) is the other half.
///
/// KNOWN LIMITATION — OFAT is BLIND TO FIELD INTERACTIONS (council-flagged, documented not hidden): a bug
/// that only fires when TWO fields are simultaneously at a boundary (e.g. currency=0.005 AND date=leap-day)
/// is NOT generated here. Pairwise/combinatorial synthesis is a tracked follow-up; do not read a green
/// synthesized corpus as "all edge combinations covered."
///
/// Rows are assembled as RFC 4180 CSV: a field value containing the delimiter, a quote, or a newline is
/// double-quoted (internal quotes doubled) so it stays ONE logical column — otherwise a boundary value like
/// `a,b` would silently split the row into extra columns and the OFAT case would test the wrong thing
/// (council-critical). For a non-CSV target format, supply pre-formatted rows instead of using this default.
public enum InputSynthesizer {

    /// RFC 4180 field quoting — keeps a delimiter/quote/newline-bearing value as a single column.
    static func csvQuote(_ field: String, delimiter: String, rowSeparator: String) -> String {
        let needsQuoting = field.contains(delimiter) || field.contains("\"")
            || field.contains("\n") || field.contains("\r") || field.contains(rowSeparator)
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public struct Field: Sendable, Equatable {
        public let name: String
        public let type: FieldType
        public let nominal: String
        public init(name: String, type: FieldType, nominal: String) {
            self.name = name; self.type = type; self.nominal = nominal
        }
    }

    public static func synthesize(record fields: [Field],
                                  delimiter: String = ",", rowSeparator: String = "\n",
                                  bulkRowCount: Int = 100) -> [EquivalenceRun.Case] {
        guard !fields.isEmpty else { return [] }
        func assemble(_ cols: [String]) -> String {
            cols.map { csvQuote($0, delimiter: delimiter, rowSeparator: rowSeparator) }.joined(separator: delimiter)
        }
        let nominalRow = assemble(fields.map(\.nominal))
        var cases: [EquivalenceRun.Case] = []

        // OFAT: vary one field at a time across its boundary catalog; the rest stay nominal. The case id
        // carries the FIELD INDEX (not just the name) so duplicate field names cannot collide into one id
        // and silently hide a regression (council).
        for (fi, field) in fields.enumerated() {
            for (vi, value) in BoundaryCatalog.values(for: field.type).enumerated() {
                var cols = fields.map(\.nominal)
                cols[fi] = value
                cases.append(.init(id: "\(fi):\(field.name)#\(vi)", input: assemble(cols)))
            }
        }

        // Structural cases at the record-set level (a different axis from field values).
        cases.append(.init(id: "struct:empty", input: ""))
        cases.append(.init(id: "struct:single", input: nominalRow))
        cases.append(.init(id: "struct:duplicate", input: [nominalRow, nominalRow].joined(separator: rowSeparator)))
        // Cap the bulk size so a caller can't turn corpus generation into an OOM/timeout (council).
        let bulk = min(max(bulkRowCount, 0), 10_000)
        if bulk > 1 {
            let rows = Array(repeating: nominalRow, count: bulk).joined(separator: rowSeparator)
            cases.append(.init(id: "struct:bulk\(bulk)", input: rows))
        }
        return cases
    }
}
