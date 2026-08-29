import Foundation

/// JSON-compatible data carried by SML command envelopes and workflow instructions.
///
/// Keeping this as a closed value type prevents an importer or model worker from smuggling
/// process-local objects, executable closures, or loosely typed `Any` values into durable state.
public enum SMLValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([SMLValue])
    case object([String: SMLValue])

    public init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            if let count = container.count,
               count > SMLValidationSupport.maximumArrayEntries {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "SML arrays cannot exceed \(SMLValidationSupport.maximumArrayEntries) entries"
                ))
            }

            var values: [SMLValue] = []
            if let count = container.count {
                values.reserveCapacity(count)
            }
            while !container.isAtEnd {
                guard values.count < SMLValidationSupport.maximumArrayEntries else {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: decoder.codingPath,
                        debugDescription: "SML arrays cannot exceed \(SMLValidationSupport.maximumArrayEntries) entries"
                    ))
                }
                values.append(try container.decode(SMLValue.self))
            }
            self = .array(values)
            return
        }

        if let container = try? decoder.container(keyedBy: SMLValueCodingKey.self) {
            let keys = container.allKeys
            guard keys.count <= SMLValidationSupport.maximumObjectEntries else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "SML objects cannot exceed \(SMLValidationSupport.maximumObjectEntries) entries"
                ))
            }

            var values: [String: SMLValue] = [:]
            values.reserveCapacity(keys.count)
            for key in keys {
                values[key.stringValue] = try container.decode(SMLValue.self, forKey: key)
            }
            self = .object(values)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "SML numeric values must be finite"
                )
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unsupported SML value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "SML numeric values must be finite"
                    )
                )
            }
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            guard value.count <= SMLValidationSupport.maximumArrayEntries else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "SML arrays cannot exceed \(SMLValidationSupport.maximumArrayEntries) entries"
                    )
                )
            }
            try container.encode(value)
        case .object(let value):
            guard value.count <= SMLValidationSupport.maximumObjectEntries else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "SML objects cannot exceed "
                            + "\(SMLValidationSupport.maximumObjectEntries) entries"
                    )
                )
            }
            try container.encode(value)
        }
    }
}

private struct SMLValueCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

public typealias SMLObject = [String: SMLValue]

/// A stable, machine-readable compiler or runtime diagnostic.
public struct SMLDiagnostic: Sendable, Codable, Equatable, CustomStringConvertible {
    public enum Severity: String, Sendable, Codable, Equatable {
        case error
        case warning
    }

    public let severity: Severity
    public let code: String
    public let path: String
    public let message: String

    public init(severity: Severity = .error, code: String, path: String, message: String) {
        self.severity = severity
        self.code = code
        self.path = path
        self.message = message
    }

    public var description: String {
        "\(severity.rawValue.uppercased()) \(code) at \(path): \(message)"
    }
}

public struct SMLValidationReport: Sendable, Codable, Equatable {
    public let diagnostics: [SMLDiagnostic]

    public init(diagnostics: [SMLDiagnostic]) {
        self.diagnostics = diagnostics
    }

    public var errors: [SMLDiagnostic] {
        diagnostics.filter { $0.severity == .error }
    }

    public var warnings: [SMLDiagnostic] {
        diagnostics.filter { $0.severity == .warning }
    }

    public var isValid: Bool { errors.isEmpty }
}

enum SMLValidationSupport {
    static let maximumObjectEntries = 256
    static let maximumArrayEntries = 1_024
    static let maximumDepth = 16
    static let maximumStringBytes = 64 * 1_024
    static let maximumValueNodes = 8_192

    static func identifierIsValid(_ value: String, maximumLength: Int = 128,
                                  allowDot: Bool = true) -> Bool {
        guard !value.isEmpty, value.count <= maximumLength,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let number = (48...57).contains(scalar.value)
            let upper = (65...90).contains(scalar.value)
            let lower = (97...122).contains(scalar.value)
            return number || upper || lower || scalar == "_" || scalar == "-"
                || (allowDot && scalar == ".")
        }
    }

    static func inspectObject(_ object: SMLObject, path: String) -> [SMLDiagnostic] {
        var nodes = 0
        return inspectObject(object, path: path, nodes: &nodes)
    }

    static func inspectObject(_ object: SMLObject, path: String,
                              nodes: inout Int) -> [SMLDiagnostic] {
        inspect(.object(object), path: path, depth: 0, nodes: &nodes)
    }

    static func inspectValue(_ value: SMLValue, path: String,
                             nodes: inout Int) -> [SMLDiagnostic] {
        inspect(value, path: path, depth: 0, nodes: &nodes)
    }

    private static func inspect(_ value: SMLValue, path: String, depth: Int,
                                nodes: inout Int) -> [SMLDiagnostic] {
        nodes += 1
        if nodes > maximumValueNodes {
            return [error("value_too_large", path, "value exceeds \(maximumValueNodes) nodes")]
        }
        if depth > maximumDepth {
            return [error("value_too_deep", path, "value exceeds depth \(maximumDepth)")]
        }

        switch value {
        case .null, .bool:
            return []
        case .number(let number):
            return number.isFinite ? [] : [error("non_finite_number", path, "number must be finite")]
        case .string(let string):
            return string.utf8.count <= maximumStringBytes
                ? []
                : [error("string_too_large", path, "string exceeds \(maximumStringBytes) UTF-8 bytes")]
        case .array(let array):
            if array.count > maximumArrayEntries {
                return [error(
                    "array_too_large", path,
                    "array exceeds \(maximumArrayEntries) entries"
                )]
            }
            var diagnostics: [SMLDiagnostic] = []
            for (index, child) in array.enumerated() {
                diagnostics += inspect(child, path: "\(path)[\(index)]", depth: depth + 1, nodes: &nodes)
                if nodes > maximumValueNodes { return diagnostics }
            }
            return diagnostics
        case .object(let object):
            if object.count > maximumObjectEntries {
                return [error(
                    "object_too_large", path,
                    "object exceeds \(maximumObjectEntries) entries"
                )]
            }
            var diagnostics: [SMLDiagnostic] = []
            for key in object.keys.sorted() {
                if !identifierIsValid(key, maximumLength: 128) {
                    diagnostics.append(error(
                        "invalid_object_key", "\(path).\(key)",
                        "keys use letters, numbers, '.', '_', or '-'"
                    ))
                }
                if let child = object[key] {
                    diagnostics += inspect(child, path: "\(path).\(key)", depth: depth + 1, nodes: &nodes)
                    if nodes > maximumValueNodes { return diagnostics }
                }
            }
            return diagnostics
        }
    }

    static func error(_ code: String, _ path: String, _ message: String) -> SMLDiagnostic {
        SMLDiagnostic(code: code, path: path, message: message)
    }
}
