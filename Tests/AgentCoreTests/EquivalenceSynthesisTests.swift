import XCTest
@testable import AgentCore

final class EquivalenceSynthesisTests: XCTestCase {

    // MARK: - BoundaryCatalog

    func testCatalogsAreNonEmptyAndCarryTheKnownTraps() {
        for t in [FieldType.integer, .decimal, .currency, .date, .text, .identifier, .boolean] {
            XCTAssertFalse(BoundaryCatalog.values(for: t).isEmpty, "\(t) catalog must not be empty")
        }
        XCTAssertTrue(BoundaryCatalog.values(for: .date).contains("2023-02-29"))   // invalid leap
        XCTAssertTrue(BoundaryCatalog.values(for: .date).contains("2024-02-29"))   // valid leap
        XCTAssertTrue(BoundaryCatalog.values(for: .currency).contains("0.005"))    // half-cent
        XCTAssertTrue(BoundaryCatalog.values(for: .integer).contains("2147483648")) // int32 overflow
        XCTAssertTrue(BoundaryCatalog.values(for: .text).contains(""))             // empty
    }

    func testCatalogIsDeterministic() {
        XCTAssertEqual(BoundaryCatalog.values(for: .currency), BoundaryCatalog.values(for: .currency))
    }

    // MARK: - InputSynthesizer

    func testSynthesizesOfatPlusStructuralCases() {
        let fields = [InputSynthesizer.Field(name: "date", type: .date, nominal: "2024-06-15")]
        let cases = InputSynthesizer.synthesize(record: fields)
        // OFAT: one case per boundary value of the single field...
        let ofat = BoundaryCatalog.values(for: .date).count
        // ...plus 4 structural cases (empty, single, duplicate, bulk).
        XCTAssertEqual(cases.count, ofat + 4)
        XCTAssertTrue(cases.contains { $0.id == "struct:empty" && $0.input.isEmpty })
        XCTAssertTrue(cases.contains { $0.id == "struct:duplicate" })
        XCTAssertTrue(cases.contains { $0.id.hasPrefix("0:date#") })
    }

    func testOfatHoldsOtherFieldsAtNominal() {
        let fields = [InputSynthesizer.Field(name: "name", type: .identifier, nominal: "bob"),
                      InputSynthesizer.Field(name: "amt", type: .currency, nominal: "10.00")]
        let cases = InputSynthesizer.synthesize(record: fields)
        // A case varying "amt" (field index 1) must keep name = nominal "bob".
        let amtCase = cases.first { $0.id == "1:amt#3" }
        XCTAssertNotNil(amtCase)
        XCTAssertTrue(amtCase!.input.hasPrefix("bob,"), "other fields must stay nominal: \(amtCase!.input)")
    }

    func testEmptyRecordSynthesizesNothing() {
        XCTAssertTrue(InputSynthesizer.synthesize(record: []).isEmpty)
    }

    // MARK: - Council fixes: structural correctness

    func testCaseIdsAreUniqueEvenWithDuplicateFieldNames() {
        // Council: two fields with the SAME name must not collide into one id (which would hide a regression).
        let fields = [InputSynthesizer.Field(name: "amt", type: .currency, nominal: "10.00"),
                      InputSynthesizer.Field(name: "amt", type: .currency, nominal: "20.00")]
        let ids = InputSynthesizer.synthesize(record: fields).map { $0.id }
        XCTAssertEqual(ids.count, Set(ids).count, "case ids must be unique even with duplicate field names")
    }

    func testDelimiterBearingValueIsQuotedNotColumnSplit() {
        // Council-critical: a value containing the delimiter must stay ONE logical column (RFC 4180 quote),
        // not silently split the row. A CSV parser must read exactly two fields back.
        let fields = [InputSynthesizer.Field(name: "note", type: .text, nominal: "x"),
                      InputSynthesizer.Field(name: "tag", type: .text, nominal: "y")]
        let cases = InputSynthesizer.synthesize(record: fields)
        // Find the case that set field 0 to the "a,b" boundary value.
        let abIndex = BoundaryCatalog.values(for: .text).firstIndex(of: "a,b")!
        let ab = cases.first { $0.id == "0:note#\(abIndex)" }!
        XCTAssertTrue(ab.input.hasPrefix("\"a,b\""), "delimiter-bearing value must be quoted: \(ab.input)")
        XCTAssertEqual(parseCSVRow(ab.input).count, 2, "must remain two columns, not split into three")
    }

