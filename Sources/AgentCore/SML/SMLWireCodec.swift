import Foundation

/// A structurally valid, authority-neutral command candidate.
///
/// An SML command bus must still bind this value to an authenticated principal, current role/task state,
/// worker lease, policy decision, and replay check before producing a separately modeled admission token.
public struct SMLCommandCandidate: Sendable, Equatable {
    let command: SMLCommandEnvelope
    public let validationReport: SMLValidationReport

    init(command: SMLCommandEnvelope, validationReport: SMLValidationReport) {
        self.command = command
        self.validationReport = validationReport
    }

    public var commandID: String { command.commandID }
    public var op: String { command.op }
}

public enum SMLWireCodecError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidLimits
    case inputTooLarge(actual: Int, maximum: Int)
    case depthLimitExceeded(path: String, maximum: Int)
    case nodeLimitExceeded(maximum: Int)
    case collectionLimitExceeded(path: String, actual: Int, maximum: Int)
    case malformedJSON(offset: Int, reason: String)
    case numericLimitExceeded(offset: Int, reason: String)
    case duplicateKey(path: String, key: String)
    case unknownKey(path: String, key: String)
    case decodingFailed(String)
    case structuralValidationFailed(SMLValidationReport)

    public var description: String {
        switch self {
        case .invalidLimits:
            return "SML wire limits must all be positive"
        case .inputTooLarge(let actual, let maximum):
            return "SML wire input is \(actual) bytes; maximum is \(maximum)"
        case .depthLimitExceeded(let path, let maximum):
            return "SML wire value at \(path) exceeds depth \(maximum)"
        case .nodeLimitExceeded(let maximum):
            return "SML wire value exceeds \(maximum) JSON nodes"
        case .collectionLimitExceeded(let path, let actual, let maximum):
            return "SML wire collection at \(path) has \(actual) elements; maximum is \(maximum)"
        case .malformedJSON(let offset, let reason):
            return "malformed SML JSON at byte \(offset): \(reason)"
        case .numericLimitExceeded(let offset, let reason):
            return "SML JSON number at byte \(offset) is outside the wire numeric profile: \(reason)"
        case .duplicateKey(let path, let key):
            return "duplicate SML JSON key '\(key)' at \(path)"
        case .unknownKey(let path, let key):
            return "unknown SML wire key '\(key)' at \(path)"
        case .decodingFailed(let reason):
            return "SML wire decoding failed: \(reason)"
        case .structuralValidationFailed(let report):
            return report.errors.map(\.description).joined(separator: "\n")
        }
    }
}

/// The sole strict JSON ingress for SML workflows and command envelopes.
///
/// The preflight parser runs before `JSONDecoder`: it enforces a byte ceiling, bounds aggregate JSON
/// nodes and nesting, validates strict JSON syntax, and rejects duplicate members (including escaped-key
/// aliases such as `"op"` and `"\u006fp"`). A second pass rejects unknown members at every structural
/// SML object. Objects carried as `SMLValue` remain open to tool/workflow-specific keys.
public enum SMLWireCodec {
    public struct Limits: Sendable, Equatable {
        public let maximumBytes: Int
        public let maximumDepth: Int
        public let maximumNodes: Int

        public init(maximumBytes: Int = 8 * 1_024 * 1_024,
                    maximumDepth: Int = 32,
                    maximumNodes: Int = 100_000) {
            self.maximumBytes = maximumBytes
            self.maximumDepth = maximumDepth
            self.maximumNodes = maximumNodes
        }

        public static let standard = Limits()
    }

    public static func decodeWorkflowImportCandidate(
        from data: Data,
        limits: Limits = .standard
    ) throws -> SMLWorkflowCandidate {
        let tree = try preflight(data, limits: limits)
        try validateWorkflowShape(tree)
        let workflow: SMLWorkflow = try decode(SMLWorkflow.self, from: data)
        do {
            return try SMLWorkflowValidator.requireValidForImport(workflow)
        } catch let error as SMLWorkflowValidationError {
            throw SMLWireCodecError.structuralValidationFailed(error.report)
        }
    }

    public static func decodeCommandCandidate(
        from data: Data,
        limits: Limits = .standard
    ) throws -> SMLCommandCandidate {
        let tree = try preflight(data, limits: limits)
        try validateCommandShape(tree)
        let command: SMLCommandEnvelope = try decode(SMLCommandEnvelope.self, from: data)
        let report = command.validate()
        guard report.isValid else {
            throw SMLWireCodecError.structuralValidationFailed(report)
        }
        return SMLCommandCandidate(command: command, validationReport: report)
    }

