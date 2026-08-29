import Foundation
import XCTest
@testable import AgentCore

final class SMLValueTests: XCTestCase {
    func testIntegralDecimalKeepsTheSingleNumericCaseAcrossRoundTrip() throws {
        let value = try roundTrip("1.0", canonicalJSON: "1")

        guard case .number(let number) = value else {
            return XCTFail("expected an SML number")
        }
        XCTAssertEqual(number, Decimal(1))
    }

    func testNegativeZeroHasCanonicalZeroSemantics() throws {
        let negativeZero = try roundTrip("-0.0", canonicalJSON: "0")
        let positiveZero = try JSONDecoder().decode(SMLValue.self, from: Data("0".utf8))

        XCTAssertEqual(negativeZero, positiveZero)
    }

    func testInt64BoundariesAndBeyondRemainExact() throws {
        for literal in [
            "-9223372036854775809",
            "-9223372036854775808",
            "9223372036854775807",
            "9223372036854775808",
            "9223372036854775809",
        ] {
            try roundTrip(literal, canonicalJSON: literal)
        }
    }

    func testPrecisionSensitiveDecimalRemainsExact() throws {
        let literal = "0.12345678901234567890123456789012345678"
        try roundTrip(literal, canonicalJSON: literal)
    }

    func testNaNEncodingIsRejected() {
        XCTAssertThrowsError(try JSONEncoder().encode(SMLValue.number(.nan))) { error in
            guard case EncodingError.invalidValue = error else {
                return XCTFail("expected invalidValue, got \(error)")
            }
        }
    }

    func testOversizedArrayIsRejectedBeforeElementDecoding() {
        let json = "[" + Array(
            repeating: "null",
            count: SMLValidationSupport.maximumArrayEntries + 1
        ).joined(separator: ",") + "]"

        XCTAssertThrowsError(
            try JSONDecoder().decode(SMLValue.self, from: Data(json.utf8))
        )
        XCTAssertThrowsError(try JSONEncoder().encode(SMLValue.array(Array(
            repeating: .null,
            count: SMLValidationSupport.maximumArrayEntries + 1
        ))))
    }

    func testOversizedObjectIsRejectedBeforeValueDecoding() {
        let fields = (0...SMLValidationSupport.maximumObjectEntries).map {
            "\"key_\($0)\":null"
        }
        let json = "{" + fields.joined(separator: ",") + "}"

        XCTAssertThrowsError(
            try JSONDecoder().decode(SMLValue.self, from: Data(json.utf8))
        )
        XCTAssertThrowsError(try JSONEncoder().encode(SMLValue.object(
            Dictionary(uniqueKeysWithValues: fields.enumerated().map {
                ("key_\($0.offset)", SMLValue.null)
            })
        )))
    }

    @discardableResult
    private func roundTrip(_ json: String, canonicalJSON: String) throws -> SMLValue {
        let decoder = JSONDecoder()
        let value = try decoder.decode(SMLValue.self, from: Data(json.utf8))
        let encoded = try JSONEncoder().encode(value)

        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), canonicalJSON)
        XCTAssertEqual(try decoder.decode(SMLValue.self, from: encoded), value)
        return value
    }
}