    func testBulkRowCountIsCapped() {
        let fields = [InputSynthesizer.Field(name: "d", type: .date, nominal: "2024-06-15")]
        let cases = InputSynthesizer.synthesize(record: fields, bulkRowCount: 10_000_000)
        let bulk = cases.first { $0.id.hasPrefix("struct:bulk") }!
        // capped at 10_000 rows → at most 10_000 separators
        XCTAssertLessThanOrEqual(bulk.input.filter { $0 == "\n" }.count, 10_000)
    }

    func testNewCatalogTrapsPresent() {
        XCTAssertTrue(BoundaryCatalog.values(for: .date).contains("2100-02-29"))   // future non-/400 century
        XCTAssertTrue(BoundaryCatalog.values(for: .currency).contains("(1.00)"))   // accounting negative
        XCTAssertTrue(BoundaryCatalog.values(for: .currency).contains("1,000.00")) // thousands separator
        XCTAssertTrue(BoundaryCatalog.values(for: .integer).contains("NaN"))
    }

    /// Minimal RFC-4180 row parser for the test — reads quoted/unquoted fields on one line.
    private func parseCSVRow(_ row: String) -> [String] {
        var fields: [String] = []; var cur = ""; var inQuotes = false
        let chars = Array(row); var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" { if i + 1 < chars.count, chars[i+1] == "\"" { cur.append("\""); i += 1 } else { inQuotes = false } }
                else { cur.append(c) }
            } else {
                if c == "\"" { inQuotes = true }
                else if c == "," { fields.append(cur); cur = "" }
                else { cur.append(c) }
            }
            i += 1
        }
        fields.append(cur)
        return fields
    }

    // MARK: - The money shot: synthesizer finds what a happy-path corpus cannot

    // A date validator whose CANDIDATE naively treats every Feb-29 as valid (ignores the leap-year rule).
    private func validate(_ s: String, checkLeap: Bool) -> String {
        let p = s.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]), m >= 1, m <= 12, d >= 1
        else { return "invalid" }
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        let daysProper = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
        let daysBuggy = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]   // Feb always 29 (the bug)
        return d <= (checkLeap ? daysProper : daysBuggy) ? "valid" : "invalid"
    }

    func testHappyPathCorpusMissesTheLeapYearBug() {
        // Only the nominal (valid, non-Feb-29) input → the buggy port looks perfectly equivalent.
        let happyPath: [EquivalenceRun.Case] = [.init(id: "nominal", input: "2024-06-15")]
        let report = EquivalenceRun.run(happyPath,
                                        oracle: { self.validate($0, checkLeap: true) },
                                        candidate: { self.validate($0, checkLeap: false) })
        XCTAssertEqual(report.overall, .evidenceBoundedEquivalent, "happy path is blind to the leap bug")
    }

    func testSynthesizedCorpusCatchesTheLeapYearBug() {
        // The SAME buggy port, but judged over a synthesized boundary corpus → the leap-day edge is caught.
        let fields = [InputSynthesizer.Field(name: "date", type: .date, nominal: "2024-06-15")]
        let synthesized = InputSynthesizer.synthesize(record: fields)
        let report = EquivalenceRun.run(synthesized,
                                        oracle: { self.validate($0, checkLeap: true) },
                                        candidate: { self.validate($0, checkLeap: false) })
        XCTAssertEqual(report.overall, .regressed, "the synthesizer must surface the leap-year divergence")
        XCTAssertGreaterThanOrEqual(report.count(.notEquivalent), 1)  // 2023-02-29 and/or 1900-02-29
    }
}
