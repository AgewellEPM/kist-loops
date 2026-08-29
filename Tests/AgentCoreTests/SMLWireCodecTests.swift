import XCTest
@testable import AgentCore

final class SMLWireCodecTests: XCTestCase {
    func testCommandIngressAppliesOnlyNonAuthorityDefaults() throws {
        let candidate = try SMLWireCodec.decodeCommandCandidate(from: data(#"""
        {
          "schema_version": 1,
          "command_id": "command-1842",
          "actor": "operator.luke",
          "role": "digital-presence-manager",
          "task": "TASK-1842",
          "op": "workflow.run",
          "issued_at_epoch": 1777000000
        }
        """#))

        XCTAssertEqual(candidate.commandID, "command-1842")
        XCTAssertEqual(candidate.op, "workflow.run")
        XCTAssertEqual(candidate.command.arguments, [:])
        XCTAssertEqual(candidate.command.scope, [:])
        XCTAssertEqual(candidate.command.expectedState, [:])
        XCTAssertTrue(candidate.validationReport.isValid)
    }

    func testWorkflowIngressAppliesNestedWireDefaults() throws {
        let candidate = try SMLWireCodec.decodeWorkflowImportCandidate(from: minimalWorkflow())
        let workflow = candidate.workflow

        XCTAssertEqual(workflow.id, "wire.minimal")
        XCTAssertEqual(workflow.instructions.count, 1)
        XCTAssertEqual(workflow.instructions[0].arguments, [:])
        XCTAssertEqual(workflow.instructions[0].scope, [:])
        XCTAssertEqual(workflow.instructions[0].expectedState, [:])
        XCTAssertEqual(workflow.instructions[0].receiptFields, [])
    }

    func testCommandSMLValueObjectsRemainOpenToDomainKeys() throws {
        let candidate = try SMLWireCodec.decodeCommandCandidate(from: data(#"""
        {
          "schema_version": 1,
          "command_id": "command-open-values",
          "actor": "operator.luke",
          "role": "operator",
          "task": "TASK-open-values",
          "op": "workflow.run",
          "arguments": {"future_argument": {"nested_extension": true}},
          "scope": {"tenant_partition": "alpha"},
          "expected_state": {"domain_phase": "queued"},
          "issued_at_epoch": 1777000000
        }
        """#))

        XCTAssertEqual(
            candidate.command.arguments["future_argument"],
            .object(["nested_extension": .bool(true)])
        )
        XCTAssertEqual(candidate.command.scope["tenant_partition"], .string("alpha"))
        XCTAssertEqual(candidate.command.expectedState["domain_phase"], .string("queued"))
    }

    func testEscapedDuplicateStructuralKeyIsRejectedBeforeDecode() {
        assertWireError(
            data(#"{"op":"workflow.run","\u006fp":"workflow.stop"}"#)
        ) { error in
            guard case .duplicateKey(let path, let key) = error else { return false }
            return path == "$" && key == "op"
        }
    }

    func testDuplicateKeyInsideOpenSMLValueIsStillRejected() {
        assertWireError(
            data(#"{"arguments":{"x":1,"\u0078":2}}"#)
        ) { error in
            guard case .duplicateKey(let path, let key) = error else { return false }
            return path == "$.arguments" && key == "x"
        }
    }

    func testUnknownStructuralKeyIsRejectedRecursively() {
        assertWorkflowWireError(workflowWithInstructionExtra(#", "surprise": true"#)) { error in
            guard case .unknownKey(let path, let key) = error else { return false }
            return path == "$.instructions[0]" && key == "surprise"
        }
    }

    func testRemovedPluginTrustFieldsAreRejectedByWireSchema() {
        let input = data(#"""
        {
          "ir_version": 1,
          "id": "plugin.wire",
          "version": "1.0.0",
          "name": "Plugin wire",
          "source": {"kind": "langgraph", "reference": "plugin.py"},
          "trigger": {"kind": "manual"},
          "state_schema": [],
          "entrypoint": "plugin",
          "instructions": [
            {
              "id": "plugin",
              "op": "RUN_PLUGIN",
              "plugin": {"id": "opaque", "trust_status": "verified"},
              "next": "done"
            },
            {"id": "done", "op": "COMPLETE"}
          ]
        }
        """#)

        assertWorkflowWireError(input) { error in
            guard case .unknownKey(let path, let key) = error else { return false }
            return path == "$.instructions[0].plugin" && key == "trust_status"
        }
    }

    func testCurrentPluginSchemaAcceptsConservativeOmittedDefaultsAsImportCandidate() throws {
        let input = data(#"""
        {
          "ir_version": 1,
          "id": "plugin.wire",
          "version": "1.0.0",
          "name": "Plugin wire",
          "source": {"kind": "langgraph", "reference": "plugin.py"},
          "trigger": {"kind": "manual"},
          "state_schema": [],
          "entrypoint": "plugin",
          "instructions": [
            {"id": "plugin", "op": "RUN_PLUGIN", "plugin": {"id": "opaque"}, "next": "done"},
            {"id": "done", "op": "COMPLETE"}
          ]
        }
        """#)

        let candidate = try SMLWireCodec.decodeWorkflowImportCandidate(from: input)
        let plugin = try XCTUnwrap(candidate.workflow.instructions[0].plugin)
        XCTAssertEqual(plugin.sideEffectLevel, .unknown)
        XCTAssertEqual(plugin.reads, [])
        XCTAssertEqual(plugin.writes, [])
        XCTAssertEqual(plugin.preconditions, [])
        XCTAssertEqual(plugin.postconditions, [])
    }

    func testOpenSMLValueKeysAreNotTreatedAsStructuralExtensions() throws {
        let input = data(#"""
        {
          "ir_version": 1,
          "id": "condition.open-value",
          "version": "1.0.0",
          "name": "Open condition value",
          "source": {"kind": "native", "reference": "test"},
          "trigger": {"kind": "manual"},
          "state_schema": [{"name": "payload", "type": "object"}],
          "entrypoint": "branch",
          "instructions": [
            {
              "id": "branch",
              "op": "BRANCH",
              "condition": {
                "clauses": [{
                  "field": "payload",
                  "op": "equals",
                  "value": {"vendor_extension": {"future_field": true}}
                }]
              },
              "true": "yes",
              "false": "no"
            },
            {"id": "yes", "op": "COMPLETE"},
            {"id": "no", "op": "COMPLETE"}
          ]
        }
        """#)

        let candidate = try SMLWireCodec.decodeWorkflowImportCandidate(from: input)
        let condition = try XCTUnwrap(candidate.workflow.instructions[0].condition)
        XCTAssertEqual(condition.combination, .all)
        XCTAssertEqual(
            condition.clauses[0].value,
            .object(["vendor_extension": .object(["future_field": .bool(true)])])
        )
    }

    func testByteDepthAndNodeLimitsRunBeforeCodable() {
        assertWireError(
            data("{}"),
            limits: .init(maximumBytes: 1, maximumDepth: 10, maximumNodes: 10)
        ) { error in
            guard case .inputTooLarge(actual: 2, maximum: 1) = error else { return false }
            return true
        }

        assertWireError(
            data("[[]]"),
            limits: .init(maximumBytes: 16, maximumDepth: 1, maximumNodes: 10)
        ) { error in
            guard case .depthLimitExceeded(path: "$[0]", maximum: 1) = error else { return false }
            return true
        }

        assertWireError(
            data("[null,null]"),
            limits: .init(maximumBytes: 32, maximumDepth: 10, maximumNodes: 2)
        ) { error in
            guard case .nodeLimitExceeded(maximum: 2) = error else { return false }
            return true
        }
    }

    func testStructuralCollectionLimitsRunBeforeCodable() {
        let oversizedStateSchema = repeatedNullArray(count: 513)
        assertWorkflowWireError(data("{\"state_schema\":\(oversizedStateSchema)}")) { error in
            error == .collectionLimitExceeded(path: "$.state_schema", actual: 513, maximum: 512)
        }

        let oversizedInstructions = repeatedNullArray(count: 4_097)
        assertWorkflowWireError(data("{\"instructions\":\(oversizedInstructions)}")) { error in
            error == .collectionLimitExceeded(path: "$.instructions", actual: 4_097, maximum: 4_096)
        }

        let oversizedClauses = repeatedNullArray(count: 33)
        assertWorkflowWireError(
            data("{\"instructions\":[{\"condition\":{\"clauses\":\(oversizedClauses)}}]}")
        ) { error in
            error == .collectionLimitExceeded(
                path: "$.instructions[0].condition.clauses",
                actual: 33,
                maximum: 32
            )
        }

        let oversizedPluginList = repeatedNullArray(count: 257)
        for field in ["reads", "writes", "preconditions", "postconditions"] {
            assertWorkflowWireError(
                data("{\"instructions\":[{\"plugin\":{\"\(field)\":\(oversizedPluginList)}}]}")
            ) { error in
                error == .collectionLimitExceeded(
                    path: "$.instructions[0].plugin.\(field)",
                    actual: 257,
                    maximum: 256
                )
            }
        }

        let oversizedReceiptFields = repeatedNullArray(count: 129)
        assertWorkflowWireError(
            data("{\"instructions\":[{\"receipt_fields\":\(oversizedReceiptFields)}]}")
        ) { error in
            error == .collectionLimitExceeded(
                path: "$.instructions[0].receipt_fields",
                actual: 129,
                maximum: 128
            )
        }
    }

    func testDecimalCoefficientLimitRejectsRoundingBeforeCodable() throws {
        let thirtyEightNines = String(repeating: "9", count: 38)
        XCTAssertNoThrow(
            try SMLWireCodec.decodeCommandCandidate(
                from: commandWithNumber(thirtyEightNines + "0")
            ),
            "a trailing zero normalizes into the exponent instead of adding coefficient precision"
        )

        assertWireError(commandWithNumber(String(repeating: "9", count: 39))) { error in
            guard case .numericLimitExceeded(_, let reason) = error else { return false }
            return reason.contains("39 significant digits")
        }
    }

    func testDecimalNormalizedExponentBoundaries() throws {
        for accepted in ["1e127", "1e-128", "10e126", "0.1e-127"] {
            XCTAssertNoThrow(
                try SMLWireCodec.decodeCommandCandidate(from: commandWithNumber(accepted)),
                "expected normalized Decimal boundary to accept \(accepted)"
            )
        }

        for rejected in ["1e128", "1e-129", "10e127", "0.1e-128"] {
            assertWireError(commandWithNumber(rejected)) { error in
                guard case .numericLimitExceeded(_, let reason) = error else { return false }
                return reason.contains("normalized exponent")
            }
        }
    }

    func testExponentLexemeLengthIsBounded() {
        assertWireError(commandWithNumber("1e00000")) { error in
            guard case .numericLimitExceeded(_, let reason) = error else { return false }
            return reason.contains("exponent exceeds 4 digits")
        }
    }

    func testDecodedButStructurallyInvalidCommandDoesNotProduceCandidate() {
        let input = data(#"""
        {
          "schema_version": 99,
          "command_id": "bad command",
          "actor": "operator",
          "role": "role",
          "task": "task",
          "op": "workflow.run",
          "issued_at_epoch": -1
        }
        """#)

        assertWireError(input) { error in
            guard case .structuralValidationFailed(let report) = error else { return false }
            let codes = Set(report.errors.map(\.code))
            return codes.contains("unsupported_schema")
                && codes.contains("invalid_identifier")
                && codes.contains("invalid_timestamp")
        }
    }

    func testMalformedJSONIsRejectedByStrictPreflight() {
        assertWireError(data(#"{"op":"workflow.run",}"#)) { error in
            guard case .malformedJSON = error else { return false }
            return true
        }
    }

    func testOversizedMemberNameIsRejectedBeforeDescendingIntoItsValue() {
        let oversizedKey = String(repeating: "k", count: 129)
        let input = data("{\"\(oversizedKey)\":\(repeatedNullArray(count: 1_000))}")

        assertWireError(
            input,
            limits: .init(maximumBytes: input.count, maximumDepth: 10, maximumNodes: 1)
        ) { error in
            guard case .malformedJSON(_, let reason) = error else { return false }
            return reason.contains("object member name exceeds 128 decoded UTF-8 bytes")
        }
    }

    private func minimalWorkflow() -> Data {
        data(#"""
        {
          "ir_version": 1,
          "id": "wire.minimal",
          "version": "1.0.0",
          "name": "Minimal",
          "source": {"kind": "native", "reference": "test"},
          "trigger": {"kind": "manual"},
          "state_schema": [],
          "entrypoint": "done",
          "instructions": [{"id": "done", "op": "COMPLETE"}]
        }
        """#)
    }

    private func workflowWithInstructionExtra(_ extra: String) -> Data {
        data("""
        {
          "ir_version": 1,
          "id": "wire.extra",
          "version": "1.0.0",
          "name": "Extra",
          "source": {"kind": "native", "reference": "test"},
          "trigger": {"kind": "manual"},
          "state_schema": [],
          "entrypoint": "done",
          "instructions": [{"id": "done", "op": "COMPLETE"\(extra)}]
        }
        """)
    }

    private func commandWithNumber(_ number: String) -> Data {
        data("""
        {
          "schema_version": 1,
          "command_id": "command-number",
          "actor": "operator.luke",
          "role": "operator",
          "task": "TASK-number",
          "op": "workflow.run",
          "arguments": {"number": \(number)},
          "issued_at_epoch": 1777000000
        }
        """)
    }

    private func repeatedNullArray(count: Int) -> String {
        "[" + Array(repeating: "null", count: count).joined(separator: ",") + "]"
    }

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }

    private func assertWireError(
        _ input: Data,
        limits: SMLWireCodec.Limits = .standard,
        file: StaticString = #filePath,
        line: UInt = #line,
        matches: (SMLWireCodecError) -> Bool
    ) {
        XCTAssertThrowsError(
            try SMLWireCodec.decodeCommandCandidate(from: input, limits: limits),
            file: file,
            line: line
        ) { error in
            guard let wireError = error as? SMLWireCodecError else {
                return XCTFail("unexpected error: \(error)", file: file, line: line)
            }
            XCTAssertTrue(matches(wireError), "unexpected wire error: \(wireError)", file: file, line: line)
        }
    }

    private func assertWorkflowWireError(
        _ input: Data,
        limits: SMLWireCodec.Limits = .standard,
        file: StaticString = #filePath,
        line: UInt = #line,
        matches: (SMLWireCodecError) -> Bool
    ) {
        XCTAssertThrowsError(
            try SMLWireCodec.decodeWorkflowImportCandidate(from: input, limits: limits),
            file: file,
            line: line
        ) { error in
            guard let wireError = error as? SMLWireCodecError else {
                return XCTFail("unexpected error: \(error)", file: file, line: line)
            }
            XCTAssertTrue(matches(wireError), "unexpected wire error: \(wireError)", file: file, line: line)
        }
    }
}