    /// Strict ingress for an open SML object such as a generated REPL state payload or a native
    /// model-tool argument object. Resource limits and duplicate-key rejection are identical to the
    /// command/workflow wire boundary; only the object's application-specific member names remain open.
    public static func decodeOpenObject(
        from data: Data,
        limits: Limits = .standard
    ) throws -> SMLObject {
        let tree = try preflight(data, limits: limits)
        guard case .object = tree else {
            throw SMLWireCodecError.decodingFailed("expected a JSON object")
        }
        let object: SMLObject = try decode(SMLObject.self, from: data)
        var nodes = 0
        let diagnostics = SMLValidationSupport.inspectObject(
            object, path: "$", nodes: &nodes
        )
        let report = SMLValidationReport(diagnostics: diagnostics)
        guard report.isValid else {
            throw SMLWireCodecError.structuralValidationFailed(report)
        }
        return object
    }

    private static func preflight(_ data: Data, limits: Limits) throws -> SMLWireJSONNode {
        guard limits.maximumBytes > 0, limits.maximumDepth > 0, limits.maximumNodes > 0 else {
            throw SMLWireCodecError.invalidLimits
        }
        guard data.count <= limits.maximumBytes else {
            throw SMLWireCodecError.inputTooLarge(actual: data.count, maximum: limits.maximumBytes)
        }
        var parser = SMLStrictJSONParser(data: data, limits: limits)
        return try parser.parse()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as SMLWireCodecError {
            throw error
        } catch {
            throw SMLWireCodecError.decodingFailed(String(describing: error))
        }
    }

    private static func validateCommandShape(_ node: SMLWireJSONNode) throws {
        guard let root = try knownObject(
            node,
            path: "$",
            keys: [
                "schema_version", "command_id", "actor", "role", "task", "op",
                "arguments", "scope", "expected_state", "issued_at_epoch",
            ]
        ) else { return }

        // These three fields intentionally carry open `SMLValue` objects. The strict parser has already
        // bounded and duplicate-checked their complete subtrees, so no structural-key walk is needed.
        _ = root
    }

    private static func validateWorkflowShape(_ node: SMLWireJSONNode) throws {
        guard let root = try knownObject(
            node,
            path: "$",
            keys: [
                "ir_version", "id", "version", "name", "source", "trigger",
                "state_schema", "interface", "entrypoint", "instructions",
            ]
        ) else { return }

        if let source = root["source"] {
            _ = try knownObject(source, path: "$.source", keys: ["kind", "reference", "digest"])
        }
        if let trigger = root["trigger"] {
            _ = try knownObject(trigger, path: "$.trigger", keys: ["kind", "value"])
        }
        if let fields = root["state_schema"],
           let values = try boundedArray(fields, path: "$.state_schema", maximum: 512) {
            for (index, value) in values.enumerated() {
                _ = try knownObject(
                    value,
                    path: "$.state_schema[\(index)]",
                    keys: ["name", "type", "required", "nullable", "description"]
                )
            }
        }
        if let interfaceNode = root["interface"],
           let interface = try knownObject(
               interfaceNode,
               path: "$.interface",
               keys: ["input_fields", "output_fields"]
           ) {
            for key in ["input_fields", "output_fields"] {
                if let fields = interface[key] {
                    _ = try boundedArray(
                        fields, path: "$.interface.\(key)", maximum: 512
                    )
                }
            }
        }
        if let instructions = root["instructions"],
           let values = try boundedArray(instructions, path: "$.instructions", maximum: 4_096) {
            for (index, value) in values.enumerated() {
                try validateInstructionShape(value, path: "$.instructions[\(index)]")
            }
        }
    }

    private static func validateInstructionShape(_ node: SMLWireJSONNode, path: String) throws {
        guard let instruction = try knownObject(
            node,
            path: path,
            keys: [
                "id", "op", "source", "purpose", "capability", "workflow", "verifier",
                "output_schema", "reason", "owner", "arguments", "scope", "expected_state",
                "condition", "plugin", "retry_policy", "receipt_fields", "next", "on_pass",
                "on_failure", "true", "false",
            ]
        ) else { return }

        if let condition = instruction["condition"] {
            try validateConditionShape(condition, path: "\(path).condition")
        }
        if let pluginNode = instruction["plugin"],
           let plugin = try knownObject(
                pluginNode,
                path: "\(path).plugin",
                keys: [
                    "id", "reads", "writes", "side_effect_level", "preconditions",
                    "postconditions", "rollback", "verifier",
                ]
            ) {
            for key in ["reads", "writes", "preconditions", "postconditions"] {
                if let list = plugin[key] {
                    _ = try boundedArray(
                        list,
                        path: "\(path).plugin.\(key)",
                        maximum: 256
                    )
                }
            }
        }
        if let retry = instruction["retry_policy"] {
            _ = try knownObject(
                retry,
                path: "\(path).retry_policy",
                keys: ["target", "maximum_attempts", "backoff_seconds"]
            )
        }
        if let receiptFields = instruction["receipt_fields"] {
            _ = try boundedArray(
                receiptFields,
                path: "\(path).receipt_fields",
                maximum: 128
            )
        }
        // arguments, scope, and expected_state are deliberately open SMLValue-bearing objects.
    }

