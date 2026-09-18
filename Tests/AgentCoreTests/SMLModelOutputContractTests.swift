import Foundation
import XCTest
@testable import AgentCore

final class SMLModelOutputContractTests: XCTestCase {
    private func contract(_ json: String) throws -> SMLModelOutputContract {
        try SMLModelOutputContract(schema: SMLWireCodec.decodeArbitraryJSONObject(from: Data(json.utf8)))
    }

    func testNestedPropertiesRequiredTypesAndClosedObjects() throws {
        let schema = try contract(#"{"type":"object","required":["person"],"additionalProperties":false,"properties":{"person":{"type":"object","required":["name","age"],"additionalProperties":false,"properties":{"name":{"type":"string","minLength":1,"maxLength":8},"age":{"type":"integer","minimum":0,"maximum":120}}}}}"#)
        let valid = #"{"person":{"name":"Ada","age":37}}"#
        XCTAssertNoThrow(try SMLModelCapabilityDriver.decodeOutput(valid, contract: schema))
        for invalid in [#"{}"#, #"{"person":{"name":"Ada"}}"#,
                        #"{"person":{"name":null,"age":37}}"#,
                        #"{"person":{"name":"Ada","age":true}}"#,
                        #"{"person":{"name":"Ada","age":37.5}}"#,
                        #"{"person":{"name":"Ada","age":121}}"#,
                        #"{"person":{"name":"Ada","age":37,"extra":1}}"#,
                        #"{"person":{"name":"Ada","age":37},"extra":1}"#] {
            XCTAssertThrowsError(try SMLModelCapabilityDriver.decodeOutput(invalid, contract: schema), invalid)
        }
    }

    func testArrayItemContractsApplyAtEveryNestedIndex() throws {
        let schema = try contract(#"{"type":"array","minItems":1,"maxItems":2,"items":{"type":"object","required":["score"],"additionalProperties":false,"properties":{"score":{"type":"number","exclusiveMinimum":0,"maximum":1}}}}"#)
        XCTAssertNoThrow(try SMLModelCapabilityDriver.decodeOutput(#"[{"score":0.5},{"score":1}]"#, contract: schema))
        for invalid in ["[]", #"[{"score":0}]"#, #"[{"score":1.1}]"#,
                        #"[{"score":0.5},{"score":"0.5"}]"#,
                        #"[{"score":0.5},{"score":0.5},{"score":0.5}]"#] {
            XCTAssertThrowsError(try SMLModelCapabilityDriver.decodeOutput(invalid, contract: schema), invalid)
        }
        do {
            _ = try SMLModelCapabilityDriver.decodeOutput(#"[{"score":0.5},{"score":false}]"#, contract: schema)
            XCTFail("item mismatch must fail")
        } catch { XCTAssertTrue(String(describing: error).contains("$[1].score")) }
    }

    func testStringLengthsCountUnicodeScalarsAndExplicitStringSchemaRequiresJSON() throws {
        let one = try contract(#"{"type":"string","minLength":1,"maxLength":1}"#)
        XCTAssertEqual(try SMLModelCapabilityDriver.decodeOutput(#""🦉""#, contract: one), .string("🦉"))
        XCTAssertThrowsError(try SMLModelCapabilityDriver.decodeOutput(#""e\u0301""#, contract: one))
        XCTAssertThrowsError(try SMLModelCapabilityDriver.decodeOutput(#""""#, contract: one))
        XCTAssertThrowsError(try SMLModelCapabilityDriver.decodeOutput("plain prose", contract: one))
        let emptyAllowed = try contract(#"{"type":"string","maxLength":0}"#)
        XCTAssertEqual(try SMLModelCapabilityDriver.decodeOutput(#""""#, contract: emptyAllowed), .string(""))
        XCTAssertEqual(try SMLModelCapabilityDriver.decodeOutput("plain prose", type: .string), .string("plain prose"))
    }

    func testOptionalPropertiesAndAdditionalDefaultsFollowSupportedContract() throws {
        let schema = try contract(#"{"type":"object","properties":{"name":{"type":"string"}}}"#)
        XCTAssertNoThrow(try schema.validate(.object([:])))
        XCTAssertNoThrow(try schema.validate(.object(["extra": .null])))
        XCTAssertThrowsError(try schema.validate(.object(["name": .null])))
        let closed = try contract(#"{"type":"object","additionalProperties":false}"#)
        XCTAssertThrowsError(try closed.validate(.object(["extra": .number(1)])))
    }

    func testObjectSizeAndExclusiveNumericBounds() throws {
        let object = try contract(#"{"type":"object","minProperties":1,"maxProperties":2}"#)
        XCTAssertThrowsError(try object.validate(.object([:])))
        XCTAssertNoThrow(try object.validate(.object(["one": .null])))
        XCTAssertThrowsError(try object.validate(.object(["one": .null, "two": .null, "three": .null])))
        let number = try contract(#"{"type":"number","minimum":1,"exclusiveMaximum":2}"#)
        XCTAssertNoThrow(try number.validate(.number(1)))
        XCTAssertThrowsError(try number.validate(.number(2)))
        XCTAssertThrowsError(try number.validate(.bool(true)))
    }

    func testInvalidAndUnsupportedConstraintsFailAtConfigurationTime() throws {
        let invalid = [
            #"{"type":"object","additionalPropertiez":false}"#,
            #"{"type":"string","minimum":1}"#,
            #"{"type":"string","pattern":"x"}"#,
            #"{"type":"object","$ref":"local"}"#,
            #"{"type":["string","null"]}"#,
            #"{"type":"null"}"#,
            #"{"type":"array","items":[{"type":"string"}]}"#,
            #"{"type":"array","minItems":2,"maxItems":1}"#,
            #"{"type":"array","maxItems":1025}"#,
            #"{"type":"string","minLength":-1}"#,
            #"{"type":"string","maxLength":1.5}"#,
            #"{"type":"number","minimum":true}"#,
            #"{"type":"number","minimum":2,"maximum":1}"#,
            #"{"type":"number","minimum":2,"exclusiveMaximum":2}"#,
            #"{"type":"object","required":["missing"]}"#,
            #"{"type":"object","properties":{"x":{"type":"string"}},"required":["x","x"]}"#,
            #"{"type":"object","additionalProperties":{"type":"string"}}"#,
            #"{"type":"object","additionalProperties":false,"minProperties":1}"#,
        ]
        for json in invalid { XCTAssertThrowsError(try contract(json), json) }
    }

    func testSchemaDepthNodeAndPromptSizeLimits() throws {
        var deep: SMLObject = ["type": .string("string")]
        for _ in 0..<10 { deep = ["type": .string("array"), "items": .object(deep)] }
        XCTAssertThrowsError(try SMLModelOutputContract(schema: deep))
        let many = Dictionary(uniqueKeysWithValues: (0..<256).map {
            ("p\($0)", SMLValue.object(["type": .string("boolean")]))
        })
        XCTAssertThrowsError(try SMLModelOutputContract(schema: ["type": .string("object"), "properties": .object(many)]))
        let large = Dictionary(uniqueKeysWithValues: (0..<180).map {
            ("p\($0)" + String(repeating: "x", count: 115), SMLValue.object(["type": .string("boolean")]))
        })
        XCTAssertThrowsError(try SMLModelOutputContract(schema: ["type": .string("object"), "properties": .object(large)]))
    }

    func testStrictDuplicateJSONParsingPrecedesNestedValidation() throws {
        let schema = try contract(#"{"type":"object","properties":{"value":{"type":"integer"}}}"#)
        XCTAssertThrowsError(try SMLModelCapabilityDriver.decodeOutput(#"{"value":1,"value":2}"#, contract: schema)) {
            XCTAssertTrue(String(describing: $0).contains("duplicate"))
        }
    }

    func testModelBindingFileLoadsMixedLegacyAndNestedContractsAndRejectsUnknownKeyword() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent(".kist/sml")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let file = config.appendingPathComponent("models.json")
        let json = #"{"schema_version":1,"purposes":{},"output_schemas":{"legacy":"string","structured":{"type":"object","required":["ok"],"properties":{"ok":{"type":"boolean"}},"additionalProperties":false}}}"#
        try Data(json.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let bindings = try SMLModelPurposeBindings.load(projectRoot: root.path)
        XCTAssertEqual(bindings.outputSchemas["legacy"], .string)
        XCTAssertEqual(bindings.outputSchemas["structured"], .object)
        XCTAssertTrue(try XCTUnwrap(bindings.outputContracts["legacy"]).acceptsPlainText)
        XCTAssertFalse(try XCTUnwrap(bindings.outputContracts["structured"]).acceptsPlainText)
        XCTAssertThrowsError(try bindings.outputContracts["structured"]?.validate(.object([:])))
        try Data(json.replacingOccurrences(of: "additionalProperties", with: "additionalProperty").utf8).write(to: file)
        XCTAssertThrowsError(try SMLModelPurposeBindings.load(projectRoot: root.path)) {
            XCTAssertTrue(String(describing: $0).contains("additionalProperty"))
        }
    }
}