    private static func validateConditionShape(_ node: SMLWireJSONNode, path: String) throws {
        guard let condition = try knownObject(
            node, path: path, keys: ["combination", "clauses"]
        ) else { return }
        guard let clauses = condition["clauses"],
              let values = try boundedArray(
                  clauses,
                  path: "\(path).clauses",
                  maximum: 32
              ) else { return }
        for (index, value) in values.enumerated() {
            // `value` is an open SMLValue subtree; only the clause wrapper itself is closed.
            _ = try knownObject(
                value,
                path: "\(path).clauses[\(index)]",
                keys: ["field", "op", "value"]
            )
        }
    }

    private static func boundedArray(
        _ node: SMLWireJSONNode,
        path: String,
        maximum: Int
    ) throws -> [SMLWireJSONNode]? {
        guard case .array(let values) = node else { return nil }
        guard values.count <= maximum else {
            throw SMLWireCodecError.collectionLimitExceeded(
                path: path,
                actual: values.count,
                maximum: maximum
            )
        }
        return values
    }

    private static func knownObject(_ node: SMLWireJSONNode, path: String,
                                    keys: Set<String>) throws -> [String: SMLWireJSONNode]? {
        guard case .object(let object) = node else { return nil }
        if let unknown = object.keys.filter({ !keys.contains($0) }).sorted().first {
            throw SMLWireCodecError.unknownKey(path: path, key: unknown)
        }
        return object
    }
}

private indirect enum SMLWireJSONNode {
    case object([String: SMLWireJSONNode])
    case array([SMLWireJSONNode])
    case scalar
}

/// A small strict JSON recognizer used only to establish resource and member-name safety before
/// Foundation materializes the Codable graph. It intentionally retains no scalar values.
private struct SMLStrictJSONParser {
    private static let maximumMemberNameBytes = 128
    private static let maximumRenderedPathBytes = 256
    private static let maximumNumberBytes = 256
    private static let maximumExponentDigits = 4

    private let bytes: [UInt8]
    private let limits: SMLWireCodec.Limits
    private var index = 0
    private var nodes = 0

    init(data: Data, limits: SMLWireCodec.Limits) {
        self.bytes = Array(data)
        self.limits = limits
    }

    mutating func parse() throws -> SMLWireJSONNode {
        skipWhitespace()
        let result = try parseValue(depth: 1, path: "$")
        skipWhitespace()
        guard index == bytes.count else {
            throw malformed("unexpected bytes after the top-level JSON value")
        }
        return result
    }

    private mutating func parseValue(depth: Int, path: String) throws -> SMLWireJSONNode {
        guard index < bytes.count else { throw malformed("expected a JSON value") }
        guard depth <= limits.maximumDepth else {
            throw SMLWireCodecError.depthLimitExceeded(path: path, maximum: limits.maximumDepth)
        }
        nodes += 1
        guard nodes <= limits.maximumNodes else {
            throw SMLWireCodecError.nodeLimitExceeded(maximum: limits.maximumNodes)
        }

        switch bytes[index] {
        case 0x7B: // {
            return try parseObject(depth: depth, path: path)
        case 0x5B: // [
            return try parseArray(depth: depth, path: path)
        case 0x22: // "
            _ = try parseString()
            return .scalar
        case 0x74: // true
            try consumeLiteral([0x74, 0x72, 0x75, 0x65])
            return .scalar
        case 0x66: // false
            try consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
            return .scalar
        case 0x6E: // null
            try consumeLiteral([0x6E, 0x75, 0x6C, 0x6C])
            return .scalar
        case 0x2D, 0x30...0x39: // - or digit
            try parseNumber()
            return .scalar
        default:
            throw malformed("expected an object, array, string, number, boolean, or null")
        }
    }

    private mutating func parseObject(depth: Int, path: String) throws -> SMLWireJSONNode {
        index += 1 // {
        skipWhitespace()
        if consume(0x7D) { return .object([:]) }

        var object: [String: SMLWireJSONNode] = [:]
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw malformed("object member names must be strings")
            }
            let key = try parseString(maximumDecodedBytes: Self.maximumMemberNameBytes)
            guard object[key] == nil else {
                throw SMLWireCodecError.duplicateKey(path: path, key: key)
            }
            skipWhitespace()
            guard consume(0x3A) else { throw malformed("expected ':' after object member name") }
            skipWhitespace()
            let childPath = pathForObjectChild(parent: path, key: key)
            object[key] = try parseValue(depth: depth + 1, path: childPath)
            skipWhitespace()
            if consume(0x7D) { return .object(object) }
            guard consume(0x2C) else { throw malformed("expected ',' or '}' in object") }
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int, path: String) throws -> SMLWireJSONNode {
        index += 1 // [
        skipWhitespace()
        if consume(0x5D) { return .array([]) }

        var array: [SMLWireJSONNode] = []
        while true {
            let childPath = pathForArrayChild(parent: path, index: array.count)
            array.append(try parseValue(depth: depth + 1, path: childPath))
            skipWhitespace()
            if consume(0x5D) { return .array(array) }
            guard consume(0x2C) else { throw malformed("expected ',' or ']' in array") }
            skipWhitespace()
        }
    }

    private mutating func parseString(maximumDecodedBytes: Int? = nil) throws -> String {
        guard consume(0x22) else { throw malformed("expected a JSON string") }
        var decoded: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case 0x22:
                guard let string = String(bytes: decoded, encoding: .utf8) else {
                    throw malformed("string is not valid UTF-8")
                }
                return string
            case 0x5C:
                try parseEscape(into: &decoded)
            case 0x00...0x1F:
                throw malformed("unescaped control byte in string")
            default:
                decoded.append(byte)
            }
            if let maximumDecodedBytes, decoded.count > maximumDecodedBytes {
                throw malformed(
                    "object member name exceeds \(maximumDecodedBytes) decoded UTF-8 bytes"
                )
            }
        }
        throw malformed("unterminated string")
    }

    private mutating func parseEscape(into decoded: inout [UInt8]) throws {
        guard index < bytes.count else { throw malformed("unterminated string escape") }
        let escape = bytes[index]
        index += 1
        switch escape {
        case 0x22, 0x5C, 0x2F:
            decoded.append(escape)
        case 0x62:
            decoded.append(0x08)
        case 0x66:
            decoded.append(0x0C)
        case 0x6E:
            decoded.append(0x0A)
        case 0x72:
            decoded.append(0x0D)
        case 0x74:
            decoded.append(0x09)
        case 0x75:
            let first = try parseHexQuad()
            let scalarValue: UInt32
            if (0xD800...0xDBFF).contains(first) {
                guard index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
                    throw malformed("high surrogate must be followed by a low surrogate")
                }
                index += 2
                let second = try parseHexQuad()
                guard (0xDC00...0xDFFF).contains(second) else {
                    throw malformed("high surrogate must be followed by a low surrogate")
                }
                scalarValue = 0x10000
                    + (UInt32(first - 0xD800) << 10)
                    + UInt32(second - 0xDC00)
            } else {
                guard !(0xDC00...0xDFFF).contains(first) else {
                    throw malformed("unpaired low surrogate")
                }
                scalarValue = UInt32(first)
            }
            guard let scalar = UnicodeScalar(scalarValue) else {
                throw malformed("invalid Unicode scalar")
            }
            decoded.append(contentsOf: String(scalar).utf8)
        default:
            throw malformed("unsupported string escape")
        }
    }

    private mutating func parseHexQuad() throws -> UInt16 {
        guard index + 4 <= bytes.count else { throw malformed("incomplete Unicode escape") }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            index += 1
            let nibble: UInt16
            switch byte {
            case 0x30...0x39: nibble = UInt16(byte - 0x30)
            case 0x41...0x46: nibble = UInt16(byte - 0x41 + 10)
            case 0x61...0x66: nibble = UInt16(byte - 0x61 + 10)
            default: throw malformed("invalid hexadecimal digit in Unicode escape")
            }
            value = (value << 4) | nibble
        }
        return value
    }

    private mutating func parseNumber() throws {
        let start = index
        if consume(0x2D), index == bytes.count { throw malformed("incomplete number") }
        guard index < bytes.count else { throw malformed("incomplete number") }

        if consume(0x30) {
            if index < bytes.count, isDigit(bytes[index]) {
                throw malformed("leading zero in number")
            }
        } else {
            guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else {
                throw malformed("invalid integer component")
            }
            index += 1
            while index < bytes.count, isDigit(bytes[index]) {
                index += 1
                try enforceNumberLength(from: start)
            }
        }

        if consume(0x2E) {
            guard index < bytes.count, isDigit(bytes[index]) else {
                throw malformed("fraction requires at least one digit")
            }
            while index < bytes.count, isDigit(bytes[index]) {
                index += 1
                try enforceNumberLength(from: start)
            }
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
            guard index < bytes.count, isDigit(bytes[index]) else {
                throw malformed("exponent requires at least one digit")
            }
            var exponentDigits = 0
            while index < bytes.count, isDigit(bytes[index]) {
                index += 1
                exponentDigits += 1
                guard exponentDigits <= Self.maximumExponentDigits else {
                    throw SMLWireCodecError.numericLimitExceeded(
                        offset: start,
                        reason: "exponent exceeds \(Self.maximumExponentDigits) digits"
                    )
                }
                try enforceNumberLength(from: start)
            }
        }
        try enforceNumberLength(from: start)
        try validateDecimalLexeme(from: start, to: index)
    }

    /// Foundation Decimal carries at most 38 significant digits with a normalized base-10 exponent in
    /// -128...127. Validate the original token so JSONDecoder cannot silently round an oversized value.
    private func validateDecimalLexeme(from start: Int, to end: Int) throws {
        var cursor = start
        if bytes[cursor] == 0x2D { cursor += 1 }

        var coefficientDigits: [UInt8] = []
        coefficientDigits.reserveCapacity(end - cursor)
        var fractionalDigits = 0
        var inFraction = false
        while cursor < end, bytes[cursor] != 0x65, bytes[cursor] != 0x45 {
            let byte = bytes[cursor]
            cursor += 1
            if byte == 0x2E {
                inFraction = true
                continue
            }
            coefficientDigits.append(byte)
            if inFraction { fractionalDigits += 1 }
        }

        var explicitExponent = 0
        if cursor < end {
            cursor += 1 // e or E
            var negative = false
            if cursor < end, bytes[cursor] == 0x2B || bytes[cursor] == 0x2D {
                negative = bytes[cursor] == 0x2D
                cursor += 1
            }
            while cursor < end {
                explicitExponent = explicitExponent * 10 + Int(bytes[cursor] - 0x30)
                cursor += 1
            }
            if negative { explicitExponent = -explicitExponent }
        }

        guard let firstNonzero = coefficientDigits.firstIndex(where: { $0 != 0x30 }) else {
            return // Every lexical representation of zero is canonicalizable without Decimal rounding.
        }
        let lastNonzero = coefficientDigits.lastIndex(where: { $0 != 0x30 }) ?? firstNonzero
        let significantDigits = lastNonzero - firstNonzero + 1
        let trailingZeroes = coefficientDigits.count - lastNonzero - 1
        let normalizedExponent = explicitExponent - fractionalDigits + trailingZeroes

        guard significantDigits <= 38 else {
            throw SMLWireCodecError.numericLimitExceeded(
                offset: start,
                reason: "normalized coefficient has \(significantDigits) significant digits; maximum is 38"
            )
        }
        guard (-128...127).contains(normalizedExponent) else {
            throw SMLWireCodecError.numericLimitExceeded(
                offset: start,
                reason: "normalized exponent \(normalizedExponent) is outside -128...127"
            )
        }
    }

    private func enforceNumberLength(from start: Int) throws {
        guard index - start <= Self.maximumNumberBytes else {
            throw SMLWireCodecError.numericLimitExceeded(
                offset: start,
                reason: "numeric token exceeds \(Self.maximumNumberBytes) bytes"
            )
        }
    }

    private mutating func consumeLiteral(_ literal: [UInt8]) throws {
        guard index + literal.count <= bytes.count,
              Array(bytes[index..<(index + literal.count)]) == literal else {
            throw malformed("invalid JSON literal")
        }
        index += literal.count
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    private func pathForObjectChild(parent: String, key: String) -> String {
        let simple = !key.isEmpty && key.unicodeScalars.allSatisfy {
            (0x30...0x39).contains($0.value)
                || (0x41...0x5A).contains($0.value)
                || (0x61...0x7A).contains($0.value)
                || $0 == "_" || $0 == "-"
        }
        let candidate = simple ? "\(parent).\(key)" : "\(parent)[member]"
        return boundedPath(candidate)
    }

    private func pathForArrayChild(parent: String, index: Int) -> String {
        boundedPath("\(parent)[\(index)]")
    }

    private func boundedPath(_ candidate: String) -> String {
        candidate.utf8.count <= Self.maximumRenderedPathBytes ? candidate : "$[nested]"
    }

    private func malformed(_ reason: String) -> SMLWireCodecError {
        .malformedJSON(offset: index, reason: reason)
    }
}
